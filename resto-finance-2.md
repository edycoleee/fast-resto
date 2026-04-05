# 📘 Arsitektur Keuangan Restoran — Revisi 2

> **Proyek referensi:** Fast-Resto (Restoran Satu Cabang)
> **Stack:** PostgreSQL, Python/FastAPI, pytest
> **Tanggal:** April 2026
> **Revisi dari:** `resto-finance-1.md`
> **Perubahan utama:** Pemisahan bahan Kategori A / B, `kitchen_overhead` masuk blok HPP

---

## Filosof Utama: Jangan Timbang Setiap Sendok

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
4. Input kitchen overhead akhir bulan (agregat bahan Kategori B)

Empat input itu menghasilkan semua laporan yang dibutuhkan: **HPP total, food cost %,
LOSS per bahan, dan L/R bulanan**.

---

## Konsep Inti (Revisi 2): Dua Kategori Bahan

Ini adalah perubahan paling penting dari revisi pertama. Semua bahan dapur dibagi dua:

```
KATEGORI A — Bahan Utama (masuk resep per-porsi)
───────────────────────────────────────────────────
  → Bahan dominan yang bisa diukur per menu
  → Contoh: ayam, ikan, beras, telur, susu, buah, tahu, tempe
  → Masuk ke tabel menu_recipes
  → HPP dihitung otomatis: qty × avg_cost × yield_factor
  → Stok dipantau: berkurang otomatis tiap order selesai
  → ingredient.ingredient_category = 'recipe'

KATEGORI B — Bahan Overhead Dapur (tidak masuk resep)
───────────────────────────────────────────────────
  → Bahan yang dipakai bersama semua menu, tidak bisa diatribusikan per porsi
  → Contoh: minyak goreng, bawang, cabai, bumbu dasar, kecap, gas LPG, garam
  → TIDAK masuk menu_recipes
  → Dicatat sebagai expenses (category = 'kitchen_overhead') akhir bulan
  → Masuk ke blok HPP di laporan, bukan Beban Operasional
  → ingredient.ingredient_category = 'overhead'
```

**Mengapa dibagi dua?**

Karena minyak goreng dipakai untuk goreng ayam, goreng tempe, oseng sayur,
dan pemanasan wajan sekaligus. Tidak ada cara yang realistis untuk mengukur
berapa ml per porsi. Memaksakan presisi di sini menghasilkan angka yang terlihat
akurat tapi sebenarnya ficitious. Lebih baik mencatat agregatnya sebagai overhead.

Kalkulasi HPP akhir:

```
HPP Total Bulan Ini =
  Food cost dari resep (Kat. A)    ← dari order_items.theoretical_cogs
  + Kitchen overhead (Kat. B)      ← dari expenses.category = 'kitchen_overhead'
  + Waste & spoilage               ← dari expenses.category IN ('food_waste','inventory_loss')
```

---

## Peta Konsep: Lima Aliran Data

```
[1] PEMBELIAN BAHAN (Kat. A)    [2] PENJUALAN MENU
    ↓ confirm_purchase()            ↓ complete_order()
    Stok bertambah              Stok berkurang (teoritis, dari resep)
              ↘                  ↙
            STOK TEORITIS SISA
                    |
                    | dibandingkan dengan
                    ↓
         [3] STOCK OPNAME (fisik)
                    ↓ confirm_opname()
             SELISIH = INVENTORY LOSS
                    |
                    ↓
         [4] KITCHEN OVERHEAD (Kat. B)
             Input akhir bulan → expenses.kitchen_overhead
                    |
                    ↓
         [5] LAPORAN L/R
              Revenue − HPP (A + B + Loss) − OpEx = Net Profit
```

---

## Bagian 1 — Struktur Database

### 1.1 Master Bahan Baku

**Perubahan dari revisi 1:** Tambah kolom `ingredient_category` untuk memisahkan
bahan yang masuk resep (Kat. A) dari bahan overhead (Kat. B).

```sql
CREATE TYPE ingredient_unit AS ENUM (
    'gram', 'ml', 'pcs', 'portion'
);

CREATE TYPE ingredient_category AS ENUM (
    'recipe',    -- Kategori A: masuk resep per-porsi, stok dipantau
    'overhead'   -- Kategori B: overhead dapur, dicatat sebagai expense bulanan
);

CREATE TABLE ingredients (
    id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id     UUID NOT NULL REFERENCES restaurants(id),
    name              VARCHAR(100) NOT NULL,
    unit              ingredient_unit NOT NULL,
    ingredient_category ingredient_category NOT NULL DEFAULT 'recipe',
    -- Harga rata-rata bergerak (weighted average cost)
    -- Diupdate otomatis setiap ada pembelian baru
    avg_cost_per_unit NUMERIC(12,4) NOT NULL DEFAULT 0,
    -- Stok teoritis saat ini — HANYA RELEVAN untuk Kategori A
    -- Kategori B tidak perlu stok tracking karena langsung jadi expense
    current_stock     NUMERIC(12,3) NOT NULL DEFAULT 0,
    -- Stok minimum — untuk alert reorder (Kat. A saja)
    reorder_point     NUMERIC(12,3) DEFAULT 0,
    is_active         BOOLEAN DEFAULT TRUE,
    created_at        TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (restaurant_id, name)
);

-- Index terpisah per kategori untuk query efisien
CREATE INDEX idx_ingredients_category
    ON ingredients(restaurant_id, ingredient_category)
    WHERE is_active = TRUE;
```

**Key decision:**
- `current_stock` dan `reorder_point` hanya bermakna untuk Kat. A
- Kat. B tidak perlu stok tracking — saat dibeli, langsung dicatat ke `expenses`
  saat akhir bulan sebagai `kitchen_overhead`
- `avg_cost_per_unit` tetap diisi untuk Kat. B supaya bisa dipakai sebagai
  referensi harga saat membuat estimasi overhead

---

### 1.2 Resep Menu (BOM — Bill of Materials)

```sql
CREATE TABLE menus (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    name            VARCHAR(100) NOT NULL,
    category        VARCHAR(50),          -- 'makanan', 'minuman', 'snack', 'lauk'
    selling_price   NUMERIC(12,2) NOT NULL,
    is_available    BOOLEAN DEFAULT TRUE,
    is_active       BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Resep: satu menu → banyak bahan Kategori A
-- PENTING: hanya bahan ingredient_category = 'recipe' yang masuk sini
CREATE TABLE menu_recipes (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    menu_id         UUID NOT NULL REFERENCES menus(id),
    ingredient_id   UUID NOT NULL REFERENCES ingredients(id),
    -- Constraint: hanya Kategori A boleh masuk resep
    -- CHECK dilakukan di aplikasi layer, bukan DB (untuk fleksibilitas)
    -- Qty yang dipakai PER SATU PORSI menu ini
    qty_per_portion NUMERIC(10,4) NOT NULL,
    -- yield_factor: konversi bahan mentah ke siap pakai
    -- Contoh: ikan lele utuh 1000g → 550g daging bersih → yield = 0.55
    -- Ayam potong: 1000g → 900g setelah trimming → yield = 0.90
    -- Untuk bahan tanpa penyusutan (tepung, gula): yield = 1.0
    yield_factor    NUMERIC(5,4) NOT NULL DEFAULT 1.0,
    notes           TEXT,
    UNIQUE (menu_id, ingredient_id)
);

-- View: HPP teoritis per menu — hanya bahan Kategori A
-- Kitchen overhead TIDAK masuk sini (sudah dipisah ke expenses bulanan)
CREATE OR REPLACE VIEW v_menu_cogs AS
SELECT
    m.id          AS menu_id,
    m.name        AS menu_name,
    m.category,
    m.selling_price,
    SUM(
        mr.qty_per_portion
        / mr.yield_factor
        * i.avg_cost_per_unit
    )             AS theoretical_cogs,
    ROUND(
        SUM(mr.qty_per_portion / mr.yield_factor * i.avg_cost_per_unit)
        / NULLIF(m.selling_price, 0) * 100
    , 1)          AS food_cost_pct_recipe_only    -- % ini BELUM termasuk overhead
FROM menus m
JOIN menu_recipes mr ON mr.menu_id = m.id
JOIN ingredients i   ON i.id = mr.ingredient_id
WHERE m.is_active = TRUE
  AND i.ingredient_category = 'recipe'    -- pastikan hanya Kat. A
GROUP BY m.id, m.name, m.category, m.selling_price;
```

**Tentang `yield_factor` — referensi cepat:**

| Bahan | Yield | Keterangan |
|---|---|---|
| Ayam potong | 0.90 | Buang lemak, tulang kecil |
| Ayam fillet | 0.95 | Minimal trimming |
| Daging sapi | 0.85 | Buang urat, lemak |
| Ikan lele (utuh) | 0.55 | Buang kepala, isi perut, tulang |
| Ikan fillet | 0.95 | Minimal loss |
| Udang (kupas) | 0.70 | Buang kepala, kulit, ekor |
| Cumi-cumi | 0.75 | Buang tulang, kulit luar |
| Tahu (potong dadu) | 0.90 | Sedikit remuk saat potong |
| Beras (→ nasi) | 1.00 | Ukur beras mentah per porsi |
| Tepung, gula | 1.00 | Tidak ada loss |
| Jeruk (peras) | 0.85 | Buang biji, ampas |

Setelah `confirm_purchase()` di-run, `avg_cost_per_unit` di `ingredients`
terupdate otomatis via weighted average. Semua view dan HPP langsung ikut update
— tidak perlu edit resep.

---

### 1.3 Pergerakan Stok (Stock Movements)

Semua perubahan stok Kategori A masuk ke satu tabel ini.
Ini adalah **audit trail lengkap** pergerakan inventori.

```sql
CREATE TYPE movement_type AS ENUM (
    'purchase',           -- beli dari supplier
    'sale',               -- terjual (dihitung dari resep × qty order)
    'waste',              -- dibuang: expired, jatuh, salah masak
    'opname_adj',         -- koreksi dari stock opname fisik
    'return_to_supplier', -- retur ke supplier
    'transfer_in',        -- penerimaan dari gudang/cabang lain (future)
    'opening'             -- stok awal saat sistem pertama dijalankan
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

CREATE INDEX idx_stock_mov_ingredient
    ON stock_movements(ingredient_id, created_at DESC);
CREATE INDEX idx_stock_mov_restaurant
    ON stock_movements(restaurant_id, movement_type, created_at DESC);
```

**Catatan:** Bahan Kategori B tidak punya stock_movements. Saat dibeli, catatannya
langsung ke `purchases` (untuk history harga) dan saat akhir bulan diinput sebagai
`expenses.kitchen_overhead`. Ini pilihan yang disengaja untuk mengurangi beban input.

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
    'received',     -- barang sudah diterima, stok sudah bertambah (Kat. A)
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

Saat status purchase diubah ke `received`, function ini berjalan.
Perilaku berbeda untuk Kat. A vs Kat. B:

- **Kat. A**: Tambah `current_stock` + update `avg_cost_per_unit` + catat `stock_movements`
- **Kat. B**: Hanya update `avg_cost_per_unit` untuk referensi harga (stok tidak dipantau)

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
        SELECT pi.*, i.current_stock, i.avg_cost_per_unit, i.ingredient_category
        FROM purchase_items pi
        JOIN ingredients i ON i.id = pi.ingredient_id
        WHERE pi.purchase_id = p_purchase_id
    LOOP
        v_old_stock := v_item.current_stock;
        v_old_cost  := v_item.avg_cost_per_unit;

        -- Weighted Average Cost — berlaku untuk semua kategori
        -- (Kat. B tetap perlu referensi harga terkini untuk estimasi overhead)
        v_new_avg_cost := (
            (v_old_stock * v_old_cost) + (v_item.qty * v_item.unit_price)
        ) / NULLIF(v_old_stock + v_item.qty, 0);

        IF v_item.ingredient_category = 'recipe' THEN
            -- Kategori A: update stok + harga
            UPDATE ingredients
            SET current_stock     = current_stock + v_item.qty,
                avg_cost_per_unit = v_new_avg_cost
            WHERE id = v_item.ingredient_id;

            -- Audit trail hanya untuk Kat. A
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
        ELSE
            -- Kategori B: hanya update referensi harga, tidak pengaruhi stok
            UPDATE ingredients
            SET avg_cost_per_unit = v_new_avg_cost
            WHERE id = v_item.ingredient_id;
        END IF;
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
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id         UUID NOT NULL REFERENCES orders(id),
    menu_id          UUID NOT NULL REFERENCES menus(id),
    menu_name        VARCHAR(100) NOT NULL,  -- snapshot nama saat transaksi
    unit_price       NUMERIC(12,2) NOT NULL, -- snapshot harga saat transaksi
    qty              INTEGER NOT NULL CHECK (qty > 0),
    subtotal         NUMERIC(14,2) GENERATED ALWAYS AS (unit_price * qty) STORED,
    -- Theoretical COGS dari bahan Kat. A saja (snapshot, bukan dari view)
    -- Overhead Kat. B tidak masuk sini — dicatat terpisah di expenses
    theoretical_cogs NUMERIC(14,2),
    notes            TEXT  -- catatan dapur: "pedas", "tanpa bawang", dll
);
```

---

### 1.6 Depresi Stok Otomatis Saat Order Selesai

Ini adalah jantung dari model Theoretical Consumption.
Saat kasir klik "Complete Order", function ini berjalan.
Hanya bahan Kategori A yang diproses — Kat. B tidak punya stok yang perlu dikurangi.

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

        -- Loop setiap bahan KATEGORI A di resep menu ini
        FOR v_recipe IN
            SELECT mr.ingredient_id,
                   mr.qty_per_portion / mr.yield_factor AS qty_needed,
                   i.avg_cost_per_unit,
                   i.ingredient_category
            FROM menu_recipes mr
            JOIN ingredients i ON i.id = mr.ingredient_id
            WHERE mr.menu_id = v_item.menu_id
              AND i.ingredient_category = 'recipe'  -- hanya Kat. A
        LOOP
            DECLARE
                v_total_qty NUMERIC := v_recipe.qty_needed * v_item.qty;
            BEGIN
                -- Kurangi stok teoritis Kat. A
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
                    -v_total_qty,
                    v_recipe.avg_cost_per_unit,
                    'order', p_order_id,
                    p_user_id
                );

                v_item_cogs := v_item_cogs
                    + (v_total_qty * v_recipe.avg_cost_per_unit);
            END;
        END LOOP;

        -- Update theoretical_cogs di order_item
        -- Nilai ini = HPP Kat. A saja, belum termasuk overhead
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

## Bagian 2 — Kategori Pengeluaran (Expense Categories)

### 2.1 ENUM expense_category (Lengkap)

Semua pengeluaran masuk ke tabel `expenses`. Pembagian kategori menentukan
di baris mana angka ini muncul di Laporan L/R.

```sql
CREATE TYPE expense_category AS ENUM (
    -- ── BLOK HPP ─────────────────────────────────────────────
    -- Tiga kategori ini masuk ke baris HPP, bukan Beban Operasional

    'food_waste',        -- bahan dibuang manual (tumpah, expired, gagal masak)
    'inventory_loss',    -- loss terdeteksi dari stock opname (otomatis dari confirm_opname)
    'kitchen_overhead',  -- bahan Kategori B: minyak, bumbu, gas LPG (input akhir bulan)

    -- ── BEBAN OPERASIONAL ────────────────────────────────────
    'salary',            -- gaji semua karyawan
    'utility',           -- listrik, air, gas (yang bukan dapur), internet
    'rent',              -- sewa tempat / cicilan
    'platform_fee',      -- komisi GrabFood, GoFood, dll (otomatis dari confirm_platform_settlement)
    'maintenance',       -- perbaikan peralatan dapur, furnitur, AC
    'marketing',         -- promosi, iklan, bikin konten
    'packaging',         -- dus, kantong, sedotan, tisu (tidak masuk resep)
    'refund',            -- uang dikembalikan ke tamu (otomatis dari refund_order)
    'other'              -- pengeluaran lain-lain yang tidak masuk kategori di atas
);
```

### 2.2 Tabel `expenses`

```sql
CREATE TABLE expenses (
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id    UUID NOT NULL REFERENCES restaurants(id),
    amount           NUMERIC(14,2) NOT NULL,
    category         expense_category NOT NULL,
    -- Untuk platform_fee: simpan nama platform-nya
    reference_platform VARCHAR(30),         -- 'grabfood', 'gofood', 'shopeefood'
    reference_type   VARCHAR(30),           -- 'opname', 'platform_batch', 'manual', 'refund'
    reference_id     UUID,
    fiscal_period    VARCHAR(7) NOT NULL,   -- 'YYYY-MM'
    expense_date     DATE NOT NULL,
    description      TEXT,
    is_active        BOOLEAN NOT NULL DEFAULT TRUE,
    created_by       UUID REFERENCES users(id),
    created_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_expenses_period
    ON expenses(restaurant_id, fiscal_period) WHERE is_active = TRUE;
CREATE INDEX idx_expenses_category
    ON expenses(restaurant_id, category, fiscal_period);
```

### 2.3 Aturan Input Kategori

| Kejadian | category | Siapa input | Otomatis? |
|---|---|---|---|
| Gaji April dibayar | `salary` | Owner | Manual |
| Tagihan listrik | `utility` | Owner | Manual |
| Sewa tempat | `rent` | Owner | Manual |
| Minyak, bumbu, gas akhir bulan | `kitchen_overhead` | Owner | Manual |
| Bahan tumpah / busuk | `food_waste` | Staf | Manual |
| Loss dari stock opname | `inventory_loss` | — | Otomatis via `confirm_opname()` |
| Komisi GrabFood/GoFood | `platform_fee` | — | Otomatis via `confirm_platform_settlement()` |
| Refund tamu | `refund` | — | Otomatis via `refund_order()` |
| Sabun cuci, alat tulis | `other` | Staf/owner | Manual |

**Aturan penting:**

`kitchen_overhead` diinput **satu kali per bulan** di akhir bulan — bukan per transaksi.
Owner cukup rekapitulasi: total beli minyak + bumbu + gas bulan ini → satu insert.
Tidak perlu detail per pembelian (sudah ada di `purchases` sebagai referensi).

---

## Bagian 3 — Stock Opname & Deteksi LOSS

### 3.1 Mengapa Stock Opname Adalah Inti Segalanya

Setelah sistem berjalan satu hari penuh:

```
Stok Teoritis Ayam (dari sistem):
  Stok pagi  = 5.000 g
  Pembelian  = +2.000 g
  Terjual    = −3.200 g  (dari 16 porsi Ayam Goreng × 200g ÷ yield 0.90)
  Teoritis   = 3.800 g   ← sistem pikir stok segini

Stock Opname malam:
  Fisik      = 3.400 g   ← kasir/dapur hitung langsung

Selisih      = −400 g    ← ini LOSS
Nilai LOSS   = 400 × Rp 38/g × 0.90 (yield) = Rp 13.680
```

Dalam satu hari. Kalau tidak dideteksi setiap hari, ini terakumulasi diam-diam.

**Sumber LOSS** yang umum di restoran kecil:
- Over-portioning (dapur kasih lebih dari resep)
- Trial masak / menu baru yang gagal
- Bahan jatuh / rusak saat memasak
- Waste tidak diinput manual
- Resep tidak akurat (yield factor keliru di awal)
- Pencurian (jarang, tapi ada)

### 3.2 Tabel Stock Opname

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
    UNIQUE (restaurant_id, opname_date)  -- satu opname per hari
);

CREATE TABLE stock_opname_items (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    opname_id       UUID NOT NULL REFERENCES stock_opnames(id),
    ingredient_id   UUID NOT NULL REFERENCES ingredients(id),
    -- Stok teoritis saat opname (snapshot dari ingredients.current_stock)
    theoretical_qty NUMERIC(12,3) NOT NULL,
    -- Stok fisik yang dihitung manusia
    actual_qty      NUMERIC(12,3) NOT NULL,
    -- Selisih: negatif = LOSS, positif = gain (jarang)
    variance        NUMERIC(12,3) GENERATED ALWAYS AS
                        (actual_qty - theoretical_qty) STORED,
    -- Nilai rupiah dari variance
    cost_per_unit   NUMERIC(12,4) NOT NULL,
    variance_value  NUMERIC(14,2) GENERATED ALWAYS AS
                        ((actual_qty - theoretical_qty) * cost_per_unit) STORED,
    UNIQUE (opname_id, ingredient_id)
);
```

**Catatan:** Stock opname hanya untuk bahan Kategori A. Kat. B tidak punya stok
teoritis yang bisa dibandingkan — ia tidak pernah masuk ke sistem sebagai stok.

### 3.3 Konfirmasi Opname: Koreksi Stok + Expense Otomatis

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
          AND soi.variance <> 0
    LOOP
        -- Koreksi stok teoritis ke angka fisik
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
            v_item.variance,
            v_item.cost_per_unit,
            'opname', p_opname_id,
            'Stock opname adjustment',
            p_user_id
        );

        IF v_item.variance < 0 THEN
            v_total_loss := v_total_loss + ABS(v_item.variance_value);
        ELSE
            v_total_gain := v_total_gain + v_item.variance_value;
        END IF;
    END LOOP;

    -- Catat LOSS ke expenses (masuk blok HPP di laporan)
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

## Bagian 4 — Kasir Multi-Channel

### 4.1 Shift Kasir

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
    opening_cash    NUMERIC(14,2) NOT NULL DEFAULT 0,
    expected_cash   NUMERIC(14,2),
    actual_cash     NUMERIC(14,2),
    cash_variance   NUMERIC(14,2) GENERATED ALWAYS AS
                        (actual_cash - expected_cash) STORED,
    notes           TEXT
);
```

### 4.2 Pembayaran

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
    reference_number VARCHAR(100),  -- nomor ref QRIS dari payment gateway
    shift_id        UUID REFERENCES kasir_shifts(id),
    confirmed_by    UUID REFERENCES users(id),
    confirmed_at    TIMESTAMPTZ,
    void_reason     TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);
```

### 4.3 GrabFood / GoFood: Gross Dicatat, Komisi Dipisah

```sql
CREATE TABLE delivery_platform_batches (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    platform        order_channel NOT NULL,  -- 'grabfood', 'gofood', dll
    period_start    DATE NOT NULL,
    period_end      DATE NOT NULL,
    gross_sales     NUMERIC(14,2) NOT NULL,
    platform_fee    NUMERIC(14,2) NOT NULL,
    net_settlement  NUMERIC(14,2) GENERATED ALWAYS AS
                        (gross_sales - platform_fee) STORED,
    bank_account    VARCHAR(50),
    is_reconciled   BOOLEAN DEFAULT FALSE,
    reconciled_at   TIMESTAMPTZ,
    notes           TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);
```

**DB Function: Konfirmasi Settlement Platform**

```sql
CREATE OR REPLACE FUNCTION confirm_platform_settlement(
    p_batch_id  UUID,
    p_user_id   UUID
) RETURNS VOID AS $$
DECLARE
    v_batch delivery_platform_batches%ROWTYPE;
BEGIN
    SELECT * INTO v_batch FROM delivery_platform_batches WHERE id = p_batch_id;

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
    SET is_reconciled = TRUE, reconciled_at = NOW()
    WHERE id = p_batch_id;
END;
$$ LANGUAGE plpgsql;
```

---

## Bagian 5 — Retur & Void

### 5.1 Void Order (Sebelum Bayar)

```sql
CREATE OR REPLACE FUNCTION void_order(
    p_order_id  UUID,
    p_reason    TEXT,
    p_user_id   UUID
) RETURNS VOID AS $$
BEGIN
    -- Untuk order 'open': stok belum dikurangi, tidak perlu reversal
    -- Untuk order 'completed' yang belum bayar: harus kembalikan stok
    UPDATE orders
    SET status = 'void',
        notes  = COALESCE(notes || ' | ', '') || 'VOID: ' || p_reason
    WHERE id = p_order_id;
END;
$$ LANGUAGE plpgsql;
```

### 5.2 Refund (Sesudah Bayar)

```sql
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

    -- Kembalikan stok Kategori A (makanan tidak jadi dikonsumsi)
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
              AND i.ingredient_category = 'recipe'  -- hanya Kat. A
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

    -- Catat expense refund (Beban Operasional)
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

    UPDATE orders SET status = 'refunded' WHERE id = p_order_id;
END;
$$ LANGUAGE plpgsql;
```

---

## Bagian 6 — Laporan Keuangan

### 6.1 View Laporan L/R Bulanan

Perubahan dari revisi 1: `kitchen_overhead` dipisahkan ke blok HPP,
bukan digabung ke `other_opex`.

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
    LEFT JOIN payments p ON p.id = i.reference_id AND i.reference_type = 'payment'
    LEFT JOIN orders   o ON o.id = p.order_id
    WHERE i.is_active = TRUE
    GROUP BY i.fiscal_period, i.restaurant_id
),
-- HPP Kategori A: dari order_items.theoretical_cogs
cogs_recipe AS (
    SELECT
        TO_CHAR(o.completed_at, 'YYYY-MM') AS fiscal_period,
        o.restaurant_id,
        SUM(oi.theoretical_cogs) AS total_cogs_recipe
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    WHERE o.status = 'completed'
    GROUP BY TO_CHAR(o.completed_at, 'YYYY-MM'), o.restaurant_id
),
-- Semua expense, dipisah per kelompok
expense_breakdown AS (
    SELECT
        e.fiscal_period,
        e.restaurant_id,
        -- ── BLOK HPP ─────────────────────────────────
        SUM(CASE WHEN e.category = 'food_waste'
                 THEN e.amount ELSE 0 END) AS food_waste,
        SUM(CASE WHEN e.category = 'inventory_loss'
                 THEN e.amount ELSE 0 END) AS inventory_loss,
        SUM(CASE WHEN e.category = 'kitchen_overhead'
                 THEN e.amount ELSE 0 END) AS kitchen_overhead,
        -- ── BEBAN OPERASIONAL ─────────────────────────
        SUM(CASE WHEN e.category = 'salary'
                 THEN e.amount ELSE 0 END) AS salary,
        SUM(CASE WHEN e.category = 'utility'
                 THEN e.amount ELSE 0 END) AS utility,
        SUM(CASE WHEN e.category = 'rent'
                 THEN e.amount ELSE 0 END) AS rent,
        SUM(CASE WHEN e.category = 'platform_fee'
                 THEN e.amount ELSE 0 END) AS platform_fee,
        SUM(CASE WHEN e.category = 'maintenance'
                 THEN e.amount ELSE 0 END) AS maintenance,
        SUM(CASE WHEN e.category = 'marketing'
                 THEN e.amount ELSE 0 END) AS marketing,
        SUM(CASE WHEN e.category = 'packaging'
                 THEN e.amount ELSE 0 END) AS packaging,
        SUM(CASE WHEN e.category = 'refund'
                 THEN e.amount ELSE 0 END) AS total_refund,
        SUM(CASE WHEN e.category = 'other'
                 THEN e.amount ELSE 0 END) AS other_opex
    FROM expenses e
    WHERE e.is_active = TRUE
    GROUP BY e.fiscal_period, e.restaurant_id
)
SELECT
    r.fiscal_period,
    r.restaurant_id,

    -- ── REVENUE ──────────────────────────────────────────────
    r.total_revenue,
    r.revenue_dinein,
    r.revenue_takeaway,
    r.revenue_delivery,

    -- ── HPP (tiga komponen) ──────────────────────────────────
    -- Komponen 1: bahan utama dari resep (Kat. A)
    COALESCE(cr.total_cogs_recipe, 0)           AS cogs_recipe,
    -- Komponen 2: overhead dapur bulanan (Kat. B)
    COALESCE(eb.kitchen_overhead, 0)            AS cogs_kitchen_overhead,
    -- Komponen 3: waste dan inventory loss
    COALESCE(eb.food_waste, 0)
        + COALESCE(eb.inventory_loss, 0)        AS cogs_waste_loss,
    -- Total HPP = Kat. A + Kat. B + Waste
    COALESCE(cr.total_cogs_recipe, 0)
        + COALESCE(eb.kitchen_overhead, 0)
        + COALESCE(eb.food_waste, 0)
        + COALESCE(eb.inventory_loss, 0)        AS total_hpp,
    ROUND((
        COALESCE(cr.total_cogs_recipe, 0)
        + COALESCE(eb.kitchen_overhead, 0)
        + COALESCE(eb.food_waste, 0)
        + COALESCE(eb.inventory_loss, 0)
    ) / NULLIF(r.total_revenue, 0) * 100, 1)   AS hpp_pct,

    -- ── GROSS PROFIT ─────────────────────────────────────────
    r.total_revenue
        - COALESCE(cr.total_cogs_recipe, 0)
        - COALESCE(eb.kitchen_overhead, 0)
        - COALESCE(eb.food_waste, 0)
        - COALESCE(eb.inventory_loss, 0)        AS gross_profit,

    -- ── BEBAN OPERASIONAL (breakdown) ────────────────────────
    COALESCE(eb.salary, 0)                      AS opex_salary,
    COALESCE(eb.utility, 0)                     AS opex_utility,
    COALESCE(eb.rent, 0)                        AS opex_rent,
    COALESCE(eb.platform_fee, 0)               AS opex_platform_fee,
    COALESCE(eb.maintenance, 0)                AS opex_maintenance,
    COALESCE(eb.marketing, 0)                  AS opex_marketing,
    COALESCE(eb.packaging, 0)                  AS opex_packaging,
    COALESCE(eb.total_refund, 0)               AS opex_refund,
    COALESCE(eb.other_opex, 0)                 AS opex_other,
    -- Total OpEx (tidak termasuk HPP expenses)
    COALESCE(eb.salary, 0)
        + COALESCE(eb.utility, 0)
        + COALESCE(eb.rent, 0)
        + COALESCE(eb.platform_fee, 0)
        + COALESCE(eb.maintenance, 0)
        + COALESCE(eb.marketing, 0)
        + COALESCE(eb.packaging, 0)
        + COALESCE(eb.total_refund, 0)
        + COALESCE(eb.other_opex, 0)            AS total_opex,

    -- ── NET PROFIT ───────────────────────────────────────────
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
        - COALESCE(eb.other_opex, 0)            AS net_profit,
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
    ) / NULLIF(r.total_revenue, 0) * 100, 1)   AS net_margin_pct

FROM revenue r
LEFT JOIN cogs_recipe      cr ON cr.fiscal_period = r.fiscal_period
                              AND cr.restaurant_id = r.restaurant_id
LEFT JOIN expense_breakdown eb ON eb.fiscal_period = r.fiscal_period
                               AND eb.restaurant_id = r.restaurant_id;
```

**Contoh output untuk April 2026:**

```
fiscal_period       | 2026-04
total_revenue       | 13.500.000
revenue_dinein      |  8.500.000
revenue_delivery    |  5.000.000
─────────────────── | ─────────────
cogs_recipe         |  4.200.000   (31.1%)
cogs_kitchen_overhead|  1.450.000  (10.7%)
cogs_waste_loss     |    320.000    (2.4%)
total_hpp           |  5.970.000   (44.2%)
gross_profit        |  7.530.000   (55.8%)
─────────────────── | ─────────────
opex_salary         |  3.500.000
opex_utility        |    450.000
opex_rent           |  2.000.000
opex_platform_fee   |  1.000.000
opex_other          |    200.000
total_opex          |  7.150.000
─────────────────── | ─────────────
net_profit          |    380.000    (2.8%)
```

---

### 6.2 View Food Cost per Menu

```sql
CREATE OR REPLACE VIEW v_menu_performance AS
SELECT
    m.name          AS menu_name,
    m.category,
    m.selling_price,
    -- HPP dari bahan Kat. A saja (overhead tidak bisa di-atribusikan per menu)
    vc.theoretical_cogs     AS cogs_recipe,
    vc.food_cost_pct_recipe_only,
    -- Total terjual bulan ini
    COUNT(oi.id)            AS qty_sold_this_month,
    SUM(oi.subtotal)        AS revenue_this_month,
    SUM(oi.theoretical_cogs) AS cogs_recipe_this_month,
    -- Margin dari Kat. A saja (lebih tinggi dari margin nyata karena belum overhead)
    SUM(oi.subtotal - COALESCE(oi.theoretical_cogs, 0)) AS margin_before_overhead
FROM menus m
JOIN v_menu_cogs vc ON vc.menu_id = m.id
LEFT JOIN order_items oi ON oi.menu_id = m.id
LEFT JOIN orders o ON o.id = oi.order_id
    AND o.status = 'completed'
    AND TO_CHAR(o.completed_at, 'YYYY-MM') = TO_CHAR(NOW(), 'YYYY-MM')
WHERE m.is_active = TRUE
GROUP BY m.id, m.name, m.category, m.selling_price,
         vc.theoretical_cogs, vc.food_cost_pct_recipe_only;
```

**Catatan interpretasi:** `food_cost_pct_recipe_only` menunjukkan HPP bahan utama
saja. Untuk mendapat food cost % yang realistis, tambahkan alokasi overhead:

```
Food cost % realistis ≈ food_cost_pct_recipe_only + (kitchen_overhead_bulan / revenue_bulan × 100%)
```

Target industri restoran Indonesia: food cost % total 28–38% (setelah overhead).

---

### 6.3 Laporan LOSS Harian

```sql
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
```

---

## Bagian 7 — Alur Operasional Harian (SDM Minimal)

```
PAGI (5 menit):
  → Kasir buka shift: input opening_cash
  → (Opsional) Input stock opname pagi: hitung bahan Kat. A yang ada

SIANG — MALAM (otomatis):
  → Order masuk → complete_order() → stok Kat. A berkurang otomatis
  → Kasir terima cash/QRIS → confirm_payment() → income tercatat
  → Order GrabFood masuk → input + complete → income bruto tercatat

MALAM (10 menit):
  → Stock opname: hitung fisik bahan Kat. A, input ke sistem
  → confirm_opname() → sistem hitung selisih, catat LOSS ke expenses
  → Kasir tutup shift: hitung fisik laci cash
  → close_shift() → bandingkan expected vs actual cash

MINGGUAN (5 menit per platform):
  → Terima laporan GrabFood/GoFood
  → Input delivery_platform_batches
  → confirm_platform_settlement() → komisi tercatat sebagai expense

AKHIR BULAN (15 menit):
  → Rekapitulasi total beli minyak + bumbu + gas bulan ini
  → Input 2–4 baris expenses (category = 'kitchen_overhead')
  → Input gaji, listrik, sewa (expenses per kategori)
  → Tarik laporan v_monthly_resto_finance → baca NET PROFIT
```

Input tidak rutin tambahan:
- **Beli bahan Kat. A** → input purchases → confirm_purchase()
- **Buang bahan** (tumpah, expired) → input waste → stok berkurang + expense food_waste
- **Refund/void** → via endpoint khusus kasir

---

## Ringkasan: Apa yang Otomatis vs Manual

| Aktivitas | Siapa Input | Otomatis |
|---|---|---|
| Beli bahan Kat. A | Owner/staf input purchase | Tambah stok, update avg cost |
| Beli bahan Kat. B | Owner catat nota, input akhir bulan | Update referensi harga |
| Terima order | Kasir input menu + qty | — |
| Selesaikan order | Kasir klik complete | Kurangi stok teoritis Kat. A, hitung HPP |
| Bayar | Kasir input payment | Income tercatat |
| Buang bahan | Staf input waste | Kurangi stok, catat expense food_waste |
| Stock opname | Staf hitung fisik Kat. A + input | Koreksi stok, catat LOSS ke expenses |
| Input kitchen overhead | Owner akhir bulan | — |
| Settlement platform | Owner input batch + confirm | Catat expense platform_fee |
| Laporan L/R | — | View otomatis, tersedia kapan saja |
| Food cost % | — | Dihitung dari resep × harga bahan terkini |

---

## Catatan Arsitektur: Layer System

```
┌──────────────────────────────────────────────┐
│  INVENTORY LAYER                             │
│  ingredients (Kat. A + B)                   │
│  menu_recipes, purchases, stock_movements   │
│  stock_opnames, delivery_platform_batches   │
│         ↓ feed ke ↓                          │
├──────────────────────────────────────────────┤
│  FINANCE LAYER                               │
│  incomes    → single source of truth revenue │
│  expenses   → HPP + OpEx (by category)       │
│  kasir_shifts → cash reconciliation          │
│         ↓ output ↓                           │
├──────────────────────────────────────────────┤
│  LAPORAN                                     │
│  v_monthly_resto_finance  → L/R bulanan      │
│  v_menu_performance       → food cost % menu │
│  v_daily_loss             → audit trail LOSS │
│  get_monthly_pl_report()  → detail per baris │
└──────────────────────────────────────────────┘
```

**Aliran expense dari sistem ke laporan:**

```
complete_order()         → order_items.theoretical_cogs (HPP Kat. A)
confirm_opname()         → expenses.inventory_loss       (HPP Waste)
log_waste()              → expenses.food_waste           (HPP Waste)
Input akhir bulan manual → expenses.kitchen_overhead     (HPP Kat. B)
confirm_platform_settle()→ expenses.platform_fee         (OpEx)
refund_order()           → expenses.refund               (OpEx)
Input manual owner       → expenses.salary/utility/rent  (OpEx)
```

Semua rule finance layer tetap berlaku:
- Income dicatat saat konfirmasi bayar (cash basis)
- Void → `is_active = FALSE`
- Single source of truth: `incomes` dan `expenses`
- Fiscal period adalah `VARCHAR(7)` format `YYYY-MM`

---

---

## Bagian 8 — Best Practice untuk Restoran Kecil

### 8.1 Prinsip: Mulai Sederhana, Perbaiki Bertahap

Jangan coba membuat semua data sempurna di hari pertama.
Urutan yang benar:

```
Minggu 1: Input master bahan (Kat. A + B), buat resep menu
Minggu 2: Jalankan sistem POS + opname harian
Minggu 3: Evaluasi variance — apakah yield factor sudah benar?
Bulan 2+: Mulai percaya angka HPP, gunakan untuk keputusan harga
```

Sistem yang dijalankan dengan data 80% akurat lebih berguna
dari sistem sempurna yang tidak pernah dipakai.

---

### 8.2 Cara Menentukan Kategori A vs B

Gunakan dua pertanyaan ini untuk setiap bahan:

| Pertanyaan | Ya → | Tidak → |
|---|---|---|
| Apakah bahan ini pakai per-porsi yang bisa diukur? | Kandidat Kat. A | Kat. B |
| Apakah porsi per menu bisa konsisten setiap masak? | Kat. A pasti | Kat. B |

**Contoh keputusan cepat:**

| Bahan | Keputusan | Alasan |
|---|---|---|
| Ayam fillet 200g per ayam geprek | ✅ Kat. A | Konsisten, bisa ditimbang |
| Beras 100g per porsi nasi | ✅ Kat. A | Konsisten, bisa ditakar |
| Minyak goreng (goreng + tumis) | ❌ Kat. B | Dipakai banyak menu, tidak bisa per-porsi |
| Bawang merah (bumbu dasar) | ❌ Kat. B | Masuk ke semua masakan sekaligus |
| Kecap manis (topping ayam geprek) | 🤔 Bisa A | Kalau cuma drizzle 1 sdt → bisa diukur |
| Gas LPG | ❌ Kat. B | Tidak ada cara mengukur per porsi |
| Susu kental manis 20ml per kopi | ✅ Kat. A | Terukur, konsisten |
| Gula pasir (untuk semua minuman) | 🤔 Tergantung | Jika tiap menu pakai qty berbeda → Kat. A; jika campur → Kat. B |

**Aturan praktis:** Kalau ragu, pilih Kat. B. Lebih baik overhead sedikit
over-estimate daripada resep yang tidak pernah bisa diikuti konsisten.

---

### 8.3 Yield Factor: Ukur Sekali, Pakai Selamanya

Cara mengukur yield factor yang benar:

```
1. Beli bahan dalam kondisi biasa (misalnya: 1 kg ikan lele utuh)
2. Proses seperti biasa (potong kepala, buang isi perut, fillet)
3. Timbang hasil bersih yang siap dimasak
4. Yield = berat bersih ÷ berat awal

Contoh:
  Lele utuh 1.000g → fillet bersih 540g → yield = 0.54
  Simpan: ingredients.yield_factor = 0.54
```

Lakukan pengukuran ini **satu kali saja** saat setup awal.
Setelah itu tidak perlu diulang kecuali supplier berganti atau
ada perubahan cara pemotongan.

**Yield factor referensi cepat untuk koreksi:**

| Jika loss di opname selalu tinggi untuk bahan X | Kemungkinan masalah |
|---|---|
| Yield factor terlalu besar (mis. 0.90 padahal harusnya 0.70) | Revisi yield ke bawah |
| Resep qty per porsi terlalu kecil | Revisi qty_per_portion ke atas |
| Dapur sering overcooking / trial | Input waste_manual rutin |

---

### 8.4 Stock Opname: Satu Kebiasaan yang Paling Penting

Stock opname harian adalah **satu-satunya cara** sistem mendeteksi
losses yang tidak terlihat: over-portioning dapur, bahan jatuh,
pencurian kecil, atau data purchase yang belum diinput.

**Format paling ringkas untuk opname malam:**

```
Bahan               | Sistem (g) | Fisik (g) | Selisih
─────────────────── | ─────────  | ─────────  | ───────
Ayam fillet         |    2.400   |    2.100   | −300 ❌
Beras               |    8.500   |    8.600   | +100 ✓
Ikan lele (mentah)  |    1.800   |    1.800   |     0 ✓
Tahu putih          |    3.200   |    2.900   | −300 ❌
```

**Interpretasi selisih:**

| Selisih | Artinya | Tindakan |
|---|---|---|
| −0 s/d −5% dari qty terjual | Normal, dalam toleransi | Tidak perlu tindakan |
| −5% s/d −15% | Perlu investigasi | Cek apakah ada purchase belum diinput, atau yield factor keliru |
| > −15% | Lampu merah | Audit dapur, cek resep, wajib investigasi |
| Positif besar (>+10%) | Kemungkinan purchase belum diinput | Cek nota pembelian hari ini |

**Tips waktu:** Opname 10 bahan utama cukup 10–15 menit.
Tidak perlu hitung semua bahan setiap hari — fokus pada bahan
dengan nilai tertinggi (ayam, daging, ikan) dan bahan yang sering bermasalah.

---

### 8.5 Stok Teoritis Negatif: Jangan Panik

Sistem **tidak memblokir** transaksi saat stok menunjukkan angka negatif.
Ini disengaja — karena `current_stock` adalah angka teoritis, bukan fisik.

**Empat penyebab umum stok negatif:**

1. **Purchase belum diinput** — beli bahan tadi pagi tapi belum di-confirm → stok turun dari penjualan, tidak naik dari pembelian
2. **Yield factor terlalu besar** — sistem pikir 1 kg ayam jadi 950g, padahal kenyataan 800g → konsumsi teoritis lebih kecil dari kenyataan
3. **Qty resep di bawah aktual** — dapur kasih porsi lebih besar dari yang tercatat di resep
4. **Opname belum di-confirm** — stok terakhir correction belum jalan

**Respons yang benar:**

```
Stok teoritis negatif?
  ↓
Cek: ada purchase hari ini yang belum diinput?
  → Ya: input sekarang → stok akan naik kembali
  → Tidak: tunggu sampai opname malam
              ↓
         confirm_opname() akan reset stok ke angka fisik
         → selisih tercatat otomatis sebagai inventory_loss
```

**Yang JANGAN dilakukan:**
- Jangan edit `current_stock` langsung via SQL tanpa opname
- Jangan blokir penjualan karena stok negatif (kecuali tombol `is_available = FALSE` memang sengaja dimatikan)

---

### 8.6 Dua Cara Tandai Menu "Habis"

Sistem punya dua sinyal "menu habis" — dan keduanya berbeda fungsi:

| Mekanisme | Dijalankan oleh | Kapan dipakai |
|---|---|---|
| `ingredients.current_stock ≤ reorder_point` | Sistem otomatis | Alert awal: beli bahan segera |
| `menus.is_available = FALSE` | Human (kasir/owner) | Menu benar-benar tidak dijual — toggle manual |

**Alur yang benar:**

```
Pagi: sistem menampilkan alert (stok mendekati habis)
  ↓
Owner cek fisik dapur
  ↓ Bahan masih ada → tidak perlu apa-apa, beli sebelum habis
  ↓ Bahan memang habis → kasir toggle is_available = FALSE
  ↓
Beli bahan datang → input purchases → confirm_purchase()
  ↓
Owner toggle is_available = TRUE → menu aktif kembali
```

`is_available = FALSE` adalah **keputusan manusia**, bukan keputusan sistem.
Sistem hanya menyediakan alert berbasis angka teoritis.

---

### 8.7 Kitchen Overhead Akhir Bulan: Ritual 15 Menit

Tidak perlu tracking minyak per botol atau gas per tabung harian.
Cukup lakukan ini sekali di akhir bulan:

```
1. Kumpulkan semua nota/struk pembelian minyak, bumbu, gas bulan ini
2. Groupkan per jenis:
   - Total beli minyak goreng: Rp xxx.xxx
   - Total beli bumbu dasar (bawang, cabai, dll): Rp xxx.xxx
   - Total beli gas LPG: Rp xxx.xxx
3. Input ke expenses:
   INSERT INTO expenses (amount, category, fiscal_period, ...)
   VALUES (xxx, 'kitchen_overhead', '2026-04', ...)
   -- 2–4 baris saja, bukan per item pembelian
4. Selesai — laporan L/R otomatis menampilkan di blok HPP
```

**Target kitchen overhead yang sehat:** 8–15% dari revenue bulanan.
Jika di atas 15%, investigasi: kemungkinan boros minyak atau
harga bahan overhead naik signifikan.

---

### 8.8 Food Cost % — Target Realistis

```
Food cost % per menu (Kat. A saja)  → v_menu_cogs.food_cost_pct_recipe_only
Food cost % total (dengan overhead) → v_monthly_resto_finance.hpp_pct
```

**Target industri restoran Indonesia:**

| Komponen | Target |
|---|---|
| HPP Kat. A (bahan utama) | 20–30% dari harga jual |
| Kitchen overhead (Kat. B) | 8–15% dari revenue bulanan |
| HPP Total (A + B + Waste) | 28–40% dari revenue |
| Gross Profit | 60–72% |
| Net Profit (setelah semua OpEx) | 10–20% (restoran kecil rapi) |

**Menu yang perlu direview jika food cost Kat. A > 40%:**
- Naikan harga jual, atau
- Revisi resep (kurangi qty bahan utama), atau
- Hapus menu dari daftar

**Menu favorit cash cow:** food cost Kat. A 15–25% + laku banyak =
prioritaskan promosi menu ini.

---

### 8.9 Checklist Bulanan (Semua Dalam 1 Jam)

```
□ Semua purchase Kat. A bulan ini sudah di-confirm?
□ Semua opname harian sudah di-confirm?
□ Settlement GrabFood/GoFood bulan ini sudah diinput + confirm?
□ Waste manual yang dicatat secara fisik sudah diinput?
□ Kitchen overhead (minyak + bumbu + gas) sudah diinput?
□ Gaji, listrik, sewa sudah diinput ke expenses?
□ Buka v_monthly_resto_finance → baca net_profit
□ Bandingkan hpp_pct dengan bulan lalu — naik/turun kenapa?
□ Cek v_menu_performance → menu mana yang paling untung bulan ini?
□ Set target bulan depan: menu apa yang perlu dipush?
```

Jika semua checklist rutin dijalankan, laporan L/R dapat dipercaya
dan keputusan bisnis bisa dibuat dengan data, bukan perasaan.

---

*Dokumen terkait: [resto-finance-1.md](./resto-finance-1.md) | [alur-resto-1.md](./alur-resto-1.md) | [simplifikasi-1.md](./simplifikasi-1.md)*
