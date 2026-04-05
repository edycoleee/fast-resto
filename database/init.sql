-- ═══════════════════════════════════════════════════════════════════════════
-- FAST-RESTO — init.sql
-- PostgreSQL schema: master data, transaksi, WA notifikasi, CMS landing
-- Dibuat: April 2026
-- Urutan: TAHAP 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- TAHAP 0 — EXTENSIONS & TIMEZONE & ENUMs
-- ═══════════════════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─────────────────────────────────────────────────────────────────────────
-- KONFIGURASI TIMEZONE
-- Semua CURRENT_DATE, NOW() akan mengembalikan waktu WIB (Asia/Jakarta)
-- TIMESTAMPTZ tetap simpan UTC secara internal
-- ─────────────────────────────────────────────────────────────────────────
ALTER DATABASE fast_resto SET timezone = 'Asia/Jakarta';
SET timezone = 'Asia/Jakarta';

-- ─────────────────────────────────────────────────────────────────────────
-- ENUMs — harus ada sebelum CREATE TABLE
-- ─────────────────────────────────────────────────────────────────────────

CREATE TYPE ingredient_unit AS ENUM (
    'gram', 'ml', 'pcs', 'portion'
);

CREATE TYPE ingredient_category AS ENUM (
    'recipe',    -- Kategori A: masuk resep per-porsi, stok dipantau
    'overhead'   -- Kategori B: overhead dapur, dicatat sebagai expense bulanan
);

CREATE TYPE movement_type AS ENUM (
    'purchase',
    'sale',
    'waste',
    'opname_adj',
    'return_to_supplier',
    'transfer_in',
    'opening'
);

CREATE TYPE purchase_status AS ENUM (
    'draft', 'received', 'paid', 'partial', 'cancelled'
);

CREATE TYPE order_channel AS ENUM (
    'dine_in', 'takeaway', 'grabfood', 'gofood', 'shopeefood'
);

CREATE TYPE order_status AS ENUM (
    'open', 'completed', 'void', 'refunded'
);

CREATE TYPE order_source AS ENUM (
    'kasir',      -- kasir yang input langsung
    'self_order', -- customer scan QR dan pesan sendiri
    'platform'    -- GrabFood, GoFood
);

CREATE TYPE payment_method AS ENUM (
    'cash', 'qris', 'transfer', 'grabfood_settlement', 'gofood_settlement'
);

CREATE TYPE payment_status AS ENUM (
    'pending', 'confirmed', 'void'
);

CREATE TYPE expense_category AS ENUM (
    -- Blok HPP
    'food_waste',
    'inventory_loss',
    'kitchen_overhead',
    -- Beban Operasional
    'salary',
    'utility',
    'rent',
    'platform_fee',
    'maintenance',
    'marketing',
    'packaging',
    'refund',
    'other'
);

CREATE TYPE opname_status AS ENUM (
    'draft', 'confirmed'
);

CREATE TYPE shift_status AS ENUM (
    'open', 'closed'
);

CREATE TYPE user_role AS ENUM (
    'owner', 'manager', 'kasir', 'dapur', 'viewer'
);


-- ═══════════════════════════════════════════════════════════════════════════
-- TAHAP 1 — RBAC: users (flat role)
-- ═══════════════════════════════════════════════════════════════════════════

-- users dibuat di sini karena beberapa tabel di TAHAP 2 referensikan created_by
-- restaurants dibuat di TAHAP 2, users.restaurant_id pakai FK deferrable
-- Solusi: buat users dulu tanpa FK constraint, tambah FK setelah restaurants ada
-- Alternatif lebih sederhana: buat restaurants dulu (lihat TAHAP 2)

-- NOTE: Tabel restaurants harus ada sebelum users karena ada FK.
-- Kita akan buat restaurants di TAHAP 2, lalu users langsung sesudahnya.


-- ═══════════════════════════════════════════════════════════════════════════
-- TAHAP 2 — MASTER DATA TABLES
-- Urutan FK: restaurants → users → suppliers → ingredients → menus
--           → menu_recipes → unit_conversions → tables → cms_*
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- 2.1 restaurants
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE restaurants (
    id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name         VARCHAR(150) NOT NULL,
    address      TEXT,
    phone        VARCHAR(30),
    tax_number   VARCHAR(50),
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────────────────
-- 2.2 users — RBAC flat role
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    name            VARCHAR(100) NOT NULL,
    email           VARCHAR(150) NOT NULL,
    -- bcrypt hash (cost factor 12) via FastAPI passlib — JANGAN simpan plaintext
    password_hash   VARCHAR(255) NOT NULL,
    role            user_role NOT NULL DEFAULT 'kasir',
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (email)
);

-- ─────────────────────────────────────────────────────────────────────────
-- 2.3 suppliers
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE suppliers (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    name            VARCHAR(100) NOT NULL,
    phone           VARCHAR(20),
    payment_terms   VARCHAR(50) DEFAULT 'cash',
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────────────────
-- 2.4 ingredients
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE ingredients (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id       UUID NOT NULL REFERENCES restaurants(id),
    name                VARCHAR(100) NOT NULL,
    unit                ingredient_unit NOT NULL,
    ingredient_category ingredient_category NOT NULL DEFAULT 'recipe',
    -- avg_cost_per_unit: Rp per BASE UNIT (gram/ml/pcs) — presisi 4dp
    -- Diupdate otomatis setiap confirm_purchase()
    avg_cost_per_unit   NUMERIC(12,4) NOT NULL DEFAULT 0,
    -- current_stock: dalam BASE UNIT — hanya bermakna untuk Kat. A
    current_stock       NUMERIC(12,3) NOT NULL DEFAULT 0,
    reorder_point       NUMERIC(12,3) DEFAULT 0,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (restaurant_id, name)
);

-- ─────────────────────────────────────────────────────────────────────────
-- 2.5 menus
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE menus (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    name            VARCHAR(100) NOT NULL,
    category        VARCHAR(50),          -- 'makanan', 'minuman', 'snack', 'lauk'
    description     TEXT,                 -- deskripsi untuk halaman landing/QR menu
    image_url       VARCHAR(500),         -- URL gambar menu
    sort_order      INTEGER DEFAULT 0,    -- urutan tampil per kategori
    selling_price   NUMERIC(12,2) NOT NULL,
    is_available    BOOLEAN NOT NULL DEFAULT TRUE,   -- sold-out toggle
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,   -- soft delete
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (restaurant_id, name)
);

-- ─────────────────────────────────────────────────────────────────────────
-- 2.6 menu_recipes — BOM (Bill of Materials) per menu
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE menu_recipes (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    menu_id         UUID NOT NULL REFERENCES menus(id),
    ingredient_id   UUID NOT NULL REFERENCES ingredients(id),
    -- qty_per_portion dalam BASE UNIT (gram/ml/pcs) — presisi 4dp
    qty_per_portion NUMERIC(10,4) NOT NULL,
    -- yield_factor: konversi bahan mentah ke siap pakai
    -- Contoh: lele 0.55 (buang kepala/perut/tulang), ayam 0.90, tepung 1.0
    yield_factor    NUMERIC(5,4) NOT NULL DEFAULT 1.0
                        CHECK (yield_factor > 0 AND yield_factor <= 1),
    notes           TEXT,
    -- is_active: FALSE saat resep baris ini digantikan versi baru
    -- JANGAN hard-delete — histori HPP perlu dipertahankan
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
    -- UNIQUE partial index: CREATE UNIQUE INDEX ... WHERE is_active = TRUE
    -- (lihat TAHAP 5)
);

-- ─────────────────────────────────────────────────────────────────────────
-- 2.7 unit_conversions — referensi konversi satuan beli vs base unit
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE unit_conversions (
    base_unit     VARCHAR(20) NOT NULL,
    purchase_unit VARCHAR(20) NOT NULL,
    -- 1 purchase_unit = factor base_unit
    factor        NUMERIC(10,4) NOT NULL CHECK (factor > 0),
    description   TEXT,
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    PRIMARY KEY (base_unit, purchase_unit)
);

-- ─────────────────────────────────────────────────────────────────────────
-- 2.8 tables — meja fisik + QR token untuk self-order
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE tables (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id UUID NOT NULL REFERENCES restaurants(id),
    table_number  VARCHAR(20) NOT NULL,
    capacity      INTEGER DEFAULT 4,
    -- qr_token: string unik 64 karakter hex — di-embed ke QR code
    -- Setiap scan → lookup meja ini → buat order dengan table_id
    qr_token      VARCHAR(64) NOT NULL UNIQUE
                      DEFAULT encode(gen_random_bytes(32), 'hex'),
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (restaurant_id, table_number)
);

-- ─────────────────────────────────────────────────────────────────────────
-- 2.9 cms_site_settings — key-value settings landing page
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE cms_site_settings (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id UUID NOT NULL REFERENCES restaurants(id),
    key           VARCHAR(100) NOT NULL,
    value         TEXT,
    updated_at    TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (restaurant_id, key)
);

-- ─────────────────────────────────────────────────────────────────────────
-- 2.10 cms_banners — banner/slider landing page
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE cms_banners (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id UUID NOT NULL REFERENCES restaurants(id),
    title         VARCHAR(150),
    subtitle      VARCHAR(300),
    image_url     VARCHAR(500) NOT NULL,
    action_url    VARCHAR(500),         -- link ke section atau promo
    sequence      INTEGER DEFAULT 0,    -- urutan slide
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    start_date    DATE,                 -- NULL = selalu tampil
    end_date      DATE,
    created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────────────────
-- 2.11 cms_promotions — halaman promo/diskon
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE cms_promotions (
    id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id  UUID NOT NULL REFERENCES restaurants(id),
    title          VARCHAR(150) NOT NULL,
    description    TEXT,
    image_url      VARCHAR(500),
    discount_pct   INTEGER,             -- 0-100, null jika bukan persen
    discount_label VARCHAR(50),         -- "Beli 2 Gratis 1", "Hemat 30%"
    start_date     DATE NOT NULL,
    end_date       DATE NOT NULL,
    is_active      BOOLEAN NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ DEFAULT NOW()
);


-- ═══════════════════════════════════════════════════════════════════════════
-- TAHAP 3 — TRANSACTION DATA TABLES
-- Urutan FK: kasir_shifts → orders → order_items → payments
--           → incomes → purchases → purchase_items → expenses
--           → delivery_platform_batches
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- 3.1 kasir_shifts
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE kasir_shifts (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    cashier_id      UUID NOT NULL REFERENCES users(id),
    shift_date      DATE NOT NULL DEFAULT CURRENT_DATE,
    opened_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at       TIMESTAMPTZ,
    status          shift_status NOT NULL DEFAULT 'open',
    opening_cash    NUMERIC(14,2) NOT NULL DEFAULT 0,
    expected_cash   NUMERIC(14,2),
    actual_cash     NUMERIC(14,2),
    cash_variance   NUMERIC(14,2) GENERATED ALWAYS AS
                        (actual_cash - expected_cash) STORED,
    notes           TEXT
);

-- ─────────────────────────────────────────────────────────────────────────
-- 3.2 orders — header order POS (termasuk QR self-order)
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE orders (
    id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id     UUID NOT NULL REFERENCES restaurants(id),
    order_number      VARCHAR(20) NOT NULL UNIQUE,  -- ORD-20260405-001
    channel           order_channel NOT NULL DEFAULT 'dine_in',
    order_source      order_source NOT NULL DEFAULT 'kasir',
    -- Untuk delivery: nomor order dari platform
    platform_order_id VARCHAR(50),
    -- FK ke meja (untuk self_order)
    table_id          UUID REFERENCES tables(id),
    -- snapshot nama meja saat order dibuat (denormalisasi ringan)
    table_number      VARCHAR(10),
    -- Info customer (opsional) — untuk struk WA
    customer_name     VARCHAR(100),
    customer_phone    VARCHAR(20),
    status            order_status NOT NULL DEFAULT 'open',
    subtotal          NUMERIC(14,2) NOT NULL DEFAULT 0,
    discount          NUMERIC(14,2) NOT NULL DEFAULT 0,
    total             NUMERIC(14,2) NOT NULL DEFAULT 0,
    shift_id          UUID REFERENCES kasir_shifts(id),
    notes             TEXT,
    created_by        UUID REFERENCES users(id),
    created_at        TIMESTAMPTZ DEFAULT NOW(),
    completed_at      TIMESTAMPTZ
);

-- ─────────────────────────────────────────────────────────────────────────
-- 3.3 order_items — detail menu per order
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE order_items (
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id         UUID NOT NULL REFERENCES orders(id),
    menu_id          UUID NOT NULL REFERENCES menus(id),
    menu_name        VARCHAR(100) NOT NULL,     -- snapshot nama saat transaksi
    unit_price       NUMERIC(12,2) NOT NULL,    -- snapshot harga saat transaksi
    qty              INTEGER NOT NULL CHECK (qty > 0),
    subtotal         NUMERIC(14,2) GENERATED ALWAYS AS (unit_price * qty) STORED,
    -- HPP teoritis Kat. A saja (diisi oleh complete_order())
    theoretical_cogs NUMERIC(14,2),
    notes            TEXT   -- catatan dapur: "pedas", "tanpa bawang", dll
);

-- ─────────────────────────────────────────────────────────────────────────
-- 3.4 payments
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE payments (
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id         UUID NOT NULL REFERENCES orders(id),
    amount           NUMERIC(14,2) NOT NULL,
    method           payment_method NOT NULL,
    status           payment_status NOT NULL DEFAULT 'pending',
    reference_number VARCHAR(100),   -- nomor ref QRIS dari payment gateway
    shift_id         UUID REFERENCES kasir_shifts(id),
    confirmed_by     UUID REFERENCES users(id),
    confirmed_at     TIMESTAMPTZ,
    void_reason      TEXT,
    created_at       TIMESTAMPTZ DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────────────────
-- 3.5 incomes — single source of truth revenue (dibuat otomatis oleh confirm_payment)
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE incomes (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    reference_type  VARCHAR(30) NOT NULL DEFAULT 'payment',
    reference_id    UUID NOT NULL,          -- payment.id
    amount          NUMERIC(14,2) NOT NULL,
    fiscal_period   VARCHAR(7) NOT NULL,    -- 'YYYY-MM' dari confirmed_at (WIB)
    income_date     DATE NOT NULL,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,  -- FALSE saat refund
    notes           TEXT,
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────────────────
-- 3.6 purchases — header pembelian bahan dari supplier
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE purchases (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    supplier_id     UUID REFERENCES suppliers(id),
    purchase_date   DATE NOT NULL DEFAULT CURRENT_DATE,
    invoice_number  VARCHAR(50),
    status          purchase_status NOT NULL DEFAULT 'draft',
    subtotal        NUMERIC(14,2) NOT NULL DEFAULT 0,
    paid_amount     NUMERIC(14,2) NOT NULL DEFAULT 0,
    notes           TEXT,
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────────────────
-- 3.7 purchase_items — detail bahan per pembelian (dengan konversi satuan)
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE purchase_items (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    purchase_id         UUID NOT NULL REFERENCES purchases(id),
    ingredient_id       UUID NOT NULL REFERENCES ingredients(id),

    -- Satuan beli (sesuai nota supplier — bisa berbeda dari base unit)
    purchase_qty        NUMERIC(12,3) NOT NULL,
    purchase_unit       VARCHAR(20) NOT NULL,    -- 'kg', 'liter', 'ikat', dll

    -- 1 purchase_unit = conversion_factor base_unit
    -- Contoh: kg→gram=1000, liter→ml=1000, lusin→pcs=12
    conversion_factor   NUMERIC(10,4) NOT NULL DEFAULT 1
                            CHECK (conversion_factor > 0),

    -- Harga per satuan BELI (sesuai nota supplier)
    unit_price          NUMERIC(12,4) NOT NULL,

    -- Kolom GENERATED — dihitung otomatis oleh DB
    -- Dipakai oleh confirm_purchase() untuk update stok dan avg_cost
    qty_in_base_unit    NUMERIC(14,4)
                            GENERATED ALWAYS AS (purchase_qty * conversion_factor) STORED,
    price_per_base_unit NUMERIC(14,6)
                            GENERATED ALWAYS AS (unit_price / conversion_factor) STORED,
    subtotal            NUMERIC(14,2)
                            GENERATED ALWAYS AS (purchase_qty * unit_price) STORED
);

-- ─────────────────────────────────────────────────────────────────────────
-- 3.8 expenses — single source of truth semua pengeluaran
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE expenses (
    id                 UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id      UUID NOT NULL REFERENCES restaurants(id),
    amount             NUMERIC(14,2) NOT NULL,
    category           expense_category NOT NULL,
    reference_platform VARCHAR(30),    -- 'grabfood', 'gofood', 'shopeefood'
    reference_type     VARCHAR(30),    -- 'opname', 'platform_batch', 'manual', 'refund'
    reference_id       UUID,
    fiscal_period      VARCHAR(7) NOT NULL,   -- 'YYYY-MM' dalam konteks WIB
    expense_date       DATE NOT NULL,
    description        TEXT,
    is_active          BOOLEAN NOT NULL DEFAULT TRUE,
    created_by         UUID REFERENCES users(id),
    created_at         TIMESTAMPTZ DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────────────────
-- 3.9 delivery_platform_batches — rekonsiliasi GrabFood/GoFood per periode
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE delivery_platform_batches (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    platform        order_channel NOT NULL,   -- 'grabfood', 'gofood'
    period_start    DATE NOT NULL,
    period_end      DATE NOT NULL,
    gross_sales     NUMERIC(14,2) NOT NULL,
    platform_fee    NUMERIC(14,2) NOT NULL,
    net_settlement  NUMERIC(14,2) GENERATED ALWAYS AS
                        (gross_sales - platform_fee) STORED,
    bank_account    VARCHAR(50),
    is_reconciled   BOOLEAN NOT NULL DEFAULT FALSE,
    reconciled_at   TIMESTAMPTZ,
    notes           TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);


-- ═══════════════════════════════════════════════════════════════════════════
-- TAHAP 4 — SUPPORTING & AUDIT TABLES
-- stock_movements → stock_opnames → stock_opname_items
-- → wa_message_templates → notification_jobs → messages
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- 4.1 stock_movements — audit trail immutable pergerakan stok Kat. A
-- JANGAN tambahkan is_active atau soft delete — ini append-only
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE stock_movements (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    ingredient_id   UUID NOT NULL REFERENCES ingredients(id),
    movement_type   movement_type NOT NULL,
    -- Positif = masuk stok, Negatif = keluar stok
    -- qty dalam BASE UNIT (gram/ml/pcs) — presisi 3dp
    qty             NUMERIC(12,3) NOT NULL,
    -- cost_per_unit: Rp per BASE UNIT — presisi 4dp
    cost_per_unit   NUMERIC(12,4) NOT NULL DEFAULT 0,
    -- ROUND eksplisit agar tidak ada akumulasi error float
    total_cost      NUMERIC(14,2) GENERATED ALWAYS AS
                        (ROUND(qty * cost_per_unit, 2)) STORED,
    reference_type  VARCHAR(30),   -- 'order', 'purchase', 'opname', 'waste_log', 'refund'
    reference_id    UUID,
    notes           TEXT,
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────────────────
-- 4.2 stock_opnames — header stock opname harian
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE stock_opnames (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    opname_date     DATE NOT NULL DEFAULT CURRENT_DATE,
    status          opname_status NOT NULL DEFAULT 'draft',
    notes           TEXT,
    created_by      UUID REFERENCES users(id),
    confirmed_by    UUID REFERENCES users(id),
    confirmed_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (restaurant_id, opname_date)   -- satu opname per hari per restoran
);

-- ─────────────────────────────────────────────────────────────────────────
-- 4.3 stock_opname_items — detail per bahan per opname
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE stock_opname_items (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    opname_id       UUID NOT NULL REFERENCES stock_opnames(id),
    ingredient_id   UUID NOT NULL REFERENCES ingredients(id),
    -- theoretical_qty: snapshot dari ingredients.current_stock saat opname dibuat
    theoretical_qty NUMERIC(12,3) NOT NULL,
    -- actual_qty: stok fisik yang dihitung manusia
    actual_qty      NUMERIC(12,3) NOT NULL,
    -- variance = actual - theoretical (negatif = LOSS)
    variance        NUMERIC(12,3) GENERATED ALWAYS AS
                        (actual_qty - theoretical_qty) STORED,
    cost_per_unit   NUMERIC(12,4) NOT NULL,
    -- variance_value = selisih × harga (negatif = rupiah yang hilang)
    variance_value  NUMERIC(14,2) GENERATED ALWAYS AS
                        ((actual_qty - theoretical_qty) * cost_per_unit) STORED,
    UNIQUE (opname_id, ingredient_id)
);

-- ─────────────────────────────────────────────────────────────────────────
-- 4.4 wa_message_templates — template body pesan WA
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE wa_message_templates (
    id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    code       VARCHAR(50) UNIQUE NOT NULL,   -- ORDER_RECEIPT, ORDER_CONFIRM
    title      VARCHAR(100) NOT NULL,
    -- body menggunakan {{placeholder}} seperti {{restaurant_name}}, {{order_number}}
    body       TEXT NOT NULL,
    is_active  BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────────────────
-- 4.5 notification_jobs — antrian kirim notifikasi WA per order
-- (dibuat oleh NotificationService FastAPI, BUKAN oleh DB function)
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE notification_jobs (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id      UUID REFERENCES orders(id) ON DELETE SET NULL,
    template_code VARCHAR(50) NOT NULL,
    -- run_at = NOW() untuk kirim langsung, future datetime untuk terjadwal
    run_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status        VARCHAR(20) NOT NULL DEFAULT 'pending',  -- pending | done | failed
    attempts      INTEGER NOT NULL DEFAULT 0,
    last_error    TEXT,
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    updated_at    TIMESTAMPTZ DEFAULT NOW(),
    -- Cegah job duplikat untuk order + template yang sama
    UNIQUE (order_id, template_code)
);

-- ─────────────────────────────────────────────────────────────────────────
-- 4.6 messages — log setiap upaya kirim WA
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE messages (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    job_id        UUID REFERENCES notification_jobs(id) ON DELETE SET NULL,
    order_id      UUID REFERENCES orders(id) ON DELETE SET NULL,
    phone         VARCHAR(20) NOT NULL,
    channel       VARCHAR(20) NOT NULL DEFAULT 'whatsapp',
    body_rendered TEXT NOT NULL,        -- isi pesan yang sudah dirender dari template
    -- wa_queue_id: ID dari gateway setelah diterima (202 Accepted)
    -- Dipakai oleh fallback sync loop untuk cek status via GET /status/{wa_queue_id}
    wa_queue_id   INTEGER,
    status        VARCHAR(20) NOT NULL DEFAULT 'queued',  -- queued | sent | failed
    sent_at       TIMESTAMPTZ,
    error_message TEXT,
    created_at    TIMESTAMPTZ DEFAULT NOW(),
    updated_at    TIMESTAMPTZ DEFAULT NOW()
);


-- ═══════════════════════════════════════════════════════════════════════════
-- TAHAP 5 — INDEXES
-- Dibuat setelah semua tabel ada
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── ingredients ──────────────────────────────────────────────────────────
CREATE INDEX idx_ingredients_category
    ON ingredients(restaurant_id, ingredient_category)
    WHERE is_active = TRUE;

-- ─── stock_movements ──────────────────────────────────────────────────────
CREATE INDEX idx_stock_mov_ingredient
    ON stock_movements(ingredient_id, created_at DESC);

CREATE INDEX idx_stock_mov_restaurant
    ON stock_movements(restaurant_id, movement_type, created_at DESC);

-- ─── orders ───────────────────────────────────────────────────────────────
CREATE INDEX idx_orders_restaurant_status
    ON orders(restaurant_id, status, completed_at DESC);

-- Khusus untuk dashboard kasir: tampilkan self-order yang belum diproses
CREATE INDEX idx_orders_self_order_pending
    ON orders(restaurant_id, created_at)
    WHERE order_source = 'self_order' AND status = 'open';

-- ─── order_items ──────────────────────────────────────────────────────────
CREATE INDEX idx_order_items_order
    ON order_items(order_id);

-- ─── payments ─────────────────────────────────────────────────────────────
CREATE INDEX idx_payments_order
    ON payments(order_id);

-- ─── incomes ──────────────────────────────────────────────────────────────
CREATE INDEX idx_incomes_period
    ON incomes(restaurant_id, fiscal_period)
    WHERE is_active = TRUE;

CREATE INDEX idx_incomes_reference
    ON incomes(reference_id, reference_type);

-- ─── expenses ─────────────────────────────────────────────────────────────
CREATE INDEX idx_expenses_period
    ON expenses(restaurant_id, fiscal_period)
    WHERE is_active = TRUE;

CREATE INDEX idx_expenses_category
    ON expenses(restaurant_id, category, fiscal_period);

-- ─── purchases ────────────────────────────────────────────────────────────
CREATE INDEX idx_purchases_status
    ON purchases(restaurant_id, status);

-- ─── kasir_shifts ─────────────────────────────────────────────────────────
CREATE INDEX idx_kasir_shifts_date
    ON kasir_shifts(restaurant_id, shift_date DESC);

-- ─── stock_opnames ────────────────────────────────────────────────────────
CREATE INDEX idx_stock_opnames_date
    ON stock_opnames(restaurant_id, opname_date DESC);

-- ─── menu_recipes — partial unique (satu bahan aktif per menu) ────────────
CREATE UNIQUE INDEX idx_menu_recipes_unique_active
    ON menu_recipes(menu_id, ingredient_id)
    WHERE is_active = TRUE;

-- ─── tables (QR) ──────────────────────────────────────────────────────────
-- Lookup terjadi setiap customer scan QR — harus cepat
CREATE INDEX idx_tables_qr_token
    ON tables(qr_token)
    WHERE is_active = TRUE;

-- ─── cms ──────────────────────────────────────────────────────────────────
CREATE INDEX idx_cms_banners_active
    ON cms_banners(restaurant_id, sequence)
    WHERE is_active = TRUE;

CREATE INDEX idx_cms_promotions_active
    ON cms_promotions(restaurant_id, end_date)
    WHERE is_active = TRUE;

CREATE INDEX idx_cms_site_settings_restaurant
    ON cms_site_settings(restaurant_id);

-- ─── WA notification ──────────────────────────────────────────────────────
CREATE INDEX idx_notif_jobs_pending
    ON notification_jobs(run_at)
    WHERE status = 'pending';

-- Fallback sync loop: cari semua messages yang masih queued
CREATE INDEX idx_messages_queued
    ON messages(wa_queue_id)
    WHERE status = 'queued';


-- ═══════════════════════════════════════════════════════════════════════════
-- TAHAP 6 — DB FUNCTIONS
-- Urutan: confirm_purchase → complete_order → confirm_payment
--        → confirm_opname → confirm_platform_settlement
--        → void_order → refund_order
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- 6.1 confirm_purchase — konfirmasi penerimaan bahan dari supplier
-- Kat. A: update stok + avg_cost + catat stock_movements
-- Kat. B: hanya update avg_cost (referensi harga overhead)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION confirm_purchase(
    p_purchase_id   UUID,
    p_confirmed_by  UUID
) RETURNS VOID AS $$
DECLARE
    v_item          RECORD;
    v_new_avg_cost  NUMERIC;
    v_old_stock     NUMERIC;
    v_old_cost      NUMERIC;
    v_status        purchase_status;
BEGIN
    -- Guard: jangan proses ulang
    SELECT status INTO v_status FROM purchases WHERE id = p_purchase_id;
    IF v_status != 'draft' THEN
        RAISE EXCEPTION 'Purchase % sudah dikonfirmasi sebelumnya (status: %)',
            p_purchase_id, v_status;
    END IF;

    FOR v_item IN
        SELECT pi.*,
               i.current_stock,
               i.avg_cost_per_unit,
               i.ingredient_category
        FROM purchase_items pi
        JOIN ingredients i ON i.id = pi.ingredient_id
        WHERE pi.purchase_id = p_purchase_id
    LOOP
        v_old_stock := v_item.current_stock;
        v_old_cost  := v_item.avg_cost_per_unit;

        -- Weighted Average Cost (WAC) — selalu dalam BASE UNIT
        -- qty_in_base_unit dan price_per_base_unit sudah di-GENERATE oleh DB
        v_new_avg_cost := (
            (v_old_stock * v_old_cost)
            + (v_item.qty_in_base_unit * v_item.price_per_base_unit)
        ) / NULLIF(v_old_stock + v_item.qty_in_base_unit, 0);

        IF v_item.ingredient_category = 'recipe' THEN
            -- Kat. A: update stok + avg_cost + catat audit trail
            UPDATE ingredients
            SET current_stock     = current_stock + v_item.qty_in_base_unit,
                avg_cost_per_unit = v_new_avg_cost
            WHERE id = v_item.ingredient_id;

            INSERT INTO stock_movements (
                restaurant_id, ingredient_id, movement_type,
                qty, cost_per_unit,
                reference_type, reference_id,
                created_by
            ) VALUES (
                (SELECT restaurant_id FROM purchases WHERE id = p_purchase_id),
                v_item.ingredient_id,
                'purchase',
                v_item.qty_in_base_unit,      -- dalam BASE UNIT (gram/ml/pcs)
                v_item.price_per_base_unit,   -- Rp per BASE UNIT
                'purchase', p_purchase_id,
                p_confirmed_by
            );
        ELSE
            -- Kat. B: hanya update referensi harga, stok tidak dipantau
            UPDATE ingredients
            SET avg_cost_per_unit = v_new_avg_cost
            WHERE id = v_item.ingredient_id;
        END IF;
    END LOOP;

    UPDATE purchases SET status = 'received' WHERE id = p_purchase_id;
END;
$$ LANGUAGE plpgsql;

-- ─────────────────────────────────────────────────────────────────────────
-- 6.2 complete_order — selesaikan order: kurangi stok + hitung HPP teoritis
-- Hanya bahan Kat. A yang diproses, Kat. B tidak punya stok yang perlu dikurangi
-- ROUND per akumulasi untuk menghindari error propagasi float
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION complete_order(
    p_order_id  UUID,
    p_user_id   UUID
) RETURNS VOID AS $$
DECLARE
    v_item          RECORD;
    v_recipe        RECORD;
    v_item_cogs     NUMERIC;
    v_restaurant_id UUID;
    v_order_status  order_status;
BEGIN
    -- Guard: jangan proses order yang sudah selesai/void
    SELECT status, restaurant_id INTO v_order_status, v_restaurant_id
    FROM orders WHERE id = p_order_id;

    IF v_order_status != 'open' THEN
        RAISE EXCEPTION 'Order % tidak dalam status open (status: %)',
            p_order_id, v_order_status;
    END IF;

    FOR v_item IN
        SELECT oi.id AS item_id, oi.menu_id, oi.qty
        FROM order_items oi
        WHERE oi.order_id = p_order_id
    LOOP
        v_item_cogs := 0;

        -- Loop setiap bahan Kat. A di resep menu ini
        FOR v_recipe IN
            SELECT mr.ingredient_id,
                   mr.qty_per_portion / mr.yield_factor AS qty_needed,
                   i.avg_cost_per_unit
            FROM menu_recipes mr
            JOIN ingredients i ON i.id = mr.ingredient_id
            WHERE mr.menu_id = v_item.menu_id
              AND mr.is_active = TRUE
              AND i.ingredient_category = 'recipe'
              AND i.is_active = TRUE
        LOOP
            DECLARE
                v_total_qty NUMERIC := v_recipe.qty_needed * v_item.qty;
            BEGIN
                -- Kurangi stok teoritis Kat. A
                UPDATE ingredients
                SET current_stock = current_stock - v_total_qty
                WHERE id = v_recipe.ingredient_id;

                -- Audit trail stock_movements
                INSERT INTO stock_movements (
                    restaurant_id, ingredient_id, movement_type,
                    qty, cost_per_unit,
                    reference_type, reference_id,
                    created_by
                ) VALUES (
                    v_restaurant_id,
                    v_recipe.ingredient_id,
                    'sale',
                    -v_total_qty,
                    v_recipe.avg_cost_per_unit,
                    'order', p_order_id,
                    p_user_id
                );

                -- Akumulasi COGS: ROUND per bahan → hindari error propagasi
                v_item_cogs := v_item_cogs
                    + ROUND(v_total_qty * v_recipe.avg_cost_per_unit, 0);
            END;
        END LOOP;

        -- Simpan theoretical_cogs di order_item (HPP Kat. A saja, dibulatkan)
        UPDATE order_items
        SET theoretical_cogs = v_item_cogs
        WHERE id = v_item.item_id;
    END LOOP;

    UPDATE orders
    SET status       = 'completed',
        completed_at = NOW()
    WHERE id = p_order_id;
END;
$$ LANGUAGE plpgsql;

-- ─────────────────────────────────────────────────────────────────────────
-- 6.3 confirm_payment — konfirmasi bayar, buat income (cash basis)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION confirm_payment(
    p_payment_id    UUID,
    p_confirmed_by  UUID
) RETURNS VOID AS $$
DECLARE
    v_payment   payments%ROWTYPE;
    v_order     orders%ROWTYPE;
BEGIN
    -- Guard: jangan proses ulang
    SELECT * INTO v_payment FROM payments WHERE id = p_payment_id;

    IF v_payment.status != 'pending' THEN
        RAISE EXCEPTION 'Payment % sudah pernah diproses (status: %)',
            p_payment_id, v_payment.status;
    END IF;

    SELECT * INTO v_order FROM orders WHERE id = v_payment.order_id;

    -- Update status payment
    UPDATE payments
    SET status       = 'confirmed',
        confirmed_by = p_confirmed_by,
        confirmed_at = NOW()
    WHERE id = p_payment_id;

    -- Income dicatat saat payment dikonfirmasi (cash basis)
    -- fiscal_period dari confirmed_at (bukan created_at) — sesuai prinsip cash basis
    INSERT INTO incomes (
        restaurant_id,
        reference_type,
        reference_id,
        amount,
        fiscal_period,
        income_date,
        is_active,
        created_by
    ) VALUES (
        v_order.restaurant_id,
        'payment',
        p_payment_id,
        v_payment.amount,
        TO_CHAR(NOW(), 'YYYY-MM'),   -- WIB bulan (karena DB timezone = Asia/Jakarta)
        CURRENT_DATE,                -- WIB date
        TRUE,
        p_confirmed_by
    );
END;
$$ LANGUAGE plpgsql;

-- ─────────────────────────────────────────────────────────────────────────
-- 6.4 confirm_opname — kunci stock opname + koreksi stok + catat LOSS
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION confirm_opname(
    p_opname_id UUID,
    p_user_id   UUID
) RETURNS VOID AS $$
DECLARE
    v_item          RECORD;
    v_restaurant_id UUID;
    v_total_loss    NUMERIC := 0;
    v_opname_status opname_status;
BEGIN
    -- Guard: jangan konfirmasi ulang
    SELECT status, restaurant_id INTO v_opname_status, v_restaurant_id
    FROM stock_opnames WHERE id = p_opname_id;

    IF v_opname_status != 'draft' THEN
        RAISE EXCEPTION 'Opname % sudah dikonfirmasi sebelumnya', p_opname_id;
    END IF;

    FOR v_item IN
        SELECT soi.*, o.opname_date
        FROM stock_opname_items soi
        JOIN stock_opnames o ON o.id = soi.opname_id
        WHERE soi.opname_id = p_opname_id
          AND soi.variance <> 0
    LOOP
        -- Koreksi stok teoritis ke angka fisik yang dihitung
        UPDATE ingredients
        SET current_stock = v_item.actual_qty
        WHERE id = v_item.ingredient_id;

        -- Audit trail: catat setiap koreksi
        INSERT INTO stock_movements (
            restaurant_id, ingredient_id, movement_type,
            qty, cost_per_unit,
            reference_type, reference_id,
            notes, created_by
        ) VALUES (
            v_restaurant_id,
            v_item.ingredient_id,
            'opname_adj',
            v_item.variance,          -- negatif = LOSS, positif = gain
            v_item.cost_per_unit,
            'opname', p_opname_id,
            'Stock opname adjustment',
            p_user_id
        );

        IF v_item.variance < 0 THEN
            v_total_loss := v_total_loss + ABS(v_item.variance_value);
        END IF;
    END LOOP;

    -- Catat total LOSS ke expenses (masuk blok HPP di laporan L/R)
    IF v_total_loss > 0 THEN
        INSERT INTO expenses (
            restaurant_id, amount, category,
            fiscal_period, expense_date,
            description, reference_type, reference_id,
            created_by
        ) VALUES (
            v_restaurant_id,
            v_total_loss,
            'inventory_loss',
            TO_CHAR(CURRENT_DATE, 'YYYY-MM'),
            CURRENT_DATE,
            'Inventory loss dari stock opname '
                || TO_CHAR(CURRENT_DATE, 'DD Mon YYYY'),
            'opname', p_opname_id,
            p_user_id
        );
    END IF;

    -- Kunci opname
    UPDATE stock_opnames
    SET status       = 'confirmed',
        confirmed_by = p_user_id,
        confirmed_at = NOW()
    WHERE id = p_opname_id;
END;
$$ LANGUAGE plpgsql;

-- ─────────────────────────────────────────────────────────────────────────
-- 6.5 confirm_platform_settlement — rekonsiliasi settlement GrabFood/GoFood
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION confirm_platform_settlement(
    p_batch_id  UUID,
    p_user_id   UUID
) RETURNS VOID AS $$
DECLARE
    v_batch delivery_platform_batches%ROWTYPE;
BEGIN
    SELECT * INTO v_batch FROM delivery_platform_batches WHERE id = p_batch_id;

    -- Guard: jangan rekonsiliasi ulang
    IF v_batch.is_reconciled THEN
        RAISE EXCEPTION 'Batch % sudah direkonsiliasi sebelumnya', p_batch_id;
    END IF;

    -- Catat komisi sebagai expense Beban Operasional (bukan HPP)
    INSERT INTO expenses (
        restaurant_id, amount, category,
        reference_platform, reference_type, reference_id,
        fiscal_period, expense_date,
        description, created_by
    ) VALUES (
        v_batch.restaurant_id,
        v_batch.platform_fee,
        'platform_fee',
        v_batch.platform::TEXT,
        'platform_batch',
        v_batch.id,
        TO_CHAR(v_batch.period_end, 'YYYY-MM'),
        v_batch.period_end,
        'Komisi ' || v_batch.platform || ' periode '
            || v_batch.period_start || ' s/d ' || v_batch.period_end
            || ' (net settlement: Rp ' || v_batch.net_settlement || ')',
        p_user_id
    );

    UPDATE delivery_platform_batches
    SET is_reconciled = TRUE,
        reconciled_at = NOW()
    WHERE id = p_batch_id;
END;
$$ LANGUAGE plpgsql;

-- ─────────────────────────────────────────────────────────────────────────
-- 6.6 void_order — batalkan order sebelum/tanpa pembayaran
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION void_order(
    p_order_id  UUID,
    p_reason    TEXT,
    p_user_id   UUID
) RETURNS VOID AS $$
DECLARE
    v_status order_status;
BEGIN
    SELECT status INTO v_status FROM orders WHERE id = p_order_id;

    IF v_status NOT IN ('open', 'completed') THEN
        RAISE EXCEPTION 'Order % tidak bisa di-void (status: %)',
            p_order_id, v_status;
    END IF;

    -- Jika order sudah 'completed' (stok sudah dikurangi):
    -- kembalikan stok Kat. A ke nilai sebelumnya
    IF v_status = 'completed' THEN
        DECLARE
            v_item   RECORD;
            v_recipe RECORD;
        BEGIN
            FOR v_item IN
                SELECT oi.menu_id, oi.qty
                FROM order_items oi
                WHERE oi.order_id = p_order_id
            LOOP
                FOR v_recipe IN
                    SELECT mr.ingredient_id,
                           mr.qty_per_portion / mr.yield_factor * v_item.qty AS qty_to_return,
                           i.avg_cost_per_unit
                    FROM menu_recipes mr
                    JOIN ingredients i ON i.id = mr.ingredient_id
                    WHERE mr.menu_id = v_item.menu_id
                      AND mr.is_active = TRUE
                      AND i.ingredient_category = 'recipe'
                LOOP
                    UPDATE ingredients
                    SET current_stock = current_stock + v_recipe.qty_to_return
                    WHERE id = v_recipe.ingredient_id;

                    INSERT INTO stock_movements (
                        restaurant_id, ingredient_id, movement_type,
                        qty, cost_per_unit, reference_type, reference_id,
                        notes, created_by
                    )
                    SELECT
                        o.restaurant_id, v_recipe.ingredient_id, 'waste',
                        v_recipe.qty_to_return, v_recipe.avg_cost_per_unit,
                        'void', p_order_id,
                        'Stok dikembalikan karena void order: ' || p_reason,
                        p_user_id
                    FROM orders o WHERE o.id = p_order_id;
                END LOOP;
            END LOOP;
        END;
    END IF;

    UPDATE orders
    SET status = 'void',
        notes  = COALESCE(notes || ' | ', '') || 'VOID: ' || p_reason
    WHERE id = p_order_id;
END;
$$ LANGUAGE plpgsql;

-- ─────────────────────────────────────────────────────────────────────────
-- 6.7 refund_order — refund setelah pembayaran dikonfirmasi
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION refund_order(
    p_order_id      UUID,
    p_payment_id    UUID,
    p_refund_amount NUMERIC,
    p_reason        TEXT,
    p_user_id       UUID
) RETURNS VOID AS $$
DECLARE
    v_restaurant_id UUID;
    v_item          RECORD;
    v_recipe        RECORD;
BEGIN
    -- Guard: cek payment masih confirmed
    IF (SELECT status FROM payments WHERE id = p_payment_id) != 'confirmed' THEN
        RAISE EXCEPTION 'Payment % tidak dalam status confirmed, tidak bisa direfund',
            p_payment_id;
    END IF;

    SELECT restaurant_id INTO v_restaurant_id FROM orders WHERE id = p_order_id;

    -- Nonaktifkan income
    UPDATE incomes
    SET is_active = FALSE,
        notes = COALESCE(notes || ' | ', '') || 'REFUNDED: ' || p_reason
    WHERE reference_id = p_payment_id
      AND reference_type = 'payment';

    -- Void payment
    UPDATE payments
    SET status     = 'void',
        void_reason = p_reason
    WHERE id = p_payment_id;

    -- Kembalikan stok Kat. A (makanan tidak jadi dikonsumsi)
    FOR v_item IN
        SELECT oi.menu_id, oi.qty
        FROM order_items oi
        WHERE oi.order_id = p_order_id
    LOOP
        FOR v_recipe IN
            SELECT mr.ingredient_id,
                   mr.qty_per_portion / mr.yield_factor * v_item.qty AS qty_to_return,
                   i.avg_cost_per_unit
            FROM menu_recipes mr
            JOIN ingredients i ON i.id = mr.ingredient_id
            WHERE mr.menu_id = v_item.menu_id
              AND mr.is_active = TRUE
              AND i.ingredient_category = 'recipe'
        LOOP
            UPDATE ingredients
            SET current_stock = current_stock + v_recipe.qty_to_return
            WHERE id = v_recipe.ingredient_id;

            INSERT INTO stock_movements (
                restaurant_id, ingredient_id, movement_type,
                qty, cost_per_unit, reference_type, reference_id,
                notes, created_by
            ) VALUES (
                v_restaurant_id, v_recipe.ingredient_id, 'sale',
                +v_recipe.qty_to_return,
                v_recipe.avg_cost_per_unit,
                'refund', p_order_id,
                'Stok dikembalikan karena refund',
                p_user_id
            );
        END LOOP;
    END LOOP;

    -- Catat expense refund (Beban Operasional — bukan HPP)
    INSERT INTO expenses (
        restaurant_id, amount, category,
        fiscal_period, expense_date,
        description, reference_type, reference_id,
        created_by
    ) VALUES (
        v_restaurant_id, p_refund_amount, 'refund',
        TO_CHAR(NOW(), 'YYYY-MM'), CURRENT_DATE,
        'Refund order '
            || (SELECT order_number FROM orders WHERE id = p_order_id)
            || ' — ' || p_reason,
        'order', p_order_id,
        p_user_id
    );

    UPDATE orders SET status = 'refunded' WHERE id = p_order_id;
END;
$$ LANGUAGE plpgsql;


-- ═══════════════════════════════════════════════════════════════════════════
-- TAHAP 7 — VIEWS (LAPORAN)
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- 7.1 v_menu_cogs — HPP teoritis per menu (Kat. A + yield factor)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_menu_cogs AS
SELECT
    m.id          AS menu_id,
    m.name        AS menu_name,
    m.category,
    m.selling_price,
    -- ROUND(SUM(...), 0): SUM dulu, ROUND sekali di akhir
    -- Hindari: SUM(ROUND(...)) yang bisa over-count error kecil
    ROUND(
        SUM(
            mr.qty_per_portion
            / mr.yield_factor
            * i.avg_cost_per_unit
        )
    , 0)          AS theoretical_cogs,
    ROUND(
        SUM(mr.qty_per_portion / mr.yield_factor * i.avg_cost_per_unit)
        / NULLIF(m.selling_price, 0) * 100
    , 1)          AS food_cost_pct_recipe_only   -- % ini BELUM termasuk overhead Kat. B
FROM menus m
JOIN menu_recipes mr ON mr.menu_id = m.id
                     AND mr.is_active = TRUE     -- hanya resep aktif
JOIN ingredients i   ON i.id = mr.ingredient_id
WHERE m.is_active = TRUE
  AND i.is_active = TRUE
  AND i.ingredient_category = 'recipe'           -- hanya Kat. A
GROUP BY m.id, m.name, m.category, m.selling_price;

-- ─────────────────────────────────────────────────────────────────────────
-- 7.2 v_monthly_resto_finance — Laporan L/R bulanan lengkap
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_monthly_resto_finance AS
WITH
revenue AS (
    SELECT
        i.fiscal_period,
        i.restaurant_id,
        SUM(i.amount) AS total_revenue,
        SUM(CASE WHEN o.channel = 'dine_in'   THEN i.amount ELSE 0 END) AS revenue_dinein,
        SUM(CASE WHEN o.channel = 'takeaway'  THEN i.amount ELSE 0 END) AS revenue_takeaway,
        SUM(CASE WHEN o.channel IN ('grabfood','gofood','shopeefood')
                                               THEN i.amount ELSE 0 END) AS revenue_delivery
    FROM incomes i
    LEFT JOIN payments p ON p.id = i.reference_id AND i.reference_type = 'payment'
    LEFT JOIN orders   o ON o.id = p.order_id
    WHERE i.is_active = TRUE
    GROUP BY i.fiscal_period, i.restaurant_id
),
cogs_recipe AS (
    SELECT
        TO_CHAR(o.completed_at, 'YYYY-MM') AS fiscal_period,
        o.restaurant_id,
        SUM(oi.theoretical_cogs)            AS total_cogs_recipe
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    WHERE o.status = 'completed'
    GROUP BY TO_CHAR(o.completed_at, 'YYYY-MM'), o.restaurant_id
),
expense_breakdown AS (
    SELECT
        e.fiscal_period,
        e.restaurant_id,
        -- Blok HPP
        SUM(CASE WHEN e.category = 'food_waste'        THEN e.amount ELSE 0 END) AS food_waste,
        SUM(CASE WHEN e.category = 'inventory_loss'    THEN e.amount ELSE 0 END) AS inventory_loss,
        SUM(CASE WHEN e.category = 'kitchen_overhead'  THEN e.amount ELSE 0 END) AS kitchen_overhead,
        -- Beban Operasional
        SUM(CASE WHEN e.category = 'salary'            THEN e.amount ELSE 0 END) AS salary,
        SUM(CASE WHEN e.category = 'utility'           THEN e.amount ELSE 0 END) AS utility,
        SUM(CASE WHEN e.category = 'rent'              THEN e.amount ELSE 0 END) AS rent,
        SUM(CASE WHEN e.category = 'platform_fee'      THEN e.amount ELSE 0 END) AS platform_fee,
        SUM(CASE WHEN e.category = 'maintenance'       THEN e.amount ELSE 0 END) AS maintenance,
        SUM(CASE WHEN e.category = 'marketing'         THEN e.amount ELSE 0 END) AS marketing,
        SUM(CASE WHEN e.category = 'packaging'         THEN e.amount ELSE 0 END) AS packaging,
        SUM(CASE WHEN e.category = 'refund'            THEN e.amount ELSE 0 END) AS total_refund,
        SUM(CASE WHEN e.category = 'other'             THEN e.amount ELSE 0 END) AS other_opex
    FROM expenses e
    WHERE e.is_active = TRUE
    GROUP BY e.fiscal_period, e.restaurant_id
)
SELECT
    r.fiscal_period,
    r.restaurant_id,

    -- Revenue
    r.total_revenue,
    r.revenue_dinein,
    r.revenue_takeaway,
    r.revenue_delivery,

    -- HPP (tiga komponen)
    COALESCE(cr.total_cogs_recipe, 0)               AS cogs_recipe,
    COALESCE(eb.kitchen_overhead, 0)                AS cogs_kitchen_overhead,
    COALESCE(eb.food_waste, 0)
        + COALESCE(eb.inventory_loss, 0)            AS cogs_waste_loss,
    COALESCE(cr.total_cogs_recipe, 0)
        + COALESCE(eb.kitchen_overhead, 0)
        + COALESCE(eb.food_waste, 0)
        + COALESCE(eb.inventory_loss, 0)            AS total_hpp,
    ROUND((
        COALESCE(cr.total_cogs_recipe, 0)
        + COALESCE(eb.kitchen_overhead, 0)
        + COALESCE(eb.food_waste, 0)
        + COALESCE(eb.inventory_loss, 0)
    ) / NULLIF(r.total_revenue, 0) * 100, 1)        AS hpp_pct,

    -- Gross Profit
    r.total_revenue
        - COALESCE(cr.total_cogs_recipe, 0)
        - COALESCE(eb.kitchen_overhead, 0)
        - COALESCE(eb.food_waste, 0)
        - COALESCE(eb.inventory_loss, 0)            AS gross_profit,

    -- Beban Operasional (breakdown)
    COALESCE(eb.salary, 0)                          AS opex_salary,
    COALESCE(eb.utility, 0)                         AS opex_utility,
    COALESCE(eb.rent, 0)                            AS opex_rent,
    COALESCE(eb.platform_fee, 0)                    AS opex_platform_fee,
    COALESCE(eb.maintenance, 0)                     AS opex_maintenance,
    COALESCE(eb.marketing, 0)                       AS opex_marketing,
    COALESCE(eb.packaging, 0)                       AS opex_packaging,
    COALESCE(eb.total_refund, 0)                    AS opex_refund,
    COALESCE(eb.other_opex, 0)                      AS opex_other,
    COALESCE(eb.salary, 0)
        + COALESCE(eb.utility, 0)
        + COALESCE(eb.rent, 0)
        + COALESCE(eb.platform_fee, 0)
        + COALESCE(eb.maintenance, 0)
        + COALESCE(eb.marketing, 0)
        + COALESCE(eb.packaging, 0)
        + COALESCE(eb.total_refund, 0)
        + COALESCE(eb.other_opex, 0)                AS total_opex,

    -- Net Profit
    r.total_revenue
        - COALESCE(cr.total_cogs_recipe, 0)
        - COALESCE(eb.kitchen_overhead, 0)
        - COALESCE(eb.food_waste, 0)
        - COALESCE(eb.inventory_loss, 0)
        - COALESCE(eb.salary, 0)
        - COALESCE(eb.utility, 0)
        - COALESCE(eb.rent, 0)
        - COALESCE(eb.platform_fee, 0)
        - COALESCE(eb.maintenance, 0)
        - COALESCE(eb.marketing, 0)
        - COALESCE(eb.packaging, 0)
        - COALESCE(eb.total_refund, 0)
        - COALESCE(eb.other_opex, 0)                AS net_profit,
    ROUND((
        r.total_revenue
        - COALESCE(cr.total_cogs_recipe, 0)
        - COALESCE(eb.kitchen_overhead, 0)
        - COALESCE(eb.food_waste, 0)
        - COALESCE(eb.inventory_loss, 0)
        - COALESCE(eb.salary, 0)
        - COALESCE(eb.utility, 0)
        - COALESCE(eb.rent, 0)
        - COALESCE(eb.platform_fee, 0)
        - COALESCE(eb.maintenance, 0)
        - COALESCE(eb.marketing, 0)
        - COALESCE(eb.packaging, 0)
        - COALESCE(eb.total_refund, 0)
        - COALESCE(eb.other_opex, 0)
    ) / NULLIF(r.total_revenue, 0) * 100, 1)        AS net_margin_pct

FROM revenue r
LEFT JOIN cogs_recipe      cr ON cr.fiscal_period = r.fiscal_period
                              AND cr.restaurant_id = r.restaurant_id
LEFT JOIN expense_breakdown eb ON eb.fiscal_period = r.fiscal_period
                               AND eb.restaurant_id = r.restaurant_id;

-- ─────────────────────────────────────────────────────────────────────────
-- 7.3 v_menu_performance — revenue + COGS per menu bulan ini
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_menu_performance AS
SELECT
    m.id            AS menu_id,
    m.name          AS menu_name,
    m.category,
    m.selling_price,
    vc.theoretical_cogs         AS cogs_recipe,
    vc.food_cost_pct_recipe_only,
    COUNT(oi.id)                AS qty_sold_this_month,
    COALESCE(SUM(oi.subtotal), 0)                           AS revenue_this_month,
    COALESCE(SUM(oi.theoretical_cogs), 0)                   AS cogs_recipe_this_month,
    COALESCE(SUM(oi.subtotal - COALESCE(oi.theoretical_cogs, 0)), 0) AS margin_before_overhead
FROM menus m
JOIN v_menu_cogs vc ON vc.menu_id = m.id
LEFT JOIN order_items oi ON oi.menu_id = m.id
LEFT JOIN orders o ON o.id = oi.order_id
    AND o.status = 'completed'
    AND TO_CHAR(o.completed_at, 'YYYY-MM') = TO_CHAR(NOW(), 'YYYY-MM')
WHERE m.is_active = TRUE
GROUP BY m.id, m.name, m.category, m.selling_price,
         vc.theoretical_cogs, vc.food_cost_pct_recipe_only;

-- ─────────────────────────────────────────────────────────────────────────
-- 7.4 v_daily_loss — audit waste + opname_adj per hari
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_daily_loss AS
SELECT
    DATE(sm.created_at)    AS loss_date,
    i.name                 AS ingredient_name,
    i.ingredient_category,
    sm.movement_type,
    ABS(sm.qty)            AS qty_lost,
    i.unit,
    sm.cost_per_unit,
    ABS(sm.total_cost)     AS loss_value,
    sm.notes
FROM stock_movements sm
JOIN ingredients i ON i.id = sm.ingredient_id
WHERE sm.movement_type IN ('waste', 'opname_adj')
  AND sm.qty < 0
ORDER BY loss_date DESC, loss_value DESC;

-- ─────────────────────────────────────────────────────────────────────────
-- 7.5 v_low_stock_alert — bahan yang stok mendekati/di bawah reorder_point
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_low_stock_alert AS
SELECT
    i.id            AS ingredient_id,
    i.name,
    i.unit,
    i.current_stock,
    i.reorder_point,
    i.avg_cost_per_unit,
    ROUND(i.current_stock * i.avg_cost_per_unit, 0) AS stock_value,
    CASE
        WHEN i.current_stock <= 0               THEN 'HABIS'
        WHEN i.current_stock < i.reorder_point  THEN 'KRITIS'
        ELSE                                         'RENDAH'
    END AS status_alert
FROM ingredients i
WHERE i.ingredient_category = 'recipe'
  AND i.is_active = TRUE
  AND i.current_stock < i.reorder_point
ORDER BY i.current_stock ASC;


-- ═══════════════════════════════════════════════════════════════════════════
-- TAHAP 8 — SEED DATA
-- Urutan INSERT mengikuti FK dependency
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- 8.1 restaurants
-- ─────────────────────────────────────────────────────────────────────────
INSERT INTO restaurants (id, name, address, phone, is_active) VALUES
(
    'a0000000-0000-0000-0000-000000000001',
    'Warung Makan Pak Budi',
    'Jl. Merdeka No. 5, Jakarta',
    '021-1234567',
    TRUE
);

-- ─────────────────────────────────────────────────────────────────────────
-- 8.2 users (password_hash = bcrypt('password123', cost=12) — ganti di production!)
-- hash dummy: $2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewdBPj0o1J.OP5Bq
-- Ini adalah placeholder — WAJIB diganti saat production setup
-- ─────────────────────────────────────────────────────────────────────────
INSERT INTO users (id, restaurant_id, name, email, password_hash, role) VALUES
(
    'b0000000-0000-0000-0000-000000000001',
    'a0000000-0000-0000-0000-000000000001',
    'Budi Santoso (Owner)',
    'owner@fastresto.id',
    '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewdBPj0o1J.OP5Bq',
    'owner'
),
(
    'b0000000-0000-0000-0000-000000000002',
    'a0000000-0000-0000-0000-000000000001',
    'Siti Rahayu (Kasir)',
    'kasir@fastresto.id',
    '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewdBPj0o1J.OP5Bq',
    'kasir'
),
(
    'b0000000-0000-0000-0000-000000000003',
    'a0000000-0000-0000-0000-000000000001',
    'Ahmad Fauzi (Dapur)',
    'dapur@fastresto.id',
    '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewdBPj0o1J.OP5Bq',
    'dapur'
);

-- ─────────────────────────────────────────────────────────────────────────
-- 8.3 suppliers
-- ─────────────────────────────────────────────────────────────────────────
INSERT INTO suppliers (id, restaurant_id, name, phone, payment_terms) VALUES
(
    'c0000000-0000-0000-0000-000000000001',
    'a0000000-0000-0000-0000-000000000001',
    'Pak Budi (Ayam & Daging)',
    '081234567890',
    'cash'
),
(
    'c0000000-0000-0000-0000-000000000002',
    'a0000000-0000-0000-0000-000000000001',
    'Bu Siti (Sayur & Bumbu)',
    '081234567891',
    'cash'
);

-- ─────────────────────────────────────────────────────────────────────────
-- 8.4 ingredients
-- PENTING: avg_cost_per_unit dan current_stock dalam BASE UNIT
-- Contoh: Ayam → gram, avg_cost=38 (Rp 38/gram = Rp 38.000/kg)
-- ─────────────────────────────────────────────────────────────────────────
INSERT INTO ingredients
    (id, restaurant_id, name, unit, ingredient_category, avg_cost_per_unit, current_stock, reorder_point)
VALUES
-- ── KATEGORI A: Bahan Utama (masuk resep per porsi, stok dipantau) ─────────
-- [01] Protein
(
    'd0000000-0000-0000-0000-000000000001',
    'a0000000-0000-0000-0000-000000000001',
    'Ayam potong', 'gram', 'recipe', 38, 5000, 1000
),
(
    'd0000000-0000-0000-0000-000000000002',
    'a0000000-0000-0000-0000-000000000001',
    'Ikan lele', 'gram', 'recipe', 28, 3000, 500
),
(
    'd0000000-0000-0000-0000-000000000003',
    'a0000000-0000-0000-0000-000000000001',
    'Telur ayam', 'pcs', 'recipe', 2000, 50, 10
),
(
    'd0000000-0000-0000-0000-000000000004',
    'a0000000-0000-0000-0000-000000000001',
    'Tahu putih', 'gram', 'recipe', 5, 2000, 400
),
(
    'd0000000-0000-0000-0000-000000000005',
    'a0000000-0000-0000-0000-000000000001',
    'Tempe', 'gram', 'recipe', 20, 1000, 200
),
-- [06] Karbohidrat
(
    'd0000000-0000-0000-0000-000000000006',
    'a0000000-0000-0000-0000-000000000001',
    'Beras', 'gram', 'recipe', 14, 10000, 2000
),
(
    'd0000000-0000-0000-0000-000000000007',
    'a0000000-0000-0000-0000-000000000001',
    'Mie kuning basah', 'gram', 'recipe', 12, 3000, 500
),
(
    'd0000000-0000-0000-0000-000000000008',
    'a0000000-0000-0000-0000-000000000001',
    'Tepung terigu', 'gram', 'recipe', 10, 2000, 300
),
(
    'd0000000-0000-0000-0000-000000000009',
    'a0000000-0000-0000-0000-000000000001',
    'Tepung beras', 'gram', 'recipe', 12, 1000, 200
),
-- [10] Sayuran
(
    'd0000000-0000-0000-0000-000000000010',
    'a0000000-0000-0000-0000-000000000001',
    'Wortel', 'gram', 'recipe', 8, 1000, 200
),
(
    'd0000000-0000-0000-0000-000000000011',
    'a0000000-0000-0000-0000-000000000001',
    'Kol / kubis', 'gram', 'recipe', 6, 1000, 200
),
(
    'd0000000-0000-0000-0000-000000000012',
    'a0000000-0000-0000-0000-000000000001',
    'Tauge', 'gram', 'recipe', 6, 500, 100
),
-- [13] Minuman
(
    'd0000000-0000-0000-0000-000000000013',
    'a0000000-0000-0000-0000-000000000001',
    'Teh celup', 'gram', 'recipe', 40, 100, 20
),
(
    'd0000000-0000-0000-0000-000000000014',
    'a0000000-0000-0000-0000-000000000001',
    'Gula pasir', 'gram', 'recipe', 16, 2000, 500
),
(
    'd0000000-0000-0000-0000-000000000015',
    'a0000000-0000-0000-0000-000000000001',
    'Jeruk nipis', 'pcs', 'recipe', 800, 30, 10
),

-- ── KATEGORI B: Overhead Dapur (tidak masuk resep, expense bulanan) ────────
(
    'd0000000-0000-0000-0000-000000000016',
    'a0000000-0000-0000-0000-000000000001',
    'Minyak goreng', 'ml', 'overhead', 0.034, 0, 0
),
(
    'd0000000-0000-0000-0000-000000000017',
    'a0000000-0000-0000-0000-000000000001',
    'Bawang merah', 'gram', 'overhead', 0.03, 0, 0
),
(
    'd0000000-0000-0000-0000-000000000018',
    'a0000000-0000-0000-0000-000000000001',
    'Cabai merah', 'gram', 'overhead', 0.04, 0, 0
),
(
    'd0000000-0000-0000-0000-000000000019',
    'a0000000-0000-0000-0000-000000000001',
    'Kecap manis', 'ml', 'overhead', 0.020, 0, 0
),
(
    'd0000000-0000-0000-0000-000000000020',
    'a0000000-0000-0000-0000-000000000001',
    'Gas LPG', 'pcs', 'overhead', 60000, 0, 0
);

-- ─────────────────────────────────────────────────────────────────────────
-- 8.5 menus
-- ─────────────────────────────────────────────────────────────────────────
INSERT INTO menus
    (id, restaurant_id, name, category, description, selling_price, sort_order, is_available)
VALUES
-- Makanan
(
    'e0000000-0000-0000-0000-000000000001',
    'a0000000-0000-0000-0000-000000000001',
    'Nasi Putih', 'makanan',
    'Nasi putih pulen porsi standar',
    5000, 1, TRUE
),
(
    'e0000000-0000-0000-0000-000000000002',
    'a0000000-0000-0000-0000-000000000001',
    'Nasi Goreng Spesial', 'makanan',
    'Nasi goreng dengan ayam suwir, udang, dan telur mata sapi',
    28000, 2, TRUE
),
(
    'e0000000-0000-0000-0000-000000000003',
    'a0000000-0000-0000-0000-000000000001',
    'Ayam Goreng Biasa', 'makanan',
    'Ayam goreng bumbu rempah, garing di luar lembut di dalam',
    22000, 3, TRUE
),
(
    'e0000000-0000-0000-0000-000000000004',
    'a0000000-0000-0000-0000-000000000001',
    'Ayam Goreng Kremes', 'makanan',
    'Ayam goreng dengan kremes tepung renyah, sajian favorit keluarga',
    25000, 4, TRUE
),
(
    'e0000000-0000-0000-0000-000000000005',
    'a0000000-0000-0000-0000-000000000001',
    'Lele Goreng', 'makanan',
    'Ikan lele segar digoreng garing, disajikan dengan lalapan',
    20000, 5, TRUE
),
(
    'e0000000-0000-0000-0000-000000000006',
    'a0000000-0000-0000-0000-000000000001',
    'Mie Goreng', 'makanan',
    'Mie kuning digoreng dengan ayam suwir dan sayuran segar',
    20000, 6, TRUE
),
-- Lauk
(
    'e0000000-0000-0000-0000-000000000007',
    'a0000000-0000-0000-0000-000000000001',
    'Tempe Goreng', 'lauk',
    'Tempe goreng crispy, cocok sebagai pendamping nasi',
    5000, 7, TRUE
),
(
    'e0000000-0000-0000-0000-000000000008',
    'a0000000-0000-0000-0000-000000000001',
    'Tahu Goreng', 'lauk',
    'Tahu putih goreng, lembut di dalam crispy di luar',
    5000, 8, TRUE
),
-- Minuman
(
    'e0000000-0000-0000-0000-000000000009',
    'a0000000-0000-0000-0000-000000000001',
    'Es Teh Manis', 'minuman',
    'Teh manis segar dengan es batu, penyegar dahaga terbaik',
    5000, 9, TRUE
),
(
    'e0000000-0000-0000-0000-000000000010',
    'a0000000-0000-0000-0000-000000000001',
    'Es Jeruk Peras', 'minuman',
    'Perasan jeruk nipis segar dicampur gula, menyegarkan',
    10000, 10, TRUE
);

-- ─────────────────────────────────────────────────────────────────────────
-- 8.6 menu_recipes — resep per menu (qty dalam BASE UNIT)
-- Referensi: simplifikasi-2.md (plate costing)
-- ─────────────────────────────────────────────────────────────────────────
INSERT INTO menu_recipes
    (menu_id, ingredient_id, qty_per_portion, yield_factor, notes)
VALUES
-- Nasi Putih: 100g beras mentah (yield 1.0 — ukur beras, bukan nasi matang)
(
    'e0000000-0000-0000-0000-000000000001',
    'd0000000-0000-0000-0000-000000000006',
    100, 1.0, 'Beras mentah; 1 porsi nasi = 100g beras'
),

-- Nasi Goreng Spesial
(
    'e0000000-0000-0000-0000-000000000002',
    'd0000000-0000-0000-0000-000000000006',
    150, 1.0, 'Beras'
),
(
    'e0000000-0000-0000-0000-000000000002',
    'd0000000-0000-0000-0000-000000000001',
    60, 0.95, 'Ayam fillet suwir'
),
(
    'e0000000-0000-0000-0000-000000000002',
    'd0000000-0000-0000-0000-000000000003',
    1, 1.0, 'Telur ayam (mata sapi)'
),
(
    'e0000000-0000-0000-0000-000000000002',
    'd0000000-0000-0000-0000-000000000010',
    20, 1.0, 'Wortel dadu'
),
(
    'e0000000-0000-0000-0000-000000000002',
    'd0000000-0000-0000-0000-000000000011',
    20, 1.0, 'Kol iris'
),

-- Ayam Goreng Biasa
(
    'e0000000-0000-0000-0000-000000000003',
    'd0000000-0000-0000-0000-000000000001',
    200, 0.90, 'Ayam potong mentah; yield 0.90 setelah trimming'
),
(
    'e0000000-0000-0000-0000-000000000003',
    'd0000000-0000-0000-0000-000000000008',
    15, 1.0, 'Tepung terigu untuk balutan'
),
(
    'e0000000-0000-0000-0000-000000000003',
    'd0000000-0000-0000-0000-000000000003',
    0.25, 1.0, 'Telur (1/4 butir untuk adonan)'
),

-- Ayam Goreng Kremes
(
    'e0000000-0000-0000-0000-000000000004',
    'd0000000-0000-0000-0000-000000000001',
    200, 0.90, 'Ayam potong mentah'
),
(
    'e0000000-0000-0000-0000-000000000004',
    'd0000000-0000-0000-0000-000000000008',
    25, 1.0, 'Tepung terigu untuk kremes'
),
(
    'e0000000-0000-0000-0000-000000000004',
    'd0000000-0000-0000-0000-000000000009',
    15, 1.0, 'Tepung beras untuk kremes renyah'
),
(
    'e0000000-0000-0000-0000-000000000004',
    'd0000000-0000-0000-0000-000000000003',
    0.25, 1.0, 'Telur'
),

-- Lele Goreng
(
    'e0000000-0000-0000-0000-000000000005',
    'd0000000-0000-0000-0000-000000000002',
    250, 0.55, 'Lele utuh; yield 0.55 setelah buang kepala/isi'
),
(
    'e0000000-0000-0000-0000-000000000005',
    'd0000000-0000-0000-0000-000000000008',
    10, 1.0, 'Tepung terigu pelapis'
),

-- Mie Goreng
(
    'e0000000-0000-0000-0000-000000000006',
    'd0000000-0000-0000-0000-000000000007',
    150, 1.0, 'Mie kuning basah'
),
(
    'e0000000-0000-0000-0000-000000000006',
    'd0000000-0000-0000-0000-000000000003',
    1, 1.0, 'Telur'
),
(
    'e0000000-0000-0000-0000-000000000006',
    'd0000000-0000-0000-0000-000000000001',
    40, 0.95, 'Ayam suwir'
),
(
    'e0000000-0000-0000-0000-000000000006',
    'd0000000-0000-0000-0000-000000000011',
    30, 1.0, 'Kol iris'
),
(
    'e0000000-0000-0000-0000-000000000006',
    'd0000000-0000-0000-0000-000000000010',
    20, 1.0, 'Wortel'
),

-- Tempe Goreng
(
    'e0000000-0000-0000-0000-000000000007',
    'd0000000-0000-0000-0000-000000000005',
    60, 1.0, 'Tempe'
),

-- Tahu Goreng
(
    'e0000000-0000-0000-0000-000000000008',
    'd0000000-0000-0000-0000-000000000004',
    80, 1.0, 'Tahu putih'
),

-- Es Teh Manis
(
    'e0000000-0000-0000-0000-000000000009',
    'd0000000-0000-0000-0000-000000000013',
    2, 1.0, 'Teh celup / teh curah (gram)'
),
(
    'e0000000-0000-0000-0000-000000000009',
    'd0000000-0000-0000-0000-000000000014',
    25, 1.0, 'Gula pasir'
),

-- Es Jeruk Peras
(
    'e0000000-0000-0000-0000-000000000010',
    'd0000000-0000-0000-0000-000000000015',
    3, 0.85, 'Jeruk nipis (3 buah, yield 0.85 buang biji/ampas)'
),
(
    'e0000000-0000-0000-0000-000000000010',
    'd0000000-0000-0000-0000-000000000014',
    20, 1.0, 'Gula pasir'
);

-- ─────────────────────────────────────────────────────────────────────────
-- 8.7 unit_conversions — tabel referensi konversi satuan beli vs base unit
-- ─────────────────────────────────────────────────────────────────────────
INSERT INTO unit_conversions (base_unit, purchase_unit, factor, description) VALUES
-- gram-based
('gram', 'gram',         1,       'Beli per gram (jarang)'),
('gram', 'kg',           1000,    'Beli per kilogram — paling umum untuk daging, beras'),
('gram', 'ons',          100,     'Beli per ons (100g)'),
('gram', 'ikat',         250,     'Default: 1 ikat sayur ~250g; konfirmasi ke supplier'),
('gram', 'papan',        200,     '1 papan tempe ~200g'),
('gram', 'biji',         80,      '1 biji tahu ~80g; sesuaikan jika berbeda'),
('gram', 'dus_10kg',     10000,   '1 dus tepung/beras 10kg'),
('gram', 'karung_25kg',  25000,   '1 karung beras 25kg'),
-- ml-based
('ml',   'ml',           1,       'Beli per ml (jarang)'),
('ml',   'liter',        1000,    'Beli per liter — umum untuk santan, susu, sirup'),
('ml',   'botol_600ml',  600,     'Botol sirup, kecap 600ml'),
('ml',   'botol_1L',     1000,    'Botol kecap manis, saus tiram 1L'),
('ml',   'jerigen_5L',   5000,    'Jerigen minyak 5L'),
('ml',   'jerigen_18L',  18000,   'Jerigen minyak 18L'),
-- pcs-based
('pcs',  'pcs',          1,       'Beli satuan — telur per butir, jeruk per buah'),
('pcs',  'lusin',        12,      'Beli per lusin (12 pcs)'),
('pcs',  'kodi',         20,      'Beli per kodi (20 pcs)'),
('pcs',  'kg_telur',     14,      'Estimasi: 1 kg telur ≈ 14 butir; konfirmasi aktual'),
-- portion-based
('portion', 'portion',   1,       'Sudah dalam satuan porsi');

-- ─────────────────────────────────────────────────────────────────────────
-- 8.8 tables — meja fisik (qr_token di-generate otomatis oleh DB)
-- ─────────────────────────────────────────────────────────────────────────
INSERT INTO tables (restaurant_id, table_number, capacity) VALUES
('a0000000-0000-0000-0000-000000000001', '1',   4),
('a0000000-0000-0000-0000-000000000001', '2',   4),
('a0000000-0000-0000-0000-000000000001', '3',   6),
('a0000000-0000-0000-0000-000000000001', '4',   2),
('a0000000-0000-0000-0000-000000000001', '5',   8);

-- ─────────────────────────────────────────────────────────────────────────
-- 8.9 cms_site_settings — default keys (value kosong, owner isi via UI)
-- ─────────────────────────────────────────────────────────────────────────
INSERT INTO cms_site_settings (restaurant_id, key, value) VALUES
('a0000000-0000-0000-0000-000000000001', 'restaurant_name',  'Warung Makan Pak Budi'),
('a0000000-0000-0000-0000-000000000001', 'tagline',          'Enak, Cepat, Terjangkau'),
('a0000000-0000-0000-0000-000000000001', 'hero_title',       'Nikmatnya Masakan Rumahan'),
('a0000000-0000-0000-0000-000000000001', 'hero_subtitle',    'Pesan dari meja, makanan langsung datang!'),
('a0000000-0000-0000-0000-000000000001', 'address',          'Jl. Merdeka No. 5, Jakarta'),
('a0000000-0000-0000-0000-000000000001', 'opening_hours',    '08.00 – 21.00 WIB'),
('a0000000-0000-0000-0000-000000000001', 'whatsapp_number',  ''),
('a0000000-0000-0000-0000-000000000001', 'instagram_url',    ''),
('a0000000-0000-0000-0000-000000000001', 'maps_embed_url',   ''),
('a0000000-0000-0000-0000-000000000001', 'footer_text',      '© 2026 Warung Makan Pak Budi. Seluruh hak cipta dilindungi.');

-- ─────────────────────────────────────────────────────────────────────────
-- 8.10 wa_message_templates — template bawaan notifikasi WA
-- ─────────────────────────────────────────────────────────────────────────
INSERT INTO wa_message_templates (code, title, body) VALUES
(
    'ORDER_RECEIPT',
    'Struk Pesanan',
    E'Halo {{customer_name}}! 👋\n\nTerima kasih sudah makan di {{restaurant_name}}.\n\nStruk Pesanan #{{order_number}}\nMeja: {{table_number}} | {{datetime}}\n\n{{items_list}}\n─────────────────\nTotal: {{total}}\nBayar: {{payment_method}}\n\nSelamat menikmati! 🍽️'
),
(
    'ORDER_CONFIRM',
    'Konfirmasi Pesanan Diterima',
    E'Halo {{customer_name}}! 👋\n\nPesanan kamu dari Meja {{table_number}} sudah kami terima.\n\n📋 #{{order_number}}\n{{items_list}}\n\nKasir kami sedang memprosesnya. Mohon tunggu sebentar ya! 🙏\n\n— Tim {{restaurant_name}}'
);

-- ─────────────────────────────────────────────────────────────────────────
-- 8.11 stock_movements — opening stock Kat. A (audit trail stok awal)
-- JANGAN langsung UPDATE ingredients.current_stock
-- Stok awal harus masuk via stock_movements type='opening'
-- ─────────────────────────────────────────────────────────────────────────
INSERT INTO stock_movements
    (restaurant_id, ingredient_id, movement_type, qty, cost_per_unit,
     reference_type, notes, created_by)
VALUES
-- [01] Ayam potong — 5000g opening
(
    'a0000000-0000-0000-0000-000000000001',
    'd0000000-0000-0000-0000-000000000001',
    'opening', 5000, 38,
    'opening', 'Stok awal sistem', 'b0000000-0000-0000-0000-000000000001'
),
-- [02] Ikan lele — 3000g opening
(
    'a0000000-0000-0000-0000-000000000001',
    'd0000000-0000-0000-0000-000000000002',
    'opening', 3000, 28,
    'opening', 'Stok awal sistem', 'b0000000-0000-0000-0000-000000000001'
),
-- [03] Telur ayam — 50 pcs opening
(
    'a0000000-0000-0000-0000-000000000001',
    'd0000000-0000-0000-0000-000000000003',
    'opening', 50, 2000,
    'opening', 'Stok awal sistem', 'b0000000-0000-0000-0000-000000000001'
),
-- [04] Tahu putih — 2000g opening
(
    'a0000000-0000-0000-0000-000000000001',
    'd0000000-0000-0000-0000-000000000004',
    'opening', 2000, 5,
    'opening', 'Stok awal sistem', 'b0000000-0000-0000-0000-000000000001'
),
-- [05] Tempe — 1000g opening
(
    'a0000000-0000-0000-0000-000000000001',
    'd0000000-0000-0000-0000-000000000005',
    'opening', 1000, 20,
    'opening', 'Stok awal sistem', 'b0000000-0000-0000-0000-000000000001'
),
-- [06] Beras — 10000g opening
(
    'a0000000-0000-0000-0000-000000000001',
    'd0000000-0000-0000-0000-000000000006',
    'opening', 10000, 14,
    'opening', 'Stok awal sistem', 'b0000000-0000-0000-0000-000000000001'
),
-- [07] Mie kuning basah — 3000g opening
(
    'a0000000-0000-0000-0000-000000000001',
    'd0000000-0000-0000-0000-000000000007',
    'opening', 3000, 12,
    'opening', 'Stok awal sistem', 'b0000000-0000-0000-0000-000000000001'
),
-- [08] Tepung terigu — 2000g opening
(
    'a0000000-0000-0000-0000-000000000001',
    'd0000000-0000-0000-0000-000000000008',
    'opening', 2000, 10,
    'opening', 'Stok awal sistem', 'b0000000-0000-0000-0000-000000000001'
),
-- [09] Tepung beras — 1000g opening
(
    'a0000000-0000-0000-0000-000000000001',
    'd0000000-0000-0000-0000-000000000009',
    'opening', 1000, 12,
    'opening', 'Stok awal sistem', 'b0000000-0000-0000-0000-000000000001'
),
-- [10] Wortel — 1000g opening
(
    'a0000000-0000-0000-0000-000000000001',
    'd0000000-0000-0000-0000-000000000010',
    'opening', 1000, 8,
    'opening', 'Stok awal sistem', 'b0000000-0000-0000-0000-000000000001'
),
-- [11] Kol / kubis — 1000g opening
(
    'a0000000-0000-0000-0000-000000000001',
    'd0000000-0000-0000-0000-000000000011',
    'opening', 1000, 6,
    'opening', 'Stok awal sistem', 'b0000000-0000-0000-0000-000000000001'
),
-- [12] Tauge — 500g opening
(
    'a0000000-0000-0000-0000-000000000001',
    'd0000000-0000-0000-0000-000000000012',
    'opening', 500, 6,
    'opening', 'Stok awal sistem', 'b0000000-0000-0000-0000-000000000001'
),
-- [13] Teh celup — 100g opening
(
    'a0000000-0000-0000-0000-000000000001',
    'd0000000-0000-0000-0000-000000000013',
    'opening', 100, 40,
    'opening', 'Stok awal sistem', 'b0000000-0000-0000-0000-000000000001'
),
-- [14] Gula pasir — 2000g opening
(
    'a0000000-0000-0000-0000-000000000001',
    'd0000000-0000-0000-0000-000000000014',
    'opening', 2000, 16,
    'opening', 'Stok awal sistem', 'b0000000-0000-0000-0000-000000000001'
),
-- [15] Jeruk nipis — 30 pcs opening
(
    'a0000000-0000-0000-0000-000000000001',
    'd0000000-0000-0000-0000-000000000015',
    'opening', 30, 800,
    'opening', 'Stok awal sistem', 'b0000000-0000-0000-0000-000000000001'
);

-- ═══════════════════════════════════════════════════════════════════════════
-- SELESAI
-- ═══════════════════════════════════════════════════════════════════════════
-- Verifikasi setelah dijalankan:
--   SELECT COUNT(*) FROM ingredients;        -- harus 20
--   SELECT COUNT(*) FROM menus;              -- harus 10
--   SELECT COUNT(*) FROM menu_recipes;       -- harus 25
--   SELECT COUNT(*) FROM unit_conversions;   -- harus 19
--   SELECT COUNT(*) FROM tables;             -- harus 5
--   SELECT COUNT(*) FROM cms_site_settings;  -- harus 10
--   SELECT COUNT(*) FROM wa_message_templates; -- harus 2
--   SELECT COUNT(*) FROM stock_movements;    -- harus 15 (opening)
--
-- Cek HPP menu:
--   SELECT menu_name, theoretical_cogs, food_cost_pct_recipe_only FROM v_menu_cogs;
--
-- Cek QR tokens meja:
--   SELECT table_number, qr_token FROM tables ORDER BY table_number;
-- ═══════════════════════════════════════════════════════════════════════════
