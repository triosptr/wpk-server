#!/bin/bash
# =============================================================
# WP-SITE — Deploy 1 WordPress site ke server yang sudah WP-BASE
# Usage: bash wp_site_deploy.sh <domain> <site-title> <admin-email>
# Idempotent. Vhost hard + FastCGI cache + pool wp bersama.
# =============================================================
set +e
D="$1"; TITLE="${2:-$D}"; EMAIL="${3:-info@${D#*.}}"
[ -z "$D" ] && { echo "Usage: $0 <domain> [title] [email]"; exit 1; }

echo "===== WP-SITE $D ====="
PHPV=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
DBNAME="wp_${D//./_}"; DBUSER="u_${D//./_}"
DBPASS=$(openssl rand -base64 18 | tr -d '/+=')
ADMINPASS=$(openssl rand -base64 16 | tr -d '/+=')
ADMINUSER=$(tr -dc 'a-z' </dev/urandom | head -c 8)

# --- DB ---
if ! mysql -e "USE \`$DBNAME\`" 2>/dev/null; then
  mysql -e "CREATE DATABASE \`$DBNAME\`; CREATE USER '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASS'; GRANT ALL ON \`$DBNAME\`.* TO '$DBUSER'@'localhost'; FLUSH PRIVILEGES;"
  echo "[db] $DBNAME dibuat"
fi

# --- docroot + WP core ---
mkdir -p /var/www/$D && cd /var/www/$D || exit 1
if [ ! -f wp-config.php ]; then
  wp core download --path=/var/www/$D --quiet
  wp config create --path=/var/www/$D --dbname="$DBNAME" --dbuser="$DBUSER" --dbpass="$DBPASS" --dbhost=localhost --quiet
  # append hardening (blok marker aman, tidak dobel)
  if ! grep -q DISALLOW_FILE_EDIT wp-config.php; then
    echo "" >> wp-config.php
    cat /root/wp-config-extra.php >> wp-config.php
  fi
  chown -R www-data:www-data /var/www/$D
  echo "[wp] core terdownload"
fi

# --- vhost ---
if [ ! -f /etc/nginx/sites-available/$D ]; then
  sed "s/__DOMAIN__/$D/g" /root/wp.vhost.template > /etc/nginx/sites-available/$D
  ln -sf /etc/nginx/sites-available/$D /etc/nginx/sites-enabled/$D
  nginx -t && systemctl reload nginx
  echo "[vhost] $D aktif (HTTP dulu, SSL belakangan)"
fi

# --- SSL (butuh DNS sudah resolve, proxy CF OFF) ---
if ! [ -d "/etc/letsencrypt/live/$D" ]; then
  certbot certonly --webroot -w /var/www/_letsencrypt -d $D --non-interactive --agree-tos -m "$EMAIL" --no-eff-email && {
    # tukar listen 80 -> ssl + redirect
    python3 - "$D" <<'PYEOF'
import sys
d = sys.argv[1]
p = f"/etc/nginx/sites-available/{d}"
s = open(p).read()
s = s.replace("listen 80;", "listen 443 ssl http2;\n    ssl_certificate /etc/letsencrypt/live/%s/fullchain.pem;\n    ssl_certificate_key /etc/letsencrypt/live/%s/privkey.pem;\n\n    # redirect http->https\n    if ($scheme != \"https\") { return 301 https://$host$request_uri; }" % (d, d))
s = s.replace("include /etc/nginx/snippets/security_headers.conf;", "include /etc/nginx/snippets/security_headers.conf;\n    ssl_protocols TLSv1.2 TLSv1.3;\n    ssl_prefer_server_ciphers on;")
open(p, "w").write(s)
PYEOF
    nginx -t && systemctl reload nginx
    echo "[ssl] OK"
  }
fi

# --- WP install ---
if ! sudo -u www-data wp core is-installed --path=/var/www/$D 2>/dev/null; then
  sudo -u www-data wp core install --path=/var/www/$D --url="https://$D" --title="$TITLE" \
    --admin_user="$ADMINUSER" --admin_password="$ADMINPASS" --admin_email="$EMAIL" --skip-email --quiet
  echo "[wp] TERINSTALL"
fi

# --- post-install WP hardening (idempotent) ---
sudo -u www-data wp option update default_comment_status closed --path=/var/www/$D
sudo -u www-data wp option update default_ping_status closed --path=/var/www/$D
sudo -u www-data wp option update blog_public 1 --path=/var/www/$D
sudo -u www-data wp rewrite structure '/%postname%/' --hard --path=/var/www/$D
sudo -u www-data wp rewrite flush --hard --path=/var/www/$D

# system cron untuk wp-cron (DISABLE_WP_CRON sudah di wp-config)
grep -q "wp-cron.php" /etc/crontab || echo "*/15 * * * * root curl -sk https://$D/wp-cron.php?doing_wp_cron >/dev/null 2>&1" >> /etc/crontab

echo "===== SITE $D SIAP ====="
echo "URL:      https://$D"
echo "Admin:    https://$D/wp-login.php"
echo "User:     $ADMINUSER"
echo "Pass:     $ADMINPASS"
echo "DB pass:  $DBPASS  (simpan aman)"
