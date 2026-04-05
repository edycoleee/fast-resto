# Simplifikasi-4: CMS Landing, QR Table Order, Nota WhatsApp

**Tanggal:** 5 April 2026
**Konteks:** Evaluasi apakah tiga fitur ini perlu direncanakan SEBELUM init.sql ditulis,
atau bisa ditambahkan belakangan.

---

## Narasi Singkat — Apa yang Diminta

Anda membayangkan alur seperti ini:

```
[CUSTOMER]
  Duduk di meja → scan QR code di meja
  ↓
  Buka halaman menu di HP (dari CMS landing)
  ↓
  Pilih menu, tap "Pesan"
  ↓
[SISTEM — BACKEND]
  Order masuk dengan status: "self_order" / "menunggu kasir"
  ↓
[KASIR — Dashboard]
  Notif order masuk dari meja X
  Kasir review: tambah item? kurangi? konfirmasi?
  ↓
  Customer bayar (QRIS / cash)
  ↓
  Kasir input payment → transaksi selesai
  ↓
[SISTEM — WhatsApp]
  Kirim struk / nota ke nomor HP customer
  (via WhatsApp Business API)
```

Pertanyaan intinya: **apakah ini perlu direncanakan sekarang, SEBELUM menulis init.sql?**

Jawabannya: **Ya, wajib direncanakan sekarang.** Berikut penjelasannya.

---

## Mengapa Harus Direncanakan Sebelum init.sql

### Alasan 1: Tiga Fitur Ini Mengubah Skema Database

Ketiga fitur yang Anda sebut bukan hanya fitur frontend — semuanya membutuhkan
**perubahan struktur tabel** yang sudah dibahas di `resto-finance-2.md`.

Kalau `init.sql` sudah dijalankan dan database sudah running, menambah kolom
atau tabel baru artinya harus tulis `ALTER TABLE` — lebih ribet dan rawan error.
Lebih baik selesaikan dulu di tahap perencanaan, lalu tulis init.sql sekali jalan.

**Apa saja yang berubah?** Lihat bagian berikutnya.

### Alasan 2: QR Order Mengubah Cara `orders` Terbentuk

Selama ini asumsinya: kasir yang buka order → kasir yang input item → bayar.
Dengan QR self-order: **customer yang buka order dan input item sendiri**.

Ini butuh:
- Tabel `tables` (daftar meja fisik di restoran)
- Kolom `table_id` di `orders` (FK ke meja)
- Kolom `order_source` di `orders` (kasir input vs customer self-order)
- Kolom `customer_name` dan `customer_phone` di `orders` (untuk nota WA)

Tanpa kolom-kolom ini, init.sql yang sudah ada tidak bisa menampung alur baru.

### Alasan 3: Nota WhatsApp Butuh Data di Database

Untuk kirim nota via WA, sistem butuh nomor HP customer.
Nomor HP ini harus disimpan — paling logis di tabel `orders` karena setiap
transaksi bisa punya customer berbeda (beda dengan konsep member).

Kalau tidak direncanakan, `orders` tidak punya `customer_phone` dan fitur WA
tidak bisa diimplementasi tanpa `ALTER TABLE` belakangan.

### Alasan 4: CMS Landing — Minimal DB Impact, Tapi Ada

CMS landing perlu tahu menu mana yang bisa dipesan (is_available) dan
tampilan kategori menu. Ini sebagian besar sudah ada di skema saat ini.
Yang mungkin perlu ditambah: `menu_image_url`, urutan tampil (`sort_order`),
dan deskripsi panjang (`description`).

Perubahan ini kecil — tapi tetap lebih baik direncanakan sekarang.

---

## Rencana Perubahan Schema

### A. Tabel Baru: `tables` (Daftar Meja Fisik)

```sql
CREATE TABLE tables (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id UUID NOT NULL REFERENCES restaurants(id),
    -- Nomor atau nama meja: "1", "2", "VIP-1", "Teras-3"
    table_number  VARCHAR(20) NOT NULL,
    -- Kapasitas kursi — opsional, untuk info saja
    capacity      INTEGER DEFAULT 4,
    -- QR code value — bisa UUID unik per meja, dipakai di URL
    -- Contoh: https://resto.app/order?t=abc123
    qr_token      VARCHAR(64) NOT NULL UNIQUE,
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (restaurant_id, table_number)
);

-- Index untuk lookup QR token (terjadi setiap customer scan)
CREATE INDEX idx_tables_qr_token ON tables(qr_token) WHERE is_active = TRUE;
```

**Catatan qr_token:**
`qr_token` adalah string unik per meja — ini yang di-embed ke dalam QR code.
Saat customer scan, aplikasi baca token ini dan tahu order dari meja mana.
Bukan UUID order (yang belum ada) — tapi UUID/token meja (tetap, tidak berubah).

---

### B. Perubahan Tabel `orders`

```sql
-- Tambah ENUM source
CREATE TYPE order_source AS ENUM (
    'kasir',       -- kasir yang input langsung (alur lama)
    'self_order',  -- customer scan QR dan pesan sendiri
    'platform'     -- GrabFood, GoFood (sudah ada di channel)
);

-- Kolom baru di orders:
table_id        UUID REFERENCES tables(id),          -- meja mana
order_source    order_source NOT NULL DEFAULT 'kasir', -- siapa yang buat
customer_name   VARCHAR(100),                          -- opsional, untuk struk
customer_phone  VARCHAR(20),                           -- untuk nota WA
```

**Kolom `table_number` yang sudah ada bisa dipertahankan** sebagai snapshot
(denormalisasi ringan) — supaya laporan lama tidak perlu JOIN ke `tables`.
Atau bisa dihapus dan ganti dengan JOIN. Pilihan: **pertahankan keduanya**,
isi `table_number` dari `tables.table_number` saat order dibuat.

---

### C. Perubahan Tabel `menus` (Untuk CMS Landing)

```sql
-- Tambah kolom opsional untuk tampilan CMS:
description     TEXT,           -- deskripsi panjang menu untuk halaman landing
image_url       VARCHAR(500),   -- URL gambar menu (CDN / storage)
sort_order      INTEGER DEFAULT 0,  -- urutan tampil di halaman (drag-and-drop)
```

Kolom ini bersifat **nullable** dan tidak mempengaruhi logika backend sama sekali —
hanya untuk tampilan CMS.

---

### D. Tabel Baru: `order_sessions` (Opsional — Multi-Round Self-Order)

Ini opsional, hanya dibutuhkan jika customer bisa **pesan lebih dari sekali**
selama di meja yang sama (misalnya: pesan makanan → makan → pesan dessert → makan → minta bill).

```sql
-- Jika tidak butuh multi-round: skip tabel ini.
-- Customer langsung submit → satu order → kasir proses.
-- Ini DISARANKAN untuk tahap pertama (YAGNI).
```

Rekomendasi: **skip dulu**. Implementasi satu order per meja per visit sudah cukup
untuk restoran satu cabang. Multi-round bisa ditambah di fase berikutnya.

---

## Alur Teknis Detail

### Alur 1: Customer Scan QR → Self Order

```
1. Customer scan QR di meja Nomor 3
   URL: https://[domain]/menu?t={qr_token_meja_3}

2. Frontend baca qr_token → API GET /tables/{qr_token}
   Response: { table_id, table_number, restaurant_id }

3. Customer browsing menu dari CMS
   API: GET /menus?restaurant_id=X&is_available=true
   Tampil: nama menu, harga, gambar, deskripsi

4. Customer pilih menu → tap "Pesan"
   Customer isi nama (opsional) dan nomor HP (untuk nota WA)
   Tap "Konfirmasi Pesanan"

5. API POST /orders/self-order
   Body: {
     table_id, customer_name, customer_phone,
     items: [{ menu_id, qty, notes }]
   }
   Backend: buat order dengan order_source='self_order', status='open'

6. Dashboard kasir: notif real-time order baru dari Meja 3
   (via WebSocket atau polling setiap 5 detik — pilih sesuai kompleksitas)
```

### Alur 2: Kasir Review → Bayar

```
7. Kasir buka order dari Meja 3 di dashboard
   Bisa: tambah item, hapus item, ubah qty
   (Permission: kasir bisa edit order dengan status 'open')

8. Customer selesai makan → minta bill
   Kasir pilih metode bayar: cash / QRIS
   Klik "Proses Pembayaran"

9. Backend jalankan complete_order() — sama seperti alur kasir biasa
   → depresi stok
   → catat ke stock_movements
   → update incomes
   → status order → 'completed'
```

### Alur 3: Kirim Nota via WhatsApp

> **Arsitektur yang dipakai:** WA Gateway self-hosted (sama persis dengan
> yang sudah berjalan di Fast-Klinik). Bukan Meta Cloud API.
> Semua best practice dari `wa-gateway.md` diadopsi penuh.

```
10. Setelah complete_order() sukses:
    Backend cek: apakah orders.customer_phone ada?

11. Jika ada → backend buat notification_job dengan:
    - template_code = 'ORDER_RECEIPT'
    - run_at = NOW() (langsung kirim, bukan terjadwal)
    - order_id = order yang baru selesai
    - status = 'pending'

12. NotificationService.process_pending_jobs() dipanggil sebagai
    FastAPI BackgroundTasks segera setelah job dibuat:
    - Render template body dengan data order
    - POST ke WA Gateway dengan idempotency_key
    - Simpan ke messages dengan status='queued'
    - Gateway proses → callback ke /internal/wa-status
    - Fallback sync background loop update jika callback terlewat

13. Status di messages: queued → sent / failed
    Bisa dipantau via dashboard owner
```

---

## Arsitektur WA — Adopsi dari Fast-Klinik (Proven)

Tidak membuat sistem WA baru dari nol. Adopsi penuh arsitektur yang
sudah terbukti berjalan di Fast-Klinik, dengan adaptasi untuk konteks restoran.

### Tiga Tabel Inti

```
order selesai                    atau  Manual via UI
      │                                      │
      ▼                                      ▼
notification_jobs  ────────────────────────►
  (antrian kirim)        │
                         ├─ NotificationService.process_pending_jobs()
                         │   ├─ render template body
                         │   ├─ POST ke WA Gateway
                         │   └─ simpan ke messages
                         │        (log hasil kirim)
                         └─ Fallback: background loop sync status
```

#### Tabel 1: `wa_message_templates` — Template Pesan

```sql
CREATE TABLE wa_message_templates (
    id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    code       VARCHAR(50) UNIQUE NOT NULL,  -- ORDER_RECEIPT, ORDER_CONFIRM
    title      VARCHAR(100) NOT NULL,
    body       TEXT NOT NULL,               -- gunakan {{placeholder}}
    is_active  BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
```

**Template bawaan (seed data):**

| Code | Trigger | Deskripsi |
|---|---|---|
| `ORDER_RECEIPT` | Setelah order selesai (complete_order) | Struk/nota ke customer |
| `ORDER_CONFIRM` | Setelah kasir konfirmasi self-order | "Pesanan kamu sudah kami terima" |

**Placeholder untuk `ORDER_RECEIPT`:**
```
{{restaurant_name}}  — nama restoran
{{order_number}}     — nomor order (ORD-20260405-001)
{{table_number}}     — nomor meja
{{customer_name}}    — nama customer
{{items_list}}       — daftar menu (dirender multiline)
{{total}}            — total bayar (format: Rp75.000)
{{payment_method}}   — Cash / QRIS
{{datetime}}         — tanggal & waktu WIB
```

**Contoh isi template `ORDER_RECEIPT`:**
```
Halo {{customer_name}}! 👋

Terima kasih sudah makan di {{restaurant_name}}.

Struk Pesanan #{{order_number}}
Meja: {{table_number}} | {{datetime}}

{{items_list}}
─────────────────
Total: {{total}}
Bayar: {{payment_method}}

Selamat menikmati! 🍽️
```

---

#### Tabel 2: `notification_jobs` — Antrian Kirim

```sql
CREATE TABLE notification_jobs (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id      UUID REFERENCES orders(id) ON DELETE SET NULL,
    template_code VARCHAR(50) NOT NULL,
    -- run_at diisi NOW() untuk kirim langsung, atau future datetime untuk terjadwal
    run_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status        VARCHAR(20) NOT NULL DEFAULT 'pending',  -- pending | done | failed
    attempts      INTEGER NOT NULL DEFAULT 0,
    last_error    TEXT,
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    updated_at    TIMESTAMPTZ DEFAULT NOW(),
    -- Cegah job duplikat untuk order + template yang sama
    UNIQUE (order_id, template_code)
);

CREATE INDEX idx_notif_jobs_pending
    ON notification_jobs(run_at)
    WHERE status = 'pending';
```

**Status job:**

| Status | Keterangan |
|---|---|
| `pending` | Belum diproses atau belum waktunya |
| `done` | Berhasil kirim ke gateway |
| `failed` | Gagal — lihat `last_error`, bisa retry manual |

---

#### Tabel 3: `messages` — Log Setiap Upaya Kirim

```sql
CREATE TABLE messages (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    job_id        UUID REFERENCES notification_jobs(id) ON DELETE SET NULL,
    order_id      UUID REFERENCES orders(id) ON DELETE SET NULL,
    phone         VARCHAR(20) NOT NULL,
    channel       VARCHAR(20) NOT NULL DEFAULT 'whatsapp',  -- whatsapp | inapp
    body_rendered TEXT NOT NULL,        -- isi pesan yang sudah dirender
    -- wa_queue_id: ID dari gateway setelah diterima (202 Accepted)
    wa_queue_id   INTEGER,
    status        VARCHAR(20) NOT NULL DEFAULT 'queued',  -- queued | sent | failed
    sent_at       TIMESTAMPTZ,
    error_message TEXT,
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    updated_at    TIMESTAMPTZ DEFAULT NOW()
);

-- Index untuk fallback sync (cari semua yang masih queued)
CREATE INDEX idx_messages_queued
    ON messages(wa_queue_id)
    WHERE status = 'queued';
```

**Mengapa `status = 'queued'` bukan langsung `'sent'`?**
Gateway memproses WA secara asinkron. Response `202 Accepted` hanya berarti
pesan masuk antrian gateway, bukan sudah terkirim ke HP customer.
Status final (`sent`/`failed`) datang via callback atau fallback sync.

---

### Konfigurasi `.env` (Sama Persis dengan Fast-Klinik)

```env
# WA Gateway — gunakan gateway yang sama
WA_GATEWAY_URL=http://192.10.10.152:8001/api/v1/whatsapp/send
WA_GATEWAY_API_KEY=your_api_key_here
WA_SOURCE_APP=fast-resto

# True = simulasi (tidak hit gateway, job tetap diproses dan masuk messages)
WA_SIMULATE=False

# URL yang bisa dijangkau dari container gateway (bukan localhost!)
WA_CALLBACK_URL=http://192.10.10.XX:PORT/internal/wa-status
```

---

### Alur Kirim Nota Detail

```python
# services/notification_service.py

async def send_order_receipt(order_id: UUID, db: Session):
    """
    Dipanggil via FastAPI BackgroundTasks setelah complete_order() sukses.
    """
    order = db.query(Order).filter(Order.id == order_id).first()
    if not order or not order.customer_phone:
        return  # tidak ada nomor HP — skip

    # 1. Buat job (UNIQUE constraint cegah duplikat)
    job = NotificationJob(
        order_id=order_id,
        template_code='ORDER_RECEIPT',
        run_at=datetime.now(WIB),  # langsung
        status='pending',
    )
    db.add(job)
    db.commit()

    # 2. Render template
    template = db.query(WaMessageTemplate).filter_by(code='ORDER_RECEIPT').first()
    body = render_template(template.body, {
        'restaurant_name': order.restaurant.name,
        'order_number': order.order_number,
        'table_number': order.table_number or '—',
        'customer_name': order.customer_name or 'Pelanggan',
        'items_list': render_items(order.order_items),
        'total': format_rupiah(order.total),
        'payment_method': order.payments[0].method.upper(),
        'datetime': format_datetime_wib(order.completed_at),
    })

    # 3. Simpan ke messages dengan status queued
    msg = Message(
        job_id=job.id,
        order_id=order_id,
        phone=order.customer_phone,
        body_rendered=body,
        status='queued',
    )
    db.add(msg)
    db.commit()

    # 4. Kirim ke WA Gateway
    try:
        result = await wa_client.send(
            phone_no=order.customer_phone,
            message=body,
            idempotency_key=f"receipt-{job.id}",   # unik per job
            callback_url=settings.WA_CALLBACK_URL,
        )
        msg.wa_queue_id = result['queue_id']
        msg.status = 'queued'    # masih queued — tunggu konfirmasi gateway
        job.status = 'done'      # job selesai di pihak kita
    except Exception as e:
        msg.status = 'failed'
        msg.error_message = str(e)
        job.status = 'failed'
        job.last_error = str(e)
    finally:
        db.commit()
```

---

### Callback dari Gateway

```python
# api/v1/endpoints/internal.py
# PENTING: dipasang di level app, BUKAN di bawah /api/v1/

@router.post("/internal/wa-status")
async def wa_status_callback(body: dict, db: Session = Depends(get_db)):
    queue_id    = body.get("queue_id")
    status      = body.get("status")       # "sent" atau "failed"
    error_detail = body.get("error_detail")
    sent_at     = body.get("sent_at")      # ISO string dari gateway

    msg = db.query(Message).filter(Message.wa_queue_id == queue_id).first()
    if msg:
        msg.status = status
        msg.error_message = error_detail
        if status == 'sent' and sent_at:
            msg.sent_at = datetime.fromisoformat(sent_at)
        db.commit()

    return {"ok": True}  # SELALU 200 — gateway tidak retry jika dapat non-200
```

**Nginx route yang diperlukan:**
```nginx
location /internal/ {
    proxy_pass http://resto-backend:8000/internal/;
    proxy_read_timeout 10s;
}
```

---

### Fallback Sync — Background Loop

Jika callback gagal (server restart, network issue), status `queued` tidak pernah
terupdate. Fallback loop aktif query ke gateway setiap 2 menit:

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

# Gunakan asyncio.create_task — lebih reliabel dari APScheduler IntervalTrigger
# (APScheduler IntervalTrigger punya bug dengan uvicorn untuk interval pendek)
```

---

### Best Practice yang Diadopsi (dari Fast-Klinik)

| # | Practice | Implementasi di Fast-Resto |
|---|---|---|
| 1 | **Idempotency key** | `f"receipt-{job.id}"` — cegah nota ganda jika retry |
| 2 | **Callback URL** | `/internal/wa-status` — update status async dari gateway |
| 3 | **Queued dulu** | Status `queued` setelah 202, bukan langsung `sent` |
| 4 | **Fallback sync** | Background loop 2 menit — update jika callback terlewat |
| 5 | **Timestamp UTC+Z** | `datetime.utcnow().isoformat() + "Z"` di semua response |
| 6 | **Header benar** | `X-Gateway-API-Key` (bukan `X-API-Key`) |
| 7 | **Callback di level app** | Pasang di `app.include_router`, bukan di `api_router` |
| 8 | **WA_SIMULATE** | Test tanpa gateway aktif — job tetap diproses, tidak kirim |
| 9 | **UNIQUE constraint** | `UNIQUE(order_id, template_code)` cegah job duplikat |
| 10 | **Frontend polling** | Polling aktif hanya saat ada `status=queued`, stop sendiri |

---

## Apa yang TIDAK Perlu Diubah di Schema

| Fitur | Perlu Perubahan DB? | Keterangan |
|---|---|---|
| CMS halaman menu | Minimal | Hanya tambah `description`, `image_url`, `sort_order` di menus |
| QR scan → buka menu | Tidak | QR hanya link URL, tidak ada logika di DB |
| Order masuk dari customer | Ya | Perlu `tables` + kolom baru di `orders` |
| Kasir review order | Tidak | Logika lama tetap berlaku untuk order yang sudah masuk |
| Proses bayar | Tidak | `complete_order()` tetap sama |
| Nota WA | Ya | Perlu `customer_phone` di `orders` + 3 tabel WA |
| Log WA | **Wajib** | `wa_message_templates`, `notification_jobs`, `messages` |

---

## CMS Landing — Arsitektur Singkat

CMS landing bukan bagian dari database PostgreSQL — ini layer terpisah.
Pilihan yang paling sederhana untuk restoran satu cabang:

```
Opsi 1: Halaman statis yang baca dari API FastAPI
  → Frontend (Next.js / plain HTML) → GET /menus → render daftar menu
  → Tidak perlu CMS terpisah
  → Cocok untuk tahap awal

Opsi 2: CMS berbasis admin panel
  → Owner bisa edit nama menu, harga, gambar dari dashboard web
  → Kolom di tabel `menus` sudah cukup (tambah image_url + description)
  → Ini sudah masuk skema FastAPI admin — tidak perlu software CMS eksternal

Opsi 3: Headless CMS eksternal (Strapi, Contentful, dll)
  → Overkill untuk restoran satu cabang
  → TIDAK DISARANKAN
```

**Rekomendasi:** Opsi 1 dulu. Dashboard admin CRUD menu (nama, harga, gambar,
is_available) adalah bagian dari FastAPI admin biasa — tidak perlu CMS terpisah.

---

## WebSocket vs Polling untuk Notif Order Masuk

Kasir perlu tahu kalau ada order baru dari customer. Dua pilihan:

| Pendekatan | Kompleksitas | Ketepatan | Rekomendasi |
|---|---|---|---|
| **Polling** (setiap 5 detik) | Rendah | Delay ~5 detik | ✅ Untuk awal |
| **WebSocket** | Tinggi | Real-time | Nanti saja |
| **Server-Sent Events (SSE)** | Sedang | Real-time | Alternatif |

Untuk restoran satu kasir, polling setiap 3–5 detik sudah cukup.
Tidak perlu WebSocket di tahap awal.

---

## Kesimpulan: Urutan Pengerjaan

```
[SEKARANG — Sebelum init.sql]
  ✅ Tambahkan ke tahap-database.md (lihat checklist di bawah):
     - ENUM order_source
     - CREATE TABLE tables
     - Kolom baru di orders: table_id, order_source, customer_name, customer_phone
     - Kolom baru di menus: description, image_url, sort_order
     - CREATE TABLE wa_message_templates, notification_jobs, messages
     - Index untuk qr_token + notification_jobs + messages

[SETELAH DOKUMENTASI LENGKAP]
  ✅ Tulis init.sql SEKALI JALAN — sudah mencakup semua tabel dan index
  ✅ Tidak perlu ALTER TABLE setelah deploy

[SETELAH init.sql BERJALAN]
  ✅ Implementasi FastAPI:
     1. Endpoint GET /menus (untuk CMS landing)
     2. Endpoint GET /tables/{qr_token} (untuk self-order)
     3. Endpoint POST /orders/self-order
     4. Dashboard kasir + notif polling
     5. NotificationService + wa_client.py (salin dari Fast-Klinik, sesuaikan)
     6. Endpoint POST /internal/wa-status (callback gateway)
     7. Background loop _wa_sync_loop (asyncio.create_task)
```

---

## Checklist Perubahan yang Harus Masuk resto-finance-2.md

Sebelum menulis init.sql, update `resto-finance-2.md` dengan:

```
[QR TABLE ORDER]
□ ENUM baru: order_source ('kasir', 'self_order', 'platform')
□ CREATE TABLE tables (id, restaurant_id, table_number, capacity, qr_token, is_active)
□ Tambah ke orders: table_id FK, order_source, customer_name, customer_phone
□ Tambah ke menus: description TEXT, image_url VARCHAR(500), sort_order INTEGER
□ Index: idx_tables_qr_token ON tables(qr_token) WHERE is_active = TRUE
□ Index partial: idx_orders_self_order_open
     ON orders(restaurant_id, created_at)
     WHERE order_source = 'self_order' AND status = 'open'

[WA GATEWAY — Adopsi dari Fast-Klinik]
□ CREATE TABLE wa_message_templates (id, code UNIQUE, title, body, is_active)
□ CREATE TABLE notification_jobs
     (id, order_id FK, template_code, run_at TIMESTAMPTZ, status, attempts, last_error)
□ UNIQUE (order_id, template_code) di notification_jobs
□ CREATE TABLE messages
     (id, job_id FK, order_id FK, phone, channel, body_rendered, wa_queue_id,
      status, sent_at, error_message)
□ Index: idx_notif_jobs_pending ON notification_jobs(run_at) WHERE status='pending'
□ Index: idx_messages_queued ON messages(wa_queue_id) WHERE status='queued'

[SEED DATA WA]
□ INSERT wa_message_templates: ORDER_RECEIPT, ORDER_CONFIRM
```

---

## Checklist Integrasi WA Gateway (dari Fast-Klinik)

Salin dari `wa-gateway.md`, adaptasi untuk Fast-Resto:

```
[ ] Kolom wa_queue_id ada di tabel messages
[ ] Status awal 'queued' setelah terima 202 dari gateway (bukan 'sent')
[ ] idempotency_key dikirim: format 'receipt-{job_id}'
[ ] UNIQUE(order_id, template_code) di notification_jobs — cegah nota ganda
[ ] callback_url dikonfigurasi dan dapat dijangkau dari container gateway
[ ] Endpoint /internal/wa-status:
    [ ] Dipasang di level app (bukan di bawah /api/v1/)
    [ ] Nginx punya route untuk path /internal/
    [ ] Selalu return {"ok": True} meski job tidak ditemukan
[ ] Fallback sync: asyncio.create_task(_wa_sync_loop) interval 2 menit
    [ ] Header: X-Gateway-API-Key (bukan X-API-Key)
[ ] UTC timestamp di response: datetime.utcnow().isoformat() + "Z"
[ ] WA_SIMULATE=True untuk development tanpa gateway aktif
[ ] Test callback dari container gateway sebelum deploy
```
