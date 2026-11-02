# PANDUAN LENGKAP: Server Kosong → WordPress Kosong Siap Diisi
# (JUMANJI v5.7)

## PERSIAPAN
1. Droplet/VPS baru: **Ubuntu 24.04 (atau 22.04)**, minimal 1GB RAM
2. Catat **IP server** yang diberikan
3. Siapkan **subdomain/domain** yang mau dipakai

---

## LANGKAH 1 — Login SSH ke server kosong
```bash
ssh root@IP_SERVER
```

## LANGKAH 2 — Pasang JUMANJI (satu baris, copy-paste)
```bash
curl -fsSL https://raw.githubusercontent.com/triosptr/wpk-server/main/wpk.sh -o /root/wpk.sh && chmod +x /root/wpk.sh && ln -sf /root/wpk.sh /usr/local/bin/jumanji && ln -sf /root/wpk.sh /usr/local/bin/wpk && curl -fsSL https://raw.githubusercontent.com/triosptr/wpk-server/main/wpk.vhost.template -o /root/wpk.vhost.template && curl -fsSL https://raw.githubusercontent.com/triosptr/wpk-server/main/wpk.vhost.inner -o /root/wpk.vhost.inner && curl -fsSL https://raw.githubusercontent.com/triosptr/wpk-server/main/wpk_ssl_gen.py -o /root/wpk_ssl_gen.py && curl -fsSL https://raw.githubusercontent.com/triosptr/wpk-server/main/wpk-config-extra.php -o /root/wpk-config-extra.php && curl -fsSL https://raw.githubusercontent.com/triosptr/wpk-server/main/wpk-watchdog.sh -o /root/wpk-watchdog.sh && chmod +x /root/wpk-watchdog.sh && jumanji
```
→ muncul menu JUMANJI dengan banner besar

## LANGKAH 3 — Install base server
Di menu ketik: **9** (Install base server)
→ 8 step otomatis ±3-5 menit (nginx, PHP 8.3 JIT, MariaDB, swap, BBR,
   firewall, fail2ban, hardening kernel)
→ **Di step 8, script meminta PORT SSH BARU:**
   - isi angka 999-1999 (misal `1877`) — kosongkan bila tetap 22
   - anti-lockout: port lama & baru hidup bersamaan dulu
→ diakhiri **CHECKLIST VERIFIKASI 18 POIN**
→ target: `>>> SEMUA CEK LOLOS — SERVER SIAP DIGUNAKAN <<<`
→ kalau ada yang merah: `jumanji fix` lalu `jumanji verify`

## LANGKAH 4 — Reboot + ganti port
Setelah base selesai, script menawarkan reboot:
- jawab **y** → server restart
- login kembali pakai port baru:
  ```bash
  ssh -p 1877 root@IP_SERVER
  ```
- jalankan: `jumanji closesmallport` → port 22 ditutup permanen
- (opsional) `jumanji` → **10** → pasang banner JUMANJI di login SSH

## LANGKAH 5 — DNS subdomain di Cloudflare
1. Cloudflare → domain → DNS → **Add record**
2. Type `A`, Name = subdomain, IPv4 = IP server
3. **Proxy: awan ABU (DNS only)** → SSL Let's Encrypt resmi
   ATAU **awan ORENG (Proxied)** → SSL via Cloudflare (origin self-signed
   otomatis dibuat; set SSL/TLS mode = **Full** di dashboard)
4. Save — JUMANJI auto-detect keduanya dan install tetap jalan

## LANGKAH 6 — Install WordPress kosong
Di menu ketik: **1**
→ masukkan subdomain → otomatis ±1-2 menit:
  database + core WordPress + vhost + SSL
→ muncul:
```
===== SITE SIAP — LANGKAH TERAKHIR VIA BROWSER =====
1. Buka  : https://subdomain.com
2. Wizard WordPress: bahasa → judul site → username → password
3. Selesai wizard → login: /wp-login.php
```

## LANGKAH 7 — Setup WordPress via wizard browser
1. Buka `https://subdomain.com`
2. Pilih **bahasa**
3. Isi **judul site**
4. Buat **username admin + password kuat** (CATAT!)
5. Install → Login

## LANGKAH 8 — (Opsional) Paket standar Trio
Yoast + Ad Inserter + ETOC + Classic Editor + tema Kadence +
komentar mati + auto-update:
- Server: `jumanji` → **3** → pilih domain → **1**
- Atau: `jumanji site subdomain.com` → pilih 1

## SELESAI — Site live, kosongan siap diisi konten

---

## PERINTAH SEHARI-HARI (jumanji / wpk sama saja)
| Perintah | Fungsi |
|---|---|
| `jumanji` | menu utama |
| `jumanji self-update` | update JUMANJI |
| `jumanji list` | daftar site + status |
| `jumanji status` | kesehatan server |
| `jumanji verify` | cek 18 poin |
| `jumanji fix` | perbaiki otomatis |
| `jumanji alerts` | temuan watchdog |
| `jumanji add <dom>` | tambah site |
| `jumanji backup <dom>` | backup DB+files |
| `jumanji remove <dom>` | hapus site (auto-backup) |
| `jumanji site <dom>` | manage per-site |

## FITUR OTOMATIS (watchdog, cron 15 menit)
- Disk ≥80% → auto-clean log; ≥90% → alert kritis
- Site down → auto-restart nginx+php-fpm → cek lagi
- Error log >100MB → truncate
- SSL <14 hari → renew otomatis
- Backup harian 01:00 (retensi 14 hari)
- Malware quick-scan uploads

## TROUBLESHOOT CEPAT
| Masalah | Solusi |
|---|---|
| SSL gagal (grey cloud) | cek A record + proxy abu |
| SSL via proxy oranye | set CF SSL mode = Full, origin self-signed otomatis |
| poin verify merah | `jumanji fix` → `jumanji verify` |
| site rusak | `jumanji repair sub.domain.com` |
| WPU/JUMANJI versi lama | `jumanji self-update` |
| port semua refused | `systemctl restart nginx` |
| lupa port SSH | lihat provider console / `cat /root/wpk-ssh-port` |
