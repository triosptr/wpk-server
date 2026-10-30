# WPK - WordPress Kit (All-in-One Server Provisioning)

Satu script untuk provisioning server WordPress dari nol: security tingkat maksimal, kecepatan maksimal, RAM/CPU sehemat mungkin - server kecil tapi kuat trafik besar.

## Instalasi

```bash
# 1. copy wpk.sh ke server baru
scp wpk.sh root@IP_SERVER:/root/

# 2. jadikan command + install base (sekali per server)
ssh root@IP_SERVER
chmod +x /root/wpk.sh && ln -sf /root/wpk.sh /usr/local/bin/wpk
wpk base          # -> 8 step + checklist verifikasi 17 poin otomatis

# 3. tiap site baru
wpk add sub.domain.com
```

## Command

- `wpk` - menu interaktif
- `wpk base` - provisioning server kosong (sekali saja)
- `wpk add <domain>` - tambah site WordPress + SSL otomatis
- `wpk list` - daftar site + status UP/HTTPS live
- `wpk status` - RAM, swap, fail2ban, disk, jumlah site
- `wpk ssl <domain>` - (re)issue SSL
- `wpk creds <domain>` - lihat kredensial site
- `wpk backup <domain>` | `backup-all` - backup
- `wpk update <domain>` - update core+plugin+tema
- `wpk remove <domain>` - hapus site (auto-backup dulu)
- `wpk security` - audit security semua site
- `wpk optimize` - bersih-bersih cache/log + reload
- `wpk verify` - checklist kesehatan 17 poin (tes hidup)

## Yang dipasang wpk base

### Security MAX
- ufw: hanya 22/80/443
- fail2ban: sshd ban 4 jam + nginx rate-limit jail
- wp-login rate-limit 10 req/menit (mati di nginx, tak sampai PHP)
- blokir xmlrpc.php / wp-config.php / readme.html / dotfiles
- security headers (HSTS, nosniff, X-Frame, Referrer-Policy)
- kernel hardening: kptr_restrict=2, dmesg_restrict, BPF user disabled, ptrace_scope=2, kexec disabled
- network hardening: syncookies, rp_filter, tolak redirect & source-route
- SSH: cipher modern saja (chacha20-poly1305, AES-GCM) + MaxAuthTries 3 - port/password TIDAK diubah
- wp-config: DISALLOW_FILE_EDIT, DISABLE_WP_CRON, xmlrpc off, FORCE_SSL_ADMIN

### Speed MAX
- PHP 8.3 + JIT tracing 64M + OPcache file cache + realpath_cache 4M
- Nginx: worker auto + CPU affinity, 4096 conn/worker, multi_accept, epoll, aio threads
- FastCGI cache 128MB zone / TTL 120 menit - visitor tak menyentuh PHP/MySQL
- TCP BBR + fastopen
- MariaDB: binlog off, query cache off, buffer 128M hemat IO

### Hemat RAM
- PHP pool ondemand: idle = 0 worker; max_children otomatis by RAM
- Swap 4G + swappiness 10 (anti-OOM)
- MariaDB profil 128M, performance_schema OFF
- logrotate size cap 100M

## Catatan
- Idempotent - semua command aman dijalankan ulang.
- Registry site: /root/wpk-sites.reg (chmod 600).
- SSL butuh DNS resolve + Cloudflare proxy OFF.
- v1.1 - Dabara untuk Trio.
