# PANDUAN LENGKAP: Server Kosong → WordPress Kosong Siap Diisi
# (WPK v4.9 — JUMANJI Server)

## PERSIAPAN
1. Droplet/VPS baru: **Ubuntu 24.04 (atau 22.04)**, minimal 1GB RAM
2. Catat **IP server** yang diberikan
3. Siapkan **subdomain/domain** yang mau dipakai

---

## LANGKAH 1 — Login SSH ke server kosong
```bash
ssh root@IP_SERVER
# (password dari provider / SSH key Bapak)
```

## LANGKAH 2 — Pasang WPK (satu baris, copy-paste)
```bash
curl -fsSL https://raw.githubusercontent.com/triosptr/wpk-server/main/wpk.sh -o /root/wpk.sh && chmod +x /root/wpk.sh && ln -sf /root/wpk.sh /usr/local/bin/wpk && wpk
```
→ muncul menu WPK dengan banner JUMANJI

## LANGKAH 3 — Install base server
Di menu ketik: **9**
→ 8 step otomatis (nginx, PHP 8.3 JIT, MariaDB, swap, BBR, firewall,
   fail2ban, hardening) ± 3-5 menit
→ diakhiri **CHECKLIST VERIFIKASI 17/18 POIN**
→ target: `>>> SEMUA CEK LOLOS — SERVER SIAP DIGUNAKAN <<<`
→ kalau ada yang merah: ketik `wpk fix` lalu `wpk verify`

**Ganti port SSH (diminta saat install):**
- Script minta port baru — isi angka 999-1999 (misal `1877`)
- Setelah install selesai, script tanya reboot → jawab `y`
- Setelah reboot, login: `ssh -p 1877 root@IP_SERVER`
- Lalu jalankan: `wpk closesmallport` (tutup port 22)
- Selanjutnya SELALU login via port baru

## LANGKAH 4 — Pasang banner JUMANJI (opsional tapi keren)
Di menu ketik: **10**
→ tiap login SSH disambut tulisan JUMANJI

## LANGKAH 5 — Siapkan DNS subdomain di Cloudflare
Sebelum install site, buat dulu DNS-nya:
1. Buka Cloudflare → pilih domain → **DNS**
2. **Add record**: Type `A`, Name `subdomain-yang-diinginkan`, IPv4 `IP_SERVER`
3. **Proxy status: OFF (awan abu-abu / DNS only)** ← WAJIB, kalau oranye SSL akan gagal
4. Save
(WPK otomatis mengecek: kalau DNS belum resolve / salah IP, dia beri tahu sebelum SSL gagal)

## LANGKAH 6 — Install WordPress kosong
Di menu ketik: **1**
→ masukkan subdomain, misal: `toko.jualpakaianbekas.com`
→ otomatis: database + core WordPress + vhost + SSL (± 1-2 menit)
→ di akhir muncul:
```
===== SITE SIAP — LANGKAH TERAKHIR VIA BROWSER =====
1. Buka  : https://toko.jualpakaianbekas.com
2. Wizard WordPress: pilih bahasa → judul site → username → password
3. Selesai wizard → login: /wp-login.php
```

## LANGKAH 7 — Setup WordPress via wizard browser
1. Buka `https://toko.jualpakaianbekas.com` di browser
2. Pilih **bahasa** (Indonesia)
3. Isi **judul site**
4. Buat **username admin** + **password kuat** (CATAT!)
5. Klik Install → login

## LANGKAH 8 — (Opsional) Pasang paket standar Trio
Setelah login beres, kalau mau langsung lengkap (Yoast, Ad Inserter,
ETOC, Classic Editor, tema Kadence, komentar mati, auto-update):
- Di server: `wpk` → **3** (Manage site) → pilih domain → **1**
- Atau langsung: `wpk site toko.jualpakaianbekas.com` → pilih 1

## SELESAI — Site live, kosongan siap diisi konten

---

## PERINTAH SEHARI-HARI
| Perintah | Fungsi |
|---|---|
| `wpk` | menu utama |
| `wpk self-update` | update WPK ke versi terbaru |
| `wpk list` | daftar semua site + status UP/HTTPS |
| `wpk status` | kesehatan server (RAM, swap, dll) |
| `wpk verify` | cek 17 poin keamanan & kesehatan |
| `wpk fix` | perbaiki otomatis poin yang gagal |
| `wpk add sub.domain.com` | tambah site baru |
| `wpk backup sub.domain.com` | backup DB+files |
| `wpk remove sub.domain.com` | hapus site (auto-backup) |
| `wpk site <domain>` | menu manage per-site |

## TROUBLESHOOT CEPAT
| Masalah | Solusi |
|---|---|
| SSL gagal | cek DNS: A record benar + proxy awan MATI (abu, bukan oranye) |
| ada poin verify merah | `wpk fix` lalu `wpk verify` |
| site error/rebuild | `wpk repair sub.domain.com` |
| WPK versi lama | `wpk self-update` |
| port semuanya refused | `systemctl restart nginx` |
