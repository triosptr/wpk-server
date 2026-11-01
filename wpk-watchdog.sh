#!/bin/bash
# WPK WATCHDOG — pengawal otomatis server WordPress (cron 15 menit)
# Output alert: /root/wpk-alerts.log — lihat via: wpk alerts
LOG=/root/wpk-alerts.log
touch "$LOG"; chmod 600 "$LOG"
alert() { echo "[$(date '+%F %T')] $1" >> "$LOG"; }
A="/usr/sbin/nginx -t"
ok(){ :; }

# 1. DISK monitoring
USE=$(df -h / | awk 'NR==2{print int($5)}')
if [ "$USE" -ge 80 ]; then
  alert "DISK ${USE}% terpakai — auto-clean log"
  find /var/log -name "*.gz" -mtime +7 -delete 2>/dev/null
  journalctl --vacuum-size=100M >/dev/null 2>&1
  for f in /var/log/nginx/*.error.log; do [ -f "$f" ] && [ $(stat -c%s "$f") -gt 104857600 ] && truncate -s 0 "$f"; done
  [ "$USE" -ge 90 ] && alert "KRITIS: disk ${USE}% — manual check: du -sh /var/www/* | sort -rh"
fi

# 2. SITE UP check + auto-recovery
if [ -s /root/wpk-sites.reg ]; then
  while IFS='|' read -r d _; do
    [ -z "$d" ] && continue
    U="https://$d"; [ -d "/etc/letsencrypt/live/$d" ] || U="http://$d"
    if ! curl -sk -o /dev/null -m 10 "$U"; then
      alert "SITE DOWN: $d — attempt recovery"
      systemctl restart nginx 2>/dev/null
      systemctl restart php8.3-fpm 2>/dev/null || systemctl restart php-fpm 2>/dev/null
      sleep 3
      curl -sk -o /dev/null -m 10 "$U" && alert "RECOVERED: $d" || alert "MASIH DOWN: $d — manual check!"
    fi
  done < /root/wpk-sites.reg
fi

# 3. Error log membengkak
for f in /var/log/nginx/*.error.log; do
  [ -f "$f" ] && [ $(stat -c%s "$f") -gt 104857600 ] && { truncate -s 0 "$f"; alert "truncate $f (>100MB)"; }
done

# 4. SSL renew check (cert <14 hari)
if command -v certbot >/dev/null; then
  for d in /etc/letsencrypt/live/*/; do
    dom=$(basename "$d")
    EXP=$(( ( $(date -d "$(openssl x509 -enddate -noout -in "$d/fullchain.pem" 2>/dev/null | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 ))
    [ "$EXP" -lt 14 ] && { certbot renew --cert-name "$dom" --quiet 2>/dev/null && alert "SSL renewed: $dom (${EXP}d tersisa)"; }
  done
fi

# 5. Backup otomatis harian 01:00 (via cron terpisah)
H=$(date +%H)
if [ "$H" = "01" ] && [ ! -f /var/run/wpk-daily-backup ]; then
  touch /var/run/wpk-daily-backup
  if [ -s /root/wpk-sites.reg ]; then
    while IFS='|' read -r d _; do
      [ -z "$d" ] && continue
      db=$(awk -F'|' -v D="$d" '$1==D{print $2}' /root/wpk-sites.reg)
      out="/root/wpk-backups/$d-$(date +%F)"
      mkdir -p "$out"
      mysqldump --single-transaction --quick "$db" 2>/dev/null | gzip > "$out/db.sql.gz"
      tar -czf "$out/files.tar.gz" -C /var/www "$d" 2>/dev/null
      alert "AUTO-BACKUP: $d → $out"
    done < /root/wpk-sites.reg
  fi
  # hapus backup >14 hari
  find /root/wpk-backups -maxdepth 1 -type d -mtime +14 -exec rm -rf {} \; 2>/dev/null
fi
[ -f /var/run/wpk-daily-backup ] && [ "$H" != "01" ] && rm -f /var/run/wpk-daily-backup

# 6. MALWARE quick-scan (pattern webshell umum)
if [ -s /root/wpk-sites.reg ]; then
  while IFS='|' read -r d _; do
    [ -z "$d" ] && continue
    W="/var/www/$d/wp-content"
    [ -d "$W" ] || continue
    # pattern: eval base64, variable-fungsi ganda, backdoor goto
    HITS=$(grep -rl --include="*.php" -E "eval\(|base64_decode\(|assert\(" "$W/uploads" 2>/dev/null | head -3)
    [ -n "$HITS" ] && alert "MALWARE-SUSPECT di uploads $d: $HITS"
  done < /root/wpk-sites.reg
fi
