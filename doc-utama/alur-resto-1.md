# 📊 Alur Data → Laporan Laba Rugi Restoran

> **Tujuan dokumen ini:** Menjelaskan secara detail bagaimana setiap baris
> di Laporan L/R terbentuk — dari mana datanya, siapa yang input, dan
> tabel/kolom mana yang menjadi sumbernya.

---

## Target Laporan

```
LAPORAN LABA RUGI — APRIL 2026
Restaurant: Fast-Resto
Period    : 2026-04
───────────────────────────────────────────────────────
PENDAPATAN BRUTO
  Dine-in / Takeaway              Rp   8.500.000
  GrabFood (gross)                Rp   3.200.000
  GoFood (gross)                  Rp   1.800.000
                                  ──────────────
  Total Revenue                   Rp  13.500.000

HARGA POKOK PENJUALAN (HPP)
  Food cost (dari resep)          Rp   4.200.000   (31.1%)
  Kitchen overhead (Kat. B)       Rp   1.450.000   (10.7%)
  Waste & spoilage                Rp     320.000    (2.4%)
                                  ──────────────
  Total HPP                       Rp   5.970.000   (44.2%)

GROSS PROFIT                      Rp   7.530.000   (55.8%)

BEBAN OPERASIONAL
  Gaji karyawan                   Rp   3.500.000
  Listrik & air                   Rp     450.000
  Komisi GrabFood                 Rp     640.000   (20% × 3.200.000)
  Komisi GoFood                   Rp     360.000   (20% × 1.800.000)
  Sewa tempat                     Rp   2.000.000
  Lain-lain                       Rp     200.000
                                  ──────────────
  Total Beban Operasional         Rp   7.150.000

NET PROFIT                        Rp     380.000    (2.8%)
───────────────────────────────────────────────────────
```

---

## Bagian 1 — Peta Setiap Baris ke Sumber Data

Ini adalah peta paling penting. Sebelum nulis satu baris SQL pun,
kamu harus tahu persis: **"baris ini dari tabel mana, kolom mana, filter apa?"**

```
┌─────────────────────────────────┬──────────────────────────────────────────────────────┐
│ Baris di Laporan                │ Sumber Data                                          │
├─────────────────────────────────┼──────────────────────────────────────────────────────┤
│ Revenue Dine-in/Takeaway        │ incomes JOIN payments JOIN orders                    │
│                                 │ WHERE orders.channel IN ('dine_in','takeaway')        │
│                                 │ AND incomes.fiscal_period = '2026-04'                │
│                                 │ AND incomes.is_active = TRUE                         │
├─────────────────────────────────┼──────────────────────────────────────────────────────┤
│ Revenue GrabFood (gross)        │ incomes JOIN payments JOIN orders                    │
│                                 │ WHERE orders.channel = 'grabfood'                    │
├─────────────────────────────────┼──────────────────────────────────────────────────────┤
│ Revenue GoFood (gross)          │ incomes JOIN payments JOIN orders                    │
│                                 │ WHERE orders.channel = 'gofood'                      │
├─────────────────────────────────┼──────────────────────────────────────────────────────┤
│ HPP - Food cost (dari resep)    │ SUM(order_items.theoretical_cogs)                    │
│                                 │ WHERE orders.status = 'completed'                    │
│                                 │ AND fiscal_period(orders.completed_at) = '2026-04'   │
├─────────────────────────────────┼──────────────────────────────────────────────────────┤
│ HPP - Kitchen overhead (Kat. B) │ expenses WHERE category = 'kitchen_overhead'         │
│                                 │ AND fiscal_period = '2026-04'                        │
├─────────────────────────────────┼──────────────────────────────────────────────────────┤
│ HPP - Waste & spoilage          │ expenses                                             │
│                                 │ WHERE category IN ('food_waste','inventory_loss')     │
│                                 │ AND fiscal_period = '2026-04'                        │
├─────────────────────────────────┼──────────────────────────────────────────────────────┤
│ Beban - Gaji karyawan           │ expenses WHERE category = 'salary'                   │
├─────────────────────────────────┼──────────────────────────────────────────────────────┤
│ Beban - Listrik & air           │ expenses WHERE category = 'utility'                  │
├─────────────────────────────────┼──────────────────────────────────────────────────────┤
│ Beban - Komisi GrabFood         │ expenses WHERE category = 'platform_fee'             │
│                                 │ AND reference_platform = 'grabfood'                  │
├─────────────────────────────────┼──────────────────────────────────────────────────────┤
│ Beban - Komisi GoFood           │ expenses WHERE category = 'platform_fee'             │
│                                 │ AND reference_platform = 'gofood'                    │
├─────────────────────────────────┼──────────────────────────────────────────────────────┤
│ Beban - Sewa tempat             │ expenses WHERE category = 'rent'                     │
├─────────────────────────────────┼──────────────────────────────────────────────────────┤
│ Beban - Lain-lain               │ expenses WHERE category = 'other'                    │
└─────────────────────────────────┴──────────────────────────────────────────────────────┘
```

---

## Bagian 2 — Tabel yang Dibutuhkan (Tambahan dari resto-finance-1.md)

### 2.1 Tabel `incomes` (Finance Layer)

Setiap pembayaran yang dikonfirmasi menghasilkan satu baris di `incomes`.
Ini adalah **single source of truth** untuk revenue.

```sql
CREATE TABLE incomes (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id   UUID NOT NULL REFERENCES restaurants(id),
    -- Link ke payment yang menghasilkan income ini
    reference_type  VARCHAR(30) NOT NULL DEFAULT 'payment',
    reference_id    UUID NOT NULL,           -- payment.id
    amount          NUMERIC(14,2) NOT NULL,  -- sama dengan payment.amount
    fiscal_period   VARCHAR(7) NOT NULL,     -- 'YYYY-MM' dari confirmed_at
    income_date     DATE NOT NULL,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    notes           TEXT,
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_incomes_period    ON incomes(restaurant_id, fiscal_period) WHERE is_active = TRUE;
CREATE INDEX idx_incomes_reference ON incomes(reference_id, reference_type);
```

### 2.2 Tabel `expenses` (Finance Layer) — Dengan Kategori Lengkap

Semua pengeluaran masuk ke sini. Kategori harus konsisten karena laporan
bergantung pada nilai `category` untuk memisahkan baris.

```sql
CREATE TYPE expense_category AS ENUM (
    -- HPP (masuk ke blok HPP di laporan, bukan OpEx)
    'food_waste',        -- bahan dibuang manual (tumpah, expired sebelum opname)
    'inventory_loss',    -- loss terdeteksi dari stock opname
    'kitchen_overhead',  -- bahan B: minyak, bumbu, gas LPG, dll (dicatat bulanan)

    -- Beban Operasional
    'salary',            -- gaji semua karyawan
    'utility',           -- listrik, air, gas, internet
    'rent',              -- sewa tempat / cicilan
    'platform_fee',      -- komisi GrabFood, GoFood, dll
    'maintenance',       -- perbaikan peralatan
    'marketing',         -- promosi, iklan
    'packaging',         -- dus, kantong, sedotan (yang tidak masuk resep)
    'refund',            -- uang dikembalikan ke tamu
    'other'              -- pengeluaran lain-lain
);

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

CREATE INDEX idx_expenses_period   ON expenses(restaurant_id, fiscal_period) WHERE is_active = TRUE;
CREATE INDEX idx_expenses_category ON expenses(restaurant_id, category, fiscal_period);
```

**Aturan input kategori (harus dipatuhi agar laporan akurat):**

| Kejadian | category | reference_platform |
|---|---|---|
| Gaji bulan April dibayar | `salary` | NULL |
| Tagihan listrik April | `utility` | NULL |
| Bayar sewa April | `rent` | NULL |
| Settlement GrabFood (komisi) | `platform_fee` | `grabfood` |
| Settlement GoFood (komisi) | `platform_fee` | `gofood` |
| Bahan tumpah / busuk | `food_waste` | NULL |
| Loss dari stock opname | `inventory_loss` | NULL |
| Minyak/bumbu/gas (akhir bulan) | `kitchen_overhead` | NULL |
| Refund tamu | `refund` | NULL |
| Beli sabun cuci piring | `other` | NULL |

---

## Bagian 3 — Alur Lengkap Per Jenis Transaksi

### 3.1 Alur Order Dine-in / Takeaway

```
[1] KASIR buka shift
        ↓
    INSERT kasir_shifts (opening_cash = 200.000)
    ↳ shift.status = 'open'

[2] TAMU pesan (kasir input)
        ↓
    INSERT orders (channel='dine_in', status='open')
    INSERT order_items (menu_id, qty, unit_price, ...)
    ↳ stok BELUM berkurang (masih 'open')

[3] KASIR klik "Selesai / Complete Order"
        ↓
    CALL complete_order(order_id, user_id)
    ↳ Untuk setiap item × resep:
       UPDATE ingredients SET current_stock -= (qty × qty_per_portion / yield_factor)
       INSERT stock_movements (type='sale', qty=-xxx, cost_per_unit=avg_cost)
       UPDATE order_items SET theoretical_cogs = dihitung dari resep
    ↳ UPDATE orders SET status='completed', completed_at=NOW()

[4] KASIR terima pembayaran
        ↓
    INSERT payments (order_id, amount, method='cash'/'qris', status='pending')

[5] KASIR konfirmasi bayar
        ↓
    CALL confirm_payment(payment_id, user_id)
    ↳ UPDATE payments SET status='confirmed', confirmed_at=NOW()
    ↳ UPDATE orders SET status='paid'
    ↳ INSERT incomes (
           restaurant_id,
           reference_type = 'payment',
           reference_id   = payment.id,
           amount         = payment.amount,
           fiscal_period  = '2026-04',   ← dari confirmed_at
           income_date    = tanggal hari ini,
           is_active      = TRUE
       )

[6] MALAM — Kasir tutup shift
        ↓
    Input actual_cash (hitung fisik laci)
    CALL close_shift(shift_id, actual_cash, user_id)
    ↳ expected_cash = opening_cash + SUM(cash payments selama shift)
    ↳ cash_variance = actual_cash - expected_cash
    ↳ UPDATE kasir_shifts SET status='closed', closed_at=NOW()
    ↳ Jika variance ≠ 0 → tampil alert ke owner

KONTRIBUSI KE LAPORAN L/R:
  Revenue Dine-in += payment.amount (via incomes)
  HPP Food cost   += SUM(order_items.theoretical_cogs)
```

---

### 3.2 Alur Order GrabFood (Channel Delivery)

GrabFood punya dua tahap: **order harian** dan **settlement mingguan**.
Keduanya harus dicatat terpisah.

```
[TAHAP A — SETIAP ORDER MASUK]

[1] Order masuk dari GrabFood (kasir input atau auto-sync)
        ↓
    INSERT orders (
        channel          = 'grabfood',
        platform_order_id = 'GF-20260405-XXXXX',  ← nomor dari GrabFood
        status           = 'open'
    )
    INSERT order_items (menu dan qty sesuai order)

[2] Siapkan pesanan → Kasir klik Complete
        ↓
    CALL complete_order(order_id, user_id)
    ↳ Stok berkurang otomatis (sama seperti dine-in)
    ↳ theoretical_cogs terhitung

[3] Konfirmasi penerimaan order (uang BELUM masuk rekening)
        ↓
    INSERT payments (
        order_id  = order.id,
        amount    = harga_menu_bruto,    ← BRUTO, bukan net
        method    = 'grabfood_settlement',
        status    = 'confirmed'          ← langsung confirmed (tidak ada pending)
    )
    ↳ INSERT incomes (amount = harga_bruto, fiscal_period='2026-04')

    CATATAN PENTING:
    Pada tahap ini, income sudah tercatat BRUTO.
    Uang fisik belum masuk rekening. Yang akan datang adalah net settlement.
    Ini adalah akrual parsial — kita acknowledge revenue saat order completed.

[TAHAP B — SETTLEMENT MINGGUAN]

[4] Tiap Minggu: GrabFood kirim laporan + transfer net ke rekening
        ↓
    Input delivery_platform_batches:
    INSERT delivery_platform_batches (
        platform     = 'grabfood',
        period_start = '2026-04-01',
        period_end   = '2026-04-07',
        gross_sales  = 800.000,     ← total order 1-7 April dari GrabFood
        platform_fee = 160.000,     ← komisi 20%
        net_settlement = 640.000    ← yang ditransfer ke rekening (generated)
    )

[5] Konfirmasi settlement (uang sudah masuk rekening)
        ↓
    CALL confirm_platform_settlement(batch_id, user_id)
    ↳ INSERT expenses (
           category           = 'platform_fee',
           reference_platform = 'grabfood',
           reference_type     = 'platform_batch',
           reference_id       = batch.id,
           amount             = batch.platform_fee,   ← 160.000
           fiscal_period      = '2026-04'
       )
    ↳ UPDATE delivery_platform_batches SET is_reconciled=TRUE

KONTRIBUSI KE LAPORAN L/R:
  Revenue GrabFood (gross) += SUM(incomes)      ← dari Tahap A
  Beban Komisi GrabFood    += SUM(expenses)     ← dari Tahap B
  
  Catatan: Net ke rekening = Gross - Komisi = 3.200.000 - 640.000 = 2.560.000
           Tapi di laporan, keduanya ditampilkan terpisah agar omzet terlihat jelas.
```

**DB Function confirm_platform_settlement:**

```sql
CREATE OR REPLACE FUNCTION confirm_platform_settlement(
    p_batch_id  UUID,
    p_user_id   UUID
) RETURNS VOID AS $$
DECLARE
    v_batch         delivery_platform_batches%ROWTYPE;
BEGIN
    SELECT * INTO v_batch FROM delivery_platform_batches WHERE id = p_batch_id;

    IF v_batch.is_reconciled THEN
        RAISE EXCEPTION 'Batch % sudah direkonsiliasi sebelumnya', p_batch_id;
    END IF;

    -- Catat komisi sebagai expense
    INSERT INTO expenses (
        restaurant_id, amount, category,
        reference_platform, reference_type, reference_id,
        fiscal_period, expense_date,
        description, created_by
    ) VALUES (
        v_batch.restaurant_id,
        v_batch.platform_fee,
        'platform_fee',
        v_batch.platform::TEXT,        -- 'grabfood' / 'gofood'
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

### 3.3 Alur Input Beban Operasional Manual

Beban yang tidak timbul dari transaksi otomatis (gaji, sewa, listrik)
harus diinput manual oleh owner/admin.

```
[GAJI KARYAWAN — input awal bulan berikutnya atau akhir bulan]

    INSERT expenses (
        restaurant_id = ...,
        amount        = 3.500.000,
        category      = 'salary',
        fiscal_period = '2026-04',      ← periode yang digaji, bukan kapan dibayar
        expense_date  = '2026-04-30',
        description   = 'Gaji karyawan April 2026 (3 orang)',
        created_by    = owner_user_id
    )

[LISTRIK & AIR — saat tagihan datang]

    INSERT expenses (
        amount      = 450.000,
        category    = 'utility',
        fiscal_period = '2026-04',
        description = 'Tagihan PLN + PDAM April 2026'
    )

[SEWA TEMPAT — saat bayar]

    INSERT expenses (
        amount      = 2.000.000,
        category    = 'rent',
        fiscal_period = '2026-04',
        description = 'Sewa ruko April 2026'
    )

[LAIN-LAIN]

    INSERT expenses (
        amount      = 200.000,
        category    = 'other',
        fiscal_period = '2026-04',
        description = 'Sabun cuci, plastik wrap, dll'
    )

[KITCHEN OVERHEAD — input akhir bulan (Kategori B)]

    -- Bahan overhead dapur (minyak, bumbu, gas) dipakai bersama semua menu.
    -- TIDAK masuk resep per-porsi, dicatat agregatif akhir bulan.
    -- Masuk ke blok HPP di laporan, bukan Beban Operasional.

    INSERT expenses (
        amount      = 850.000,
        category    = 'kitchen_overhead',
        fiscal_period = '2026-04',
        expense_date  = '2026-04-30',
        description = 'Minyak goreng April: 25 liter × Rp 34.000'
    )

    INSERT expenses (
        amount      = 420.000,
        category    = 'kitchen_overhead',
        fiscal_period = '2026-04',
        expense_date  = '2026-04-30',
        description = 'Bumbu dasar April: bawang, cabai, rempah, kecap, dll'
    )

    INSERT expenses (
        amount      = 180.000,
        category    = 'kitchen_overhead',
        fiscal_period = '2026-04',
        expense_date  = '2026-04-30',
        description = 'Gas LPG April: 3 tabung 12kg × Rp 60.000'
    )
```

---

### 3.4 Alur HPP — Food Waste & Inventory Loss

```
[FOOD WASTE — input manual saat bahan dibuang]

Contoh: minyak goreng tumpah 500ml (Rp 7.500)
    ↓
    INSERT waste_logs (ingredient_id, qty, cost_per_unit, reason, created_by)

    CALL log_waste(ingredient_id, qty=500, reason='Tumpah saat goreng', user_id)
    ↳ UPDATE ingredients SET current_stock -= 500ml
    ↳ INSERT stock_movements (type='waste', qty=-500, cost_per_unit=15)
    ↳ INSERT expenses (
           category      = 'food_waste',
           amount        = 500 × 15 = 7.500,
           fiscal_period = '2026-04',
           description   = 'Waste: minyak goreng 500ml — Tumpah saat goreng'
       )

[INVENTORY LOSS — otomatis dari stock opname]

Contoh: opname malam, ayam teoritis 3.800g tapi fisik 3.400g
    ↓
    Input stock_opname_items: actual_qty = 3.400
    ↳ variance = 3.400 - 3.800 = -400g (LOSS)

    CALL confirm_opname(opname_id, user_id)
    ↳ UPDATE ingredients SET current_stock = 3.400  ← koreksi ke fisik
    ↳ INSERT stock_movements (type='opname_adj', qty=-400, cost_per_unit=35)
    ↳ INSERT expenses (
           category      = 'inventory_loss',
           amount        = 400 × 35 = 14.000,
           fiscal_period = '2026-04',
           description   = 'Inventory loss opname 5 Apr 2026: ayam -400g'
       )

KONTRIBUSI KE LAPORAN L/R:
  Waste & spoilage = SUM(expenses WHERE category IN ('food_waste','inventory_loss'))
```

---

## Bagian 4 — SQL View Laporan L/R Final

Ini view yang menghasilkan tepat seperti format laporan di atas.

```sql
CREATE OR REPLACE FUNCTION get_monthly_pl_report(
    p_restaurant_id UUID,
    p_period        VARCHAR(7)   -- format 'YYYY-MM'
)
RETURNS TABLE (
    line_group      TEXT,
    line_label      TEXT,
    amount          NUMERIC,
    pct_of_revenue  NUMERIC
) AS $$
DECLARE
    v_total_revenue NUMERIC;
BEGIN
    -- Hitung total revenue dulu untuk kalkulasi persen
    SELECT COALESCE(SUM(i.amount), 0) INTO v_total_revenue
    FROM incomes i
    WHERE i.restaurant_id = p_restaurant_id
      AND i.fiscal_period  = p_period
      AND i.is_active      = TRUE;

    RETURN QUERY

    -- ── REVENUE ────────────────────────────────────────────────
    SELECT
        'revenue'::TEXT,
        'Dine-in / Takeaway'::TEXT,
        COALESCE(SUM(i.amount), 0),
        ROUND(COALESCE(SUM(i.amount), 0) / NULLIF(v_total_revenue,0) * 100, 1)
    FROM incomes i
    JOIN payments p ON p.id = i.reference_id AND i.reference_type = 'payment'
    JOIN orders   o ON o.id = p.order_id
    WHERE i.restaurant_id = p_restaurant_id
      AND i.fiscal_period  = p_period
      AND i.is_active      = TRUE
      AND o.channel IN ('dine_in', 'takeaway')

    UNION ALL

    SELECT 'revenue', 'GrabFood (gross)',
        COALESCE(SUM(i.amount), 0),
        ROUND(COALESCE(SUM(i.amount), 0) / NULLIF(v_total_revenue,0) * 100, 1)
    FROM incomes i
    JOIN payments p ON p.id = i.reference_id AND i.reference_type = 'payment'
    JOIN orders   o ON o.id = p.order_id
    WHERE i.restaurant_id = p_restaurant_id
      AND i.fiscal_period  = p_period
      AND i.is_active      = TRUE
      AND o.channel = 'grabfood'

    UNION ALL

    SELECT 'revenue', 'GoFood (gross)',
        COALESCE(SUM(i.amount), 0),
        ROUND(COALESCE(SUM(i.amount), 0) / NULLIF(v_total_revenue,0) * 100, 1)
    FROM incomes i
    JOIN payments p ON p.id = i.reference_id AND i.reference_type = 'payment'
    JOIN orders   o ON o.id = p.order_id
    WHERE i.restaurant_id = p_restaurant_id
      AND i.fiscal_period  = p_period
      AND i.is_active      = TRUE
      AND o.channel = 'gofood'

    UNION ALL
    SELECT 'revenue_total', 'Total Revenue',
        v_total_revenue,
        100.0

    -- ── HPP ────────────────────────────────────────────────────
    UNION ALL

    SELECT 'hpp', 'Food cost (dari resep)',
        COALESCE(SUM(oi.theoretical_cogs), 0),
        ROUND(COALESCE(SUM(oi.theoretical_cogs), 0) / NULLIF(v_total_revenue,0) * 100, 1)
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    WHERE o.restaurant_id = p_restaurant_id
      AND o.status         = 'completed'
      AND TO_CHAR(o.completed_at, 'YYYY-MM') = p_period

    UNION ALL

    SELECT 'hpp', 'Waste & spoilage',
        COALESCE(SUM(e.amount), 0),
        ROUND(COALESCE(SUM(e.amount), 0) / NULLIF(v_total_revenue,0) * 100, 1)
    FROM expenses e
    WHERE e.restaurant_id = p_restaurant_id
      AND e.fiscal_period  = p_period
      AND e.is_active       = TRUE
      AND e.category IN ('food_waste', 'inventory_loss')

    UNION ALL

    SELECT 'hpp', 'Kitchen overhead (Kat. B)',
        COALESCE(SUM(e.amount), 0),
        ROUND(COALESCE(SUM(e.amount), 0) / NULLIF(v_total_revenue,0) * 100, 1)
    FROM expenses e
    WHERE e.restaurant_id = p_restaurant_id
      AND e.fiscal_period  = p_period
      AND e.is_active       = TRUE
      AND e.category = 'kitchen_overhead'

    UNION ALL
    SELECT 'hpp_total', 'Total HPP',
        COALESCE((
            SELECT SUM(oi2.theoretical_cogs)
            FROM orders o2 JOIN order_items oi2 ON oi2.order_id = o2.id
            WHERE o2.restaurant_id = p_restaurant_id
              AND o2.status = 'completed'
              AND TO_CHAR(o2.completed_at, 'YYYY-MM') = p_period
        ), 0)
        +
        COALESCE((
            SELECT SUM(e2.amount)
            FROM expenses e2
            WHERE e2.restaurant_id = p_restaurant_id
              AND e2.fiscal_period = p_period
              AND e2.is_active = TRUE
              AND e2.category IN ('food_waste','inventory_loss')
        ), 0)
        +
        COALESCE((
            SELECT SUM(e3.amount)
            FROM expenses e3
            WHERE e3.restaurant_id = p_restaurant_id
              AND e3.fiscal_period = p_period
              AND e3.is_active = TRUE
              AND e3.category = 'kitchen_overhead'
        ), 0),
        NULL

    -- ── BEBAN OPERASIONAL ───────────────────────────────────────
    UNION ALL

    SELECT 'opex', 'Gaji karyawan',
        COALESCE(SUM(e.amount), 0), NULL
    FROM expenses e
    WHERE e.restaurant_id = p_restaurant_id AND e.fiscal_period = p_period
      AND e.is_active = TRUE AND e.category = 'salary'

    UNION ALL

    SELECT 'opex', 'Listrik & air',
        COALESCE(SUM(e.amount), 0), NULL
    FROM expenses e
    WHERE e.restaurant_id = p_restaurant_id AND e.fiscal_period = p_period
      AND e.is_active = TRUE AND e.category = 'utility'

    UNION ALL

    SELECT 'opex', 'Komisi GrabFood',
        COALESCE(SUM(e.amount), 0), NULL
    FROM expenses e
    WHERE e.restaurant_id = p_restaurant_id AND e.fiscal_period = p_period
      AND e.is_active = TRUE AND e.category = 'platform_fee'
      AND e.reference_platform = 'grabfood'

    UNION ALL

    SELECT 'opex', 'Komisi GoFood',
        COALESCE(SUM(e.amount), 0), NULL
    FROM expenses e
    WHERE e.restaurant_id = p_restaurant_id AND e.fiscal_period = p_period
      AND e.is_active = TRUE AND e.category = 'platform_fee'
      AND e.reference_platform = 'gofood'

    UNION ALL

    SELECT 'opex', 'Sewa tempat',
        COALESCE(SUM(e.amount), 0), NULL
    FROM expenses e
    WHERE e.restaurant_id = p_restaurant_id AND e.fiscal_period = p_period
      AND e.is_active = TRUE AND e.category = 'rent'

    UNION ALL

    SELECT 'opex', 'Lain-lain',
        COALESCE(SUM(e.amount), 0), NULL
    FROM expenses e
    WHERE e.restaurant_id = p_restaurant_id AND e.fiscal_period = p_period
      AND e.is_active = TRUE
      AND e.category IN ('marketing','maintenance','packaging','other')

    UNION ALL
    SELECT 'opex_total', 'Total Beban Operasional',
        COALESCE(SUM(e.amount), 0), NULL
    FROM expenses e
    WHERE e.restaurant_id = p_restaurant_id AND e.fiscal_period = p_period
      AND e.is_active = TRUE
      AND e.category NOT IN ('food_waste','inventory_loss','kitchen_overhead','refund')

    -- ── NET PROFIT ──────────────────────────────────────────────
    UNION ALL

    SELECT 'net_profit', 'NET PROFIT', (
        v_total_revenue
        - COALESCE((
            SELECT SUM(oi2.theoretical_cogs)
            FROM orders o2 JOIN order_items oi2 ON oi2.order_id = o2.id
            WHERE o2.restaurant_id = p_restaurant_id AND o2.status = 'completed'
              AND TO_CHAR(o2.completed_at, 'YYYY-MM') = p_period
          ), 0)
        - COALESCE((
            SELECT SUM(e2.amount) FROM expenses e2
            WHERE e2.restaurant_id = p_restaurant_id AND e2.fiscal_period = p_period
              AND e2.is_active = TRUE
              AND e2.category IN ('food_waste','inventory_loss','kitchen_overhead')
          ), 0)
        - COALESCE((
            SELECT SUM(e3.amount) FROM expenses e3
            WHERE e3.restaurant_id = p_restaurant_id AND e3.fiscal_period = p_period
              AND e3.is_active = TRUE
              AND e3.category NOT IN ('food_waste','inventory_loss','kitchen_overhead','refund')
          ), 0)
    ),
    ROUND((
        v_total_revenue
        - (SELECT COALESCE(SUM(oi2.theoretical_cogs),0)
           FROM orders o2 JOIN order_items oi2 ON oi2.order_id=o2.id
           WHERE o2.restaurant_id=p_restaurant_id AND o2.status='completed'
             AND TO_CHAR(o2.completed_at,'YYYY-MM')=p_period)
        - (SELECT COALESCE(SUM(e2.amount),0) FROM expenses e2
           WHERE e2.restaurant_id=p_restaurant_id AND e2.fiscal_period=p_period
             AND e2.is_active=TRUE
             AND e2.category IN ('food_waste','inventory_loss','kitchen_overhead'))
        - (SELECT COALESCE(SUM(e3.amount),0) FROM expenses e3
           WHERE e3.restaurant_id=p_restaurant_id AND e3.fiscal_period=p_period
             AND e3.is_active=TRUE
             AND e3.category NOT IN ('food_waste','inventory_loss','kitchen_overhead','refund'))
    ) / NULLIF(v_total_revenue,0) * 100, 1);

END;
$$ LANGUAGE plpgsql;
```

**Cara pakai:**
```sql
SELECT * FROM get_monthly_pl_report(
    'uuid-restaurant',
    '2026-04'
);
```

**Output:**
```
line_group    | line_label               | amount      | pct_of_revenue
──────────────┼──────────────────────────┼─────────────┼────────────────
revenue       | Dine-in / Takeaway       | 8500000.00  | 63.0
revenue       | GrabFood (gross)         | 3200000.00  | 23.7
revenue       | GoFood (gross)           | 1800000.00  | 13.3
revenue_total | Total Revenue            | 13500000.00 | 100.0
hpp           | Food cost (dari resep)   | 4200000.00  | 31.1
hpp           | Kitchen overhead (Kat. B)| 1450000.00  | 10.7
hpp           | Waste & spoilage         | 320000.00   | 2.4
hpp_total     | Total HPP               | 5970000.00  | 44.2
opex          | Gaji karyawan            | 3500000.00  |
opex          | Listrik & air            | 450000.00   |
opex          | Komisi GrabFood          | 640000.00   |
opex          | Komisi GoFood            | 360000.00   |
opex          | Sewa tempat              | 2000000.00  |
opex          | Lain-lain                | 200000.00   |
opex_total    | Total Beban Operasional  | 7150000.00  |
net_profit    | NET PROFIT               | 380000.00   | 2.8
```

---

## Bagian 5 — Checklist Bulanan Agar Laporan Akurat

Laporan bulan April hanya akurat jika semua item berikut sudah diinput
sebelum laporan ditarik (idealnya sebelum tutup buku tanggal 1 Mei):

```
CHECKLIST APRIL 2026
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
REVENUE
  [ ] Semua order dine-in/takeaway sudah confirmed payment
  [ ] Semua order GrabFood sudah confirmed (gross amount)
  [ ] Semua order GoFood sudah confirmed (gross amount)
  [ ] Tidak ada order status 'open' yang tertinggal dari April

HPP
  [ ] Stock opname terakhir April sudah confirmed
      → inventory_loss expense sudah terbuat
  [ ] Semua waste manual sudah diinput
      → food_waste expense sudah terbuat
  [ ] Kitchen overhead (minyak, bumbu, gas) sudah diinput akhir bulan
      → kitchen_overhead expense sudah terbuat (Kategori B)

PLATFORM FEE
  [ ] Settlement GrabFood minggu 1 April → confirmed (expense platform_fee)
  [ ] Settlement GrabFood minggu 2 April → confirmed
  [ ] Settlement GrabFood minggu 3 April → confirmed
  [ ] Settlement GrabFood minggu 4 April → confirmed
  [ ] (Sama untuk GoFood)
  Cek: SUM(komisi grabfood) harus ≈ 20% × revenue grabfood

BEBAN OPERASIONAL
  [ ] Gaji April sudah diinput (category=salary)
  [ ] Tagihan listrik/air sudah diinput (category=utility)
  [ ] Sewa April sudah diinput (category=rent)
  [ ] Pengeluaran lain sudah diinput

TUTUP BUKU
  [ ] Semua item di atas selesai
  [ ] Tarik laporan, verifikasi angka masuk akal
  [ ] CALL close_fiscal_period(restaurant_id, '2026-04', user_id)
      → Setelah ini tidak bisa input transaksi ke April lagi
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Bagian 6 — Rekonsiliasi: Deteksi Kebocoran Data

Sebelum tutup buku, Owner perlu cek tiga rekonsiliasi ini:

### Rekonsiliasi 1: Revenue vs Order

```sql
-- Harus sama: total revenue dari incomes = total order yang completed
SELECT
    SUM(i.amount)          AS total_incomes,
    SUM(o.total)           AS total_orders_completed,
    SUM(i.amount) - SUM(o.total) AS selisih  -- harus 0
FROM incomes i
JOIN payments p ON p.id = i.reference_id
JOIN orders   o ON o.id = p.order_id
WHERE i.restaurant_id = '<id>'
  AND i.fiscal_period  = '2026-04'
  AND i.is_active      = TRUE;
```

### Rekonsiliasi 2: GrabFood — Order vs Settlement

```sql
-- Total order grabfood di sistem vs gross_sales di batch
SELECT
    (SELECT SUM(i.amount)
     FROM incomes i JOIN payments p ON p.id=i.reference_id
     JOIN orders o ON o.id=p.order_id
     WHERE o.channel='grabfood' AND i.fiscal_period='2026-04'
       AND i.is_active=TRUE)          AS sistem_gross,

    (SELECT SUM(gross_sales)
     FROM delivery_platform_batches
     WHERE platform='grabfood'
       AND TO_CHAR(period_end,'YYYY-MM')='2026-04')
                                       AS batch_gross,

    -- Harus 0 atau sangat kecil (beda karena cut-off akhir bulan)
    (SELECT SUM(i.amount) FROM incomes i JOIN payments p ON p.id=i.reference_id
     JOIN orders o ON o.id=p.order_id WHERE o.channel='grabfood'
       AND i.fiscal_period='2026-04' AND i.is_active=TRUE)
    -
    (SELECT SUM(gross_sales) FROM delivery_platform_batches
     WHERE platform='grabfood' AND TO_CHAR(period_end,'YYYY-MM')='2026-04')
                                       AS selisih;
```

### Rekonsiliasi 3: Food Cost vs Pembelian Bahan

```sql
-- Sanity check: total pembelian bahan bulan ini
-- Harus lebih besar dari food cost (karena ada sisa stok)
SELECT
    (SELECT SUM(pi.subtotal) FROM purchase_items pi
     JOIN purchases pu ON pu.id=pi.purchase_id
     WHERE pu.restaurant_id='<id>'
       AND TO_CHAR(pu.purchase_date,'YYYY-MM')='2026-04'
       AND pu.status IN ('received','paid'))    AS total_beli,

    (SELECT SUM(oi.theoretical_cogs) FROM order_items oi
     JOIN orders o ON o.id=oi.order_id
     WHERE o.restaurant_id='<id>' AND o.status='completed'
       AND TO_CHAR(o.completed_at,'YYYY-MM')='2026-04') AS total_food_cost,

    -- jika total_beli < total_food_cost → ada bahan yang tidak diinput pembeliannya!
    (SELECT SUM(pi.subtotal) FROM purchase_items pi
     JOIN purchases pu ON pu.id=pi.purchase_id
     WHERE pu.restaurant_id='<id>'
       AND TO_CHAR(pu.purchase_date,'YYYY-MM')='2026-04'
       AND pu.status IN ('received','paid'))
    -
    (SELECT SUM(oi.theoretical_cogs) FROM order_items oi
     JOIN orders o ON o.id=oi.order_id
     WHERE o.restaurant_id='<id>' AND o.status='completed'
       AND TO_CHAR(o.completed_at,'YYYY-MM')='2026-04')  AS selisih_beli_vs_cogs;
-- Positif = masih ada stok sisa (normal)
-- Negatif = ada bahan dipakai tapi pembeliannya tidak tercatat (alarm!)
```
