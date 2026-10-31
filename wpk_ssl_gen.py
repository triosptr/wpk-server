import re, sys
d = sys.argv[1]
import os
tp = "/root/wpk.vhost.template"
if not os.path.exists(tp): tp = "/root/wp-server-base/wpk.vhost.template"
tmpl = open(tp).read()
body = tmpl.replace("__DOMAIN__", d).replace("__SOCKET__", "/run/php/php8.3-fpm-wp.sock")
inner = body.strip()
ssl_lines = (
    f"    ssl_certificate /etc/letsencrypt/live/{d}/fullchain.pem;\n"
    f"    ssl_certificate_key /etc/letsencrypt/live/{d}/privkey.pem;\n"
    "    ssl_protocols TLSv1.2 TLSv1.3;\n"
    "    ssl_prefer_server_ciphers on;\n"
    "    include /etc/nginx/snippets/security_headers.conf;\n"
)
vhost = (
    f"# WPK vhost HTTPS - {d}\n"
    "server {\n"
    "    listen 443 ssl http2;\n"
    f"    server_name {d};\n"
    f"    root /var/www/{d};\n"
    "    index index.php;\n"
    + inner + "\n"
    + ssl_lines +
    "}\n\n"
    "server {\n"
    "    listen 80;\n"
    f"    server_name {d};\n"
    "    location ^~ /.well-known/acme-challenge/ { root /var/www/_letsencrypt; }\n"
    "    location / { return 301 https://$host$request_uri; }\n"
    "}\n"
)
open(f"/etc/nginx/sites-available/{d}", "w").write(vhost)
print("vhost written")
