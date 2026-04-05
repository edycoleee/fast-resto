# Integrasi WA Gateway — Fast-Klinik

Dokumen ini menjelaskan bagaimana sistem notifikasi WhatsApp bekerja di aplikasi ini:
arsitektur tabel, alur pengiriman, konfigurasi, scheduler otomatis, dan cara mengelola antrian pesan.

> **Dokumen ini juga berfungsi sebagai referensi *best practice*** untuk aplikasi lain
> yang ingin mengintegrasikan WA Gateway yang sama. Bagian [Best Practice](#best-practice)
> di akhir dokumen merangkum semua pelajaran yang diperoleh saat development.

---

## Arsitektur Umum

```
Transaksi terjadi              Setiap hari 05:05 (otomatis)  atau  Manual via UI
(lease / booking)                          │                             │
        │                                  ▼                             ▼
        ▼                         _run_scheduled_maintenance()   POST /maintenance/run
notification_jobs  ─────────────────────────────────────────────────►
  (antrian jadwal)                         │
                                           ├─ MaintenanceService.run()
                                           │   (expire booking, dll.)
                                           └─ NotificationService.process_pending_jobs()
                                               ├─ render template body
                                               ├─ POST ke WA Gateway
                                               └─ simpan ke messages
                                                    (log hasil kirim)
```

**Tiga tabel utama:**

| Tabel | Peran |
|---|---|
| `notification_jobs` | Antrian terjadwal — kapan pesan harus dikirim |
| `message_templates` | Template isi pesan + jam kirim per kode |
| `messages` | Log setiap upaya kirim (berhasil, gagal, atau inapp) |

---

## Skema Tabel

### `notification_jobs` — Antrian Jadwal

```sql
CREATE TABLE notification_jobs (
    id            INTEGER PRIMARY KEY,
    lease_id      INTEGER REFERENCES leases(id) ON DELETE CASCADE,
    booking_id    INTEGER REFERENCES bookings(id) ON DELETE CASCADE,
    customer_id   INTEGER REFERENCES customers(id) ON DELETE SET NULL,
    template_code TEXT NOT NULL,              -- misal: BILLING_D5, BOOKING_D1
    run_at        TEXT NOT NULL,              -- YYYY-MM-DD HH:MM:SS (waktu lokal)
    status        TEXT NOT NULL DEFAULT 'pending',   -- pending | done | failed
    attempts      INTEGER NOT NULL DEFAULT 0,
    last_error    TEXT,
    created_at    DATETIME,
    updated_at    DATETIME,
    UNIQUE (booking_id, lease_id, template_code, run_at)  -- cegah duplikat
);
```

**Kolom `run_at`:**
- Disimpan dalam waktu lokal server (WIB/UTC+7), bukan UTC
- Diisi saat lease/booking dibuat, berdasarkan `send_time` pada template terkait
- Scheduler membandingkan: `run_at <= datetime('now', 'localtime')`

**Status job:**

| Status | Keterangan |
|---|---|
| `pending` | Belum saatnya, atau belum diproses |
| `done` | Berhasil dikirim |
| `failed` | Gagal kirim — lihat `last_error`, bisa di-retry manual |

---

### `message_templates` — Template Pesan

```sql
CREATE TABLE message_templates (
    id        INTEGER PRIMARY KEY,
    code      TEXT UNIQUE NOT NULL,
    title     TEXT NOT NULL,
    body      TEXT NOT NULL,          -- gunakan {{placeholder}}
    target    TEXT NOT NULL,          -- customer | admin
    is_active INTEGER NOT NULL DEFAULT 1,
    send_time TEXT NOT NULL DEFAULT '05:00',   -- HH:MM waktu lokal
    created_at DATETIME,
    updated_at DATETIME
);
```

**Template bawaan (di-seed otomatis saat startup):**

| Code | Trigger | Target | send_time default |
|---|---|---|---|
| `BILLING_D5` | 5 hari sebelum end_date lease | customer | 05:00 |
| `BILLING_D1` | 1 hari sebelum end_date lease | customer | 05:00 |
| `OVERDUE_D3_ADMIN` | 3 hari setelah end_date lease (belum bayar) | admin | 05:00 |
| `BOOKING_D1` | 1 hari sebelum check-in booking | customer | 05:00 |
| `PAYMENT_DUE_D3` | 3 hari sebelum jatuh tempo bulanan | customer | 05:00 |

**Placeholder yang tersedia:**

```
{{customer_name}}   — nama penyewa
{{room_number}}     — nomor kamar
{{end_date}}        — tanggal berakhir sewa / jatuh tempo
{{amount}}          — nominal tagihan (format: 1.500.000)
```

> **Catatan `send_time`:** Nilai ini dibaca saat job dibuat (generate_lease_jobs, dll.)
> dan di-embed langsung ke kolom `run_at`. Mengubah `send_time` template hanya
> berlaku untuk job yang dibuat setelahnya — job lama tidak berubah.

---

### `messages` — Log Hasil Kirim

```sql
CREATE TABLE messages (
    id            INTEGER PRIMARY KEY,
    template_id   INTEGER REFERENCES message_templates(id) ON DELETE SET NULL,
    lease_id      INTEGER REFERENCES leases(id) ON DELETE SET NULL,
    booking_id    INTEGER REFERENCES bookings(id) ON DELETE SET NULL,
    customer_id   INTEGER REFERENCES customers(id) ON DELETE SET NULL,
    target        TEXT NOT NULL,           -- customer | admin
    channel       TEXT NOT NULL DEFAULT 'inapp',  -- whatsapp | inapp
    subject       TEXT,
    body_rendered TEXT NOT NULL,           -- isi pesan yang sudah dirender
    status        TEXT NOT NULL DEFAULT 'queued',  -- sent | failed | queued
    sent_at       TEXT,
    error_message TEXT,
    created_at    DATETIME,
    updated_at    DATETIME
);
```

| channel | Keterangan |
|---|---|
| `whatsapp` | Dikirim ke WA Gateway |
| `inapp` | Nomor tidak ada atau `ADMIN_PHONE` kosong — tersimpan hanya di log |

---

## Konfigurasi `.env`

```env
# WA Gateway
WA_GATEWAY_URL=http://192.10.10.152:8001/api/v1/whatsapp/send
WA_GATEWAY_API_KEY=your_api_key_here
WA_SOURCE_APP=fast-kos

# True = simulasi (tidak hit gateway, job tetap diproses dan disimpan ke messages)
WA_SIMULATE=False

# Nomor WA admin untuk notifikasi OVERDUE_D3_ADMIN
# Format: 628xxxxxxxxx (tanpa + atau spasi)
ADMIN_PHONE=628123456789
```

---

## Scheduler Otomatis (Built-in)

Backend menggunakan **APScheduler** yang berjalan di dalam proses FastAPI — tidak butuh cron eksternal.

### Jadwal
```
Setiap hari pukul 05:05 waktu lokal server
```

### Cara kerja
```python
# main.py — dijalankan saat startup
scheduler = AsyncIOScheduler()
scheduler.add_job(
    _run_scheduled_maintenance,
    trigger=CronTrigger(hour=5, minute=5),
    misfire_grace_time=3600,   # toleransi 1 jam jika server sempat mati
)
scheduler.start()
```

`misfire_grace_time=3600` berarti: jika server mati saat jam 05:05 lalu restart sebelum jam 06:05,
job tetap dijalankan sekali saat startup.

### Status scheduler via API
```
GET /api/v1/maintenance/scheduler
```
Response:
```json
{
  "cron": "05:05",
  "last_run_at": "2026-03-12 05:05:01",
  "last_result": { "sent": 3, "failed": 0, "expired": 1 },
  "last_error": null
}
```

> State ini disimpan in-memory (`utils/scheduler_state.py`) dan reset saat backend restart.
> Di halaman Maintenance, info ini ditampilkan otomatis di atas tombol "Jalankan Sekarang".

---

## Alur Kerja Lengkap

### 1. Pembuatan Job (saat transaksi dibuat)

```
POST /leases
  └─ LeaseService.create()
       ├─ NotificationJobRepository.generate_lease_jobs(lease_id, customer_id, end_date)
       │    ├─ BILLING_D5       : run_at = end_date - 5 hari @ send_time template
       │    ├─ BILLING_D1       : run_at = end_date - 1 hari @ send_time template
       │    └─ OVERDUE_D3_ADMIN : run_at = end_date + 3 hari @ send_time template
       └─ NotificationJobRepository.generate_monthly_payment_jobs(...)
            └─ PAYMENT_DUE_D3 : run_at = due_date - 3 hari (per bulan, selama masa sewa)

POST /bookings
  └─ BookingService.create()
       └─ NotificationJobRepository.generate_booking_jobs(booking_id, customer_id, checkin_date)
            └─ BOOKING_D1 : run_at = checkin_date - 1 hari @ send_time template
```

Perhitungan `run_at` dilakukan di Python (bukan SQLite), sehingga jam kirim template ikut ter-embed:
```python
base = datetime.fromisoformat("2026-04-30")   # end_date
h, m = 5, 0                                    # dari template.send_time "05:00"
run_at = (base + timedelta(days=-5)).replace(hour=h, minute=m, second=0)
# → "2026-04-25 05:00:00"
```

---

### 2. Pemrosesan Job (saat maintenance dijalankan)

```
_run_scheduled_maintenance()  atau  POST /api/v1/maintenance/run
    │
    ├─ MaintenanceService.run()
    │   └─ expire booking, tutup lease jatuh tempo, dll.
    │
    └─ NotificationService.process_pending_jobs()
         │
         ├─ Query:
         │    SELECT * FROM notification_jobs
         │    WHERE status = 'pending'
         │      AND run_at <= datetime('now', 'localtime')
         │    LIMIT 20
         │
         └─ Untuk setiap job:
              ├─ Render body template dengan data penyewa
              ├─ target = customer  → kirim ke customer.phone via WA Gateway
              ├─ target = admin     → kirim ke ADMIN_PHONE via WA Gateway
              │                       (jika ADMIN_PHONE kosong → simpan sebagai inapp)
              ├─ Berhasil → mark_done() + save_message(status='sent')
              └─ Gagal    → mark_failed(error) + save_message(status='failed')
```

**Payload ke WA Gateway:**
```json
POST http://192.10.10.152:8001/api/v1/whatsapp/send
X-Gateway-API-Key: <WA_GATEWAY_API_KEY>

{
  "phone_no":   "628122850264",
  "message":    "Halo Budi, sewa kamar 101 akan berakhir pada 30-04-2026. Tagihan Rp1.500.000.",
  "source_app": "fast-kos"
}
```

---

## Mengelola Antrian via UI

Halaman **Maintenance** menyediakan semua kontrol:

| Aksi | Cara |
|---|---|
| Lihat antrian | Tabel "Antrian Notifikasi" — status, jadwal, customer |
| Preview pesan | Klik ikon mata → tampil isi pesan yang sudah dirender |
| Kirim manual | Klik tombol kirim → `POST /notifications/jobs/{id}/send` |
| Batalkan job | Klik hapus → `DELETE /notifications/jobs/{id}` |
| Lihat log kirim | Tabel "Log Pesan" — channel, status, waktu kirim |

### Endpoint API

```
GET    /api/v1/notifications/jobs              — daftar job (semua status)
GET    /api/v1/notifications/jobs/{id}/preview — preview pesan dirender
POST   /api/v1/notifications/jobs/{id}/send    — kirim manual sekarang
DELETE /api/v1/notifications/jobs/{id}         — batalkan/hapus job

POST   /api/v1/maintenance/run                 — jalankan maintenance + proses job
GET    /api/v1/maintenance/scheduler           — status scheduler otomatis
GET    /api/v1/maintenance/config              — status konfigurasi WA Gateway
GET    /api/v1/messages                        — log semua pesan terkirim
```

---

## Mengubah Template Pesan

Halaman **Maintenance → Format Pesan (Template)**:

- **Isi Pesan** — edit teks, gunakan `{{placeholder}}`
- **Jam Kirim** — waktu lokal, berlaku untuk job yang dibuat setelah simpan
- **Nonaktifkan** — job yang sudah ada tetap berjalan; job baru tidak dibuat untuk template nonaktif

> Job pending yang sudah ada di antrian `run_at`-nya tidak berubah meski template diedit.
> Untuk menggunakan jadwal baru, hapus job pending terkait — job baru otomatis terbuat
> saat lease/booking berikutnya dibuat, atau restart service terkait.

---

## Alur Status Job

```
[generate saat transaksi]
         │
         ▼
      pending
         │
         ├──── scheduler 05:05 atau manual ────► run_at tercapai?
         │                                           │ Ya
         │                                           ▼
         │                               WA Gateway berhasil? ──► done → messages (sent)
         │                                           │ Tidak
         │                                           ▼
         └──────────────────────────────────►  failed → messages (failed)
                                                           │
                                                           ▼
                                              retry manual: POST /jobs/{id}/send
```

---

## File Terkait

| File | Fungsi |
|---|---|
| [backend/utils/wa_client.py](backend/utils/wa_client.py) | HTTP client ke WA Gateway (httpx async, timeout 10s) |
| [backend/utils/wa_templates.py](backend/utils/wa_templates.py) | Render `{{placeholder}}` dan context builder |
| [backend/utils/scheduler_state.py](backend/utils/scheduler_state.py) | State in-memory riwayat terakhir scheduler |
| [backend/models/notification_job.py](backend/models/notification_job.py) | Model tabel antrian job |
| [backend/models/message.py](backend/models/message.py) | Model tabel log pesan |
| [backend/models/message_template.py](backend/models/message_template.py) | Model tabel template + send_time |
| [backend/repositories/notification_job_repository.py](backend/repositories/notification_job_repository.py) | generate job, get pending, mark done/failed, `_get_send_time()` |
| [backend/services/notification_service.py](backend/services/notification_service.py) | Orkestrasi: render → kirim → log |
| [backend/api/v1/endpoints/maintenance.py](backend/api/v1/endpoints/maintenance.py) | Semua endpoint maintenance & notifikasi |
| [backend/main.py](backend/main.py) | Lifespan: init DB + seed + start scheduler |
| [backend/config/settings.py](backend/config/settings.py) | `WA_GATEWAY_URL`, `WA_GATEWAY_API_KEY`, `WA_SIMULATE`, `ADMIN_PHONE` |

---

## Troubleshooting

### Pesan tidak terkirim padahal sudah waktunya
1. Buka UI → **Log Pesan** — cari entri `status=failed`, lihat `error_message`
2. Cek `GET /api/v1/maintenance/scheduler` — apakah `last_run_at` ada?
3. Pastikan `WA_GATEWAY_URL` dan `WA_GATEWAY_API_KEY` benar di `.env`
4. Test koneksi ke gateway langsung:
   ```bash
   curl -X POST http://192.10.10.152:8001/api/v1/whatsapp/send \
     -H "X-Gateway-API-Key: your_key" \
     -H "Content-Type: application/json" \
     -d '{"phone_no":"628xxx","message":"test","source_app":"test"}'
   ```

### Job tidak dibuat saat lease/booking baru
- Pastikan template terkait ada di DB dan `is_active=1`
- Cek log backend untuk error saat `generate_*_jobs()`

### WA Gateway tidak terhubung tapi ingin test notifikasi
```env
WA_SIMULATE=True
```
Job tetap diproses normal (status `done`, masuk ke `messages`) tapi tidak ada HTTP request ke gateway.

### Pesan terkirim double
- Constraint `UNIQUE(booking_id, lease_id, template_code, run_at)` mencegah duplikat `INSERT`
- Jika masih terjadi, pastikan tidak ada dua proses maintenance berjalan bersamaan

---

## Best Practice

Bagian ini merangkum semua pelajaran yang diperoleh selama development dan debugging integrasi ini.
Tujuannya agar aplikasi lain yang menggunakan WA Gateway yang sama tidak mengulangi kesalahan yang sama.

---

### 1. Idempotency Key — Cegah Pesan Ganda saat Retry

**Masalah:** Jika request ke gateway timeout atau koneksi terputus setelah gateway menerima pesan
tetapi sebelum respons diterima, aplikasi akan retry dan mengirim pesan duplikat ke user.

**Solusi:** Selalu sertakan `idempotency_key` yang unik per percobaan kirim:

```python
await wa_client.send(
    phone_no=phone,
    message=body,
    idempotency_key=f"notif-{job_id}",   # unik per job
    callback_url=callback_url,
)
```

**Aturan pembuatan key:**
- Gunakan format `{prefix}-{entity_id}` yang stabil dan dapat direproduksi
- `notif-{job_id}` untuk pengiriman terjadwal
- `resend-msg-{message_id}` untuk pengiriman ulang manual
- Key yang sama → gateway abaikan duplikat, kembalikan response sukses

---

### 2. Callback URL — Terima Update Status Asinkron

**Masalah:** Gateway memproses pesan secara asinkron. Response `202 Accepted` hanya berarti
pesan diantrekan, bukan terkirim. Status akhir (`sent`/`failed`) baru diketahui nanti.

**Solusi:** Daftarkan endpoint callback agar gateway POST status akhir ke aplikasi:

```python
await wa_client.send(
    phone_no=phone,
    message=body,
    idempotency_key=f"notif-{job_id}",
    callback_url=settings.WA_CALLBACK_URL,   # misal: http://myapp.com/internal/wa-status
)
```

**Simpan status awal sebagai `queued`, bukan `sent`:**
```python
# Setelah terima 202 dari gateway:
save_message(status="queued", wa_queue_id=result["queue_id"])
# Status diupdate ke "sent"/"failed" nanti via callback atau fallback sync
```

**Format payload callback dari gateway:**
```json
{
  "queue_id":    55,
  "phone_no":    "628122850264",
  "source_app":  "fast-kos",
  "status":      "sent",        // atau "failed"
  "error_detail": null,
  "sent_at":     "2026-03-26T10:34:40.123456"
}
```

**Endpoint penerima callback — selalu return 200:**
```python
@router.post("/internal/wa-status")
async def wa_status_callback(body: dict, db: Session = Depends(get_db)):
    queue_id = body.get("queue_id")
    status   = body.get("status")
    sent_at  = body.get("sent_at")
    repo.update_message_wa_status(queue_id, status, sent_at, body.get("error_detail"))
    return {"ok": True}   # SELALU return 200 agar gateway tidak retry callback
```

---

### 3. Callback URL — Persyaratan Jaringan

**Masalah kritis:** `callback_url` harus dapat dijangkau dari container gateway, bukan dari
container aplikasi itu sendiri. Jika gateway dan aplikasi berada di Docker network yang berbeda,
URL internal docker (misalnya `http://kos-backend:8000`) **tidak akan bisa diakses**.

**Aturan:**
- Gunakan **IP host atau domain publik**, bukan nama container Docker
- Jika aplikasi di-proxy via nginx, pastikan ada route untuk path callback:

```nginx
# nginx-kos.conf
location /internal/ {
    proxy_pass http://kos-backend:8000/internal/;
    proxy_read_timeout 10s;
}
```

- Endpoint callback **jangan diletakkan di bawah prefix `/api/v1/`** atau path berautentikasi —
  gateway POST ke sana tanpa token. Mount langsung di level app:

```python
# main.py — BENAR: tanpa prefix, bisa dijangkau sebagai /internal/wa-status
app.include_router(notification_router)

# SALAH: terkubur di /api/v1/internal/wa-status
api_router.include_router(notification_router)
```

**Contoh URL yang benar:**
```env
WA_CALLBACK_URL=http://192.10.10.152:3001/internal/wa-status
```

**Test dari container gateway:**
```bash
docker exec wa-gateway curl -X POST http://192.10.10.152:3001/internal/wa-status \
  -H "Content-Type: application/json" \
  -d '{"queue_id":999,"status":"sent","phone_no":"628xxx","source_app":"test"}'
# Harus return: {"ok":true}
```

---

### 4. Fallback Sync — Jangan Bergantung Hanya pada Callback

**Masalah:** Callback bersifat *fire-and-forget* — jika gagal (network timeout, server sedang
restart, dll.), gateway **tidak retry** dan status pesan di DB aplikasi akan selamanya `queued`.

**Solusi:** Implementasikan background sync yang aktif query status dari gateway:

```python
# services/notification_service.py
async def sync_queued_wa_statuses(db) -> int:
    """
    Fallback sync: query wa-gateway untuk setiap message yang masih 'queued'.
    Return jumlah pesan yang berhasil di-update.
    """
    repo = NotificationJobRepository(db)
    queue_ids = repo.get_queued_wa_ids()   # SELECT wa_queue_id WHERE status='queued'
    if not queue_ids:
        return 0

    base = settings.WA_GATEWAY_URL.rsplit("/", 1)[0]  # URL base tanpa /send
    headers = {"X-Gateway-API-Key": settings.WA_GATEWAY_API_KEY}
    updated = 0
    async with httpx.AsyncClient(timeout=10) as client:
        for qid in queue_ids:
            r = await client.get(f"{base}/queue/{qid}", headers=headers)
            if r.status_code != 200:
                continue
            gw_status = r.json()["data"]["status"]
            if gw_status not in ("sent", "failed"):
                continue  # masih pending/processing di gateway, skip
            repo.update_message_wa_status(qid, gw_status, ...)
            updated += 1
    return updated
```

**Jalankan sebagai background loop di lifespan FastAPI:**

```python
# main.py
async def _wa_sync_loop():
    while True:
        await asyncio.sleep(120)   # setiap 2 menit
        db = SessionLocal()
        try:
            await sync_queued_wa_statuses(db)
        finally:
            db.close()

@asynccontextmanager
async def lifespan(app):
    sync_task = asyncio.create_task(_wa_sync_loop())
    yield
    sync_task.cancel()
```

> **Kenapa `asyncio.create_task` bukan APScheduler `IntervalTrigger`?**
> APScheduler memiliki bug pada integrasi dengan uvicorn: `IntervalTrigger` kadang tidak
> terpicu meski scheduler berjalan. `asyncio.create_task` hidup di event loop yang sama
> dengan uvicorn sehingga lebih reliabel untuk interval pendek.

**Header autentikasi yang benar untuk WA Gateway ini:**
```python
# BENAR
headers = {"X-Gateway-API-Key": settings.WA_GATEWAY_API_KEY}

# SALAH — akan 403
headers = {"X-API-Key": settings.WA_GATEWAY_API_KEY}
```

---

### 5. Timezone — Simpan UTC+Z, Tampilkan Lokal

**Masalah:** Python `datetime.utcnow().isoformat()` menghasilkan string tanpa timezone suffix,
misalnya `2026-03-26T03:33:48`. Browser JavaScript menginterpretasi string tanpa suffix `Z`
sebagai **waktu lokal**, padahal isinya UTC. Akibatnya jam yang ditampilkan salah.

**Solusi backend — selalu tambahkan `Z` di akhir string UTC:**
```python
# BENAR — browser tahu ini UTC, konversi otomatis ke lokal saat display
def _now_str() -> str:
    return datetime.utcnow().isoformat() + "Z"
# → "2026-03-26T03:33:48.123456Z"

# SALAH — browser anggap waktu lokal, tampil minus 7 jam di browser WIB
def _now_str() -> str:
    return datetime.utcnow().isoformat()
# → "2026-03-26T03:33:48.123456"
```

**Solusi frontend — gunakan `Intl.DateTimeFormat` untuk format lokal otomatis:**
```js
// format.js
export function formatDateTime(dateStr) {
  if (!dateStr) return '—'
  return new Intl.DateTimeFormat('id-ID', {
    day: 'numeric', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  }).format(new Date(dateStr))   // new Date("...Z") otomatis konversi ke lokal browser
}
```

Dengan kombinasi `"...Z"` di backend dan `Intl.DateTimeFormat` di frontend:
- DB menyimpan `2026-03-26T03:33:48Z` (UTC)
- Browser WIB (UTC+7) menampilkan `26 Mar 2026, 10.33` ✓

---

### 6. Health Check — Parsing Response Gateway

**Masalah:** Response `/check-key` dari gateway memiliki struktur nested yang tidak konsisten —
field `is_connected` bisa ada di dua tempat berbeda tergantung versi gateway.

**Solusi — baca dari kedua tempat dengan fallback:**
```python
async def health_check(self) -> dict:
    r = await client.post(check_key_url, ...)
    data = r.json().get("data", {})

    # Coba lokasi flat dulu, lalu nested sebagai fallback
    is_connected = data.get("is_connected")
    wa_number = data.get("wa_number")

    if is_connected is None:
        # Struktur nested: data.provider_response.data.licenses_key[0]
        licenses = (
            data.get("provider_response", {})
                .get("data", {})
                .get("licenses_key", [{}])
        )
        key_info = licenses[0] if licenses else {}
        is_connected = key_info.get("is_connected", False)
        wa_number = key_info.get("wa_number")

    return {"is_connected": bool(is_connected), "wa_number": wa_number}
```

---

### 7. Frontend Auto-Refresh — Polling Kondisional

**Masalah:** Status pesan di frontend tidak update otomatis setelah backend sync ('queued' → 'sent').

**Solusi — polling aktif hanya saat ada pesan `queued`, berhenti sendiri saat selesai:**

```js
// PesanPage.jsx
const hasQueued = (msgFetch.data?.items || []).some(m => m.status === 'queued')

// Gunakan ref agar interval tidak di-reset setiap render
const refetchRef = useRef(msgFetch.refetch)
refetchRef.current = msgFetch.refetch

useEffect(() => {
  if (!hasQueued) return                              // stop jika tidak ada queued
  const id = setInterval(() => refetchRef.current(), 10_000)  // polling 10 detik
  return () => clearInterval(id)                     // cleanup saat unmount/stop
}, [hasQueued])
```

**Alur lengkap status pesan di UI:**
```
[kirim] → queued  (frontend polling aktif, 10 detik sekali)
              ↓ (max 2 menit — backend sync dari gateway)
           sent   (frontend polling berhenti otomatis)
```

---

### Checklist Integrasi untuk Aplikasi Baru

Salin checklist ini saat memulai integrasi WA Gateway di proyek baru:

```
[ ] Tambah kolom wa_queue_id di tabel messages/log
[ ] Simpan status awal sebagai 'queued' setelah terima 202 (bukan 'sent')
[ ] idempotency_key dikirim: format {prefix}-{entity_id} yang stabil
[ ] callback_url dikonfigurasi dan dapat dijangkau dari container gateway
[ ] Endpoint /internal/wa-status:
    [ ] Dipasang di level app (bukan di bawah /api/v1 atau prefix berautentikasi)
    [ ] nginx punya route untuk path /internal/
    [ ] Selalu return 200 meski data tidak ditemukan
[ ] Fallback sync background loop aktif (asyncio.create_task, interval 2 menit)
    [ ] Header menggunakan X-Gateway-API-Key (bukan X-API-Key)
[ ] UTC timestamp disimpan dengan suffix Z ("...UTC_ISO_STRING...Z")
[ ] Frontend: auto-polling kondisional aktif saat ada status queued
[ ] Health check mem-parsing struktur nested response /check-key
[ ] Test callback dari container gateway sebelum deploy ke production
```