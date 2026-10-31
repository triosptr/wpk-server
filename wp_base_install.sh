#!/bin/bash
# =============================================================
# WP-BASE — Golden base install untuk server WordPress baru
# Server kecil (1GB/2GB RAM) tapi kuat trafik besar.
# Ubuntu 22/24 + Nginx + PHP 8.3 FPM + MariaDB + WP-CLI
# + Security tingkat tinggi + Optimasi memori penuh.
# IDEMPOTENT — aman dijalankan ulang.
# Jalankan: bash wp_base_install.sh
# =============================================================
set +e

echo "===== WP-BASE $(hostname) @ $(date -u +%Y-%m-%dT%H:%M:%SZ) ====="

# ---------- 0) Cek root ----------
[ "$(id -u)" = 0 ] || { echo "HARUS root"; exit 1; }

# ---------- 1) Base packages ----------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx mariadb-server curl git unzip ufw fail2ban \
  software-properties-common gnupg2 lsb-release

# PHP 8.3 (Ondrej PPA, fallback repo distro)
if ! php -v 2>/dev/null | grep -q '8.3'; then
  add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 || true
  apt-get update -qq
fi
apt-get install -y -qq php8.3-fpm php8.3-cli php8.3-mysql php8.3-curl \
  php8.3-gd php8.3-xml php8.3-zip php8.3-mbstring php8.3-intl \
  php8.3-opcache php8.3-bcmath php8.3-imagick >/dev/null 2>&1

# WP-CLI
if [ ! -x /usr/local/bin/wp ]; then
  curl -sS https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
  chmod +x /usr/local/bin/wp
fi

# ---------- 2) SWAP (anti-OOM, wajib utk server kecil) ----------
if ! swapon --show | grep -q .; then
  echo "[swap] menambah 4G swapfile"
  (fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none)
  chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
cat > /etc/sysctl.d/99-tune.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
net.core.somaxconn=1024
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
EOF
sysctl --system >/dev/null 2>&1

# ---------- 3) MariaDB hemat memori ----------
cat > /etc/mysql/mariadb.conf.d/99-tune.cnf <<'EOF'
[mysqld]
# profil hemat 1-2GB RAM, cukup utk 10-20 situs WP trafik menengah
innodb_buffer_pool_size = 128M
innodb_log_file_size    = 32M
innodb_flush_method     = O_DIRECT
innodb_flush_log_at_trx_commit = 2
key_buffer_size         = 8M
max_connections         = 60
tmp_table_size          = 16M
max_heap_table_size     = 16M
table_open_cache        = 400
performance_schema      = OFF
skip-name-resolve
bind-address            = 127.0.0.1
slow_query_log          = OFF
EOF
systemctl restart mariadb

# MariaDB secure: root unix_socket + hapus anon/test
mysql -e "DELETE FROM mysql.user WHERE User=''; DELETE FROM mysql.db WHERE Db LIKE 'test%'; DROP DATABASE IF EXISTS test; FLUSH PRIVILEGES;" 2>/dev/null

# ---------- 4) PHP-FPM: ondemand + tuning (inti hemat RAM) ----------
PHPV=8.3
mkdir -p /etc/php/$PHPV/fpm/pool.d

# Global php.ini
P=/etc/php/$PHPV/fpm/php.ini
sed -i 's/^memory_limit = .*/memory_limit = 192M/'  $P
sed -i 's/^max_execution_time = .*/max_execution_time = 120/' $P
sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 32M/' $P
sed -i 's/^post_max_size = .*/post_max_size = 32M/' $P
sed -i 's/^expose_php = .*/expose_php = Off/' $P
sed -i 's/^;?date.timezone =.*/date.timezone = Asia\/Jakarta/' $P

# OPcache agresif (tanpa tambah RAM besar, performa naik besar)
cat > /etc/php/$PHPV/fpm/conf.d/90-opcache.ini <<'EOF'
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=16000
opcache.validate_timestamps=1
opcache.revalidate_freq=60
opcache.save_comments=1
EOF

# Pool "wp" ondemand — worker baru lahir hanya saat trafik datang.
# Ini kunci "server kecil kuat trafik": idle = ~0 worker, puncak =
# max_children sesuai RAM. Rumus: max_children = RAM_free_MB / 60MB.
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
if   [ "$RAM_MB" -ge 3800 ]; then MAXC=40
elif [ "$RAM_MB" -ge 1800 ]; then MAXC=20
else MAXC=10; fi

cat > /etc/php/$PHPV/fpm/pool.d/wp.conf <<EOF
[wp]
user = www-data
group = www-data
listen = /run/php/php$PHPV-fpm-wp.sock
listen.owner = www-data
listen.group = www-data
pm = ondemand
pm.max_children = $MAXC
pm.process_idle_timeout = 20s
pm.max_requests = 500
; hemat + matikan warning spam di level system
php_admin_flag[log_errors] = off
php_admin_value[error_log] = /var/log/php-fpm/wp-error.log
; security
php_admin_flag[allow_url_include] = off
php_admin_value[open_basedir] = /var/www:/tmp:/var/lib/php/sessions
EOF

# matikan pool default www (tidak dipakai — semua vhost pakai pool wp)
if [ -f /etc/php/$PHPV/fpm/pool.d/www.conf ]; then
  mv /etc/php/$PHPV/fpm/pool.d/www.conf /etc/php/$PHPV/fpm/pool.d/www.conf.disabled
fi
mkdir -p /var/log/php-fpm && chown www-data:www-data /var/log/php-fpm
php-fpm$PHPV -t && systemctl restart php$PHPV-fpm

# ---------- 5) Nginx: global hardening + FastCGI cache ----------
cat > /etc/nginx/conf.d/wp-base.conf <<'EOF'
# --- hide version ---
server_tokens off;

# --- FastCGI cache zones (per site ditambah terpisah) ---
fastcgi_cache_path /etc/nginx/fcgi_cache levels=1:2 keys_zone=WPGLOBAL:64m inactive=60m use_temp_path=off;
fastcgi_cache_key "$scheme$request_method$host$request_uri";
fastcgi_cache_use_stale error timeout invalid_header updating http_500 http_503;
fastcgi_cache_valid 200 301 302 60m;

# --- client limits ---
client_max_body_size 32m;
client_body_timeout 12s;
client_header_timeout 12s;
send_timeout 12s;
keepalive_timeout 30s;

# --- rate limit zones (brute-force & flood) ---
limit_req_zone $binary_remote_addr zone=wplogin:5m rate=10r/m;
limit_req_zone $binary_remote_addr zone=general:10m rate=30r/s;

# --- file cache ---
open_file_cache max=10000 inactive=30s;
open_file_cache_valid 60s;
open_file_cache_min_uses 2;
open_file_cache_errors on;

# --- gzip ---
gzip on;
gzip_vary on;
gzip_comp_level 5;
gzip_min_length 256;
gzip_types text/plain text/css text/xml text/javascript application/javascript application/json application/xml image/svg+xml;
EOF

# security headers snippet
mkdir -p /etc/nginx/snippets
cat > /etc/nginx/snippets/security_headers.conf <<'EOF'
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
EOF

# template vhost WP siap pakai
cat > /root/wp.vhost.template <<'EOF'
# Template vhost WordPress — replace __DOMAIN__ saat deploy
server {
    listen 80;
    server_name __DOMAIN__;
    root /var/www/__DOMAIN__;
    index index.php;

    include /etc/nginx/snippets/security_headers.conf;

    # HTTP->HTTPS otomatis pasang setelah certbot (line terpisah ditambahkan)
    location /.well-known/acme-challenge/ { root /var/www/_letsencrypt; }

    # cache statis
    location ~* \.(css|js|jpg|jpeg|png|gif|webp|svg|ico|woff2?|ttf)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }

    # WordPress login: rate-limit ketat
    location = /wp-login.php {
        limit_req zone=wplogin burst=5 nodelay;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm-wp.sock;
        fastcgi_read_timeout 120;
    }

    # blokir file sensitif
    location ~* /(wp-config\.php|readme\.html|license\.txt|xmlrpc\.php) { deny all; }
    location ~ /\. { deny all; }

    # PHP (FastCGI cache: skip utk logged-in/commenter)
    set $skip_cache 0;
    if ($http_cookie ~* "comment_author|wordpress_[a-f0-9]+|wp-postpass|wordpress_no_cache|wordpress_logged_in") { set $skip_cache 1; }

    location / { try_files $uri $uri/ /index.php?$args; }

    location ~ \.php$ {
        try_files $uri =404;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm-wp.sock;
        fastcgi_cache WPGLOBAL;
        fastcgi_cache_bypass $skip_cache;
        fastcgi_no_cache     $skip_cache;
        fastcgi_read_timeout 120;
    }
}
EOF

mkdir -p /var/www/_letsencrypt /etc/nginx/fcgi_cache
nginx -t && systemctl reload nginx

# ---------- 6) UFW firewall ----------
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp   # SSH (sesuaikan bila port dipindah)
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status verbose

# ---------- 7) fail2ban ----------
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = 22
maxretry = 4
bantime = 4h

[nginx-limit-req]
enabled = true
logpath = /var/log/nginx/*error.log
maxretry = 10
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# ---------- 8) SSH hardening (aman: tidak mematikan password, tidak pindah port) ----------
cat > /etc/ssh/sshd_config.d/99-wpbase.conf <<'EOF'
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowAgentForwarding no
MaxSessions 4
EOF
sshd -t && systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null

# ---------- 9) Kernel/system hemat ----------
systemctl disable --now unattended-upgrades 2>/dev/null  # keputusan manual update (opsional)
apt-get install -y -qq haveged 2>/dev/null               # entropi cepat utk TLS
systemctl enable --now haveged 2>/dev/null

# ---------- 10) WordPress default wp-config hardening (dipakai per-install) ----------
cat > /root/wp-config-extra.php <<'EOF'
// --- Tambahkan ke wp-config.php tiap instalasi WP ---
define('DISALLOW_FILE_EDIT', true);      // blokir editor plugin/tema
define('DISABLE_WP_CRON', true);         // cron via system cron, bukan on-request
define('WP_POST_REVISIONS', 5);          // hemat DB
define('EMPTY_TRASH_DAYS', 7);
define('WP_AUTO_UPDATE_CORE', 'minor');  // auto minor only
define('FORCE_SSL_ADMIN', true);
define('WP_MEMORY_LIMIT', '128M');
define('WP_MAX_MEMORY_LIMIT', '192M');
// disable xmlrpc sepenuhnya (sudah juga diblokir nginx)
add_filter('xmlrpc_enabled', '__return_false');
EOF

# ---------- 11) Audit ----------
echo "===== AUDIT ====="
echo "swap:      $(swapon --show | tail -1)"
echo "ram:       $(free -h | sed -n 2p | awk '{print $2" total / "$7" avail"}')"
echo "php-fpm:   $(ps aux | grep php-fpm | grep -v grep | wc -l) procs (ondemand, idle ~0)"
echo "mariadb:   $(systemctl is-active mariadb)"
echo "nginx:     $(systemctl is-active nginx) ($(nginx -v 2>&1))"
echo "ufw:       $(ufw status | head -1)"
echo "fail2ban:  $(fail2ban-client status sshd 2>/dev/null | grep -c 'Currently banned') banned now"
echo "ports:     $(ss -tulnp | awk 'NR>1{print $5}' | grep -oE '[0-9]+$' | sort -un | tr '\n' ' ')"
echo "===== WP-BASE SELESAI ====="
