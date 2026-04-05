# 📘 Arsitektur Keuangan Restoran — Satu Cabang, SDM Minimal

> **Proyek referensi:** Fast-Resto (Restoran Satu Cabang)
> **Stack:** PostgreSQL, Python/FastAPI, pytest
> **Tanggal:** April 2026

---

## Filosofi Utama: Jangan Timbang Setiap Sendok

Restoran kecil dengan SDM minimal punya satu ketakutan terbesar saat mendengar kata
"inventory": bayangan seseorang di dapur yang timbang tiap gram bumbu sebelum masak.

**Itu bukan cara kerjanya.**

Best practice industri F&B — dari warung berkembang sampai chain 50 cabang — semua
menggunakan prinsip yang sama:

> **Jual dulu, hitung konsumsi teoritis berdasarkan yang terjual,
> lalu bandingkan dengan stok fisik. Selisihnya = LOSS.**

Ini disebut **Theoretical vs Actual Food Cost Model**. Dapur tidak perlu input
apa-apa saat memasak. Sistem menghitung sendiri "seharusnya habis berapa" dari
data penjualan. Yang perlu dilakukan manusia hanyalah:

1. Input pembelian bahan (sekali per kedatangan supplier)
2. Input stock opname (hitung fisik — sekali sehari, pagi atau malam)
3. Input waste manual kalau ada bahan yang sengaja dibuang

Tiga input itu menghasilkan semua laporan yang kamu butuhkan: **HPP, food cost %,
LOSS per bahan, dan L/R bulanan**.

---

## Peta Konsep: Empat Aliran Data

```
[1] PEMBELIAN BAHAN         [2] PENJUALAN MENU
    ↓                           ↓
    Stok bertambah          Stok berkurang (teoritis, dari resep)
              ↘              ↙
            STOK TEORITIS SISA
                    |
                    | dibandingkan dengan
                    ↓
         [3] STOCK OPNAME (fisik)
                    |
                    ↓
             SELISIH = LOSS
                    |
                    ↓
         [4] LAPORAN L/R
              Revenue - HPP - OpEx - Loss = Net Profit
```

Dari empat aliran ini, hanya (1) pembelian dan (3) stock opname yang butuh input
manusia. Sisanya **otomatis dihitung oleh sistem**.

---

## Bagian 1 — Struktur Database

### 1.1 Master Bahan Baku

```sql
CREATE TYPE ingredient_unit AS ENUM (
    'gram', 'ml', 'pcs', 'portion'
);

CREATE TABLE ingredients (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    name            VARCHAR(100) NOT NULL,
    unit            ingredient_unit NOT NULL,
    -- Harga rata-rata bergerak (weighted average cost)
    -- Diupdate otomatis setiap ada pembelian baru
    avg_cost_per_unit NUMERIC(12,4) NOT NULL DEFAULT 0,
    -- Stok teoritis saat ini (diupdate otomatis oleh sistem)
    current_stock   NUMERIC(12,3) NOT NULL DEFAULT 0,
    -- Stok minimum — untuk alert reorder
    reorder_point   NUMERIC(12,3) DEFAULT 0,
    is_active       BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (restaurant_id, name)
);
```

**Key decision:** `current_stock` di sini adalah **stok teoritis** — dihitung
dari: pembelian - konsumsi teoritis (dari penjualan) - waste yang diinput manual.
Bukan stok fisik. Stok fisik hanya diketahui saat stock opname.

---

### 1.2 Resep Menu (BOM — Bill of Materials)

```sql
CREATE TABLE menus (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    name            VARCHAR(100) NOT NULL,
    category        VARCHAR(50),          -- 'makanan', 'minuman', 'snack'
    selling_price   NUMERIC(12,2) NOT NULL,
    is_available    BOOLEAN DEFAULT TRUE,
    is_active       BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Resep: satu menu → banyak bahan
CREATE TABLE menu_recipes (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    menu_id         UUID NOT NULL REFERENCES menus(id),
    ingredient_id   UUID NOT NULL REFERENCES ingredients(id),
    -- Qty yang dipakai PER SATU PORSI menu ini
    qty_per_portion NUMERIC(10,4) NOT NULL,
    -- yield_factor: konversi bahan mentah ke siap pakai
    -- Contoh: 1000g daging mentah = 750g setelah dipotong/rebus → yield 0.75
    -- Untuk bahan yang tidak ada penyusutan: yield = 1.0
    yield_factor    NUMERIC(5,4) NOT NULL DEFAULT 1.0,
    notes           TEXT,
    UNIQUE (menu_id, ingredient_id)
);

-- View: HPP teoritis per menu (dihitung real-time dari harga bahan terkini)
CREATE OR REPLACE VIEW v_menu_cogs AS
SELECT
    m.id          AS menu_id,
    m.name        AS menu_name,
    m.selling_price,
    SUM(
        mr.qty_per_portion
        / mr.yield_factor
        * i.avg_cost_per_unit
    )             AS theoretical_cogs,
    ROUND(
        SUM(mr.qty_per_portion / mr.yield_factor * i.avg_cost_per_unit)
        / NULLIF(m.selling_price, 0) * 100
    , 1)          AS food_cost_pct
FROM menus m
JOIN menu_recipes mr ON mr.menu_id = m.id
JOIN ingredients i   ON i.id = mr.ingredient_id
WHERE m.is_active = TRUE
GROUP BY m.id, m.name, m.selling_price;
```

**Tentang `yield_factor`:**

Ini konsep penting yang sering diabaikan restoran kecil. Jika kamu beli ayam
1000g, setelah dipotong (buang tulang, kulit, lemak berlebih) mungkin hanya
tersisa 750g daging bersih yang bisa dimasak. Maka yield = 0.75. Dengan mencatat
yield di resep, HPP-mu langsung akurat tanpa perlu hitung manual.

---

### 1.3 Pergerakan Stok (Stock Movements)

Semua perubahan stok — apapun penyebabnya — masuk ke satu tabel ini.
Ini adalah **audit trail lengkap** pergerakan inventori.

```sql
CREATE TYPE movement_type AS ENUM (
    'purchase',       -- beli dari supplier
    'sale',           -- terjual (dihitung dari resep × qty order)
    'waste',          -- dibuang: expired, jatuh, salah masak
    'opname_adj',     -- koreksi dari stock opname fisik
    'return_to_supplier', -- retur ke supplier
    'transfer_in',    -- penerimaan dari gudang/cabang lain (future)
    'opening'         -- stok awal saat sistem pertama dijalankan
);

CREATE TABLE stock_movements (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    ingredient_id   UUID NOT NULL REFERENCES ingredients(id),
    movement_type   movement_type NOT NULL,
    -- Positif = masuk, Negatif = keluar
    qty             NUMERIC(12,3) NOT NULL,
    -- Harga per unit SAAT transaksi ini terjadi (bukan avg_cost terkini)
    cost_per_unit   NUMERIC(12,4) NOT NULL DEFAULT 0,
    total_cost      NUMERIC(14,2) GENERATED ALWAYS AS (qty * cost_per_unit) STORED,
    -- Reference ke sumber transaksi
    reference_type  VARCHAR(30),   -- 'order', 'purchase', 'opname', 'waste_log'
    reference_id    UUID,
    notes           TEXT,
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_stock_mov_ingredient ON stock_movements(ingredient_id, created_at DESC);
CREATE INDEX idx_stock_mov_restaurant ON stock_movements(restaurant_id, movement_type, created_at DESC);
```

---

### 1.4 Pembelian Bahan dari Supplier

```sql
CREATE TABLE suppliers (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    name            VARCHAR(100) NOT NULL,
    phone           VARCHAR(20),
    payment_terms   VARCHAR(50) DEFAULT 'cash', -- 'cash', 'net7', 'net30'
    is_active       BOOLEAN DEFAULT TRUE
);

CREATE TYPE purchase_status AS ENUM (
    'draft',        -- baru diinput, belum final
    'received',     -- barang sudah diterima, stok sudah bertambah
    'paid',         -- sudah dibayar lunas
    'partial',      -- dibayar sebagian (hutang ke supplier)
    'cancelled'
);

CREATE TABLE purchases (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    supplier_id     UUID REFERENCES suppliers(id),
    purchase_date   DATE NOT NULL DEFAULT CURRENT_DATE,
    invoice_number  VARCHAR(50),         -- nomor faktur supplier (opsional)
    status          purchase_status NOT NULL DEFAULT 'draft',
    subtotal        NUMERIC(14,2) NOT NULL DEFAULT 0,
    paid_amount     NUMERIC(14,2) NOT NULL DEFAULT 0,
    -- Hutang ke supplier = subtotal - paid_amount
    notes           TEXT,
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE purchase_items (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    purchase_id     UUID NOT NULL REFERENCES purchases(id),
    ingredient_id   UUID NOT NULL REFERENCES ingredients(id),
    qty             NUMERIC(12,3) NOT NULL,
    unit_price      NUMERIC(12,4) NOT NULL,
    subtotal        NUMERIC(14,2) GENERATED ALWAYS AS (qty * unit_price) STORED
);
```

**DB Function: Konfirmasi Pembelian**

Saat status purchase diubah ke `received`, function ini berjalan:
1. Tambah `current_stock` di tabel `ingredients`
2. Update `avg_cost_per_unit` menggunakan weighted average
3. Insert record di `stock_movements` per item

```sql
CREATE OR REPLACE FUNCTION confirm_purchase(
    p_purchase_id   UUID,
    p_confirmed_by  UUID
) RETURNS VOID AS $$
DECLARE
    v_item          RECORD;
    v_new_avg_cost  NUMERIC;
    v_old_stock     NUMERIC;
    v_old_cost      NUMERIC;
BEGIN
    -- Loop setiap item pembelian
    FOR v_item IN
        SELECT pi.*, i.current_stock, i.avg_cost_per_unit
        FROM purchase_items pi
        JOIN ingredients i ON i.id = pi.ingredient_id
        WHERE pi.purchase_id = p_purchase_id
    LOOP
        v_old_stock := v_item.current_stock;
        v_old_cost  := v_item.avg_cost_per_unit;

        -- Weighted Average Cost formula:
        -- new_avg = (old_stock × old_cost + new_qty × new_price) / (old_stock + new_qty)
        v_new_avg_cost := (
            (v_old_stock * v_old_cost) + (v_item.qty * v_item.unit_price)
        ) / NULLIF(v_old_stock + v_item.qty, 0);

        -- Update stok dan harga rata-rata
        UPDATE ingredients
        SET current_stock     = current_stock + v_item.qty,
            avg_cost_per_unit = v_new_avg_cost
        WHERE id = v_item.ingredient_id;

        -- Catat di audit trail
        INSERT INTO stock_movements (
            restaurant_id, ingredient_id, movement_type,
            qty, cost_per_unit,
            reference_type, reference_id,
            created_by
        ) VALUES (
            (SELECT restaurant_id FROM purchases WHERE id = p_purchase_id),
            v_item.ingredient_id, 'purchase',
            v_item.qty, v_item.unit_price,
            'purchase', p_purchase_id,
            p_confirmed_by
        );
    END LOOP;

    -- Update status purchase
    UPDATE purchases
    SET status = 'received'
    WHERE id = p_purchase_id;
END;
$$ LANGUAGE plpgsql;
```

---

### 1.5 Order Penjualan (POS)

```sql
CREATE TYPE order_channel AS ENUM (
    'dine_in',      -- makan di tempat
    'takeaway',     -- bawa pulang
    'grabfood',     -- via GrabFood
    'gofood',       -- via GoFood
    'shopeefood'    -- via ShopeeFood
);

CREATE TYPE order_status AS ENUM (
    'open',         -- pesanan sedang berjalan
    'completed',    -- selesai dan sudah dibayar
    'void',         -- dibatalkan sebelum pembayaran
    'refunded'      -- sudah dibayar, lalu di-refund
);

CREATE TABLE orders (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    order_number    VARCHAR(20) NOT NULL UNIQUE,  -- ORD-20260405-001
    channel         order_channel NOT NULL DEFAULT 'dine_in',
    -- Untuk delivery: nomor order dari platform
    platform_order_id VARCHAR(50),
    table_number    VARCHAR(10),
    status          order_status NOT NULL DEFAULT 'open',
    -- Harga jual total (bruto)
    subtotal        NUMERIC(14,2) NOT NULL DEFAULT 0,
    discount        NUMERIC(14,2) NOT NULL DEFAULT 0,
    total           NUMERIC(14,2) NOT NULL DEFAULT 0,
    -- Shift kasir saat order ini selesai
    shift_id        UUID REFERENCES kasir_shifts(id),
    notes           TEXT,
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    completed_at    TIMESTAMPTZ
);

CREATE TABLE order_items (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id        UUID NOT NULL REFERENCES orders(id),
    menu_id         UUID NOT NULL REFERENCES menus(id),
    menu_name       VARCHAR(100) NOT NULL,  -- snapshot nama saat transaksi
    unit_price      NUMERIC(12,2) NOT NULL, -- snapshot harga saat transaksi
    qty             INTEGER NOT NULL CHECK (qty > 0),
    subtotal        NUMERIC(14,2) GENERATED ALWAYS AS (unit_price * qty) STORED,
    -- Theoretical COGS saat transaksi (snapshot, bukan dari view)
    theoretical_cogs NUMERIC(14,2),
    notes           TEXT  -- catatan dapur: "pedas", "tanpa bawang", dll
);
```

---

### 1.6 Depresi Stok Otomatis Saat Order Selesai

Ini adalah jantung dari model Theoretical Consumption.
Saat kasir klik "Complete Order", function ini berjalan:

```sql
CREATE OR REPLACE FUNCTION complete_order(
    p_order_id  UUID,
    p_user_id   UUID
) RETURNS VOID AS $$
DECLARE
    v_item          RECORD;
    v_recipe        RECORD;
    v_cogs_total    NUMERIC := 0;
    v_item_cogs     NUMERIC;
    v_restaurant_id UUID;
BEGIN
    SELECT restaurant_id INTO v_restaurant_id
    FROM orders WHERE id = p_order_id;

    -- Loop setiap item order
    FOR v_item IN
        SELECT oi.*, oi.qty
        FROM order_items oi
        WHERE oi.order_id = p_order_id
    LOOP
        v_item_cogs := 0;

        -- Loop setiap bahan di resep menu ini
        FOR v_recipe IN
            SELECT mr.ingredient_id,
                   mr.qty_per_portion / mr.yield_factor AS qty_needed,
                   i.avg_cost_per_unit
            FROM menu_recipes mr
            JOIN ingredients i ON i.id = mr.ingredient_id
            WHERE mr.menu_id = v_item.menu_id
        LOOP
            -- Total bahan yang dikonsumsi untuk item ini
            -- = qty resep × qty order
            DECLARE
                v_total_qty NUMERIC := v_recipe.qty_needed * v_item.qty;
            BEGIN
                -- Kurangi stok teoritis
                UPDATE ingredients
                SET current_stock = current_stock - v_total_qty
                WHERE id = v_recipe.ingredient_id;

                -- Catat di audit trail
                INSERT INTO stock_movements (
                    restaurant_id, ingredient_id, movement_type,
                    qty, cost_per_unit,
                    reference_type, reference_id,
                    created_by
                ) VALUES (
                    v_restaurant_id,
                    v_recipe.ingredient_id, 'sale',
                    -v_total_qty,  -- negatif = keluar
                    v_recipe.avg_cost_per_unit,
                    'order', p_order_id,
                    p_user_id
                );

                -- Akumulasi COGS item ini
                v_item_cogs := v_item_cogs
                    + (v_total_qty * v_recipe.avg_cost_per_unit);
            END;
        END LOOP;

        -- Update theoretical_cogs di order_item (snapshot)
        UPDATE order_items
        SET theoretical_cogs = v_item_cogs
        WHERE id = v_item.id;

        v_cogs_total := v_cogs_total + v_item_cogs;
    END LOOP;

    -- Tandai order selesai
    UPDATE orders
    SET status       = 'completed',
        completed_at = NOW()
    WHERE id = p_order_id;
END;
$$ LANGUAGE plpgsql;
```

---

## Bagian 2 — Stock Opname & Deteksi LOSS

### 2.1 Mengapa Stock Opname Adalah Inti Segalanya

Setelah sistem berjalan satu hari penuh, situasinya seperti ini:

```
Stok Teoritis Ayam (dari sistem):
  Stok pagi  = 5000g
  Pembelian  = +2000g
  Terjual    = -3200g  (dari 16 porsi Ayam Goreng × 200g)
  Teoritis   = 3800g   ← sistem pikir stok segini

Stock Opname malam:
  Fisik      = 3400g   ← kasir/dapur hitung langsung

Selisih      = 400g    ← ini LOSS
```

400g senilai 400 × Rp 35/g = **Rp 14.000 loss** dari ayam saja,
dalam satu hari. Kalau tidak dideteksi, ini terakumulasi diam-diam.

**Sumber LOSS** yang umum di restoran kecil:
- Over-portioning (dapur kasih lebih dari resep)
- Trial masak / menu baru gagal
- Makanan jatuh / rusak saat masak
- Bahan tidak diinput waste-nya
- Pencurian (jarang, tapi ada)
- Resep tidak akurat (yield factor salah di awal)

### 2.2 Tabel Stock Opname

```sql
CREATE TYPE opname_status AS ENUM (
    'draft',        -- sedang diinput
    'confirmed'     -- dikunci, koreksi sudah diterapkan
);

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
    -- Satu opname per hari
    UNIQUE (restaurant_id, opname_date)
);

CREATE TABLE stock_opname_items (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    opname_id       UUID NOT NULL REFERENCES stock_opnames(id),
    ingredient_id   UUID NOT NULL REFERENCES ingredients(id),
    -- Stok teoritis saat opname dilakukan (diambil dari sistem)
    theoretical_qty NUMERIC(12,3) NOT NULL,
    -- Stok fisik yang dihitung manusia
    actual_qty      NUMERIC(12,3) NOT NULL,
    -- Selisih: negatif = LOSS, positif = gain (jarang, biasanya salah input)
    variance        NUMERIC(12,3) GENERATED ALWAYS AS (actual_qty - theoretical_qty) STORED,
    -- Nilai rupiah dari variance (cost per unit saat opname)
    cost_per_unit   NUMERIC(12,4) NOT NULL,
    variance_value  NUMERIC(14,2) GENERATED ALWAYS AS
                        ((actual_qty - theoretical_qty) * cost_per_unit) STORED,
    UNIQUE (opname_id, ingredient_id)
);
```

### 2.3 Konfirmasi Opname: Koreksi Stok Otomatis

```sql
CREATE OR REPLACE FUNCTION confirm_opname(
    p_opname_id UUID,
    p_user_id   UUID
) RETURNS VOID AS $$
DECLARE
    v_item          RECORD;
    v_restaurant_id UUID;
    v_total_loss    NUMERIC := 0;
    v_total_gain    NUMERIC := 0;
BEGIN
    SELECT restaurant_id INTO v_restaurant_id
    FROM stock_opnames WHERE id = p_opname_id;

    FOR v_item IN
        SELECT soi.*, o.opname_date
        FROM stock_opname_items soi
        JOIN stock_opnames o ON o.id = soi.opname_id
        WHERE soi.opname_id = p_opname_id
          AND soi.variance <> 0  -- hanya yang ada selisih
    LOOP
        -- Update stok teoritis ke angka fisik
        UPDATE ingredients
        SET current_stock = v_item.actual_qty
        WHERE id = v_item.ingredient_id;

        -- Catat koreksi di audit trail
        INSERT INTO stock_movements (
            restaurant_id, ingredient_id, movement_type,
            qty, cost_per_unit,
            reference_type, reference_id,
            notes, created_by
        ) VALUES (
            v_restaurant_id,
            v_item.ingredient_id, 'opname_adj',
            v_item.variance,          -- positif atau negatif
            v_item.cost_per_unit,
            'opname', p_opname_id,
            'Stock opname adjustment',
            p_user_id
        );

        -- Akumulasi nilai
        IF v_item.variance < 0 THEN
            v_total_loss := v_total_loss + ABS(v_item.variance_value);
        ELSE
            v_total_gain := v_total_gain + v_item.variance_value;
        END IF;
    END LOOP;

    -- Catat total LOSS ke expenses (jika ada)
    IF v_total_loss > 0 THEN
        INSERT INTO expenses (
            restaurant_id, amount, category,
            fiscal_period, expense_date,
            description, reference_type, reference_id,
            created_by
        ) VALUES (
            v_restaurant_id,
            v_total_loss,
            'inventory_loss',  -- kategori khusus untuk LOSS
            TO_CHAR(CURRENT_DATE, 'YYYY-MM'),
            CURRENT_DATE,
            'Inventory loss dari stock opname ' || TO_CHAR(CURRENT_DATE, 'DD Mon YYYY'),
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
```

---

## Bagian 3 — Kasir Multi-Channel

### 3.1 Shift Kasir

```sql
CREATE TYPE shift_status AS ENUM ('open', 'closed');

CREATE TABLE kasir_shifts (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    cashier_id      UUID NOT NULL REFERENCES users(id),
    shift_date      DATE NOT NULL DEFAULT CURRENT_DATE,
    opened_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at       TIMESTAMPTZ,
    status          shift_status NOT NULL DEFAULT 'open',
    -- Uang tunai awal di laci
    opening_cash    NUMERIC(14,2) NOT NULL DEFAULT 0,
    -- Dihitung sistem dari transaksi cash selama shift
    expected_cash   NUMERIC(14,2),
    -- Dihitung fisik saat tutup shift
    actual_cash     NUMERIC(14,2),
    -- Selisih: positif = lebih, negatif = kurang
    cash_variance   NUMERIC(14,2) GENERATED ALWAYS AS
                        (actual_cash - expected_cash) STORED,
    notes           TEXT
);
```

### 3.2 Pembayaran & Settlement

```sql
CREATE TYPE payment_method AS ENUM (
    'cash', 'qris', 'transfer', 'grabfood_settlement', 'gofood_settlement'
);

CREATE TYPE payment_status AS ENUM ('pending', 'confirmed', 'void');

CREATE TABLE payments (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id        UUID NOT NULL REFERENCES orders(id),
    amount          NUMERIC(14,2) NOT NULL,
    method          payment_method NOT NULL,
    status          payment_status NOT NULL DEFAULT 'pending',
    -- Untuk QRIS: nomor referensi dari payment gateway
    reference_number VARCHAR(100),
    shift_id        UUID REFERENCES kasir_shifts(id),
    confirmed_by    UUID REFERENCES users(id),
    confirmed_at    TIMESTAMPTZ,
    void_reason     TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);
```

### 3.3 GrabFood / GoFood: Gross Dicatat, Komisi Dipisah

```sql
-- Platform delivery batches (settlement mingguan dari platform)
CREATE TABLE delivery_platform_batches (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    platform        order_channel NOT NULL,  -- 'grabfood', 'gofood', dll
    period_start    DATE NOT NULL,
    period_end      DATE NOT NULL,
    -- Total bruto semua order periode ini
    gross_sales     NUMERIC(14,2) NOT NULL,
    -- Komisi platform (sudah termasuk PPN komisi)
    platform_fee    NUMERIC(14,2) NOT NULL,
    -- Net yang ditransfer ke rekening restoran
    net_settlement  NUMERIC(14,2) GENERATED ALWAYS AS
                        (gross_sales - platform_fee) STORED,
    -- Rekening penerima settlement
    bank_account    VARCHAR(50),
    -- Apakah transfer sudah masuk (rekonsiliasi)
    is_reconciled   BOOLEAN DEFAULT FALSE,
    reconciled_at   TIMESTAMPTZ,
    notes           TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);
```

**Alur pencatatan GrabFood yang benar:**

```
1. Setiap order GrabFood masuk → order.channel = 'grabfood'
   → Revenue dicatat BRUTO (misal Rp 45.000)
   → Stok berkurang sesuai resep

2. Setiap Minggu: GrabFood transfer net ke rekening
   → Input delivery_platform_batches
   → platform_fee otomatis jadi EXPENSE (bukan pengurang revenue)

3. Rekonsiliasi:
   → Total order grabfood di sistem minggu ini = ?
   → Cocok dengan gross_sales di batch? → OK
   → Net transfer sudah masuk rekening? → reconciled = TRUE
```

---

## Bagian 4 — Retur & Void

### 4.1 Void Order (Sebelum Bayar)

Tamu batal, salah input. Stok teoritis harus dikembalikan.

```sql
CREATE OR REPLACE FUNCTION void_order(
    p_order_id  UUID,
    p_reason    TEXT,
    p_user_id   UUID
) RETURNS VOID AS $$
DECLARE
    v_item      RECORD;
BEGIN
    -- Kembalikan stok teoritis yang sudah dikurangi saat complete_order
    -- (hanya berlaku kalau order pernah completed sebelum void — edge case)
    -- Untuk order yang masih 'open', stok belum dikurangi, jadi tidak perlu reversal

    UPDATE orders
    SET status = 'void',
        notes  = COALESCE(notes || ' | ', '') || 'VOID: ' || p_reason
    WHERE id = p_order_id;
END;
$$ LANGUAGE plpgsql;
```

### 4.2 Refund (Sesudah Bayar)

Berbeda dari void. Uang sudah masuk, harus dikembalikan.

```sql
-- Alur refund:
-- 1. payment.status → 'void'
-- 2. incomes.is_active → FALSE (income dinonaktifkan)
-- 3. orders.status → 'refunded'
-- 4. Stok dikembalikan karena makanan tidak jadi dikonsumsi
-- 5. Catat expense 'refund' sebesar amount yang dikembalikan

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
    SELECT restaurant_id INTO v_restaurant_id FROM orders WHERE id = p_order_id;

    -- Nonaktifkan income
    UPDATE incomes
    SET is_active = FALSE,
        notes = COALESCE(notes || ' | ', '') || 'REFUNDED: ' || p_reason
    WHERE reference_id = p_payment_id AND reference_type = 'payment';

    -- Void payment
    UPDATE payments
    SET status = 'void', void_reason = p_reason
    WHERE id = p_payment_id;

    -- Kembalikan stok (karena makanan tidak jadi dikonsumsi)
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
                +v_recipe.qty_to_return,  -- positif = kembali ke stok
                v_recipe.avg_cost_per_unit,
                'refund', p_order_id,
                'Stok dikembalikan karena refund',
                p_user_id
            );
        END LOOP;
    END LOOP;

    -- Catat pengeluaran refund ke expenses
    INSERT INTO expenses (
        restaurant_id, amount, category,
        fiscal_period, expense_date,
        description, reference_type, reference_id, created_by
    ) VALUES (
        v_restaurant_id, p_refund_amount, 'refund',
        TO_CHAR(NOW(), 'YYYY-MM'), CURRENT_DATE,
        'Refund order ' || (SELECT order_number FROM orders WHERE id = p_order_id)
            || ' — ' || p_reason,
        'order', p_order_id, p_user_id
    );

    -- Update order status
    UPDATE orders SET status = 'refunded' WHERE id = p_order_id;
END;
$$ LANGUAGE plpgsql;
```

---

## Bagian 5 — Laporan Keuangan

### 5.1 View Laporan L/R Bulanan

```sql
CREATE OR REPLACE VIEW v_monthly_resto_finance AS
WITH
-- Revenue dari semua channel
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
    LEFT JOIN payments  p ON p.id = i.reference_id AND i.reference_type = 'payment'
    LEFT JOIN orders    o ON o.id = p.order_id
    WHERE i.is_active = TRUE
    GROUP BY i.fiscal_period, i.restaurant_id
),
-- HPP dari stok yang terkonsumsi (dari order_items.theoretical_cogs)
cogs AS (
    SELECT
        TO_CHAR(o.completed_at, 'YYYY-MM') AS fiscal_period,
        o.restaurant_id,
        SUM(oi.theoretical_cogs) AS total_cogs
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    WHERE o.status = 'completed'
    GROUP BY TO_CHAR(o.completed_at, 'YYYY-MM'), o.restaurant_id
),
-- Semua expense per kategori
opex AS (
    SELECT
        e.fiscal_period,
        e.restaurant_id,
        SUM(e.amount) AS total_expense,
        SUM(CASE WHEN e.category = 'inventory_loss'
                 THEN e.amount ELSE 0 END) AS inventory_loss,
        SUM(CASE WHEN e.category = 'platform_fee'
                 THEN e.amount ELSE 0 END) AS platform_fee,
        SUM(CASE WHEN e.category = 'refund'
                 THEN e.amount ELSE 0 END) AS total_refund,
        SUM(CASE WHEN e.category NOT IN ('inventory_loss','platform_fee','refund')
                 THEN e.amount ELSE 0 END) AS other_opex
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
    -- HPP
    COALESCE(c.total_cogs, 0)        AS total_cogs,
    ROUND(COALESCE(c.total_cogs, 0) / NULLIF(r.total_revenue, 0) * 100, 1)
                                     AS food_cost_pct,
    -- Gross Profit
    r.total_revenue - COALESCE(c.total_cogs, 0) AS gross_profit,
    -- OpEx breakdown
    COALESCE(e.inventory_loss, 0)    AS inventory_loss,
    COALESCE(e.platform_fee, 0)      AS platform_fee,
    COALESCE(e.total_refund, 0)      AS total_refund,
    COALESCE(e.other_opex, 0)        AS other_opex,
    COALESCE(e.total_expense, 0)     AS total_expense,
    -- Net Profit
    r.total_revenue
        - COALESCE(c.total_cogs, 0)
        - COALESCE(e.total_expense, 0) AS net_profit,
    ROUND((
        r.total_revenue
        - COALESCE(c.total_cogs, 0)
        - COALESCE(e.total_expense, 0)
    ) / NULLIF(r.total_revenue, 0) * 100, 1) AS net_margin_pct
FROM revenue r
LEFT JOIN cogs  c ON c.fiscal_period  = r.fiscal_period  AND c.restaurant_id  = r.restaurant_id
LEFT JOIN opex  e ON e.fiscal_period  = r.fiscal_period  AND e.restaurant_id  = r.restaurant_id;
```

### 5.2 View Food Cost per Menu

```sql
CREATE OR REPLACE VIEW v_menu_performance AS
SELECT
    m.name        AS menu_name,
    m.category,
    m.selling_price,
    -- HPP teoritis (dari harga bahan terkini)
    vc.theoretical_cogs,
    vc.food_cost_pct,
    -- Total terjual bulan ini
    COUNT(oi.id)  AS qty_sold_this_month,
    SUM(oi.subtotal) AS revenue_this_month,
    SUM(oi.theoretical_cogs) AS cogs_this_month,
    -- Kontribusi margin (revenue - cogs per menu)
    SUM(oi.subtotal - COALESCE(oi.theoretical_cogs, 0)) AS margin_this_month
FROM menus m
JOIN v_menu_cogs vc ON vc.menu_id = m.id
LEFT JOIN order_items oi ON oi.menu_id = m.id
LEFT JOIN orders o ON o.id = oi.order_id
    AND o.status = 'completed'
    AND TO_CHAR(o.completed_at, 'YYYY-MM') = TO_CHAR(NOW(), 'YYYY-MM')
WHERE m.is_active = TRUE
GROUP BY m.id, m.name, m.category, m.selling_price,
         vc.theoretical_cogs, vc.food_cost_pct;
```

### 5.3 Laporan LOSS Harian

```sql
CREATE OR REPLACE VIEW v_daily_loss AS
SELECT
    DATE(sm.created_at)    AS loss_date,
    i.name                 AS ingredient_name,
    sm.movement_type,
    ABS(sm.qty)            AS qty_lost,
    i.unit,
    sm.cost_per_unit,
    ABS(sm.total_cost)     AS loss_value,
    sm.notes
FROM stock_movements sm
JOIN ingredients i ON i.id = sm.ingredient_id
WHERE sm.movement_type IN ('waste', 'opname_adj')
  AND sm.qty < 0  -- hanya yang negatif (keluar/hilang)
ORDER BY loss_date DESC, loss_value DESC;
```

---

## Bagian 6 — Alur Operasional Harian (SDM Minimal)

Dengan arsitektur di atas, rutinitas harian hanya tiga hal:

```
PAGI (5 menit):
  → Kasir buka shift: input opening_cash
  → (Opsional) Input stock opname pagi: hitung bahan yang ada

SIANG — MALAM (otomatis):
  → Order masuk → complete_order() → stok berkurang otomatis
  → Kasir terima cash/QRIS → confirm_payment() → income tercatat

MALAM (10 menit):
  → Stock opname: hitung sisa bahan fisik, input ke sistem
  → confirm_opname() → sistem hitung selisih, catat LOSS
  → Kasir tutup shift: hitung fisik laci cash
  → close_shift() → bandingkan expected vs actual cash
```

Tiga kejadian tidak rutin yang butuh input manual:
- **Beli bahan dari supplier** → input purchases → confirm_purchase()
- **Buang bahan** (tumpah, expired) → input waste_log → stok berkurang
- **Refund/void** → dilakukan via endpoint khusus oleh kasir

---

## Ringkasan: Apa yang Otomatis vs Manual

| Aktivitas | Siapa Input | Sistem Otomatis |
|---|---|---|
| Beli bahan | Staf/owner input purchase | Tambah stok, update avg cost, catat expense |
| Terima order | Kasir input menu + qty | — |
| Selesaikan order | Kasir klik complete | Kurangi stok teoritis, hitung HPP |
| Bayar | Kasir input payment | Income tercatat |
| Buang bahan | Staf input waste | Kurangi stok, catat expense waste |
| Stock opname | Staf hitung fisik + input | Koreksi stok, catat LOSS sebagai expense |
| Laporan L/R | — | View otomatis, tersedia kapan saja |
| Food cost % | — | Dihitung dari resep × harga bahan terkini |

---

## Catatan Arsitektur: Hubungan ke Finance Layer

Sistem inventori restoran ini **tidak menggantikan** finance layer yang sudah ada
(incomes, expenses, fiscal_periods). Ia berada **di atasnya**:

```
┌─────────────────────────────────────────┐
│  INVENTORY LAYER (baru)                 │
│  ingredients, menu_recipes, purchases,  │
│  stock_movements, stock_opnames         │
│         ↓ feed ke ↓                     │
├─────────────────────────────────────────┤
│  FINANCE LAYER (sudah ada)              │
│  incomes, expenses, fiscal_periods,     │
│  payments, kasir_shifts                 │
│         ↓ output ↓                      │
├─────────────────────────────────────────┤
│  LAPORAN                                │
│  L/R, Food Cost %, LOSS Report          │
└─────────────────────────────────────────┘
```

Semua rule dari finance layer tetap berlaku:
- Income dicatat saat konfirmasi bayar (cash basis)
- Void → `is_active = FALSE`
- Fiscal period locking
- Single source of truth: `incomes` dan `expenses`

Inventori hanya menambahkan feed ke expenses (via COGS dan LOSS) dan
ke incomes (via revenue dari penjualan menu).
