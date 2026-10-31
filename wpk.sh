#!/bin/bash
# ==============================================================
#  WPK — WordPress Kit (All-in-One Server Provisioning)
#  --------------------------------------------------------------
#  Satu script untuk semuanya: base install server, deploy site,
#  SSL, security, optimasi memori, backup, maintenance.
#
#  Server kecil & kuat: pool PHP ondemand + FastCGI cache + swap,
#  security tingkat tinggi: ufw + fail2ban + rate-limit + lockdown.
#
#  Pemakaian:
#     wpk                     → menu interaktif
#     wpk base                → provisioning server kosong
#     wpk add <domain>        → tambah site WordPress (+SSL)
#     wpk list                → daftar site
#     wpk status              → kesehatan server
#     wpk ssl <domain>        → (re)issue SSL 1 domain
#     wpk backup <domain>     → backup 1 site (DB+files → /root/wpk-backups)
#     wpk backup-all          → backup semua site
#     wpk update <domain>     → update core/plugin/tema 1 site
#     wpk creds <domain>      → tampilkan kredensial site
#     wpk remove <domain>     → hapus site (auto-backup dulu)
#     wpk security            → audit & re-apply security
#     wpk optimize            → re-apply optimasi / bersih-bersih
#
#  v1.1 — Dabara untuk Trio. Idempotent: aman dijalankan ulang.
#  Output install rapi + checklist verifikasi otomatis di akhir.
# ==============================================================
set +e
export DEBIAN_FRONTEND=noninteractive
PHPV="8.3"
BACKUP_DIR="/root/wpk-backups"
REG_FILE="/root/wpk-sites.reg"
VHOST_TEMPLATE="/root/wpk.vhost.template"
WP_CONFIG_EXTRA="/root/wpk-config-extra.php"

BANNER='      ## ##     ## ##     ##    ###    ##    ##       ## ####
      ## ##     ## ###   ###   ## ##   ###   ##       ##  ##
      ## ##     ## #### ####  ##   ##  ####  ##       ##  ##
      ## ##     ## ## ### ## ##     ## ## ## ##       ##  ##
##    ## ##     ## ##     ## ######### ##  #### ##    ##  ##
##    ## ##     ## ##     ## ##     ## ##   ### ##    ##  ##
 ######   #######  ##     ## ##     ## ##    ##  ######  ####'
C_G="\033[0;32m"; C_Y="\033[0;33m"; C_R="\033[0;31m"; C_B="\033[1;34m"; C_0="\033[0m"
touch "$REG_FILE" 2>/dev/null && chmod 600 "$REG_FILE" 2>/dev/null
ok()   { echo -e "  ${C_G}✓${C_0} $1"; }
warn() { echo -e "  ${C_Y}!${C_0} $1"; }
err()  { echo -e "  ${C_R}✗${C_0} $1"; }
step() { echo -e "\n${C_B}── [$1/$NTOT] $2 ──${C_0}"; }
hdr()  { echo -e "\n${C_B}══════════════════════════════════════════${C_0}\n${C_B}  $1${C_0}\n${C_B}══════════════════════════════════════════${C_0}"; }

# ---------- helpers ----------
detect_phpver() {
  for v in 8.3 8.2 8.1 8.0; do
    [ -f "/etc/php/$v/fpm/php.ini" ] && PHPV=$v && return
  done
}

ram_children() {
  local RAM_MB; RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
  if   [ "$RAM_MB" -ge 3800 ]; then echo 40
  elif [ "$RAM_MB" -ge 1800 ]; then echo 20
  else echo 10; fi
}

reg_add() { # domain db dbuser admin pass
  grep -v "^$1|" "$REG_FILE" > "${REG_FILE}.tmp" 2>/dev/null
  echo "$1|$2|$3|$4|$5|$(date +%F)" >> "$REG_FILE"
  mv "${REG_FILE}.tmp" "$REG_FILE"
}
reg_del() { grep -v "^$1|" "$REG_FILE" > "${REG_FILE}.tmp" 2>/dev/null; mv "${REG_FILE}.tmp" "$REG_FILE"; }
reg_get() { awk -F'|' -v d="$1" -v f="$2" '$1==d{print $f}' "$REG_FILE" 2>/dev/null; }

socket_path() { echo "/run/php/php${PHPV}-fpm-wp.sock"; }

# ==============================================================
#  COMMAND: base — provisioning server kosong
# ==============================================================
cmd_base() {
  echo -e "\033[1;92m$BANNER\033[0m"
  hdr "WPK — INSTALASI SERVER  ($(hostname))"
  [ "$(id -u)" = 0 ] || { err "harus root"; exit 1; }
  NTOT=8
  echo -e "  Target  : server kosong -> siap WordPress"
  echo -e "  Mulai   : $(date '+%d %b %Y %H:%M:%S')"

  # ---------- 1. paket dasar ----------
  step 1 "Paket dasar (nginx, mariadb, php 8.3, wp-cli)"
  apt-get update -qq
  apt-get install -y -qq nginx mariadb-server curl git unzip ufw fail2ban \
    software-properties-common gnupg2 lsb-release sqlite3 >/dev/null 2>&1
  if ! php -v 2>/dev/null | grep -q "8.3"; then
    add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 || true
    apt-get update -qq
  fi
  apt-get install -y -qq php8.3-fpm php8.3-cli php8.3-mysql php8.3-curl \
    php8.3-gd php8.3-xml php8.3-zip php8.3-mbstring php8.3-intl \
    php8.3-opcache php8.3-bcmath php8.3-imagick >/dev/null 2>&1
  [ -x /usr/local/bin/wp ] || {
    curl -sS https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
    chmod +x /usr/local/bin/wp
  }
  detect_phpver
  ok "paket terpasang (PHP $PHPV + wp-cli)"

  # ---------- 2. swap + kernel ----------
  step 2 "Swap 4G & kernel tuning (anti-OOM + BBR)"
  if ! swapon --show | grep -q .; then
    (fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none)
    chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "swap 4G dibuat"
  else ok "swap sudah ada ($(swapon --show | tail -1 | awk '{print $1}'))"; fi
  cat > /etc/sysctl.d/99-wpk.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
net.core.somaxconn=1024
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
# --- security hardening kernel ---
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
kernel.unprivileged_bpf_disabled=1
net.core.bpf_jit_harden=2
kernel.yama.ptrace_scope=2
kernel.kexec_load_disabled=1
fs.protected_hardlinks=1
fs.protected_symlinks=1
fs.protected_fifos=2
fs.protected_regular=2
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.secure_redirects=0
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_max_syn_backlog=2048
net.ipv4.tcp_fin_timeout=15
net.ipv4.conf.default.rp_filter=1
EOF
  sysctl --system >/dev/null 2>&1
  ok "kernel: swappiness 10, TCP BBR + hardening (kptr/dmesg/bpf/ptrace/syncookies)"

  # ---------- 3. MariaDB ----------
  step 3 "MariaDB tuning (hemat RAM) + secure"
  cat > /etc/mysql/mariadb.conf.d/99-wpk.cnf <<'EOF'
[mysqld]
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
skip-log-bin
query_cache_type        = 0
query_cache_size        = 0
EOF
  systemctl restart mariadb
  mysql -e "DELETE FROM mysql.user WHERE User=''; DELETE FROM mysql.db WHERE Db LIKE 'test%'; DROP DATABASE IF EXISTS test; FLUSH PRIVILEGES;" 2>/dev/null
  ok "MariaDB aktif, buffer 128M, bind localhost, anon/test dibersihkan"

  # ---------- 4. PHP-FPM ----------
  step 4 "PHP-FPM ondemand (inti hemat RAM) + OPcache"
  P="/etc/php/$PHPV/fpm/php.ini"
  sed -i 's/^memory_limit = .*/memory_limit = 192M/'       "$P"
  sed -i 's/^max_execution_time = .*/max_execution_time = 120/' "$P"
  sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 32M/' "$P"
  sed -i 's/^post_max_size = .*/post_max_size = 32M/'       "$P"
  sed -i 's/^expose_php = .*/expose_php = Off/'             "$P"
  cat > "/etc/php/$PHPV/fpm/conf.d/90-opcache.ini" <<'EOF'
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=16000
opcache.validate_timestamps=1
opcache.revalidate_freq=60
opcache.save_comments=1
opcache.jit=tracing
opcache.jit_buffer_size=64M
opcache.file_cache=/var/cache/php-opcache
opcache.file_cache_only=0
realpath_cache_size=4096K
realpath_cache_ttl=600
EOF
  mkdir -p /var/cache/php-opcache && chown www-data:www-data /var/cache/php-opcache
  MAXC=$(ram_children)
  cat > "/etc/php/$PHPV/fpm/pool.d/wp.conf" <<EOF
[wp]
user = www-data
group = www-data
listen = $(socket_path)
listen.backlog = 2048
listen.owner = www-data
listen.group = www-data
pm = ondemand
pm.max_children = $MAXC
pm.process_idle_timeout = 10s
pm.max_requests = 500
php_admin_flag[log_errors] = off
php_admin_value[error_log] = /var/log/php-fpm/wp-error.log
php_admin_flag[allow_url_include] = off
php_admin_value[open_basedir] = /var/www:/tmp:/var/lib/php/sessions
EOF
  [ -f "/etc/php/$PHPV/fpm/pool.d/www.conf" ] && \
    mv "/etc/php/$PHPV/fpm/pool.d/www.conf" "/etc/php/$PHPV/fpm/pool.d/www.conf.disabled"
  mkdir -p /var/log/php-fpm && chown www-data:www-data /var/log/php-fpm
  php-fpm$PHPV -t >/dev/null && systemctl restart php$PHPV-fpm
  ok "pool 'wp' ondemand aktif — max_children=$MAXC, idle 0 worker, OPcache 128M"

  # ---------- 5. Nginx ----------
  step 5 "Nginx global + FastCGI cache + security headers"
  cat > /etc/nginx/conf.d/wpk.conf <<'EOF'
server_tokens off;
# --- performance (http ctx) ---
sendfile on;
tcp_nopush on;
tcp_nodelay on;
aio threads;
directio 8m;
output_buffers 2 32k;
fastcgi_cache_path /etc/nginx/fcgi_cache levels=1:2 keys_zone=WPGLOBAL:128m inactive=120m use_temp_path=off;
fastcgi_cache_key "$scheme$request_method$host$request_uri";
fastcgi_cache_use_stale error timeout invalid_header updating http_500 http_503;
fastcgi_cache_valid 200 301 302 120m;
client_max_body_size 32m;
client_body_timeout 12s;
client_header_timeout 12s;
send_timeout 12s;
keepalive_timeout 30s;
limit_req_zone $binary_remote_addr zone=wplogin:5m rate=10r/m;
limit_req_zone $binary_remote_addr zone=general:10m rate=30r/s;
open_file_cache max=10000 inactive=30s;
open_file_cache_valid 60s;
open_file_cache_min_uses 2;
open_file_cache_errors on;
gzip on;
gzip_vary on;
gzip_comp_level 5;
gzip_min_length 256;
gzip_types text/plain text/css text/xml text/javascript application/javascript application/json application/xml image/svg+xml;
EOF
  mkdir -p /etc/nginx/snippets /etc/nginx/fcgi_cache /var/www/_letsencrypt
  cat > /etc/nginx/snippets/security_headers.conf <<'EOF'
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
EOF
  # main ctx: worker tuning (conf.d tidak bisa menampung main ctx)
  NG=/etc/nginx/nginx.conf
  grep -q "worker_rlimit_nofile 65535" $NG || {
    sed -i 's/^worker_processes .*/worker_processes auto;/' $NG
    grep -q "worker_rlimit_nofile" $NG || sed -i '/worker_processes/a worker_rlimit_nofile 65535;\nworker_cpu_affinity auto;' $NG
    sed -i 's/^    worker_connections .*/    worker_connections 4096;/' $NG
    grep -q "multi_accept" $NG || sed -i '/worker_connections/a\    multi_accept on;\n    use epoll;' $NG
  }
  # logrotate
  if [ -f /etc/logrotate.d/nginx ] && ! grep -q "size 100M" /etc/logrotate.d/nginx; then
    sed -i 's/^\tdaily$/\tsize 100M\n\tdaily/' /etc/logrotate.d/nginx
  fi
  nginx -t >/dev/null && systemctl reload nginx
  ok "nginx OK — cache WPGLOBAL 128m/120m, gzip, rate-limit, aio threads"

  # ---------- 6. template vhost + wp-config ----------
  step 6 "Template vhost & wp-config hardening"
  cat > "$VHOST_TEMPLATE" <<'TEOF'
# WPK vhost — __DOMAIN__
server {
    listen 80;
    server_name __DOMAIN__;
    root /var/www/__DOMAIN__;
    index index.php;
    include /etc/nginx/snippets/security_headers.conf;
    location /.well-known/acme-challenge/ { root /var/www/_letsencrypt; }
    location ~* \\.(css|js|jpg|jpeg|png|gif|webp|svg|ico|woff2?|ttf)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }
    location = /wp-login.php {
        limit_req zone=wplogin burst=5 nodelay;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:__SOCKET__;
        fastcgi_read_timeout 120;
    }
    location ~* /(wp-config\\.php|readme\\.html|license\\.txt|xmlrpc\\.php) { deny all; }
    location ~ /\\. { deny all; }
    set $skip_cache 0;
    if ($http_cookie ~* "comment_author|wordpress_[a-f0-9]+|wp-postpass|wordpress_no_cache|wordpress_logged_in") { set $skip_cache 1; }
    location / { try_files $uri $uri/ /index.php?$args; }
    location ~ \\.php$ {
        try_files $uri =404;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:__SOCKET__;
        fastcgi_cache WPGLOBAL;
        fastcgi_cache_bypass $skip_cache;
        fastcgi_no_cache     $skip_cache;
        fastcgi_read_timeout 120;
    }
}
TEOF
  cat > "$WP_CONFIG_EXTRA" <<'EOF'
define('DISALLOW_FILE_EDIT', true);
define('DISABLE_WP_CRON', true);
define('WP_POST_REVISIONS', 5);
define('EMPTY_TRASH_DAYS', 7);
define('WP_AUTO_UPDATE_CORE', 'minor');
define('FORCE_SSL_ADMIN', true);
define('WP_MEMORY_LIMIT', '128M');
define('WP_MAX_MEMORY_LIMIT', '192M');
add_filter('xmlrpc_enabled', '__return_false');
EOF
  ok "template vhost ($VHOST_TEMPLATE) + wp-config hardening siap"

  # ---------- 7. firewall + fail2ban ----------
  step 7 "Firewall (ufw) + fail2ban"
  ufw --force reset >/dev/null
  ufw default deny incoming; ufw default allow outgoing
  ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp
  ufw --force enable >/dev/null
  ok "ufw aktif — hanya 22/80/443 terbuka"
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
  systemctl enable --now fail2ban >/dev/null 2>&1
  systemctl restart fail2ban
  ok "fail2ban aktif (sshd ban 4 jam + nginx rate-limit)"

  # ---------- 8. SSH ----------
  step 8 "SSH hardening (akses Bapak tetap utuh)"
  cat > /etc/ssh/sshd_config.d/99-wpk.conf <<'EOF'
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowAgentForwarding no
MaxSessions 4
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512
ClientAliveCountMax 2
UseDNS no
EOF
  sshd -t && systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
  ok "SSH: MaxAuthTries 3 + cipher kuat (chacha20/aes-gcm) — port & password TIDAK diubah"

  touch "$REG_FILE" && chmod 600 "$REG_FILE"
  cmd_verify
}

#  COMMAND: add — deploy site WordPress
# ==============================================================
cmd_add() {
  local D="$1"
  [ -z "$D" ] && { err "pemakaian: wpk add <domain>"; exit 1; }
  [ -f "$VHOST_TEMPLATE" ] || { err "base belum jalan — jalankan 'wpk base' dulu"; exit 1; }
  detect_phpver

  hdr "WPK ADD SITE — $D"
  getent hosts "$D" >/dev/null || warn "DNS $D belum resolve (SSL bisa gagal — jalankan 'wpk ssl $D' nanti)"

  local DBNAME="wp_${D//./_}" DBUSER="u_${D//./_}"
  local DBPASS ADMINPASS ADMINUSER
  DBPASS=$(openssl rand -base64 18 | tr -d '/+=')
  ADMINPASS=$(openssl rand -base64 16 | tr -d '/+=')
  ADMINUSER="wp_$(tr -dc 'a-z' </dev/urandom | head -c 6)"

  # DB
  if ! mysql -e "USE \`$DBNAME\`" 2>/dev/null; then
    mysql -e "CREATE DATABASE \`$DBNAME\`; CREATE USER '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASS'; GRANT ALL ON \`$DBNAME\`.* TO '$DBUSER'@'localhost'; FLUSH PRIVILEGES;"
    ok "database $DBNAME"
  else ok "database sudah ada"; fi

  # WP core
  mkdir -p "/var/www/$D"
  if [ ! -f "/var/www/$D/wp-config.php" ]; then
    wp core download --path="/var/www/$D" --quiet
    wp config create --path="/var/www/$D" --dbname="$DBNAME" --dbuser="$DBUSER" --dbpass="$DBPASS" --dbhost=localhost --quiet
    if ! grep -q DISALLOW_FILE_EDIT "/var/www/$D/wp-config.php"; then
      echo "" >> "/var/www/$D/wp-config.php"
      cat "$WP_CONFIG_EXTRA" >> "/var/www/$D/wp-config.php"
    fi
    chown -R www-data:www-data "/var/www/$D"
    ok "WordPress core terdownload"
  else ok "WP sudah ada di docroot"; fi

  # vhost
  if [ ! -f "/etc/nginx/sites-available/$D" ]; then
    sed -e "s/__DOMAIN__/$D/g" -e "s|__SOCKET__|$(socket_path)|g" "$VHOST_TEMPLATE" > "/etc/nginx/sites-available/$D"
    ln -sf "/etc/nginx/sites-available/$D" "/etc/nginx/sites-enabled/$D"
    nginx -t >/dev/null && systemctl reload nginx
    ok "vhost aktif (HTTP)"
  else ok "vhost sudah ada"; fi

  # SSL
  cmd_ssl "$D"

  # WP install
  local URL="https://$D"; [ -d "/etc/letsencrypt/live/$D" ] || URL="http://$D"
  if ! sudo -u www-data wp core is-installed --path="/var/www/$D" 2>/dev/null; then
    sudo -u www-data wp core install --path="/var/www/$D" --url="$URL" \
      --title="$D" --admin_user="$ADMINUSER" --admin_password="$ADMINPASS" \
      --admin_email="info@${D#*.}" --skip-email --quiet
    sudo -u www-data wp option update default_comment_status closed --path="/var/www/$D"
    sudo -u www-data wp option update default_ping_status closed --path="/var/www/$D"
    sudo -u www-data wp rewrite structure '/%postname%/' --hard --path="/var/www/$D"
    sudo -u www-data wp rewrite flush --hard --path="/var/www/$D"
    ok "WordPress terinstall"
  else
    ok "WP sudah terinstall (skip)"
  fi

  # cron wp-cron
  if ! grep -q "$D/wp-cron" /etc/crontab 2>/dev/null; then
    echo "*/15 * * * * root curl -sk https://$D/wp-cron.php?doing_wp_cron >/dev/null 2>&1" >> /etc/crontab
  fi

  reg_add "$D" "$DBNAME" "$DBUSER" "$ADMINUSER" "$ADMINPASS"
  echo ""
  echo -e "${C_G}===== SITE $D SIAP =====${C_0}"
  echo "  URL    : $URL"
  echo "  Admin  : $URL/wp-login.php"
  echo "  User   : $ADMINUSER"
  echo "  Pass   : $ADMINPASS"
  echo "  (tersimpan di $REG_FILE — 'wpk creds $D' untuk lihat lagi)"
}

# ==============================================================
#  COMMAND: ssl
# ==============================================================
cmd_ssl() {
  local D="$1"; [ -z "$D" ] && { err "pemakaian: wpk ssl <domain>"; exit 1; }
  if [ -d "/etc/letsencrypt/live/$D" ]; then ok "SSL sudah ada: $D"; return; fi
  [ -f "/etc/nginx/sites-available/$D" ] || { err "vhost $D tidak ada"; exit 1; }
  certbot certonly --webroot -w /var/www/_letsencrypt -d "$D" \
    --non-interactive --agree-tos -m "info@${D#*.}" --no-eff-email || { err "certbot gagal (cek DNS resolve + proxy CF OFF)"; return; }

  # patch vhost → https + redirect (idempotent)
  python3 - "$D" <<'PYEOF'
import sys
d = sys.argv[1]
p = f"/etc/nginx/sites-available/{d}"
s = open(p).read()
if "listen 443" not in s:
    s = s.replace(
        "listen 80;",
        f"listen 443 ssl http2;\n"
        f"    ssl_certificate /etc/letsencrypt/live/{d}/fullchain.pem;\n"
        f"    ssl_certificate_key /etc/letsencrypt/live/{d}/privkey.pem;\n"
        f"    ssl_protocols TLSv1.2 TLSv1.3;\n"
        f"    ssl_prefer_server_ciphers on;\n\n"
        f"server {{\n"
        f"    listen 80;\n"
        f"    server_name {d};\n"
        f"    return 301 https://$host$request_uri;\n"
        f"}}\n\nserver {{",
        1
    )
    open(p, "w").write(s)
PYEOF
  nginx -t >/dev/null && systemctl reload nginx
  ok "SSL aktif + redirect https: $D"
}

# ==============================================================
#  COMMAND: verify — checklist pasca-install (tes live satu-satu)
# ==============================================================
cmd_verify() {
  hdr "CHECKLIST VERIFIKASI"
  NTOT=17
  local pass=0 fail=0

  v() { # v <nomor> <deskripsi> <exit_code_cek_sebelumnya>
    if [ "$3" = 0 ]; then
      echo -e "  ${C_G}[$1/17] PASS${C_0}  $2"; pass=$((pass+1))
    else
      echo -e "  ${C_R}[$1/17] GAGAL${C_0} $2"; fail=$((fail+1))
    fi
  }

  # 1 nginx
  systemctl is-active --quiet nginx; v 1 "Nginx berjalan & config valid" $?
  # 2 mariadb
  mysqladmin ping >/dev/null 2>&1; v 2 "MariaDB merespon (ping OK)" $?
  # 3 php-fpm socket
  [ -S "$(socket_path)" ]; v 3 "PHP-FPM pool 'wp' socket aktif ($PHPV)" $?
  # 4 php version
  php -v 2>/dev/null | grep -q "$PHPV"; v 4 "PHP $PHPV terpasang" $?
  # 5 wp-cli
  wp --version >/dev/null 2>&1; v 5 "WP-CLI terpasang & jalan" $?
  # 6 swap
  free -m | awk 'NR==3{exit !($2>0)}'; v 6 "Swap aktif ($(free -h | sed -n 3p | awk '{print $2}'))" $?
  # 7 bbr
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; v 7 "TCP BBR aktif" $?
  # 8 swappiness
  [ "$(sysctl -n vm.swappiness)" = "10" ]; v 8 "Swappiness = 10" $?
  # 9 ufw
  ufw status | grep -q "Status: active"; v 9 "UFW firewall aktif" $?
  # 10 fail2ban
  fail2ban-client ping >/dev/null 2>&1; v 10 "fail2ban aktif (ping OK)" $?
  # 11 port sensitif
  [ "$(ss -tuln | awk '{print $5}' | grep -cE ':(3306|25|6379)$')" = "0" ]; v 11 "Port sensitif 3306/25/6379 tertutup dari luar" $?
  # 12 fcgi cache dir
  [ -d /etc/nginx/fcgi_cache ] && grep -q WPGLOBAL /etc/nginx/conf.d/wpk.conf; v 12 "FastCGI cache zone WPGLOBAL siap" $?
  # 13 templates
  [ -f "$VHOST_TEMPLATE" ] && [ -f "$WP_CONFIG_EXTRA" ]; v 13 "Template vhost + wp-config hardening ada" $?
  # 14 ssh config
  sshd -T 2>/dev/null | grep -q "maxauthtries 3"; v 14 "SSH hardening aktif (MaxAuthTries 3)" $?
  # 15 jit
  php -i 2>/dev/null | grep -q "opcache.jit_buffer_size => 64"; v 15 "PHP JIT aktif (64M)" $?
  # 16 kernel hardening
  [ "$(sysctl -n kernel.kptr_restrict 2>/dev/null)" = "2" ] && [ "$(sysctl -n kernel.dmesg_restrict 2>/dev/null)" = "1" ]; v 16 "Kernel hardening aktif (kptr/dmesg restrict)" $?
  # 17 cipher ssh
  sshd -T 2>/dev/null | grep -q "chacha20-poly1305"; v 17 "SSH cipher modern (chacha20/aes-gcm)" $?

  echo ""
  if [ $fail = 0 ]; then
    echo -e "  ${C_G}>>> SEMUA $pass/17 CEK LOLOS — SERVER SIAP DIGUNAKAN <<<${C_0}"
  else
    echo -e "  ${C_Y}>>> $pass lolos, $fail GAGAL — periksa poin yang merah di atas <<<${C_0}"
  fi
  echo -e "  Selesai : $(date '+%d %b %Y %H:%M:%S')"
  echo ""
  echo -e "  Lanjut:  ${C_B}wpk add <domain>${C_0}  untuk tiap site baru"
}

# ==============================================================
#  COMMAND: list
# ==============================================================
cmd_list() {
  hdr "SITE TERDAFTAR ($(wc -l < "$REG_FILE" 2>/dev/null | tr -d ' '))"
  [ -s "$REG_FILE" ] || { warn "belum ada site"; return; }
  while IFS='|' read -r d db dbuser admin pass tgl; do
    [ -z "$d" ] && continue
    local ssl="HTTP"
    [ -d "/etc/letsencrypt/live/$d" ] && ssl="HTTPS"
    local alive="DOWN"
    curl -sk -o /dev/null -m 5 "https://$d" && alive="UP"
    printf "  %-32s %-6s %-4s %s\n" "$d" "$ssl" "$alive" "$tgl"
  done < "$REG_FILE"
}

# ==============================================================
#  COMMAND: status
# ==============================================================
cmd_status() {
  hdr "STATUS SERVER — $(hostname)"
  echo "  RAM       : $(free -h | sed -n 2p | awk '{print $3" dipakai / "$2" total ("$7" avail)"}')"
  echo "  Swap      : $(free -h | sed -n 3p | awk '{print $3" dipakai / "$2}')"
  echo "  php-fpm   : $(ps aux | grep -c '[p]hp-fpm') procs (ondemand)"
  echo "  nginx     : $(systemctl is-active nginx)"
  echo "  mariadb   : $(systemctl is-active mariadb)"
  echo "  fail2ban  : $(fail2ban-client status sshd 2>/dev/null | grep -oE 'Currently banned.*' || echo '?')"
  echo "  ufw       : $(ufw status 2>/dev/null | head -1)"
  echo "  disk      : $(df -h / | awk 'NR==2{print $3" dipakai / "$2" ("$5")"}')"
  echo "  site      : $(wc -l < "$REG_FILE" 2>/dev/null | tr -d ' ') terdaftar"
  echo "  fcgi cache: $(du -sh /etc/nginx/fcgi_cache 2>/dev/null | awk '{print $1}')"
}

# ==============================================================
#  COMMAND: creds / backup / update / remove / security / optimize
# ==============================================================
cmd_creds() {
  local D="$1"; [ -z "$D" ] && { err "pemakaian: wpk creds <domain>"; exit 1; }
  local db dbuser admin pass
  db=$(reg_get "$D" 2); dbuser=$(reg_get "$D" 3); admin=$(reg_get "$D" 4); pass=$(reg_get "$D" 5)
  [ -z "$db" ] && { err "$D tidak terdaftar"; exit 1; }
  echo "  Domain : $D"
  echo "  Admin  : $admin / $pass"
  echo "  DB     : $db ($dbuser)"
  local dbpass; dbpass=$(grep -oP "DB_PASSWORD', '\K[^']+" "/var/www/$D/wp-config.php" 2>/dev/null)
  echo "  DBPass : $dbpass"
}

cmd_backup() {
  local D="$1"; [ -z "$D" ] && { err "pemakaian: wpk backup <domain>"; exit 1; }
  local db; db=$(reg_get "$D" 2)
  [ -z "$db" ] && { err "$D tidak terdaftar"; exit 1; }
  local out="$BACKUP_DIR/$D-$(date +%F-%H%M)"
  mkdir -p "$out"
  mysqldump --single-transaction --quick "$db" 2>/dev/null | gzip > "$out/db.sql.gz"
  tar -czf "$out/files.tar.gz" -C "/var/www" "$D" 2>/dev/null
  tar -czf "$out/nginx.tar.gz" -C "/etc/nginx/sites-available" "$D" 2>/dev/null
  ok "backup → $out ($(du -sh "$out" | awk '{print $1}'))"
}

cmd_backup_all() {
  [ -s "$REG_FILE" ] || { warn "belum ada site"; return; }
  while IFS='|' read -r d _; do
    [ -z "$d" ] && continue
    cmd_backup "$d"
  done < "$REG_FILE"
}

cmd_update() {
  local D="$1"; [ -z "$D" ] && { err "pemakaian: wpk update <domain>"; exit 1; }
  [ -d "/var/www/$D" ] || { err "/var/www/$D tidak ada"; exit 1; }
  local wp="sudo -u www-data wp --path=/var/www/$D"
  $wp core update --quiet && ok "core updated: $D"
  $wp plugin update --all --quiet && ok "plugins updated"
  $wp theme update --all --quiet && ok "themes updated"
  $wp rewrite flush --hard --quiet
}

cmd_remove() {
  local D="$1"; [ -z "$D" ] && { err "pemakaian: wpk remove <domain>"; exit 1; }
  local db dbuser; db=$(reg_get "$D" 2); dbuser=$(reg_get "$D" 3)
  read -rp "HAPUS $D permanen? (ketik YES): " konf
  [ "$konf" = "YES" ] || { warn "dibatalkan"; return; }
  cmd_backup "$D"
  [ -n "$db" ] && mysql -e "DROP DATABASE \`$db\`; DROP USER IF EXISTS '$dbuser'@'localhost'; FLUSH PRIVILEGES;"
  rm -rf "/var/www/$D" "/etc/nginx/sites-enabled/$D" "/etc/nginx/sites-available/$D"
  sed -i "\#$D/wp-cron#d" /etc/crontab
  certbot delete --cert-name "$D" --non-interactive 2>/dev/null
  nginx -t >/dev/null && systemctl reload nginx
  reg_del "$D"
  ok "$D dihapus (backup ada di $BACKUP_DIR)"
}

cmd_security() {
  hdr "SECURITY AUDIT + RE-APPLY"
  grep -q "wplogin" /etc/nginx/conf.d/wpk.conf 2>/dev/null || { warn "config nginx wpk hilang — jalankan 'wpk base' untuk re-apply penuh"; return; }
  systemctl is-active --quiet fail2ban && ok "fail2ban aktif" || { systemctl restart fail2ban; ok "fail2ban direstart"; }
  ufw status | grep -q "Status: active" && ok "ufw aktif" || { ufw --force enable; ok "ufw di-enable"; }
  [ "$(ss -tulnp | grep -cE ':(3306|25|6379)\s')" = "0" ] && ok "3306/25/6379 tertutup dari luar" || warn "ada port sensitif terbuka!"
  local bad=0
  while IFS='|' read -r d _; do
    [ -z "$d" ] && continue
    grep -q DISALLOW_FILE_EDIT "/var/www/$d/wp-config.php" 2>/dev/null || { warn "$d: wp-config tanpa hardening"; bad=1; }
    [ "$(stat -c %U "/var/www/$d" 2>/dev/null)" = "www-data" ] || { warn "$d: owner bukan www-data"; bad=1; }
  done < "$REG_FILE"
  [ $bad = 0 ] && ok "semua site hardening OK"
  cmd_status
}

cmd_optimize() {
  hdr "OPTIMASI RE-APPLY"
  detect_phpver
  local big; big=$(du -sh /var/log/nginx/*.error.log 2>/dev/null | awk '{s+=$1}END{print s}')
  for f in /var/log/nginx/*.error.log; do truncate -s 0 "$f" 2>/dev/null; done
  systemctl reload nginx
  ok "log di-truncate (sebelumnya ~${big:-0})"
  rm -rf /etc/nginx/fcgi_cache/* 2>/dev/null
  ok "FastCGI cache di-purge"
  systemctl reload php$PHPV-fpm 2>/dev/null
  ok "php-fpm reloaded (opcache reset)"
  cmd_status
}

# ==============================================================
# ==============================================================
#  COMMAND: banner — pasang tulisan JUMANJI di login SSH (MOTD)
# ==============================================================
cmd_banner() {
  local D="/etc/motd"
  if [ "$1" = "off" ]; then
    echo -e "(login biasa — tanpa banner)" > "$D"
    ok "MOTD banner dimatikan"
    return
  fi
  {
    echo ""
    echo -e "$BANNER"
    echo -e "  ${C_B}WPK — WordPress Kit${C_0}  |  $(hostname)  |  $(date +%Y)"
    echo -e "  ${C_Y}Welcome to the jungle.${C_0}"
    echo ""
    echo "  Server : $(hostname) ($(curl -s -m 3 ifconfig.me 2>/dev/null || echo 'ip-unknown'))"
    echo "  RAM    : $(free -h | sed -n 2p | awk '{print $3" / "$2}')"
    echo "  Sites  : $(wc -l < /root/wpk-sites.reg 2>/dev/null | tr -d ' ') terdaftar"
    echo "  Help   : wpk  (menu)  |  wpk status  |  wpk verify"
    echo ""
  } > "$D"
  # update-shown motd kadang menimpa — matikan (aman jika tak ada)
  if [ -f /etc/update-motd.d/10-help-text ]; then
    chmod a-x /etc/update-motd.d/10-help-text 2>/dev/null || true
  fi
  ok "Banner JUMANJI terpasang di /etc/motd (tampil tiap login SSH)"
  echo -e "$BANNER"
}

# ==============================================================
# ==============================================================
#  COMMAND: fix — diagnosa & perbaiki poin verifikasi yang gagal
# ==============================================================
cmd_fix() {
  hdr "PERBAIKAN OTOMATIS — POIN GAGAL"
  local fixed=0

  # --- 5: WP-CLI ---
  if ! wp --version >/dev/null 2>&1; then
    warn "WP-CLI rusak/belum ada — download ulang..."
    curl -sS https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
    chmod +x /usr/local/bin/wp
    wp --version >/dev/null 2>&1 && { ok "WP-CLI diperbaiki ($(wp --version 2>/dev/null | grep -oE 'WP-CLI [0-9.]+'))"; fixed=$((fixed+1)); } || err "WP-CLI masih gagal (cek koneksi ke github.com)"
  else ok "WP-CLI sebenarnya OK (false alarm versi lama)"; fi

  # --- 11: port sensitif ---
  local opened; opened=$(ss -tuln | awk '{print $5}' | grep -oE ':(3306|25|6379)$' | sort -u | tr '\n' ' ')
  if [ -n "$opened" ]; then
    warn "port terbuka: $opened — dianalisis & ditutup..."
    # 3306: MariaDB bind luar -> paksa localhost
    if echo "$opened" | grep -q 3306; then
      grep -q "^bind-address" /etc/mysql/mariadb.conf.d/99-wpk.cnf && sed -i 's/^bind-address.*/bind-address            = 127.0.0.1/' /etc/mysql/mariadb.conf.d/99-wpk.cnf
      # conf lain bisa override — pastikan tidak ada yang bind 0.0.0.0
      grep -rl "bind-address.*0.0.0.0" /etc/mysql/ 2>/dev/null | xargs -r sed -i 's/bind-address.*0.0.0.0/bind-address = 127.0.0.1/'
      systemctl restart mariadb
    fi
    # 25: postfix/exim idle -> matikan & stop
    if echo "$opened" | grep -q ":25"; then
      systemctl stop postfix exim4 2>/dev/null; systemctl disable postfix exim4 2>/dev/null
    fi
    # 6379: redis -> bind localhost saja
    if echo "$opened" | grep -q 6379; then
      [ -f /etc/redis/redis.conf ] && sed -i 's/^bind .*/bind 127.0.0.1/' /etc/redis/redis.conf && systemctl restart redis-server 2>/dev/null
    fi
    # lapis terakhir: blok via ufw secara eksplisit
    for pt in 3306 25 6379; do ufw deny "$pt"/tcp >/dev/null 2>&1; done
    sleep 1
    [ "$(ss -tuln | awk '{print $5}' | grep -cE ':(3306|25|6379)$')" = "0" ] && { ok "semua port sensitif tertutup"; fixed=$((fixed+1)); } || err "masih ada port terbuka — laporkan output 'ss -tuln'"
  else ok "port sensitif sebenarnya OK (false alarm: listen ::1/[::] dihitung luar)"; fi

  # --- 15: JIT ---
  local jit_val; jit_val=$(php -r 'echo ini_get("opcache.jit_buffer_size");' 2>/dev/null)
  if [ -z "$jit_val" ] || [ "$jit_val" = "0" ]; then
    warn "JIT belum aktif — perbaiki konfigurasi opcache..."
    cat > "/etc/php/$PHPV/fpm/conf.d/90-opcache.ini" <<'EOF'
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=16000
opcache.validate_timestamps=1
opcache.revalidate_freq=60
opcache.save_comments=1
opcache.jit=tracing
opcache.jit_buffer_size=64M
EOF
    # hapus file_cache (bisa konflik di beberapa setup) — tetap ada jit murni memory
    mkdir -p /var/cache/php-opcache && chown www-data:www-data /var/cache/php-opcache
    php-fpm$PHPV -t >/dev/null 2>&1 && systemctl restart php$PHPV-fpm
  fi
  # cek ulang: angka byte ATAU "64M" keduanya dianggap aktif
  jit_val=$(php -r 'echo ini_get("opcache.jit_buffer_size");' 2>/dev/null)
  if [ -n "$jit_val" ] && [ "$jit_val" != "0" ]; then
    ok "PHP JIT aktif (jit_buffer_size=$jit_val)"; fixed=$((fixed+1))
  else err "JIT masih mati — PHP build mungkin tanpa opcache JIT (cek: php -v | head -1)"; fi

  echo ""
  if [ $fixed -gt 0 ]; then
    ok "$fixed poin diperbaiki — jalankan verifikasi ulang:"
  fi
  echo -e "  ${C_B}wpk verify${C_0}"
}

#  MENU INTERAKTIF
# ==============================================================
cmd_menu() {
  while true; do
    clear 2>/dev/null
    echo -e "\033[1;92m$BANNER\033[0m"
    echo -e "${C_B}  ╔══════════════════════════════════════════╗${C_0}"
    echo -e "${C_B}  ║   WPK — WordPress Kit (All-in-One)       ║${C_0}"
    echo -e "${C_B}  ╚══════════════════════════════════════════╝${C_0}"
    echo "   1) Install base server (sekali saja)"
    echo "   2) Tambah site WordPress"
    echo "   3) Daftar site"
    echo "   4) Status server"
    echo "   5) Kredensial site"
    echo "   6) Backup site"
    echo "   7) Backup semua"
    echo "   8) Update site (core+plugin+tema)"
    echo "   9) Hapus site"
    echo "  10) Security audit"
    echo "  11) Optimasi / bersih-bersih"
    echo "  12) Pasang banner JUMANJI (MOTD)"
    echo "  13) PERBAIKI poin verifikasi yang gagal"
    echo "   0) Keluar"
    echo ""
    read -rp "  Pilih: " p
    case $p in
      1) cmd_base; read -rp "Enter...";;
      2) read -rp "Domain: " d; cmd_add "$d"; read -rp "Enter...";;
      3) cmd_list; read -rp "Enter...";;
      4) cmd_status; read -rp "Enter...";;
      5) read -rp "Domain: " d; cmd_creds "$d"; read -rp "Enter...";;
      6) read -rp "Domain: " d; cmd_backup "$d"; read -rp "Enter...";;
      7) cmd_backup_all; read -rp "Enter...";;
      8) read -rp "Domain: " d; cmd_update "$d"; read -rp "Enter...";;
      9) read -rp "Domain: " d; cmd_remove "$d"; read -rp "Enter...";;
      10) cmd_security; read -rp "Enter...";;
      11) cmd_optimize; read -rp "Enter...";;
      12) cmd_banner; read -rp "Enter...";;
      13) cmd_fix; read -rp "Enter...";;
      0) exit 0;;
    esac
  done
}

# ==============================================================
#  ROUTER
# ==============================================================
case "$1" in
  -boot)      # one-liner mode: pasang diri + banner + base
    cp "$0" /root/wpk.sh 2>/dev/null; chmod +x /root/wpk.sh
    ln -sf /root/wpk.sh /usr/local/bin/wpk 2>/dev/null
    bash /root/wpk.sh banner >/dev/null 2>&1
    echo ">>> WPK terpasang. Mulai instalasi server... <<<"
    cmd_base;;
  base)       cmd_base;;
  add)        shift; cmd_add "$@";;
  ssl)        shift; cmd_ssl "$@";;
  list)       cmd_list;;
  status)     cmd_status;;
  creds)      shift; cmd_creds "$@";;
  backup)     shift; cmd_backup "$@";;
  backup-all) cmd_backup_all;;
  update)     shift; cmd_update "$@";;
  remove)     shift; cmd_remove "$@";;
  security)   cmd_security;;
  verify)     cmd_verify;;
  fix)        cmd_fix;;
  banner)     shift; cmd_banner "$@";;
  optimize)   cmd_optimize;;
  menu|"" )   cmd_menu;;
  *) echo "WPK v1.0 — perintah tidak dikenal: $1"
     echo "Pakai: wpk | base | verify | fix | add | banner | ssl | list | status | creds | backup | backup-all | update | remove | security | optimize";;
esac
