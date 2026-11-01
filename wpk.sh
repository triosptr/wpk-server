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
#  v2.0 — Dabara untuk Trio. Idempotent: aman dijalankan ulang.
#  Menu utama: SITE (install/manage WP) + SERVER (restart/cache/domain/SSL).
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

# ---------- helper: install WP-CLI multi-source ----------
install_wpcli() {
  local DST="/usr/local/bin/wp"
  local R="https://raw.githubusercontent.com/triosptr/wpk-server/main/wp-cli.phar"
  # 1. repo sendiri (paling stabil — dependency kita)
  if curl -fsSL -m 120 "$R" -o "$DST" 2>/dev/null && [ $(stat -c%s "$DST" 2>/dev/null || echo 0) -gt 5000000 ]; then
    chmod +x "$DST"
    wp --allow-root --version >/dev/null 2>&1 && return 0
  fi
  # 2. wp-cli resmi
  if curl -fsSL -m 120 https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o "$DST" 2>/dev/null && [ $(stat -c%s "$DST" 2>/dev/null || echo 0) -gt 5000000 ]; then
    chmod +x "$DST"
    wp --allow-root --version >/dev/null 2>&1 && return 0
  fi
  # 3. GitHub release
  if curl -fsSL -m 120 https://github.com/wp-cli/wp-cli/releases/download/v2.11.0/wp-cli-2.11.0.phar -o "$DST" 2>/dev/null && [ $(stat -c%s "$DST" 2>/dev/null || echo 0) -gt 5000000 ]; then
    chmod +x "$DST"
    wp --allow-root --version >/dev/null 2>&1 && return 0
  fi
  rm -f "$DST"
  return 1
}

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
  apt-get install -y -qq nginx mariadb-server curl git unzip ufw fail2ban certbot \
    software-properties-common gnupg2 lsb-release sqlite3 >/dev/null 2>&1
  if ! php -v 2>/dev/null | grep -q "8.3"; then
    add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 || true
    apt-get update -qq
  fi
  apt-get install -y -qq php8.3-fpm php8.3-cli php8.3-mysql php8.3-curl \
    php8.3-gd php8.3-xml php8.3-zip php8.3-mbstring php8.3-intl \
    php8.3-opcache php8.3-bcmath php8.3-imagick \
    libnginx-mod-http-brotli-filter libnginx-mod-http-brotli-static >/dev/null 2>&1
  if ! wp --allow-root --version >/dev/null 2>&1; then
    if install_wpcli; then
      ok "wp-cli terpasang"
    else
      warn "wp-cli gagal di-install (koneksi GitHub?) — jalankan: wpk fix"
    fi
  else ok "wp-cli sudah ada"; fi
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
# --- performance (http ctx; sendfile/tcp_nodelay sudah di nginx.conf utama) ---
aio threads;
fastcgi_cache_path /etc/nginx/fcgi_cache levels=1:2 keys_zone=WPGLOBAL:128m inactive=120m use_temp_path=off;
fastcgi_cache_key "$scheme$request_method$host$request_uri";
fastcgi_cache_use_stale error timeout invalid_header updating http_500 http_503;
add_header X-FastCGI-Cache $upstream_cache_status always;
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
EOF
  # brotli hanya ditulis bila module terload (auto-enabled via apt install step 1)
  if ls /etc/nginx/modules-enabled/*brotli* >/dev/null 2>&1 || nginx -V 2>&1 | grep -q brotli; then
    cat >> /etc/nginx/conf.d/wpk.conf <<'BREOF'
brotli on;
brotli_comp_level 6;
brotli_types text/plain text/css text/xml text/javascript application/javascript application/json application/xml image/svg+xml;
BREOF
  else
    warn "module brotli tidak tersedia — lanjut dengan gzip saja"
  fi
  # gzip/sendfile TIDAK ditulis di sini — sudah ada di nginx.conf utama (hindari duplikat)
  cat > /etc/nginx/conf.d/wpk-tls.conf <<'TLSEOF'
ssl_session_cache shared:SSL:20m;
ssl_session_timeout 1d;
ssl_session_tickets on;
ssl_early_data on;
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;
TLSEOF
  mkdir -p /etc/nginx/snippets /etc/nginx/fcgi_cache /var/www/_letsencrypt
  chmod 755 /var/www /var/www/_letsencrypt
  mkdir -p /var/www/_letsencrypt/.well-known/acme-challenge && chmod -R 755 /var/www/_letsencrypt/.well-known
  cat > /etc/nginx/snippets/security_headers.conf <<'EOF'
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
EOF
  # hapus sisa konflik duplikat dari versi lama
  sed -i -E '/^\s*(sendfile|tcp_nopush|tcp_nodelay|directio|output_buffers|gzip|gzip_vary|gzip_comp_level|gzip_min_length|gzip_types) /d' /etc/nginx/conf.d/wpk.conf 2>/dev/null
  # brotli directive tanpa module = nginx mati — buang
  if ! ls /etc/nginx/modules-enabled/*brotli* >/dev/null 2>&1 && ! nginx -V 2>&1 | grep -q brotli; then
    sed -i -E '/^\s*brotli(_comp_level|_types)? /d' /etc/nginx/conf.d/wpk.conf 2>/dev/null
  fi
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
    location ^~ /.well-known/acme-challenge/ { root /var/www/_letsencrypt; }
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
EOF
  # catatan: xmlrpc diblokir via nginx deny — TIDAK pakai add_filter di wp-config (bukan fungsi WP yang valid di sana)
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

  # self-heal: template wajib FULL (punya server{}); kalau inner-only/korup → tarik dari repo
  if [ ! -s "$VHOST_TEMPLATE" ] || ! grep -q "^server {" "$VHOST_TEMPLATE"; then
    warn "template vhost tidak valid — menarik dari repo..."
    curl -fsSL https://raw.githubusercontent.com/triosptr/wpk-server/main/wpk.vhost.template -o "$VHOST_TEMPLATE" 2>/dev/null
    grep -q "^server {" "$VHOST_TEMPLATE" || { err "template tetap invalid — cek internet server"; exit 1; }
    ok "template diperbaiki"
  fi
  hdr "INSTALL WORDPRESS BARU — $D"
  echo -e "  ${C_Y}Langkah yang akan dijalankan otomatis:${C_0}"
  echo -e "   1. Database + user random"
  echo -e "   2. WordPress core download"
  echo -e "   3. vhost nginx + security"
  echo -e "   4. SSL Let's Encrypt"
  echo -e "   5. WordPress kosong siap — setup admin via wizard browser"
  echo -e "      (bahasa → judul site → username → password)"
  echo ""
  echo -e "  ${C_Y}Sy DNS (Cloudflare):${C_0} A record -> $(curl -s -m 3 ifconfig.me 2>/dev/null || echo 'IP-server') , proxy awan ${C_Y}MATI${C_0} (grey cloud / DNS only)"
  getent hosts "$D" >/dev/null &&     { RESOLVED_IP=$(getent ahostsv4 "$D" | awk '{print $1}' | head -1)
      [ -z "$RESOLVED_IP" ] && RESOLVED_IP=$(getent hosts "$D" | awk '{print $1}' | head -1)
      SERVER_IP=$(curl -s -m 3 ifconfig.me 2>/dev/null)
      [ -n "$SERVER_IP" ] && [ "$RESOLVED_IP" != "$SERVER_IP" ] && warn "DNS $D mengarah ke $RESOLVED_IP, bukan IP server ini ($SERVER_IP) — periksa A record"; } ||     warn "DNS $D BELUM resolve — buat A record di Cloudflare (proxy MATI/awan abu), lalu 'wpk ssl $D' nanti"

  local DBNAME="wp_${D//./_}" DBUSER="u_${D//./_}"
  local DBPASS
  DBPASS=$(openssl rand -base64 18 | tr -d '/+=')
  # admin user/password: di-setup Bapak via wizard WordPress di browser (bukan CLI)

  # DB
  if ! mysql -e "USE \`$DBNAME\`" 2>/dev/null; then
    mysql -e "CREATE DATABASE \`$DBNAME\`; CREATE USER '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASS'; GRANT ALL ON \`$DBNAME\`.* TO '$DBUSER'@'localhost'; FLUSH PRIVILEGES;"
    ok "database $DBNAME"
  else ok "database sudah ada"; fi

  # WP core
  mkdir -p "/var/www/$D"
  if [ ! -f "/var/www/$D/wp-config.php" ]; then
    if ! wp core download --path="/var/www/$D" --quiet --allow-root; then
      err "download WordPress core gagal (cek internet server)"; return 1
    fi
    if ! wp config create --path="/var/www/$D" --dbname="$DBNAME" --dbuser="$DBUSER" --dbpass="$DBPASS" --dbhost=localhost --quiet --allow-root; then
      err "wp config create gagal (DB/password)"; return 1
    fi
    # config-extra wajib bersih — kalau mengandung racun add_filter, tulis ulang inline
    if [ ! -s "$WP_CONFIG_EXTRA" ] || grep -q "add_filter" "$WP_CONFIG_EXTRA" 2>/dev/null; then
      cat > "$WP_CONFIG_EXTRA" <<'CFGEOF'
define('DISALLOW_FILE_EDIT', true);
define('DISABLE_WP_CRON', true);
define('WP_POST_REVISIONS', 5);
define('EMPTY_TRASH_DAYS', 7);
define('WP_AUTO_UPDATE_CORE', 'minor');
define('FORCE_SSL_ADMIN', true);
define('WP_MEMORY_LIMIT', '128M');
define('WP_MAX_MEMORY_LIMIT', '192M');
CFGEOF
    fi
    if ! grep -q DISALLOW_FILE_EDIT "/var/www/$D/wp-config.php"; then
      echo "" >> "/var/www/$D/wp-config.php"
      cat "$WP_CONFIG_EXTRA" >> "/var/www/$D/wp-config.php"
    fi
    sed -i "/add_filter(.*xmlrpc_enabled.*/d" "/var/www/$D/wp-config.php"
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

  # SSL (kalau DNS belum siap → lanjut HTTP, SSL bisa 'wpk ssl <domain>' belakangan)
  if ! cmd_ssl "$D"; then
    warn "SSL dilewati dulu — site jalan via HTTP. Setelah DNS beres: wpk ssl $D"
  fi

  # WordPress KOSONG — admin/password/judul di-setup via WIZARD WordPress di browser
  # (tahap install: bahasa → judul site → username admin → password)
  local URL="https://$D"; [ -d "/etc/letsencrypt/live/$D" ] || URL="http://$D"
  if sudo -u www-data /usr/local/bin/wp core is-installed --path="/var/www/$D" 2>/dev/null; then
    ok "WP sudah terinstall (skip)"
  fi

  # verifikasi wizard tampil
  local http_code; http_code=$(curl -sk -o /dev/null -w "%{http_code}" -m 10 "$URL/wp-admin/setup-config.php" 2>/dev/null)
  http_code=${http_code:-000}
  if [ "$http_code" = "200" ] || [ "$http_code" = "302" ]; then
    ok "wizard WordPress siap: $URL"
  else
    # coba root URL — kalau DB sudah connect, wizard redirect ke install.php
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" -m 10 "$URL" 2>/dev/null)
    if [ "$http_code" = "200" ] || [ "$http_code" = "302" ]; then
      ok "site siap: $URL (buka di browser untuk setup wizard)"
    else
      warn "site belum merespon ($http_code) — cek: wpk repair $D"
    fi
  fi

  # cron wp-cron
  if ! grep -q "$D/wp-cron" /etc/crontab 2>/dev/null; then
    echo "*/15 * * * * root curl -sk https://$D/wp-cron.php?doing_wp_cron >/dev/null 2>&1" >> /etc/crontab
  fi

  reg_add "$D" "$DBNAME" "$DBUSER" "wizard-setup" "-"

  echo ""
  echo -e "${C_G}===== SITE $D SIAP — LANGKAH TERAKHIR VIA BROWSER =====${C_0}"
  echo -e "  1. Buka  : ${C_B}$URL${C_0}"
  echo -e "  2. Wizard WordPress akan memandu: pilih bahasa → judul site →"
  echo -e "     username admin → password (BUAT YANG KUAT)"
  echo -e "  3. Selesai wizard → login: $URL/wp-login.php"
  echo -e "  4. Opsional: ${C_B}wpk site $D${C_0} → 1 (install plugin+tema standar)"
  echo ""
  echo -e "  ${C_Y}Catatan: DB pass tersimpan di $REG_FILE${C_0}"
}

# ==============================================================
#  COMMAND: ssl
# ==============================================================
cmd_ssl() {
  local D="$1"; [ -z "$D" ] && { err "pemakaian: wpk ssl <domain>"; exit 1; }
  if [ -d "/etc/letsencrypt/live/$D" ] && grep -q "listen 443" "/etc/nginx/sites-available/$D" 2>/dev/null; then
    ok "SSL sudah ada: $D"; return
  fi
  [ -d "/etc/letsencrypt/live/$D" ] && ok "cert ada tapi vhost belum HTTPS — regen vhost..."
  [ -f "/etc/nginx/sites-available/$D" ] || { err "vhost $D tidak ada — wpk add $D dulu"; exit 1; }

  # pre-flight DNS (hindari buang kuota rate-limit Let's Encrypt: 5 gagal/jam)
  local RESOLVED_IP SERVER_IP
  RESOLVED_IP=$(getent ahostsv4 "$D" 2>/dev/null | awk '{print $1}' | head -1)
  SERVER_IP=$(curl -s -m 3 ifconfig.me 2>/dev/null)
  if [ -z "$RESOLVED_IP" ]; then
    err "DNS $D belum resolve — buat A record di Cloudflare (proxy awan MATI/grey), tunggu 1-2 menit, ulangi"
    return 1
  fi
  if [ -n "$SERVER_IP" ] && [ "$RESOLVED_IP" != "$SERVER_IP" ]; then
    err "DNS $D -> $RESOLVED_IP, bukan IP server ini ($SERVER_IP)"
    echo -e "   ${C_Y}Perbaiki A record di Cloudflare (proxy MATI/grey), lalu ulangi${C_0}"
    return 1
  fi
  ok "DNS OK: $D -> $RESOLVED_IP"
  # pastikan vhost pakai ^~ untuk acme (override deny dotfiles regex)
  if [ -f "/etc/nginx/sites-available/$D" ] && grep -q "^    location /\.well-known/acme-challenge/" "/etc/nginx/sites-available/$D"; then
    sed -i 's|^    location /\.well-known/acme-challenge/|    location ^~ /.well-known/acme-challenge/|' "/etc/nginx/sites-available/$D"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
  fi
  chmod -R 755 /var/www/_letsencrypt 2>/dev/null
  mkdir -p /var/www/_letsencrypt/.well-known/acme-challenge
  certbot certonly --webroot -w /var/www/_letsencrypt -d "$D" \
    --non-interactive --agree-tos -m "info@${D#*.}" --no-eff-email || {
      err "certbot gagal. Cek:"
      echo -e "   ${C_Y}1. A record $D -> IP server ini (Cloudflare DNS)"
      echo -e "   2. Proxy awan MATI (grey cloud / DNS only) — bukan oranye"
      echo -e "   3. Perbaiki lalu jalankan ulang: wpk ssl $D${C_0}"
      return; }

  # patch vhost → regen HTTPS dari template (bersih, tak bisa merusak struktur)
  python3 /root/wpk_ssl_gen.py "$D"
  ln -sf "/etc/nginx/sites-available/$D" "/etc/nginx/sites-enabled/$D"
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
    ok "SSL aktif + redirect https: $D"
  else
    err "nginx test gagal: $(nginx -t 2>&1 | tail -1)"
  fi
}

# ==============================================================
#  COMMAND: verify — checklist pasca-install (tes live satu-satu)
# ==============================================================
cmd_verify() {
  hdr "CHECKLIST VERIFIKASI"
  detect_phpver
  local HAS_SITE=0
  [ -s "$REG_FILE" ] && HAS_SITE=1
  if [ $HAS_SITE = 1 ]; then NTOT=18; else NTOT=17; fi
  local pass=0 fail=0

  v() { # v <nomor> <deskripsi> <exit_code_cek_sebelumnya>
    if [ "$3" = 0 ]; then
      echo -e "  ${C_G}[$1/$NTOT] PASS${C_0}  $2"; pass=$((pass+1))
    else
      echo -e "  ${C_R}[$1/$NTOT] GAGAL${C_0} $2"; fail=$((fail+1))
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
  # 5 wp-cli (root butuh --allow-root)
  wp --allow-root --version >/dev/null 2>&1; v 5 "WP-CLI terpasang & jalan" $?
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
  # 11 port sensitif (loopback tidak dihitung — hanya bind luar yang bahaya)
  [ "$(ss -tuln | awk '{print $5}' | grep -E ':(3306|25|6379)$' | grep -cvE '^(127\.|\[::1\]|::1)')" = "0" ]; v 11 "Port sensitif 3306/25/6379 tertutup dari luar" $?
  # 12 fcgi cache dir (file mungkin belum ada bila base belum jalan)
  [ -d /etc/nginx/fcgi_cache ] && { [ -f /etc/nginx/conf.d/wpk.conf ] && grep -q WPGLOBAL /etc/nginx/conf.d/wpk.conf; }; v 12 "FastCGI cache zone WPGLOBAL siap" $?
  # 13 templates
  [ -f "$VHOST_TEMPLATE" ] && [ -f "$WP_CONFIG_EXTRA" ]; v 13 "Template vhost + wp-config hardening ada" $?
  # 14 ssh config
  sshd -T 2>/dev/null | grep -q "maxauthtries 3"; v 14 "SSH hardening aktif (MaxAuthTries 3)" $?
  # 15 jit (baca dari konfig PHP-FPM SAPI, bukan CLI)
  php-fpm$PHPV -i 2>/dev/null | grep -qE "opcache.jit_buffer_size => (64M|67108864)"; v 15 "PHP JIT aktif (64M)" $?
  # 16 kernel hardening
  [ "$(sysctl -n kernel.kptr_restrict 2>/dev/null)" = "2" ] && [ "$(sysctl -n kernel.dmesg_restrict 2>/dev/null)" = "1" ]; v 16 "Kernel hardening aktif (kptr/dmesg restrict)" $?
  # 17 cipher ssh
  sshd -T 2>/dev/null | grep -q "chacha20-poly1305"; v 17 "SSH cipher modern (chacha20/aes-gcm)" $?
  # 18 site live check (kalau ada site terdaftar)
  if [ -s "$REG_FILE" ]; then
    local any_up=0
    while IFS='|' read -r sd _; do
      [ -z "$sd" ] && continue
      local U="https://$sd"; [ -d "/etc/letsencrypt/live/$sd" ] || U="http://$sd"
      curl -sk -o /dev/null -m 8 "$U" && any_up=1 && break
    done < "$REG_FILE"
    [ $any_up = 1 ]; v 18 "Minimal satu site merespon (live check)" $?
  else
    NTOT=17  # tanpa site, kembali ke 17 poin
    v 17 "Belum ada site terdaftar (skip live check)" 0
  fi

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
  if [ "$admin" = "wizard-setup" ]; then
    echo "  Admin  : (di-setup via wizard browser — belum/belum dicatat)"
    echo "           setelah wizard, catat manual atau: wpk site $D → 5c reset"
  else
    echo "  Admin  : $admin / $pass"
  fi
  echo "  DB     : $db ($dbuser)"
  local dbpass
  if [ -f "/var/www/$D/wp-config.php" ]; then
    dbpass=$(grep -oP "DB_PASSWORD'[^']*'\K[^']+" "/var/www/$D/wp-config.php" 2>/dev/null)
  fi
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
  local wp="sudo -u www-data /usr/local/bin/wp --path=/var/www/$D"
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
# ==============================================================
#  COMMAND: site — menu manage per-domain (WordPress lengkap)
# ==============================================================
cmd_site() {
  local D="$1"
  detect_phpver
  if [ -z "$D" ]; then
    hdr "PILIH SITE"
    [ -s "$REG_FILE" ] || { warn "belum ada site — wpk add <domain> dulu"; return; }
    local i=1; local DOMAINS=()
    while IFS='|' read -r d _; do
      [ -z "$d" ] && continue
      echo "   $i) $d"
      DOMAINS+=("$d"); i=$((i+1))
    done < "$REG_FILE"
    echo "    0) batal"
    read -rp "  Nomor site: " n
    [ "$n" = "0" ] || [ -z "$n" ] && return
    D="${DOMAINS[$((n-1))]}"
  fi
  [ -d "/var/www/$D" ] || { err "/var/www/$D tidak ada"; return; }

  while true; do
    echo ""
    echo -e "${C_B}  ── MANAGE: $D ──${C_0}"
    echo "   1) Install paket lengkap (plugin+tema+SEO+security) — setelah wizard"
    echo "   2) Info & kredensial"
    echo "   3) Plugin: list / install / aktif / update"
    echo "   4) Tema: aktifkan / update"
    echo "   5) User: tambah admin / reset password"
    echo "   6) Cache: purge (FastCGI) + rewrite flush"
    echo "   7) Backup sekarang"
    echo "   8) Update semua (core+plugin+tema)"
    echo "   9) Debug: on/off (WP_DEBUG)"
    echo "  10) Maintenance mode: on/off"
    echo "   0) kembali"
    read -rp "  Pilih: " p
    case $p in
      1) wp_full_install "$D";;
      2) cmd_creds "$D"; echo "  Docroot : /var/www/$D"; echo "  PHP ver : $PHPV";;
      3) wp_plugin_menu "$D";;
      4) wp_theme_menu "$D";;
      5) wp_user_menu "$D";;
      6) wp_purge "$D";;
      7) cmd_backup "$D";;
      8) cmd_update "$D";;
      9) wp_debug_toggle "$D";;
      10) wp_maintenance "$D";;
      0) break;;
      "") break;;
    esac
    [ -t 0 ] || break
    [ "$p" != "0" ] && read -rp "  Enter..."
  done
  [ -z "$IN_MENU" ] && { ok "kembali ke menu utama..."; cmd_menu; }
}

# ---------- helper WordPress per-domain ----------
wp_full_install() {
  local D="$1"; local wp="sudo -u www-data /usr/local/bin/wp --path=/var/www/$D"
  hdr "INSTALL WORDPRESS LENGKAP — $D"
  detect_phpver
  $wp core is-installed --quiet 2>/dev/null || { err "WP core belum terinstall — jalankan core install dulu"; return; }

  echo -e "  Menginstall paket standar..."
  # plugin standar AdSense-ready (pola situs Trio)
  for pl in classic-editor wordpress-seo ad-inserter easy-table-of-contents; do
    $wp plugin install "$pl" --activate --quiet 2>/dev/null && ok "plugin: $pl" || warn "plugin $pl gagal (mungkin sudah ada)"
  done
  # tema Kadence
  $wp theme install kadence --quiet 2>/dev/null && $wp theme activate kadence --quiet 2>/dev/null && ok "tema: Kadence aktif"
  # hapus tema default & plugin bawaan
  for t in $($wp theme list --status=inactive --field=name 2>/dev/null); do $wp theme delete "$t" --quiet 2>/dev/null; done
  $wp plugin delete akismet hello --quiet 2>/dev/null
  # komentar mati total
  $wp option update default_comment_status closed --quiet
  $wp option update default_ping_status closed --quiet
  $wp option update comment_moderation 1 --quiet
  $wp option update thread_comments "" --quiet
  # hapus konten bawaan
  $wp post delete 1 2 3 --force --quiet 2>/dev/null
  # permalink + diskusi
  $wp rewrite structure '/%postname%/' --hard --quiet
  $wp rewrite flush --hard --quiet
  # yoast welcome config skip
  $wp option set yoast_mailsense_summary_emails_disabled '' --quiet 2>/dev/null
  # auto-update plugin+tema
  $wp plugin auto-updates enable --all --quiet 2>/dev/null
  $wp theme auto-updates enable --all --quiet 2>/dev/null

  # favicon placeholder di-set saat add logo; site icon via media nanti
  wp_purge "$D"
  ok "INSTALL LENGKAP — site siap isi konten"
}

wp_plugin_menu() {
  local D="$1"; local wp="sudo -u www-data /usr/local/bin/wp --path=/var/www/$D"
  echo "  a) list  b) install  c) aktif  d) deaktif  e) hapus"
  read -rp "  pilih: " sp; read -rp "  slug plugin (kosongkan utk list): " slug
  case $sp in
    a) $wp plugin list;;
    b) [ -n "$slug" ] && $wp plugin install "$slug" --activate && ok "installed: $slug";;
    c) [ -n "$slug" ] && $wp plugin activate "$slug" && ok "aktif: $slug";;
    d) [ -n "$slug" ] && $wp plugin deactivate "$slug" && ok "nonaktif: $slug";;
    e) [ -n "$slug" ] && $wp plugin uninstall "$slug" --deactivate && ok "hapus: $slug";;
  esac
}

wp_theme_menu() {
  local D="$1"; local wp="sudo -u www-data /usr/local/bin/wp --path=/var/www/$D"
  echo "  a) list  b) aktifkan  c) update semua"
  read -rp "  pilih: " sp; read -rp "  nama tema: " slug
  case $sp in
    a) $wp theme list;;
    b) [ -n "$slug" ] && $wp theme activate "$slug" && ok "tema aktif: $slug";;
    c) $wp theme update --all && ok "tema updated";;
  esac
}

wp_user_menu() {
  local D="$1"; local wp="sudo -u www-data /usr/local/bin/wp --path=/var/www/$D"
  echo "  a) list user  b) tambah admin  c) reset password user"
  read -rp "  pilih: " sp
  case $sp in
    a) $wp user list --fields=ID,user_login,roles,email;;
    b) read -rp "  username baru: " u; read -rp "  email: " e
       [ -z "$u" ] || [ -z "$e" ] && { err "username & email wajib diisi"; return; }
       local np; np=$(openssl rand -base64 14 | tr -d '/+=')
       $wp user create "$u" "$e" --role=administrator --user_pass="$np" --quiet &&        ok "admin dibuat: $u / $np (CATAT SEKARANG)";;
    c) read -rp "  username: " u
       local np; np=$(openssl rand -base64 14 | tr -d '/+=')
       $wp user update "$u" --user_pass="$np" --quiet && ok "password $u = $np";;
  esac
}

wp_purge() {
  local D="$1"
  rm -rf /etc/nginx/fcgi_cache/* 2>/dev/null
  sudo -u www-data /usr/local/bin/wp --path="/var/www/$D" rewrite flush --hard --quiet 2>/dev/null
  sudo -u www-data /usr/local/bin/wp --path="/var/www/$D" cache flush --quiet 2>/dev/null
  systemctl reload nginx
  ok "cache $D di-purge (FastCGI + WP object cache + rewrite)"
}

wp_debug_toggle() {
  local D="$1"; local cfg="/var/www/$D/wp-config.php"
  if grep -q "define( *'WP_DEBUG'.*true" "$cfg" 2>/dev/null || grep -q 'WP_DEBUG.*, true' "$cfg"; then
    sed -i "s/define( *'WP_DEBUG'.*/define( 'WP_DEBUG', false );/" "$cfg"
    ok "WP_DEBUG OFF"
  else
    sed -i "s/define( *'WP_DEBUG'.*/define( 'WP_DEBUG', true );\ndefine( 'WP_DEBUG_LOG', true );\ndefine( 'WP_DEBUG_DISPLAY', false );/" "$cfg"
    ok "WP_DEBUG ON (log: /var/www/$D/wp-content/debug.log)"
  fi
}

wp_maintenance() {
  local D="$1"; local f="/var/www/$D/.maintenance"
  if [ -f "$f" ]; then rm -f "$f"; ok "maintenance OFF"; else echo '<?php $upgrading = time();' > "$f"; ok "maintenance ON"; fi
}

# ==============================================================
#  COMMAND: server — menu manajemen server (restart/cache/domain/dll)
# ==============================================================
cmd_server() {
  while true; do
    echo ""
    echo -e "${C_B}  ── SERVER: $(hostname) ──${C_0}"
    echo "   1) Restart web stack (nginx + php-fpm + mariadb)"
    echo "   2) Reboot server"
    echo "   3) Purge semua cache (FastCGI + OPcache)"
    echo "   4) Bersihkan log besar + truncate"
    echo "   5) Domain: list / tambah / hapus"
    echo "   6) SSL: renew semua / issue 1 domain"
    echo "   7) Live log akses (tail -f)"
    echo "   8) Cek error terakhir (nginx error log)"
    echo "   9) Disk: pemakaian + file terbesar"
    echo "  10) Update OS (apt upgrade)"
    echo "  11) Security audit (semua site + firewall)"
    echo "  12) Verifikasi kesehatan 17 poin"
    echo "   0) kembali"
    read -rp "  Pilih: " p
    case $p in
      1) systemctl reload nginx; systemctl restart php$PHPV-fpm 2>/dev/null || systemctl restart php-fpm
         echo -n "  restart mariadb? (y/N): "; read y
         [ "$y" = "y" ] && systemctl restart mariadb
         ok "web stack restarted";;
      2) echo -n "  REBOOT server sekarang? (ketik YES): "; read y
         [ "$y" = "YES" ] && { ok "rebooting..."; sleep 2; reboot; } || warn "dibatalkan";;
      3) rm -rf /etc/nginx/fcgi_cache/* 2>/dev/null
         systemctl reload php$PHPV-fpm 2>/dev/null
         systemctl reload nginx
         ok "semua cache purged (FastCGI + OPcache reset)";;
      4) du -sh /var/log/* 2>/dev/null | sort -rh | head -8
         for f in /var/log/nginx/*.error.log /var/log/php-fpm/*.log; do
           [ -f "$f" ] && [ $(stat -c%s "$f") -gt 52428800 ] && truncate -s 0 "$f" && ok "truncate: $f"
         done
         journalctl --vacuum-size=100M >/dev/null 2>&1
         ok "log dibersihkan";;
      5) server_domain_menu;;
      6) echo "  a) renew semua (certbot renew)  b) issue 1 domain"
         read -rp "  pilih: " sp
         case $sp in
           a) certbot renew --quiet && ok "SSL renewed";;
           b) read -rp "  domain: " d; cmd_ssl "$d";;
         esac;;
      7) echo -e "  ${C_Y}(Ctrl+C untuk keluar)${C_0}"; tail -f /var/log/nginx/access.log 2>/dev/null | head -50;;
      8) tail -30 /var/log/nginx/error.log 2>/dev/null || ok "error log kosong";;
      9) df -h / | sed -n 2p
         echo "  --- 10 file/folder terbesar di /var/www ---"
         du -sh /var/www/* 2>/dev/null | sort -rh | head -10;;
      10) apt-get update -qq && apt-get upgrade -y -qq && ok "OS updated";;
      11) cmd_security;;
      12) cmd_verify;;
      0) break;;
      "") break;;
    esac
    [ -t 0 ] || break
    [ "$p" != "0" ] && read -rp "  Enter..."
  done
  [ -z "$IN_MENU" ] && { ok "kembali ke menu utama..."; cmd_menu; }
}

server_domain_menu() {
  echo "  a) list site  b) tambah site  c) hapus site  d) detail site"
  read -rp "  pilih: " sp
  case $sp in
    a) cmd_list;;
    b) read -rp "  domain (sub.domain.com): " d; [ -n "$d" ] && cmd_add "$d";;
    c) read -rp "  domain: " d; [ -n "$d" ] && cmd_remove "$d";;
    d) read -rp "  domain: " d; [ -n "$d" ] && { cmd_creds "$d"; grep "^$d|" "$REG_FILE"; };;
  esac
}

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
  detect_phpver
  local fixed=0

  # --- nginx: bersihkan duplikat dari versi lama + reload ---
  if [ -f /etc/nginx/conf.d/wpk.conf ]; then
    sed -i -E '/^\s*(sendfile|tcp_nopush|tcp_nodelay|directio|output_buffers|gzip|gzip_vary|gzip_comp_level|gzip_min_length|gzip_types|brotli|brotli_comp_level|brotli_types) /d' /etc/nginx/conf.d/wpk.conf
    # brotli boleh kembali kalau module ada
    if ls /etc/nginx/modules-enabled/*brotli* >/dev/null 2>&1 || nginx -V 2>&1 | grep -q brotli; then
      grep -q "^brotli on;" /etc/nginx/conf.d/wpk.conf || cat >> /etc/nginx/conf.d/wpk.conf <<'BREOF'
brotli on;
brotli_comp_level 6;
brotli_types text/plain text/css text/xml text/javascript application/javascript application/json application/xml image/svg+xml;
BREOF
    fi
  fi
  # nginx mati total (config invalid)? cari & karantina vhost rusak lalu start
  if ! systemctl is-active --quiet nginx; then
    warn "nginx down — cari vhost invalid & karantina..."
    for f in /etc/nginx/sites-enabled/*; do
      [ -f "$f" ] || continue
      BAK="/root/wpk-quarantine-$(basename $f)"
      mv "$f" "$BAK" 2>/dev/null
      if nginx -t >/dev/null 2>&1; then
        warn "vhost $(basename $f) invalid → dikarantina ke $BAK"
        systemctl reset-failed nginx 2>/dev/null; systemctl start nginx
        systemctl is-active --quiet nginx && { ok "nginx hidup lagi"; fixed=$((fixed+1)); }
        break
      else
        mv "$BAK" "$f"  # bukan dia yang rusak — kembalikan
      fi
    done
    systemctl is-active --quiet nginx || { err "nginx tetap gagal start: $(nginx -t 2>&1 | tail -1)"; }
  else
    nginx -t >/dev/null 2>&1 && systemctl reload nginx && ok "nginx OK" || err "nginx config error: $(nginx -t 2>&1 | tail -1)"
  fi

  # --- 5: WP-CLI ---
  if ! wp --allow-root --version >/dev/null 2>&1; then
    warn "WP-CLI rusak/belum ada — coba 3 sumber..."
    if install_wpcli; then
      ok "WP-CLI diperbaiki"; fixed=$((fixed+1))
    else
      err "WP-CLI masih gagal. Diagnosa:"
      echo -e "   ${C_Y}curl -sI -m 10 https://raw.githubusercontent.com/triosptr/wpk-server/main/wp-cli.phar${C_0}"
      echo -e "   ${C_Y}→ kalau timeout: koneksi ke GitHub bermasalah dari server ini${C_0}"
    fi
  else ok "WP-CLI OK"; fi

  # --- 11: port sensitif — hanya yang bind ke luar (0.0.0.0 / [::] / *) yang bahaya ---
  local badport=0
  for pt in 3306 25 6379; do
    # listener yang bind selain loopback
    local ln; ln=$(ss -tuln | awk -v p=":${pt}" '$5 ~ p {print $5}' | grep -vE '^(127\.0\.0\.1|\[::1\]|::1):' | head -1)
    if [ -z "$ln" ]; then
      continue   # tidak listen sama sekali, atau hanya loopback = aman
    fi
    warn "port $pt listen di $ln (luar) — ditangani:"
    badport=1
    case $pt in
      3306)
        grep -rlE "bind-address.*0\.0\.0\.0" /etc/mysql/ 2>/dev/null | xargs -r sed -i 's/bind-address.*/bind-address = 127.0.0.1/'
        grep -q "^bind-address" /etc/mysql/mariadb.conf.d/99-wpk.cnf 2>/dev/null || echo "bind-address = 127.0.0.1" >> /etc/mysql/mariadb.conf.d/99-wpk.cnf
        systemctl restart mariadb 2>/dev/null
        ;;
      25)
        for svc in postfix exim4 sendmail; do
          systemctl stop $svc 2>/dev/null; systemctl disable $svc 2>/dev/null
        done
        # kalau masih ada yang listen 25, temukan PID-nya
        local pid; pid=$(ss -tlnp 2>/dev/null | awk '/:25 /{print $NF}' | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
        [ -n "$pid" ] && { ps -p $pid -o comm= ; kill $pid 2>/dev/null; }
        ;;
      6379)
        [ -f /etc/redis/redis.conf ] && sed -i 's/^bind .*/bind 127.0.0.1/' /etc/redis/redis.conf
        systemctl restart redis-server 2>/dev/null || { local pid2; pid2=$(ss -tlnp 2>/dev/null | awk '/:6379 /{print $NF}' | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2); [ -n "$pid2" ] && kill $pid2 2>/dev/null; }
        ;;
    esac
  done
  [ $badport = 0 ] && ok "tidak ada port sensitif yang bind ke luar (aman)"

  # recheck poin 11
  local still=0
  for pt in 3306 25 6379; do
    ss -tuln | awk -v p=":${pt}" '$5 ~ p {print $5}' | grep -vqE '^(127\.|\[::1\]|::1)' && still=$((still+1))
  done
  if [ $still = 0 ]; then
    ok "port sensitif kini hanya loopback / mati"; [ $badport = 1 ] && fixed=$((fixed+1))
  else
    err "masih ada $still port bind luar — jalankan 'ss -tuln | grep -E "3306|25|6379"' dan laporkan"
  fi

  # --- 15: JIT ---
  local jit_val; jit_val=$(php -r 'echo ini_get("opcache.jit_buffer_size");' 2>/dev/null)
  if [ -z "$jit_val" ] || [ "$jit_val" = "0" ]; then
    warn "JIT belum aktif — tulis ulang konfigurasi opcache..."
    if [ ! -d "/etc/php/$PHPV/fpm/conf.d" ]; then
      # PHP tidak terdeteksi — cari versi yang benar-benar ada
      for v in 8.3 8.2 8.1 8.0; do
        [ -d "/etc/php/$v/fpm/conf.d" ] && PHPV=$v && break
      done
    fi
    if [ -d "/etc/php/$PHPV/fpm/conf.d" ]; then
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
      php-fpm$PHPV -t >/dev/null 2>&1 && systemctl restart php$PHPV-fpm
    else
      err "direktori PHP-FPM tidak ditemukan — PHP belum terpasang? jalankan 'wpk base' dulu"
    fi
    jit_val=$(php -r 'echo ini_get("opcache.jit_buffer_size");' 2>/dev/null)
  fi
  if php-fpm$PHPV -i 2>/dev/null | grep -qE "opcache.jit_buffer_size => (64M|67108864)"; then
    ok "PHP JIT aktif (FPM SAPI)"; fixed=$((fixed+1))
  else
    err "JIT mati — kemungkinan opcache module tidak load. Cek: php -m | grep -i opcache"
  fi

  echo ""
  echo -e "  Diperbaiki: ${C_G}$fixed poin${C_0} — cek ulang: ${C_B}wpk verify${C_0}"
}

# ==============================================================
#  COMMAND: update-self — tarik versi terbaru dari GitHub repo
# ==============================================================
cmd_update_self() {
  local TMP="/tmp/wpk.sh.new" TMPV="/tmp/wpk.vhost.new" TMPC="/tmp/wpk.cfg.new"
  curl -fsSL https://raw.githubusercontent.com/triosptr/wpk-server/main/wpk.sh -o "$TMP" || { err "download gagal (cek internet server)"; return; }
  curl -fsSL https://raw.githubusercontent.com/triosptr/wpk-server/main/wpk.vhost.template -o "$TMPV" 2>/dev/null
  curl -fsSL https://raw.githubusercontent.com/triosptr/wpk-server/main/wpk-config-extra.php -o "$TMPC" 2>/dev/null
  bash -n "$TMP" || { err "file baru invalid — batal"; return; }
  mv "$TMP" /root/wpk.sh && chmod +x /root/wpk.sh
  [ -s "$TMPV" ] && mv "$TMPV" "$VHOST_TEMPLATE"
  [ -s "$TMPC" ] && mv "$TMPC" "$WP_CONFIG_EXTRA"
  ln -sf /root/wpk.sh /usr/local/bin/wpk 2>/dev/null
  ok "WPK updated → jalankan ulang: wpk"
}

# ==============================================================
#  COMMAND: repair — pulihkan site yang setengah terpasang
# ==============================================================
cmd_repair() {
  local D="$1"; [ -z "$D" ] && { err "pemakaian: wpk repair <domain>"; exit 1; }
  hdr "REPAIR — $D"
  detect_phpver
  [ -d "/var/www/$D" ] || { err "docroot tidak ada"; exit 1; }

  # self-heal: pastikan semua asset repo ada (inner, generator)
  R="https://raw.githubusercontent.com/triosptr/wpk-server/main"
  [ -s /root/wpk.vhost.inner ] || curl -fsSL "$R/wpk.vhost.inner" -o /root/wpk.vhost.inner 2>/dev/null
  [ -s /root/wpk_ssl_gen.py ] || curl -fsSL "$R/wpk_ssl_gen.py" -o /root/wpk_ssl_gen.py 2>/dev/null
  [ -s "$VHOST_TEMPLATE" ] || curl -fsSL "$R/wpk.vhost.template" -o "$VHOST_TEMPLATE" 2>/dev/null

  # WP core download ulang kalau index.php tidak ada
  if [ ! -f "/var/www/$D/index.php" ]; then
    wp core download --path="/var/www/$D" --allow-root --force --quiet && ok "WP core di-download ulang"
  fi

  # wp-config: ekstrak kredensial dari file lama → buat ulang BERSIH (perbaiki "Strange wp-config")
  local DBNAME DBUSER DBPASS
  if [ -f "/var/www/$D/wp-config.php" ]; then
    DBNAME=$(grep -oP "DB_NAME'[^']*'\K[^']+" "/var/www/$D/wp-config.php" | head -1)
    DBUSER=$(grep -oP "DB_USER'[^']*'\K[^']+" "/var/www/$D/wp-config.php" | head -1)
    DBPASS=$(grep -oP "DB_PASSWORD'[^']*'\K[^']+" "/var/www/$D/wp-config.php" | head -1)
    if [ -z "$DBNAME" ] || [ -z "$DBUSER" ]; then
      DBNAME="wp_${D//./_}"; DBUSER="u_${D//./_}"
      DBPASS=$(openssl rand -base64 18 | tr -d '/+=')
      mysql -e "CREATE DATABASE IF NOT EXISTS \`$DBNAME\`; CREATE USER IF NOT EXISTS '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASS'; GRANT ALL ON \`$DBNAME\`.* TO '$DBUSER'@'localhost'; FLUSH PRIVILEGES;"
    fi
    wp config create --path="/var/www/$D" --dbname="$DBNAME" --dbuser="$DBUSER" --dbpass="$DBPASS" --dbhost=localhost --quiet --allow-root --force
    grep -q DISALLOW_FILE_EDIT "/var/www/$D/wp-config.php" || cat "$WP_CONFIG_EXTRA" >> "/var/www/$D/wp-config.php"
    # sanitizer: buang racun add_filter dari wp-config (bukan fungsi WP di sana)
    sed -i "/add_filter(.*xmlrpc_enabled.*/d" "/var/www/$D/wp-config.php"
    chown www-data:www-data "/var/www/$D/wp-config.php"
    chmod 600 "/var/www/$D/wp-config.php"
    ok "wp-config dibuat ulang bersih (creds: $DBNAME/$DBUSER)"
  else
    err "wp-config tidak ada — jalankan wpk add"; exit 1
  fi

  # vhost: regen dari template — TAPI template di disk mungkin lama; regen template dulu dari wpk.sh
  [ -s "$VHOST_TEMPLATE" ] || { err "template tidak ada — wpk self-update dulu"; exit 1; }
  # pastikan template punya ^~ acme (bila file lama, patch)
  sed -i 's|^    location /\.well-known/acme-challenge/|    location ^~ /.well-known/acme-challenge/|' "$VHOST_TEMPLATE"
  sed -e "s/__DOMAIN__/$D/g" -e "s|__SOCKET__|$(socket_path)|g" "$VHOST_TEMPLATE" > "/etc/nginx/sites-available/$D"
  ln -sf "/etc/nginx/sites-available/$D" "/etc/nginx/sites-enabled/$D"

  # SSL: kalau cert sudah ada, tulis vhost HTTPS via generator (sama seperti cmd_ssl)
  if [ -d "/etc/letsencrypt/live/$D" ]; then
    python3 /root/wpk_ssl_gen.py "$D"
  fi

  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
    ok "vhost OK"
  else
    err "nginx test gagal: $(nginx -t 2>&1 | tail -1)"
  fi

  # SSL kalau belum ada
  [ -d "/etc/letsencrypt/live/$D" ] || cmd_ssl "$D"

  # skema kosong: JANGAN core-install via CLI — wizard browser yang install
  local URL="https://$D"; [ -d "/etc/letsencrypt/live/$D" ] || URL="http://$D"
  if sudo -u www-data /usr/local/bin/wp core is-installed --path="/var/www/$D" 2>/dev/null; then
    ok "WP sudah terinstall"
  else
    ok "WordPress kosong — buka $URL untuk setup wizard (bahasa→judul→admin→password)"
  fi
  curl -sk -o /dev/null -m 5 "$URL" && ok "site UP: $URL" || warn "site belum merespon (DNS/propagasi)"
}

#  MENU INTERAKTIF
# ==============================================================
cmd_menu() {
  IN_MENU=1
  while true; do
    clear 2>/dev/null
    echo -e "\033[1;92m$BANNER\033[0m"
    echo -e "${C_B}  ╔══════════════════════════════════════════╗${C_0}"
    echo -e "${C_B}  ║   WPK — WordPress Kit (All-in-One)       ║${C_0}"
    echo -e "${C_B}  ╚══════════════════════════════════════════╝${C_0}"
    echo -e "  ${C_G}── WORDPRESS ──${C_0}"
    echo "   1) INSTALL WordPress baru (kosong, setup via wizard browser)"
    echo "   2) Daftar site"
    echo "   3) Manage site (install lengkap, plugin, tema, user...)"
    echo -e "  ${C_G}── SERVER ──${C_0}"
    echo "   4) Manajemen server (restart, cache, domain, SSL, log...)"
    echo "   5) Status server"
    echo "   6) Security audit"
    echo "   7) Verifikasi kesehatan (17 poin)"
    echo "   8) Perbaiki poin gagal (fix)"
    echo -e "  ${C_G}── LAINNYA ──${C_0}"
    echo "   9) Install base server (sekali saja)"
    echo "  10) Banner JUMANJI (MOTD)"
    echo "  11) Update WPK ke versi terbaru"
    echo "  12) REPAIR site bermasalah"
    echo "   0) Keluar"
    echo ""
    read -rp "  Pilih: " p
    case $p in
      1) read -rp "  Domain: " d; [ -n "$d" ] && cmd_add "$d";;
      2) cmd_list;;
      3) cmd_site;;
      4) cmd_server;;
      5) cmd_status;;
      6) cmd_security;;
      7) cmd_verify;;
      8) cmd_fix;;
      9) cmd_base;;
      10) cmd_banner;;
      11) cmd_update_self;;
      12) read -rp "  Domain: " d; [ -n "$d" ] && cmd_repair "$d";;
      0) exit 0;;
      "") exit 0;;
    esac
    # guard EOF: kalau stdin habis (bukan interaktif), keluar — cegah infinite loop
    [ -t 0 ] || { echo ""; break; }
    [ "$p" != "0" ] && read -rp "  Enter..."
  done
}

# ==============================================================
#  ROUTER
# ==============================================================
case "$1" in
  -boot)      # one-liner mode: pasang diri + banner + base
    cp "$0" /root/wpk.sh 2>/dev/null; chmod +x /root/wpk.sh
    R="https://raw.githubusercontent.com/triosptr/wpk-server/main"
    curl -fsSL "$R/wpk.vhost.template" -o "$VHOST_TEMPLATE" 2>/dev/null
    curl -fsSL "$R/wpk.vhost.inner" -o /root/wpk.vhost.inner 2>/dev/null
    curl -fsSL "$R/wpk_ssl_gen.py" -o /root/wpk_ssl_gen.py 2>/dev/null
    curl -fsSL "$R/wpk-config-extra.php" -o "$WP_CONFIG_EXTRA" 2>/dev/null
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
  site)       shift; cmd_site "$@";;
  server)     cmd_server;;
  self-update) cmd_update_self;;
  repair)     shift; cmd_repair "$@";;
  banner)     shift; cmd_banner "$@";;
  optimize)   cmd_optimize;;
  menu|"" )   cmd_menu;;
  *) echo "WPK v4.0 — perintah tidak dikenal: $1"
     echo "Pakai: wpk | base | verify | fix | add | banner | ssl | list | status | creds | backup | backup-all | update | remove | security | optimize";;
esac
