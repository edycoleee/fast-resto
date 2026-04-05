# 📋 Tahap Pembuatan `init.sql` — Fast-Resto

> **Tujuan dokumen ini:** Roadmap eksekusi init.sql sebelum menulis satu baris SQL.
> Selesaikan perencanaan di sini dulu — saat eksekusi tinggal copy-paste urutan ini.

---

## Mengapa File Kosong Terus?

Problem sebelumnya: `create_file` dipanggil saat file sudah ada → tooling
tidak overwrite, hasilnya file tetap kosong atau gagal.
**Solusi:** Hapus file dulu via terminal, baru tulis ulang — atau gunakan
`replace_string_in_file` pada file kosong (isi `oldString` = string kosong).

---

## Urutan Eksekusi di `init.sql`

PostgreSQL memiliki dependency antar objek. Urutan ini **wajib** diikuti
agar tidak ada `ERROR: relation does not exist` saat migrate.

```
TAHAP 0   Extensions & ENUMs
TAHAP 1   RBAC Tables          (roles, permissions, role_permissions)
TAHAP 2   Master Data Tables   (restaurants, users, ingredients, menus, suppliers)
TAHAP 3   Transaction Tables   (orders, payments, purchases, incomes, expenses, …)
TAHAP 4   Supporting Tables    (stock_movements, stock_opnames, kasir_shifts, …)
TAHAP 5   Indexes
TAHAP 6   DB Functions         (confirm_purchase, complete_order, confirm_opname, …)
TAHAP 7   Views (Laporan)      (v_menu_cogs, v_monthly_resto_finance, …)
TAHAP 8   Seed Data
```

---

## TAHAP 0 — Extensions & ENUMs

### Extensions yang dibutuhkan

```sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";    -- uuid_generate_v4()
CREATE EXTENSION IF NOT EXISTS "pgcrypto";     -- crypt() untuk password hash
```

### Daftar ENUM yang harus ditulis (urutan bebas, tapi SEBELUM tabel)

| ENUM Name | Nilai |
|---|---|
| `ingredient_unit` | gram, ml, pcs, portion |
| `ingredient_category` | recipe, overhead |
| `movement_type` | purchase, sale, waste, opname_adj, return_to_supplier, transfer_in, opening |
| `purchase_status` | draft, received, paid, partial, cancelled |
| `order_channel` | dine_in, takeaway, grabfood, gofood, shopeefood |
| `order_status` | open, completed, void, refunded |
| `payment_method` | cash, qris, transfer, grabfood_settlement, gofood_settlement |
| `payment_status` | pending, confirmed, void |
| `expense_category` | food_waste, inventory_loss, kitchen_overhead, salary, utility, rent, platform_fee, maintenance, marketing, packaging, refund, other |
| `opname_status` | draft, confirmed |
| `shift_status` | open, closed |
| `user_role` | owner, manager, kasir, dapur, viewer |
| `order_source` | kasir, self_order, platform |

---

## TAHAP 1 — RBAC Tables

### Prinsip RBAC yang dipakai

Model ini menggunakan **flat role** (bukan hierarchical) karena restoran kecil.
Tidak perlu permission granular per endpoint — cukup role-based menu guard.

```
user.role  →  determines which menu/endpoint is accessible
```

### MenuGuard: Akses per Role

| Role | Menu yang Bisa Diakses |
|---|---|
| `owner` | Dashboard, L/R, Semua menu, Settings, RBAC |
| `manager` | Dashboard, Laporan, Order, Pembelian, Opname, Expenses |
| `kasir` | Order (POS), Pembayaran, Shift buka/tutup |
| `dapur` | Stock opname, Waste input, Lihat stok |
| `viewer` | Dashboard read-only, Laporan read-only |

### Tabel RBAC

```
┌─────────────────────────────────────────────────────────────────┐
│  Cukup dengan: users.role (ENUM)                                │
│  Tidak perlu tabel roles/permissions terpisah untuk fase awal   │
│  karena rule-nya sederhana dan tidak berubah sering             │
│                                                                 │
│  Jika suatu saat perlu granular: tambahkan tabel                │
│  role_menu_access(role, menu_key, can_read, can_write)          │
└─────────────────────────────────────────────────────────────────┘
```

**Tabel yang perlu ditulis di TAHAP 1:**

```sql
-- 1. users (inti RBAC)
CREATE TABLE users (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id UUID NOT NULL REFERENCES restaurants(id),
    name          VARCHAR(100) NOT NULL,
    email         VARCHAR(100) UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,          -- bcrypt via pgcrypto
    role          user_role NOT NULL DEFAULT 'kasir',
    is_active     BOOLEAN DEFAULT TRUE,
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    last_login_at TIMESTAMPTZ
);
```

**Catatan keamanan:**
- Password TIDAK PERNAH disimpan plain text
- Hash menggunakan bcrypt (cost factor 12) via FastAPI `passlib`
- `email` adalah unique identifier untuk login

---

## TAHAP 2 — Master Data Tables

Urutan FK dependency dalam tahap ini:

```
restaurants        ← tidak ada dependency
    ↓
users              ← FK: restaurant_id → restaurants
    ↓
suppliers          ← FK: restaurant_id → restaurants
    ↓
ingredients        ← FK: restaurant_id → restaurants
    ↓
menus              ← FK: restaurant_id → restaurants
    ↓
menu_recipes       ← FK: menu_id → menus, ingredient_id → ingredients
```

### Checklist tabel Master Data

| # | Tabel | Kolom Kritis yang Harus Ada |
|---|---|---|
| 1 | `restaurants` | id, name, address, phone, tax_number, created_at |
| 2 | `users` | id, restaurant_id, name, email, password_hash, role, is_active |
| 3 | `suppliers` | id, restaurant_id, name, phone, payment_terms, is_active |
| 4 | `ingredients` | id, restaurant_id, name, unit **(base unit)**, ingredient_category, avg_cost_per_unit, current_stock, reorder_point, is_active |
| 5 | `menus` | id, restaurant_id, name, category, **description**, **image_url**, **sort_order**, selling_price, is_available, is_active |
| 6 | `menu_recipes` | id, menu_id, ingredient_id, qty_per_portion **(dalam base unit)**, yield_factor, notes, **is_active** |
| 7 | `unit_conversions` | base_unit, purchase_unit, factor, description, **is_active** |
| 8 | `tables` | id, restaurant_id, table_number, capacity, **qr_token** (UNIQUE), is_active |
| 9 | `cms_site_settings` | id, restaurant_id, key, value — setting teks landing page per key |
| 10 | `cms_banners` | id, restaurant_id, title, subtitle, image_url, sequence, is_active, start_date, end_date |
| 11 | `cms_promotions` | id, restaurant_id, title, description, image_url, discount_label, start_date, end_date, is_active |

### Tabel `tables` — Meja Fisik & QR Token

```sql
CREATE TABLE tables (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id UUID NOT NULL REFERENCES restaurants(id),
    table_number  VARCHAR(20) NOT NULL,
    capacity      INTEGER DEFAULT 4,
    -- qr_token: string unik per meja, di-embed ke QR code
    -- URL: https://[domain]/menu?t={qr_token}
    -- TIDAK berubah saat order baru — token meja bersifat permanen
    qr_token      VARCHAR(64) NOT NULL UNIQUE DEFAULT encode(gen_random_bytes(32), 'hex'),
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (restaurant_id, table_number)
);
```

### Tabel CMS — Landing Page

```sql
-- Key-value settings: restaurant_name, tagline, hero_title, whatsapp_number, address, dll
CREATE TABLE cms_site_settings (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id UUID NOT NULL REFERENCES restaurants(id),
    key           VARCHAR(100) NOT NULL,
    value         TEXT,
    updated_at    TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (restaurant_id, key)
);

CREATE TABLE cms_banners (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id UUID NOT NULL REFERENCES restaurants(id),
    title         VARCHAR(150),
    subtitle      VARCHAR(300),
    image_url     VARCHAR(500) NOT NULL,
    action_url    VARCHAR(500),
    sequence      INTEGER DEFAULT 0,
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    start_date    DATE,
    end_date      DATE,
    created_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE cms_promotions (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id UUID NOT NULL REFERENCES restaurants(id),
    title         VARCHAR(150) NOT NULL,
    description   TEXT,
    image_url     VARCHAR(500),
    discount_label VARCHAR(50),
    start_date    DATE NOT NULL,
    end_date      DATE NOT NULL,
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ DEFAULT NOW()
);
```

---

### ⚠️ Masalah Satuan: Supplier vs Dapur

Ini adalah jebakan paling umum di sistem restoran. Harus dipahami sebelum menulis DDL.

```
SUPPLIER JUAL     SISTEM SIMPAN    RESEP PAKAI
────────────────   ────────────     ───────────
5 kg ayam         5000 gram        200 gram/porsi
2 liter minyak    2000 ml          30 ml/porsi
1 ikat bayam      250 gram         80 gram/porsi
12 butir telur    12 pcs           1 pcs/porsi
1 dus mie         10000 gram       150 gram/porsi
```

Jika tidak ada konversi, maka:
- Input purchase: "5 kg @ Rp38.000/kg" → `avg_cost_per_unit = 38000` (per KG!)
- Recipe hitung: `200g × 38000` = **Rp 7.600.000** per porsi ← SALAH
- Seharusnya: `200g × 38` = **Rp 7.600** per porsi ← BENAR

**Prinsip yang harus dipegang:**

```
ingredients.unit          = BASE UNIT (terkecil) → gram / ml / pcs / portion
menu_recipes.qty_portion  = dalam BASE UNIT
stock_movements.qty       = dalam BASE UNIT
ingredients.avg_cost      = Rp per BASE UNIT

purchase_items.purchase_unit      = satuan supplier (boleh beda)
purchase_items.conversion_factor  = berapa base unit per satuan beli
purchase_items.qty_in_base_unit   = purchase_qty × conversion_factor  [GENERATED]
purchase_items.price_per_base_unit = unit_price / conversion_factor    [GENERATED]
```

### Tabel Referensi Konversi Satuan

Ini adalah tabel helper untuk UI — saat staf input pembelian,
frontend bisa auto-fill `conversion_factor` berdasarkan pasangan `base_unit` + `purchase_unit`.

```
base_unit | purchase_unit | factor  | Keterangan
───────── | ───────────── | ─────── | ─────────────────────────
gram      | gram          | 1       | beli per gram (jarang)
gram      | kg            | 1000    | beli per kilogram
gram      | ons           | 100     | beli per ons (100g)
gram      | ikat          | 250     | default; konfirmasi ke supplier
gram      | porsi         | variable| tergantung resep, tidak disarankan
ml        | ml            | 1       | beli per mililiter (jarang)
ml        | liter         | 1000    | beli per liter
ml        | botol_600ml   | 600     | misal: sirup, kecap
ml        | botol_1L      | 1000    | misal: kecap, saus tiram
pcs       | pcs           | 1       | beli satuan
pcs       | lusin         | 12      | beli per lusin (telur, dll)
pcs       | kodi          | 20      | beli per kodi
pcs       | dus           | variable| sesuai isi dus
portion   | portion       | 1       | sudah per porsi
```

**Kasus khusus yang perlu diperhatikan:**

| Bahan | Masalah | Solusi |
|---|---|---|
| Telur | Beli per kg (14 butir/kg) atau per butir | Input per `pcs` (butir); jika beli 1 kg = 14 pcs, factor=14 |
| Tahu | Beli per biji (1 biji ~80g), resep per gram | Set unit=gram; beli 10 biji = 10×80=800g, factor=80 |
| Tempe | Beli per papan (~200g), resep per gram | factor=200 untuk purchase_unit='papan' |
| Kelapa parut | Beli per butir (~150g santan), resep per ml santan | Pisahkan: buat ingredient 'santan ml', beli per liter |
| Jeruk | Resep per pcs (buah), beli per kg | Pilih: store per pcs, factor=7 (rata-rata 7 buah/kg) |
| Gas LPG | Kategori B, tidak perlu konversi gram | Catat sebagai expense langsung, bukan stok |

### Constraint yang WAJIB ada

```
ingredients: UNIQUE(restaurant_id, name)
menus:       UNIQUE(restaurant_id, name)
users:       UNIQUE(email)
menu_recipes: UNIQUE(menu_id, ingredient_id)
stock_opnames: UNIQUE(restaurant_id, opname_date)  ← satu per hari
```

---

## TAHAP 2b — Kolom Baru di Tabel Existing

Kolom-kolom ini ditambahkan ke tabel yang **sudah didefinisikan** di `resto-finance-2.md`.
Harus ada di DDL `init.sql` — jangan lupa:

```sql
-- menus: tambah kolom CMS & QR order
description   TEXT,
image_url     VARCHAR(500),
sort_order    INTEGER DEFAULT 0,

-- orders: tambah kolom QR self-order
table_id        UUID REFERENCES tables(id),
order_source    order_source NOT NULL DEFAULT 'kasir',
customer_name   VARCHAR(100),
customer_phone  VARCHAR(20),
```

**Catatan `table_number` di orders:** pertahankan kolom `table_number VARCHAR(10)` yang sudah ada
sebagai snapshot denormalisasi — isi otomatis dari `tables.table_number` saat order dibuat.
Dua kolom bersamaan: `table_id` (FK) + `table_number` (snapshot).

---

## TAHAP 3 — Transaction Data Tables

Urutan FK dependency:

```
kasir_shifts       ← FK: restaurant_id, cashier_id → users
    ↓
orders             ← FK: restaurant_id, shift_id → kasir_shifts
    ↓
order_items        ← FK: order_id → orders, menu_id → menus
    ↓
payments           ← FK: order_id → orders, shift_id → kasir_shifts
    ↓
incomes            ← FK: restaurant_id, created_by → users
    ↓
purchases          ← FK: restaurant_id, supplier_id → suppliers
    ↓
purchase_items     ← FK: purchase_id → purchases, ingredient_id → ingredients
    ↓
expenses           ← FK: restaurant_id, created_by → users
    ↓
delivery_platform_batches ← FK: restaurant_id
```

### Checklist tabel Transaksi

| # | Tabel | Fungsi |
|---|---|---|
| 1 | `kasir_shifts` | Rekonsiliasi kas per shift |
| 2 | `orders` | Header order POS |
| 3 | `order_items` | Detail menu per order + theoretical_cogs |
| 4 | `payments` | Pembayaran per order (cash/QRIS) |
| 5 | `incomes` | Single source of truth revenue (dibuat otomatis saat payment confirm) |
| 6 | `purchases` | Header pembelian bahan |
| 7 | `purchase_items` | Detail bahan per pembelian |
| 8 | `expenses` | Single source of truth semua pengeluaran |
| 9 | `delivery_platform_batches` | Rekonsiliasi GrabFood/GoFood per periode |

### Kolom Generated (tidak perlu diisi manual, DB yang hitung)

```sql
-- purchase_items
subtotal NUMERIC(14,2) GENERATED ALWAYS AS (qty * unit_price) STORED

-- order_items
subtotal NUMERIC(14,2) GENERATED ALWAYS AS (unit_price * qty) STORED

-- kasir_shifts
cash_variance NUMERIC(14,2) GENERATED ALWAYS AS (actual_cash - expected_cash) STORED

-- delivery_platform_batches
net_settlement NUMERIC(14,2) GENERATED ALWAYS AS (gross_sales - platform_fee) STORED

-- stock_opname_items
variance       NUMERIC(12,3) GENERATED ALWAYS AS (actual_qty - theoretical_qty) STORED
variance_value NUMERIC(14,2) GENERATED ALWAYS AS ((actual_qty - theoretical_qty) * cost_per_unit) STORED

-- stock_movements
total_cost NUMERIC(14,2) GENERATED ALWAYS AS (qty * cost_per_unit) STORED
```

---

## TAHAP 4 — Supporting / Audit Tables

| # | Tabel | Fungsi |
|---|---|---|
| 1 | `stock_movements` | Audit trail setiap perubahan stok Kat. A |
| 2 | `stock_opnames` | Header stock opname harian |
| 3 | `stock_opname_items` | Detail per bahan per opname |
| 4 | `wa_message_templates` | Template body pesan WA (ORDER_RECEIPT, ORDER_CONFIRM) |
| 5 | `notification_jobs` | Antrian kirim notif WA per order |
| 6 | `messages` | Log setiap upaya kirim WA (queued/sent/failed + wa_queue_id) |

**Catatan:** Tabel 1–3 di-*populate* otomatis oleh DB functions, bukan input manual.
Tabel 4–6 di-*populate* oleh NotificationService FastAPI.

### Tabel WA Notification

```sql
CREATE TABLE wa_message_templates (
    id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    code       VARCHAR(50) UNIQUE NOT NULL,  -- ORDER_RECEIPT, ORDER_CONFIRM
    title      VARCHAR(100) NOT NULL,
    body       TEXT NOT NULL,               -- {{placeholder}}
    is_active  BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE notification_jobs (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id      UUID REFERENCES orders(id) ON DELETE SET NULL,
    template_code VARCHAR(50) NOT NULL,
    run_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status        VARCHAR(20) NOT NULL DEFAULT 'pending',  -- pending|done|failed
    attempts      INTEGER NOT NULL DEFAULT 0,
    last_error    TEXT,
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    updated_at    TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (order_id, template_code)  -- cegah job duplikat per order
);

CREATE TABLE messages (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    job_id        UUID REFERENCES notification_jobs(id) ON DELETE SET NULL,
    order_id      UUID REFERENCES orders(id) ON DELETE SET NULL,
    phone         VARCHAR(20) NOT NULL,
    channel       VARCHAR(20) NOT NULL DEFAULT 'whatsapp',  -- whatsapp|inapp
    body_rendered TEXT NOT NULL,
    wa_queue_id   INTEGER,         -- ID dari gateway setelah 202 Accepted
    status        VARCHAR(20) NOT NULL DEFAULT 'queued',  -- queued|sent|failed
    sent_at       TIMESTAMPTZ,
    error_message TEXT,
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    updated_at    TIMESTAMPTZ DEFAULT NOW()
);
```

**Dependency FK:** `notification_jobs` dan `messages` referensikan `orders` → harus dibuat SETELAH TAHAP 3.

---

## TAHAP 5 — Indexes

Indexes dibuat SETELAH semua tabel ada.
Fokus pada kolom yang sering di-WHERE atau di-JOIN:

```
ingredients:          (restaurant_id, ingredient_category) WHERE is_active
stock_movements:      (ingredient_id, created_at DESC)
stock_movements:      (restaurant_id, movement_type, created_at DESC)
orders:               (restaurant_id, status, completed_at DESC)
orders:               (restaurant_id, created_at) WHERE order_source='self_order' AND status='open'
order_items:          (order_id)
payments:             (order_id)
incomes:              (restaurant_id, fiscal_period) WHERE is_active
expenses:             (restaurant_id, fiscal_period) WHERE is_active
expenses:             (restaurant_id, category, fiscal_period)
purchases:            (restaurant_id, status)
kasir_shifts:         (restaurant_id, shift_date DESC)
stock_opnames:        (restaurant_id, opname_date DESC)

-- Indeks baru (CMS + QR + WA)
tables:               (qr_token) WHERE is_active = TRUE         ← lookup setiap scan QR
cms_banners:          (restaurant_id, sequence) WHERE is_active = TRUE
cms_promotions:       (restaurant_id, end_date) WHERE is_active = TRUE
cms_site_settings:    (restaurant_id)
notification_jobs:    (run_at) WHERE status = 'pending'
messages:             (wa_queue_id) WHERE status = 'queued'     ← fallback sync loop
```

---

## TAHAP 6 — DB Functions

Urutan penulisan (fungsi yang dipanggil fungsi lain harus ada dulu):

| # | Function | Dipanggil saat | Output ke |
|---|---|---|---|
| 1 | `confirm_purchase(purchase_id, user_id)` | Purchase di-confirm | ingredients.current_stock + stock_movements |
| 2 | `complete_order(order_id, user_id)` | Order selesai | order_items.theoretical_cogs + stock_movements |
| 3 | `confirm_payment(payment_id, user_id)` | Payment dikonfirmasi | incomes (buat baris baru) |
| 4 | `confirm_opname(opname_id, user_id)` | Opname dikunci | ingredients.current_stock + expenses.inventory_loss |
| 5 | `confirm_platform_settlement(batch_id, user_id)` | Settlement platform | expenses.platform_fee |
| 6 | `void_order(order_id, reason, user_id)` | Order dibatalkan | orders.status = 'void' |
| 7 | `refund_order(order_id, payment_id, amount, reason, user_id)` | Refund | incomes.is_active=FALSE + expenses.refund + stok kembali |

### Pola Semua DB Functions

Setiap fungsi harus punya guard:
```sql
-- Guard: jangan proses ulang jika sudah pernah diproses
IF (SELECT status FROM purchases WHERE id = p_purchase_id) = 'received' THEN
    RAISE EXCEPTION 'Purchase sudah pernah dikonfirmasi';
END IF;
```

---

## TAHAP 7 — Views (Laporan)

| # | View | Kegunaan |
|---|---|---|
| 1 | `v_menu_cogs` | HPP teoritis per menu (Kat. A + yield factor) |
| 2 | `v_monthly_resto_finance` | L/R bulanan lengkap dengan breakdown 3-komponen HPP |
| 3 | `v_menu_performance` | Revenue + COGS per menu bulan ini |
| 4 | `v_daily_loss` | Audit waste + opname_adj per hari |
| 5 | `v_low_stock_alert` | Alert stok mendekati/di bawah reorder_point |

### `v_low_stock_alert` — View yang Belum Ada di File Lain

```sql
CREATE OR REPLACE VIEW v_low_stock_alert AS
SELECT
    i.name,
    i.current_stock,
    i.reorder_point,
    i.unit,
    CASE
        WHEN i.current_stock <= 0               THEN 'HABIS_TEORITIS'
        WHEN i.current_stock < i.reorder_point  THEN 'SEGERA_BELI'
        ELSE 'AMAN'
    END AS status_alert
FROM ingredients i
WHERE i.ingredient_category = 'recipe'
  AND i.is_active = TRUE
  AND i.current_stock < i.reorder_point
ORDER BY i.current_stock ASC;
```

### Function Alternatif untuk Laporan Bulanan (get_monthly_pl_report)

Versi function dari alur-resto-1.md — cocok untuk dipanggil via API dengan parameter period:

```sql
-- Dipanggil: SELECT * FROM get_monthly_pl_report('2026-04', <restaurant_uuid>)
```

---

## TAHAP 8 — Seed Data

Urutan insert mengikuti FK dependency (sama dengan urutan tabel):

```
1. INSERT restaurants (1 row — Fast-Resto)
2. INSERT users       (3 rows — owner, kasir1, dapur1)
3. INSERT suppliers   (2 rows — Supplier Ayam, Supplier Sayur)
4. INSERT ingredients
       Kat. A: 15 bahan utama (dari simplifikasi-3 Template 1, No. 01–15)
       Kat. B: 5 overhead (minyak, bawang, cabai, bumbu, gas)
5. INSERT menus       (10 menu — dari simplifikasi-2)
6. INSERT menu_recipes (sesuai plate costing di simplifikasi-2)
```

### Seed Data Minimal yang Wajib Ada

| Tabel | Qty | Catatan |
|---|---|---|
| restaurants | 1 | Fast-Resto, satu cabang |
| users | 3 | owner (role=owner), kasir (role=kasir), dapur (role=dapur) |
| suppliers | 2 | Pak Budi (ayam/daging), Bu Siti (sayur/bumbu) |
| ingredients Kat. A | 15 | Dari template, sudah ada avg_cost + current_stock awal |
| ingredients Kat. B | 5 | Minyak, bawang, cabai, bumbu, gas — current_stock = 0 (tidak ditracking) |
| menus | 10 | Ayam goreng, nasi putih, nasi goreng, mie goreng, lele, tempe, tahu, teh, jeruk, kopi |
| menu_recipes | ~25 | Sesuai plate costing simplifikasi-2 |
| tables | 5 | Meja 1–5, qr_token di-generate otomatis via `encode(gen_random_bytes(32),'hex')` |
| cms_site_settings | 10 | Keys default: restaurant_name, tagline, hero_title, dll (value kosong, owner isi via UI) |
| wa_message_templates | 2 | ORDER_RECEIPT + ORDER_CONFIRM (isi lengkap, lihat landing-resto.md) |

### Nilai Awal Stok (untuk testing)

```sql
-- Set stok awal via stock_movements type='opening'
-- Jangan langsung UPDATE ingredients.current_stock
-- karena audit trail harus mencatat ini sebagai 'opening'
```

### Seed `unit_conversions` (wajib ada sebelum seed purchase_items)

```sql
INSERT INTO unit_conversions (base_unit, purchase_unit, factor, description) VALUES
-- gram-based ingredients
('gram', 'gram',        1,       'Beli per gram (jarang)'),
('gram', 'kg',          1000,    'Beli per kilogram — paling umum untuk daging, beras'),
('gram', 'ons',         100,     'Beli per ons (100g)'),
('gram', 'ikat',        250,     'Default: 1 ikat sayur ~250g; konfirmasi ke supplier'),
('gram', 'papan',       200,     '1 papan tempe ~200g'),
('gram', 'biji',        80,      '1 biji tahu ~80g; sesuaikan jika berbeda'),
('gram', 'dus_10kg',    10000,   '1 dus tepung/beras 10kg'),
('gram', 'karung_25kg', 25000,   '1 karung beras 25kg'),
-- ml-based ingredients
('ml',   'ml',          1,       'Beli per ml (jarang)'),
('ml',   'liter',       1000,    'Beli per liter — umum untuk santan, susu, sirup'),
('ml',   'botol_600ml', 600,     'Botol sirup, kecap 600ml'),
('ml',   'botol_1L',    1000,    'Botol kecap manis, saus tiram 1L'),
('ml',   'jerigen_5L',  5000,    'Jerigen minyak 5L'),
('ml',   'jerigen_18L', 18000,   'Jerigen minyak 18L'),
-- pcs-based ingredients
('pcs',  'pcs',         1,       'Beli satuan — telur per butir, jeruk per buah'),
('pcs',  'lusin',       12,      'Beli per lusin (12 pcs)'),
('pcs',  'kodi',        20,      'Beli per kodi (20 pcs)'),
('pcs',  'kg_telur',    14,      'Estimasi: 1 kg telur ≈ 14 butir; konfirmasi aktual'),
-- portion-based
('portion', 'portion',  1,       'Sudah dalam satuan porsi');
```

**Catatan penting untuk seed `ingredients` Kat. A:**
```
Semua avg_cost_per_unit dan current_stock di seed data
harus dalam BASE UNIT (gram/ml/pcs).

Contoh:
  Ayam potong: unit='gram', avg_cost_per_unit=38, current_stock=5000
  (bukan: avg_cost=38000/kg, current_stock=5)
```

---

## PENTING: Soft Delete — Audit & Strategi

### Dua Mekanisme Soft Delete yang Dipakai

Sistem ini menggunakan **dua pendekatan berbeda secara sengaja** — bukan inkonsistensi:

| Mekanisme | Tabel yang Pakai | Alasan |
|---|---|---|
| `is_active BOOLEAN` | Master data + finance records | Data referensial, bisa diaktifkan kembali |
| `status ENUM` (void/cancelled/refunded) | Transaksional dengan state machine | Audit trail state perlu detail, bukan sekedar aktif/nonaktif |

### Audit Lengkap per Tabel

```
TABEL                    MEKANISME        CATATAN
───────────────────────  ───────────────  ─────────────────────────────────────────────
restaurants              is_active ✅     (belum eksplisit di resto-finance-2 — tambahkan)
users                    is_active ✅     (di tahap-database.md TAHAP 1)
suppliers                is_active ✅
ingredients              is_active ✅     + reorder_point untuk logic lain
menus                    is_active ✅     + is_available (sold-out toggle, terpisah!)
menu_recipes             ❌ BELUM         → perlu is_active (saat resep menu diubah)
unit_conversions         ❌ BELUM         → perlu is_active (jika satuan beli berubah)

orders                   status ENUM ✅   void / completed / refunded
order_items              ❌ tidak perlu   → ikut orders, tidak perlu sendiri
payments                 status ENUM ✅   pending / confirmed / void
kasir_shifts             status ENUM ✅   open / closed (tidak perlu is_active)
purchases                status ENUM ✅   draft / received / paid / cancelled

incomes                  is_active ✅     → FALSE saat refund (sengaja beda dari orders)
expenses                 is_active ✅     → FALSE jika input salah

stock_movements          ❌ TIDAK BOLEH   → immutable audit trail, JANGAN soft delete
stock_opnames            status ENUM ✅   draft / confirmed (tidak perlu is_active)
stock_opname_items       ❌ tidak perlu   → ikut opname header
delivery_platform_batches is_reconciled✅  bukan is_active — ini field domain, bukan delete
```

### Mengapa `menu_recipes` Perlu `is_active`

```
Skenario: Menu "Ayam Goreng Biasa" awalnya pakai tepung terigu 15g.
Owner memutuskan ganti resep: hapus tepung, tambah maizena.

Tanpa is_active:
  DELETE menu_recipes WHERE menu_id=X AND ingredient_id=tepung_id
  → Riwayat HPP sebelum perubahan HILANG
  → Tidak bisa audit: "dulu HPP-nya berapa?"

Dengan is_active:
  UPDATE menu_recipes SET is_active=FALSE WHERE menu_id=X AND ingredient_id=tepung_id
  → INSERT menu_recipes (menu_id=X, ingredient_id=maizena_id, ...)
  → Riwayat HPP lama masih ada (audit trail)
  → View v_menu_cogs filter WHERE mr.is_active = TRUE (pakai resep terkini)
```

### Aturan Besi Soft Delete

```
1. JANGAN pernah DELETE pada tabel yang memiliki referensi historis
   → ingredients, menus, menu_recipes, suppliers, users

2. BOLEH soft delete dengan is_active = FALSE:
   → Master data (ingredients, menus, menu_recipes, dll)
   → Finance records (incomes, expenses) saat ada koreksi

3. JANGAN soft delete audit trail:
   → stock_movements → selalu append-only, tidak pernah dihapus
   → stock_opname_items → ikut header opname

4. Tabel transaksional pakai status ENUM, bukan is_active:
   → orders, payments, purchases → karena perlu tahu "status apa" bukan sekedar "aktif/tidak"

5. Selalu tambah index partial WHERE is_active = TRUE:
   → Queries yang filter is_active = TRUE akan gunakan index ini (jauh lebih cepat)
```

### Fix yang Harus Dilakukan di init.sql

```sql
-- Tambahkan ke menu_recipes:
is_active BOOLEAN NOT NULL DEFAULT TRUE,

-- Update v_menu_cogs WHERE clause:
WHERE m.is_active = TRUE
  AND mr.is_active = TRUE        -- ← tambahkan ini
  AND i.is_active = TRUE         -- ← tambahkan ini
  AND i.ingredient_category = 'recipe'

-- Tambahkan ke unit_conversions:
is_active BOOLEAN NOT NULL DEFAULT TRUE,

-- Tambahkan ke restaurants:
is_active BOOLEAN NOT NULL DEFAULT TRUE,
```

---

## PENTING: Timezone — UTC vs WIB

### Masalah yang Harus Dipahami

`TIMESTAMPTZ` di PostgreSQL **selalu menyimpan UTC secara internal**.
Saat dibaca kembali, PostgreSQL konversi ke timezone sesi aktif.
Yang bermasalah adalah `CURRENT_DATE` dan `NOW()` — keduanya mengacu ke
**timezone sesi**, bukan UTC absolute.

```
Skenario bug nyata:
  Server timezone: UTC
  Kasir buka shift jam 00:30 WIB (tengah malam)

  WIB 00:30 = UTC 17:30 HARI SEBELUMNYA
  (WIB = UTC+7, jadi midnight WIB = 17:00 sore UTC kemarin)

  DEFAULT CURRENT_DATE di server UTC → mencatat tanggal KEMARIN
  Padahal kasir sudah merasa ini hari baru!

  Dampak:
  → kasir_shifts.shift_date = tanggal salah ← BUG
  → stock_opnames.opname_date = tanggal salah ← BUG
  → expenses.fiscal_period = bulan salah (jika dilakukan tengah malam) ← BUG
```

### Solusi yang Dipilih: Set Timezone di Level Database

Karena restoran ini beroperasi di satu zona waktu (WIB = Asia/Jakarta),
solusi paling aman adalah set timezone database ke WIB:

```sql
-- Tambahkan di awal init.sql, sebelum CREATE TABLE
-- Ini membuat semua CURRENT_DATE, NOW() di DB mengacu WIB
ALTER DATABASE fast_resto SET timezone = 'Asia/Jakarta';
```

Dengan ini:
- `TIMESTAMPTZ` tetap simpan UTC secara internal (tidak berubah) ✅
- `CURRENT_DATE` mengembalikan tanggal WIB ✅
- `NOW()` mengembalikan waktu WIB (tapi disimpan sebagai UTC+7 offset) ✅
- Semua query tanggal konsisten dengan realita operasional ✅

### Tabel Perbandingan Pendekatan

| Pendekatan | Kelebihan | Kekurangan |
|---|---|---|
| **Server UTC + app kirim date** | Paling fleksibel untuk multi-timezone | Harus selalu pass date dari app, DEFAULT CURRENT_DATE tidak aman |
| **DB timezone = Asia/Jakarta** ← pilihan kita | Simple, tidak perlu ubah app | Tidak fleksibel jika buka cabang di zona lain |
| **DB timezone = UTC + CURRENT_DATE AT TIME ZONE** | Eksplisit | Query jadi verbose |

### Implementasi Konsisten di Semua Function

Di semua DB function, ganti `CURRENT_DATE` dan `NOW()` yang untuk field bisnis:

```sql
-- KURANG BAIK (bergantung session timezone):
expense_date = CURRENT_DATE
fiscal_period = TO_CHAR(NOW(), 'YYYY-MM')

-- LEBIH BAIK (setelah DB timezone = Asia/Jakarta):
-- NOW() sudah dalam konteks WIB, CURRENT_DATE sudah WIB
-- Tidak perlu ubah apapun — hasil sudah correct
expense_date = CURRENT_DATE           -- WIB date ✅
fiscal_period = TO_CHAR(NOW(), 'YYYY-MM')  -- WIB month ✅

-- ATAU: jika ingin eksplisit tanpa bergantung DB timezone:
expense_date = (NOW() AT TIME ZONE 'Asia/Jakarta')::DATE
fiscal_period = TO_CHAR(NOW() AT TIME ZONE 'Asia/Jakarta', 'YYYY-MM')
```

### Kolom `fiscal_period` — Aturan Khusus

`fiscal_period` adalah `VARCHAR(7)` berformat `'YYYY-MM'`.
Ini kolom strategis karena seluruh laporan L/R bergantung padanya.

```
Aturan:
1. fiscal_period SELALU dalam konteks WIB (bukan UTC)
2. Untuk incomes: fiscal_period dari confirmed_at (bukan created_at)
3. Untuk expenses: fiscal_period dari expense_date (tanggal aktual transaksi)
4. Untuk kitchen_overhead: fiscal_period diisi manual oleh owner

Mengapa confirmed_at bukan created_at untuk incomes?
  Order dibuat jam 23:55, dikonfirmasi setelah midnight 00:05
  → created_at = bulan ini, confirmed_at = bulan depan
  → Cash basis: revenue dicatat saat confirmed → pakai confirmed_at ✅
```

### FastAPI: Koneksi Database dengan Timezone

```python
# database.py — pastikan setiap koneksi pakai timezone yang benar
from sqlalchemy import create_engine, event
from sqlalchemy.orm import sessionmaker

engine = create_engine(DATABASE_URL)

@event.listens_for(engine, "connect")
def set_timezone(dbapi_connection, connection_record):
    cursor = dbapi_connection.cursor()
    cursor.execute("SET timezone = 'Asia/Jakarta'")
    cursor.close()

# Atau via connection string:
DATABASE_URL = "postgresql://user:pass@host/fast_resto?options=-c%20timezone%3DAsia%2FJakarta"
```

### Format Timestamp di API Response

```python
# schemas.py — Pydantic
from datetime import datetime
from zoneinfo import ZoneInfo

WIB = ZoneInfo("Asia/Jakarta")

def to_wib(dt: datetime) -> str:
    """Convert UTC datetime dari DB ke string WIB untuk response."""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=ZoneInfo("UTC"))
    return dt.astimezone(WIB).strftime("%Y-%m-%d %H:%M WIB")

# Contoh: datetime(2026, 4, 5, 17, 30, tzinfo=UTC) → "2026-04-06 00:30 WIB"
```

### Ringkasan Aturan Timezone

```
DB internal        → SELALU UTC (TIMESTAMPTZ menjamin ini)
DB timezone setting → Asia/Jakarta (untuk CURRENT_DATE, NOW() correct)
API response        → tampilkan dalam WIB (konversi di Python)
Datepicker UI       → user input tanggal WIB, kirim ke API sebagai WIB date string
fiscal_period       → selalu YYYY-MM dalam konteks WIB
```

### Tambahkan ke init.sql (paling atas, setelah CREATE EXTENSION)

```sql
-- ─────────────────────────────────────────────────────────────
-- KONFIGURASI TIMEZONE
-- Semua CURRENT_DATE, NOW() akan mengembalikan waktu WIB
-- TIMESTAMPTZ tetap simpan UTC secara internal
-- ─────────────────────────────────────────────────────────────
ALTER DATABASE fast_resto SET timezone = 'Asia/Jakarta';

-- Set untuk sesi ini juga (karena ALTER DATABASE baru berlaku di koneksi baru)
SET timezone = 'Asia/Jakarta';
```

---

## PENTING: Presisi Angka Uang (Numeric Precision)

### Masalah Float yang Sering Muncul

PostgreSQL `NUMERIC` tidak menggunakan floating point biner (seperti Python `float`),
jadi tidak ada error pembulatan seperti `0.1 + 0.2 = 0.30000000000000004`.
Namun **perkalian dua NUMERIC dengan presisi berbeda** menghasilkan presisi gabungan:

```
NUMERIC(12,3) × NUMERIC(12,4) = NUMERIC(24,7)   ← 7 desimal!
```

Untuk sistem restoran, nilai Rp dengan 7 desimal tidak bermakna dan membuat query
hasil kotor. Aturan yang wajib diterapkan:

### Aturan Presisi Per Jenis Kolom

```
TIPE DATA              CONTOH NILAI       PRESISI    ALASAN
──────────────────── ────────────────── ──────────── ──────────────────────────────
Harga jual menu       Rp 22.000          NUMERIC(12,2) → dipakai untuk tagihan
Harga per base unit   Rp 38 / gram       NUMERIC(12,4) → presisi untuk WAC kecil
  (avg_cost_per_unit)
Stok bahan            5000 gram          NUMERIC(12,3) → max 0.001 gram
Qty per porsi resep   200g / 0.25 pcs    NUMERIC(10,4) → max 0.0001
Yield factor          0.9000             NUMERIC(5,4)  → max 0.0001
Nilai uang final      Rp 8.250           NUMERIC(14,2) → sen (dalam praktik 0dp)
Subtotal transaksi    Rp 850.000         NUMERIC(14,2) → standar rupiah
Food cost %           37.5%              ROUND(..., 1) → 1 desimal cukup
```

### Aturan ROUND: Kapan dan Di Mana

```
SALAH (koma panjang di hasil SELECT):
─────────────────────────────────────
  SUM(qty / yield * cost)  → hasil: 8249.9999...  atau  8250.3333...

BENAR (ROUND sekali di akhir, BUKAN di setiap baris):
──────────────────────────────────────────────────────
  ROUND(SUM(qty / yield * cost), 0)  → hasil: 8250

Prinsip: SUM dulu (akumulasi semua baris), baru ROUND sekali.
Jika ROUND dilakukan per baris → rounding error kecil
tapi bisa berakumulasi jika ada 100+ menu.
```

### Tiga Titik Kritis yang Wajib Di-ROUND

| Titik | Query / Code | ROUND ke |
|---|---|---|
| `v_menu_cogs.theoretical_cogs` | `ROUND(SUM(qty/yield * cost), 0)` | 0 dp (rupiah bulat) |
| `complete_order()` akumulasi | `v_item_cogs + ROUND(qty * cost, 0)` | 0 dp per bahan |
| `stock_movements.total_cost` | `ROUND(qty * cost_per_unit, 2)` | 2 dp (sen) |
| **JANGAN** di-ROUND | `avg_cost_per_unit` (WAC) | Biarkan 4dp — ini intermediate |
| **JANGAN** di-ROUND | `qty_per_portion`, `yield_factor` | Biarkan 4dp — ini intermediate |

### Kenapa avg_cost_per_unit Tidak Di-ROUND?

```
Ayam: qty 5000g, total beli Rp 190.000
avg_cost = 190.000 / 5000 = 38.0000 Rp/gram  ← OK

Campuran:
  Beli 1: 3000g @ Rp 33.000 total
  Beli 2: 2000g @ Rp 80.000 total
  WAC = (3000×11 + 2000×40) / 5000 = 113.000/5000 = 22.6000 Rp/gram

Jika WAC di-ROUND ke 2dp = 22.60
  HPP 200g = 200 × 22.60 = 4.520

Jika WAC tidak di-ROUND = 22.6000
  HPP 200g = 200 × 22.6000 = 4.520

Selisih kecil per porsi, tapi kalau ada bahan dengan WAC = 0.0333/gram
  ROUND(0.0333, 2) = 0.03 → error 10% per gram!
  Biarkan 4dp supaya akumulasi ratusan porsi tidak drift.
```

### Aturan Tampilan di Frontend (bukan di DB)

Pembulatan untuk tampilan harga ke pengguna dilakukan di **frontend / API response**,
bukan di level query. DB menyimpan nilai akurat, frontend format tampilan:

```python
# FastAPI / Python — format Rp tanpa desimal untuk tampilan
def format_rupiah(amount: Decimal) -> str:
    return f"Rp {int(round(amount)):,}".replace(",", ".")
# Contoh: Decimal("8250.33") → "Rp 8.250"
```

```
DB simpan:  8250.33
API return: 8250          (after round to int)
UI tampil:  Rp 8.250
```

---

## Checklist Sebelum Eksekusi init.sql

```
□ Semua ENUM sudah terdaftar di TAHAP 0 sebelum CREATE TABLE
□ Extension uuid-ossp dan pgcrypto sudah di-enable
□ Tabel restaurants ada sebelum users (FK dependency)
□ Semua GENERATED ALWAYS AS pakai STORED (bukan VIRTUAL)
□ Semua FK memakai ON DELETE RESTRICT (default) — jangan CASCADE kecuali disengaja
□ Semua password di seed data memakai hash (bukan plain text)
□ Guard di setiap DB function sudah ada (cegah double-process)
□ View dibuat SETELAH semua tabel yang direferensikan ada
□ Seed data tidak hardcode UUID — pakai uuid_generate_v4() atau variabel
□ Jalankan di database kosong — jika ada error, drop semua dan jalankan ulang
□ [PRESISI] ROUND(SUM(...), 0) di v_menu_cogs.theoretical_cogs (bukan SUM saja)
□ [PRESISI] ROUND per baris di complete_order() sebelum akumulasi v_item_cogs
□ [PRESISI] stock_movements.total_cost pakai ROUND(qty*cost, 2) bukan qty*cost
□ [PRESISI] avg_cost_per_unit TIDAK di-ROUND — biarkan 4dp sebagai intermediate
□ [PRESISI] format Rupiah (tanpa sen) dilakukan di frontend, bukan di query DB
□ [SOFT DELETE] menu_recipes punya is_active BOOLEAN DEFAULT TRUE
□ [SOFT DELETE] UNIQUE index di menu_recipes pakai PARTIAL: WHERE is_active = TRUE
□ [SOFT DELETE] v_menu_cogs JOIN menu_recipes WHERE is_active=TRUE dan ingredients WHERE is_active=TRUE
□ [SOFT DELETE] stock_movements TIDAK punya is_active — ini benar (immutable audit trail)
□ [SOFT DELETE] unit_conversions punya is_active BOOLEAN DEFAULT TRUE
□ [TIMEZONE] ALTER DATABASE fast_resto SET timezone = 'Asia/Jakarta' di awal init.sql
□ [TIMEZONE] SET timezone = 'Asia/Jakarta' setelah ALTER DATABASE (untuk sesi init.sql)
□ [TIMEZONE] FastAPI: set timezone di event listener connect (lihat contoh di atas)
□ [TIMEZONE] fiscal_period selalu dari konteks WIB — setelah DB timezone diset, NOW() sudah WIB
□ [TIMEZONE] TIMESTAMPTZ tetap simpan UTC — sudah benar, tidak perlu diubah

[QR TABLE ORDER]
□ ENUM order_source ditambah di TAHAP 0 bersama ENUM lain
□ CREATE TABLE tables (qr_token DEFAULT encode(gen_random_bytes(32),'hex') UNIQUE)
□ Index: idx_tables_qr_token ON tables(qr_token) WHERE is_active = TRUE
□ orders: tambah table_id FK (nullable), order_source DEFAULT 'kasir', customer_name, customer_phone
□ orders: pertahankan table_number VARCHAR(10) sebagai snapshot (isi dari tables.table_number)
□ Index partial: idx_orders_self_order_open WHERE order_source='self_order' AND status='open'

[CMS LANDING PAGE]
□ menus: tambah description TEXT, image_url VARCHAR(500), sort_order INTEGER DEFAULT 0
□ CREATE TABLE cms_site_settings (restaurant_id, key, value) UNIQUE(restaurant_id, key)
□ CREATE TABLE cms_banners (sequence, start_date, end_date, is_active)
□ CREATE TABLE cms_promotions (discount_label, start_date, end_date, is_active)
□ Seed cms_site_settings: 10 default keys (restaurant_name, tagline, hero_title, dll)
□ Semua tabel CMS punya is_active → soft delete via is_active=FALSE

[WA GATEWAY — Adopsi Fast-Klinik]
□ CREATE TABLE wa_message_templates (code UNIQUE, body dengan {{placeholder}})
□ CREATE TABLE notification_jobs (UNIQUE(order_id, template_code), status pending/done/failed)
□ CREATE TABLE messages (wa_queue_id INTEGER, status queued/sent/failed)
□ Index: idx_notif_jobs_pending ON notification_jobs(run_at) WHERE status='pending'
□ Index: idx_messages_queued ON messages(wa_queue_id) WHERE status='queued'
□ Seed wa_message_templates: ORDER_RECEIPT + ORDER_CONFIRM (isi lengkap dari landing-resto.md)
□ notification_jobs dan messages dibuat SETELAH orders (FK dependency)
```

---

## Perintah Eksekusi (Terminal)

```bash
# Buat database baru (sekali saja)
createdb fast_resto

# Jalankan init.sql
psql -d fast_resto -f init.sql

# Verifikasi tabel terbuat
psql -d fast_resto -c "\dt"

# Verifikasi views
psql -d fast_resto -c "\dv"

# Verifikasi functions
psql -d fast_resto -c "\df"
```

---

## Estimasi Ukuran init.sql

| Bagian | Estimasi Baris |
|---|---|
| Extensions + ENUMs | ~65 baris |
| Master Data Tables (incl. tables, cms_*) | ~200 baris |
| Transaction Tables (incl. kolom baru orders) | ~160 baris |
| Supporting Tables (incl. wa_*, notification_*) | ~130 baris |
| Indexes | ~45 baris |
| DB Functions | ~300 baris |
| Views | ~150 baris |
| Seed Data (incl. tables, cms_settings, wa_templates) | ~200 baris |
| **Total estimasi** | **~1.250 baris** |

Naik dari estimasi sebelumnya (~1.040) karena tambahan:
- 3 tabel CMS (cms_site_settings, cms_banners, cms_promotions)
- 1 tabel meja (tables)
- 3 tabel WA (wa_message_templates, notification_jobs, messages)
- Kolom baru di menus dan orders
- Seed data tambahan (meja, cms settings, wa templates)

---

*Dokumen perencanaan ini selesai. Eksekusi: tulis init.sql mengikuti urutan TAHAP 0 → TAHAP 8.*
