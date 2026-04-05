# 📘 Level 2 — Credit & Receivables: Panduan Lengkap

> **Proyek referensi:** Aplikasi Manajemen Kos
> **Durasi estimasi:** 3–4 minggu
> **Prasyarat:** Level 1 selesai 100% — kamu harus bisa menjawab semua checklist Level 1 tanpa melihat catatan
> **Yang kamu butuhkan:** PostgreSQL, Python/FastAPI, pytest

---

## Sebelum Mulai: Apa Bedanya Level 2 dengan Level 1?

Di Level 1, semua transaksi **tunai langsung**:
- Pasien datang → bayar → kwitansi → selesai
- Income langsung terbukukan saat uang masuk

Di Level 2, kamu akan menghadapi sesuatu yang jauh lebih umum di dunia nyata:

> **Kewajiban yang ditunda, dan pendapatan yang belum cair.**

Dua konsep inti Level 2:

```
KONSEP 1: DEPOSIT = KEWAJIBAN (bukan income!)
  Penghuni bayar Rp 1.500.000 deposit saat check-in.
  Uang ini masuk ke rekeningmu... tapi bukan milikmu.
  Kamu WAJIB mengembalikannya kalau tidak ada kerusakan.
  → Di neraca: adalah hutang (liability), bukan pendapatan.

KONSEP 2: ACCRUAL = TAGIHAN DULU, BAYAR NANTI
  Tanggal 1 April kamu buat tagihan sewa untuk semua penghuni.
  Tapi mereka baru bayar tanggal 5, 7, 10, bahkan ada yang terlambat.
  → Income sudah "ada" sejak 1 April (saat tagihan dibuat)?
    Atau baru ada saat uang masuk?
  → Di cash basis (Level 1): income saat uang masuk.
  → Di accrual basis (Level 2): income saat hak tagih timbul (= saat tagihan dibuat).
```

Ini bukan sekadar teori. Kalau kamu salah mendesain ini, aplikasi kosmu akan:
- Melaporkan deposit sebagai income → laporan profit membesar palsu
- Tidak bisa tahu siapa yang belum bayar sewa bulan ini
- Tidak bisa hitung berapa total piutang outstanding
- Tidak bisa generate reminder otomatis ke penghuni telat bayar

---

## Peta Modul Level 2

```
Modul 2.1 — Deposit (Kewajiban): 2–3 hari
  → Tabel deposits, deposit_usages
  → 3 skenario: return normal, kerusakan, kabur
  → DB function: settle_deposit()

Modul 2.2 — Accrual + Piutang: 3–4 hari  
  → Tabel rent_invoices, receivables
  → Generate tagihan otomatis (idempotent)
  → Aging piutang (30/60/90 hari)
  → DB function: generate_monthly_invoices()

Modul 2.3 — Rekonsiliasi: 2–3 hari
  → Teknik validasi data keuangan
  → Query rekonsiliasi kas vs tagihan
  → Deteksi anomali: pembayaran tanpa tagihan, tagihan tanpa pembayaran

Checkpoint — Mini Proyek API Kos
```

---

## Setup Awal: Database Kos

Sebelum mulai, buat schema untuk proyek kos. Ini terpisah dari Sultan Fatah —
buat database baru.

```bash
createdb kos_dev
```

Jalankan script berikut untuk membuat fondasi:

```sql
-- schema_kos.sql

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ENUM types
CREATE TYPE gender_type AS ENUM ('male', 'female', 'other');
CREATE TYPE deposit_status AS ENUM (
    'held',           -- ditahan, belum diproses
    'returned',       -- dikembalikan penuh atau sebagian
    'forfeited',      -- diambil karena kerusakan/kabur
    'partially_used'  -- sebagian dipakai, sebagian dikembalikan
);
CREATE TYPE receivable_status AS ENUM (
    'outstanding',    -- belum dibayar, belum jatuh tempo
    'overdue',        -- belum dibayar, sudah lewat jatuh tempo
    'paid',           -- lunas
    'partial',        -- dibayar sebagian
    'written_off'     -- dihapuskan (hopeless debt)
);
CREATE TYPE payment_method_type AS ENUM (
    'cash', 'transfer', 'qris', 'debit_card', 'other'
);

-- Tabel utama
CREATE TABLE kos_properties (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name        VARCHAR(200) NOT NULL,
    address     TEXT,
    owner_name  VARCHAR(100),
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE rooms (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    property_id     UUID NOT NULL REFERENCES kos_properties(id),
    room_number     VARCHAR(10) NOT NULL,
    monthly_rate    NUMERIC(12,2) NOT NULL,
    is_available    BOOLEAN DEFAULT TRUE,
    UNIQUE (property_id, room_number)
);

CREATE TABLE tenants (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    full_name       VARCHAR(100) NOT NULL,
    phone           VARCHAR(20),
    id_card_number  VARCHAR(20),
    gender          gender_type,
    emergency_contact_name  VARCHAR(100),
    emergency_contact_phone VARCHAR(20),
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE tenancy_periods (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id),
    room_id         UUID NOT NULL REFERENCES rooms(id),
    check_in_date   DATE NOT NULL,
    check_out_date  DATE,
    is_active       BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE deposits (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenancy_id      UUID NOT NULL REFERENCES tenancy_periods(id),
    tenant_id       UUID NOT NULL REFERENCES tenants(id),
    property_id     UUID NOT NULL,
    amount          NUMERIC(12,2) NOT NULL,
    status          deposit_status DEFAULT 'held',
    returned_amount NUMERIC(12,2) DEFAULT 0,
    received_at     DATE NOT NULL,
    settled_at      DATE,
    notes           TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE deposit_usages (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    deposit_id      UUID NOT NULL REFERENCES deposits(id),
    amount          NUMERIC(12,2) NOT NULL,
    purpose         VARCHAR(200) NOT NULL,  -- 'kerusakan AC', 'tunggakan sewa', dll
    usage_date      DATE NOT NULL,
    notes           TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE rent_invoices (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenancy_id      UUID NOT NULL REFERENCES tenancy_periods(id),
    tenant_id       UUID NOT NULL REFERENCES tenants(id),
    room_id         UUID NOT NULL REFERENCES rooms(id),
    period          VARCHAR(7) NOT NULL,    -- 'YYYY-MM'
    amount          NUMERIC(12,2) NOT NULL,
    due_date        DATE NOT NULL,
    issued_at       DATE NOT NULL DEFAULT CURRENT_DATE,
    status          VARCHAR(20) DEFAULT 'unpaid',  -- unpaid, partial, paid
    notes           TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (tenancy_id, period)  -- idempotency: satu tagihan per penghuni per bulan
);

CREATE TABLE receivables (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    invoice_id      UUID NOT NULL REFERENCES rent_invoices(id),
    tenant_id       UUID NOT NULL REFERENCES tenants(id),
    amount          NUMERIC(12,2) NOT NULL,
    paid_amount     NUMERIC(12,2) DEFAULT 0,
    due_date        DATE NOT NULL,
    status          receivable_status DEFAULT 'outstanding',
    last_reminder_at TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE rent_payments (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    receivable_id   UUID NOT NULL REFERENCES receivables(id),
    invoice_id      UUID NOT NULL REFERENCES rent_invoices(id),
    amount          NUMERIC(12,2) NOT NULL,
    method          payment_method_type NOT NULL,
    paid_at         TIMESTAMPTZ DEFAULT NOW(),
    notes           TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE incomes (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    property_id     UUID NOT NULL,
    reference_id    UUID,   -- FK ke rent_payments atau deposit_usages
    reference_type  VARCHAR(50),  -- 'rent_payment', 'penalty', 'deposit_forfeiture'
    amount          NUMERIC(12,2) NOT NULL,
    category        VARCHAR(50) NOT NULL,  -- 'rent', 'penalty', 'deposit_forfeiture', 'other'
    fiscal_period   VARCHAR(7) NOT NULL,
    income_date     DATE NOT NULL,
    is_active       BOOLEAN DEFAULT TRUE,
    notes           TEXT,
    created_by      UUID,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE expenses (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    property_id     UUID NOT NULL,
    amount          NUMERIC(12,2) NOT NULL,
    category        VARCHAR(50) NOT NULL,  -- 'deposit_return', 'repairs', 'operational'
    fiscal_period   VARCHAR(7) NOT NULL,
    expense_date    DATE NOT NULL,
    description     TEXT,
    is_active       BOOLEAN DEFAULT TRUE,
    created_by      UUID,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- View: aging piutang
CREATE OR REPLACE VIEW v_receivables_aging AS
SELECT
    rv.id                   AS receivable_id,
    t.full_name             AS tenant_name,
    r.room_number,
    ri.period,
    rv.amount               AS tagihan,
    rv.paid_amount          AS sudah_dibayar,
    rv.amount - rv.paid_amount AS sisa_hutang,
    rv.due_date,
    CURRENT_DATE - rv.due_date AS hari_overdue,
    CASE
        WHEN CURRENT_DATE <= rv.due_date THEN 'belum_jatuh_tempo'
        WHEN CURRENT_DATE - rv.due_date <= 30 THEN '1_30_hari'
        WHEN CURRENT_DATE - rv.due_date <= 60 THEN '31_60_hari'
        WHEN CURRENT_DATE - rv.due_date <= 90 THEN '61_90_hari'
        ELSE 'lebih_90_hari'
    END                     AS aging_bucket,
    rv.status
FROM receivables rv
JOIN rent_invoices ri ON rv.invoice_id = ri.id
JOIN tenants t        ON rv.tenant_id = t.id
JOIN tenancy_periods tp ON ri.tenancy_id = tp.id
JOIN rooms r          ON tp.room_id = r.id
WHERE rv.status IN ('outstanding', 'overdue', 'partial');

-- Seed data
INSERT INTO kos_properties (id, name, address, owner_name)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    'Kos Mawar Indah', 'Jl. Mawar No. 5, Semarang', 'H. Mursyid'
);

INSERT INTO rooms (property_id, room_number, monthly_rate) VALUES
    ('11111111-1111-1111-1111-111111111111', '1A', 800000),
    ('11111111-1111-1111-1111-111111111111', '1B', 800000),
    ('11111111-1111-1111-1111-111111111111', '2A', 900000),
    ('11111111-1111-1111-1111-111111111111', '2B', 900000),
    ('11111111-1111-1111-1111-111111111111', '3A', 1000000);
```

---

## MODUL 2.1 — Deposit: Kewajiban, Bukan Pendapatan

### Mengapa Ini Penting Secara Akuntansi

Ketika penghuni membayar deposit Rp 1.500.000:

```
Yang terjadi di rekening bank: +1.500.000
Yang terjadi di neraca:        +1.500.000 (aset = kas bertambah)
                               +1.500.000 (kewajiban = hutang ke penghuni)

Persamaan neraca tetap seimbang:
  ASET = KEWAJIBAN + EKUITAS
  +1.500.000 = +1.500.000 + 0
```

Kalau kamu salah mencatatnya sebagai income:
- Laporan L/R membengkak palsu +1.500.000
- Pajak penghasilan kelebihan dihitung
- Saat deposit harus dikembalikan: tidak ada "budget" untuk mengembalikan
- Penghuni marah, owner bingung

### Langkah 2.1.1: Setup Data Penghuni dan Deposit

Jalankan manual di psql:

```sql
-- Buat tenant
INSERT INTO tenants (id, full_name, phone, id_card_number, gender,
                     emergency_contact_name, emergency_contact_phone)
VALUES (
    'aaaa0001-0000-0000-0000-000000000001',
    'Budi Santoso', '081234567890', '3374010101900001', 'male',
    'Ibu Sari (Ibu)', '082345678901'
);

-- Check-in ke kamar 1A
INSERT INTO tenancy_periods (id, tenant_id, room_id, check_in_date)
VALUES (
    'bbbb0001-0000-0000-0000-000000000001',
    'aaaa0001-0000-0000-0000-000000000001',
    (SELECT id FROM rooms WHERE room_number = '1A'),
    '2026-01-01'
);

-- Budi bayar deposit 2x sewa = 1.600.000
INSERT INTO deposits (id, tenancy_id, tenant_id, property_id, amount, received_at)
VALUES (
    'cccc0001-0000-0000-0000-000000000001',
    'bbbb0001-0000-0000-0000-000000000001',
    'aaaa0001-0000-0000-0000-000000000001',
    '11111111-1111-1111-1111-111111111111',
    1600000,
    '2026-01-01'
);

-- PERHATIAN: Tidak ada INSERT ke tabel incomes di sini!
-- Deposit BUKAN income. Tabel incomes tidak disentuh.
```

Cek:
```sql
-- Deposit ada di tabel deposits
SELECT id, amount, status FROM deposits WHERE tenant_id = 'aaaa0001-...';

-- Tabel incomes kosong (tidak ada income dari deposit)
SELECT COUNT(*) FROM incomes;  -- harus 0
```

### Langkah 2.1.2: Tiga Skenario Settlement Deposit

#### Skenario A: Penghuni Keluar Normal, Tidak Ada Kerusakan

```sql
-- Budi check-out Maret 2026, semua bersih
-- Langkah 1: Tutup tenancy
UPDATE tenancy_periods
SET check_out_date = '2026-03-31', is_active = FALSE
WHERE id = 'bbbb0001-0000-0000-0000-000000000001';

-- Langkah 2: Catat expense (deposit dikembalikan = pengeluaran kas)
INSERT INTO expenses (property_id, amount, category, fiscal_period, expense_date, description)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    1600000,                -- full deposit
    'deposit_return',
    '2026-03',
    '2026-03-31',
    'Pengembalian deposit Budi Santoso - kamar 1A'
);

-- Langkah 3: Update status deposit
UPDATE deposits
SET status = 'returned',
    returned_amount = 1600000,
    settled_at = '2026-03-31',
    notes = 'Pengembalian penuh - kondisi kamar baik'
WHERE id = 'cccc0001-0000-0000-0000-000000000001';

-- Tabel incomes tetap tidak disentuh.
-- Deposit return = expense (kas keluar), bukan pengurangan income.
```

#### Skenario B: Penghuni Keluar, Ada Kerusakan Sebagian

```sql
-- Penghuni Ani check-out, AC rusak perlu perbaikan Rp 600.000
-- Setup Ani dulu
INSERT INTO tenants (id, full_name, phone, gender)
VALUES ('aaaa0002-0000-0000-0000-000000000002', 'Ani Wijaya', '087654321098', 'female');

INSERT INTO tenancy_periods (id, tenant_id, room_id, check_in_date)
VALUES (
    'bbbb0002-0000-0000-0000-000000000002',
    'aaaa0002-0000-0000-0000-000000000002',
    (SELECT id FROM rooms WHERE room_number = '2A'),
    '2026-01-15'
);

INSERT INTO deposits (id, tenancy_id, tenant_id, property_id, amount, received_at)
VALUES (
    'cccc0002-0000-0000-0000-000000000002',
    'bbbb0002-0000-0000-0000-000000000002',
    'aaaa0002-0000-0000-0000-000000000002',
    '11111111-1111-1111-1111-111111111111',
    1800000,  -- 2x sewa kamar 2A
    '2026-01-15'
);

-- Ani check-out Maret, AC rusak Rp 600.000
-- Langkah 1: Catat penggunaan deposit untuk perbaikan
INSERT INTO deposit_usages (deposit_id, amount, purpose, usage_date, notes)
VALUES (
    'cccc0002-0000-0000-0000-000000000002',
    600000,
    'Perbaikan unit AC',
    '2026-03-31',
    'AC tidak dingin, perlu ganti freon dan servis rutin'
);

-- Langkah 2: Catat expense perbaikan (dari deposit)
INSERT INTO expenses (property_id, amount, category, fiscal_period, expense_date, description)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    600000,
    'repairs',
    '2026-03',
    '2026-03-31',
    'Perbaikan AC kamar 2A (diambil dari deposit Ani Wijaya)'
);

-- Langkah 3: Catat expense untuk sisa deposit yang dikembalikan
INSERT INTO expenses (property_id, amount, category, fiscal_period, expense_date, description)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    1200000,  -- 1.800.000 - 600.000 = 1.200.000 dikembalikan
    'deposit_return',
    '2026-03',
    '2026-03-31',
    'Pengembalian sisa deposit Ani Wijaya - kamar 2A'
);

-- Langkah 4: Update status deposit
UPDATE deposits
SET status = 'partially_used',
    returned_amount = 1200000,
    settled_at = '2026-03-31',
    notes = 'Rp 600.000 dipakai perbaikan AC, sisa Rp 1.200.000 dikembalikan'
WHERE id = 'cccc0002-0000-0000-0000-000000000002';

-- Tabel incomes tetap TIDAK disentuh untuk skenario ini.
-- Uang perbaikan adalah pengeluaran (expense/repairs), bukan income.
```

#### Skenario C: Penghuni Kabur, Kerusakan Melebihi Deposit

```sql
-- Cici punya deposit Rp 1.500.000, tapi kerusakan Rp 2.200.000
INSERT INTO tenants (id, full_name, phone, gender)
VALUES ('aaaa0003-0000-0000-0000-000000000003', 'Cici Marlina', '081111222333', 'female');

INSERT INTO tenancy_periods (id, tenant_id, room_id, check_in_date)
VALUES (
    'bbbb0003-0000-0000-0000-000000000003',
    'aaaa0003-0000-0000-0000-000000000003',
    (SELECT id FROM rooms WHERE room_number = '3A'),
    '2025-10-01'
);

INSERT INTO deposits (id, tenancy_id, tenant_id, property_id, amount, received_at)
VALUES (
    'cccc0003-0000-0000-0000-000000000003',
    'bbbb0003-0000-0000-0000-000000000003',
    'aaaa0003-0000-0000-0000-000000000003',
    '11111111-1111-1111-1111-111111111111',
    1500000,
    '2025-10-01'
);

-- Cici kabur Maret 2026, kerusakan Rp 2.200.000
-- Langkah 1: Pakai seluruh deposit untuk kerusakan (Rp 1.500.000)
INSERT INTO deposit_usages (deposit_id, amount, purpose, usage_date)
VALUES (
    'cccc0003-0000-0000-0000-000000000003',
    1500000,
    'Kerusakan: pintu, kaca jendela, kloset (penghuni kabur)',
    '2026-03-15'
);

-- Langkah 2: Catat expense kerusakan total (Rp 2.200.000)
INSERT INTO expenses (property_id, amount, category, fiscal_period, expense_date, description)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    2200000,
    'repairs',
    '2026-03',
    '2026-03-15',
    'Perbaikan kamar 3A pasca penghuni kabur (Cici Marlina)'
);

-- Langkah 3: Catat income dari penyitaan deposit
-- Ini SATU-SATUNYA skenario di mana deposit menjadi income!
INSERT INTO incomes (property_id, reference_id, reference_type, amount, category,
                     fiscal_period, income_date, notes)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    'cccc0003-0000-0000-0000-000000000003',
    'deposit',
    1500000,  -- seluruh deposit disita
    'deposit_forfeiture',
    '2026-03',
    '2026-03-15',
    'Penyitaan deposit Cici Marlina - penghuni kabur, kerusakan Rp 2.200.000'
);

-- Langkah 4: Sisa Rp 700.000 (2.200.000 - 1.500.000) = piutang ke Cici
-- (tangani sebagai bad debt / write-off nanti kalau tidak bisa ditagih)
INSERT INTO receivables (invoice_id, tenant_id, amount, due_date, status)
-- Catatan: untuk kasus ini mungkin perlu tabel khusus "damage_claims"
-- Tapi untuk kesederhanaan Level 2, bisa catat di receivables juga

-- Langkah 5: Update status deposit
UPDATE deposits
SET status = 'forfeited',
    returned_amount = 0,
    settled_at = '2026-03-15',
    notes = 'Deposit disita penuh. Kerusakan total Rp 2.200.000, sisa Rp 700.000 ditagihkan'
WHERE id = 'cccc0003-0000-0000-0000-000000000003';
```

### Ringkasan 3 Skenario Deposit

| Skenario | Deposit | Tabel incomes | Tabel expenses |
|---|---|---|---|
| Normal, tidak ada kerusakan | returned | ❌ tidak disentuh | deposit_return (full) |
| Ada kerusakan < deposit | partially_used | ❌ tidak disentuh | repairs + deposit_return |
| Kabur / kerusakan > deposit | forfeited | ✅ deposit_forfeiture | repairs |

**Aturan emas:** Deposit masuk ke `incomes` **hanya** jika disita (`forfeited`).
Dalam semua kasus lain, deposit adalah pergerakan kas — bukan pendapatan.

---

## MODUL 2.2 — Accrual Basis: Tagihan Dulu, Bayar Nanti

### Cash Basis vs Accrual Basis — Bedanya Untuk Developer

```
CASH BASIS (Level 1 — Klinik):
  Income dicatat saat UANG MASUK.
  Tanggal income = tanggal payment confirmed.

  Implikasi:
  - Tidak ada piutang (receivable) — kalau belum bayar, belum dicatat
  - Laporan bulan ini = uang yang sudah diterima bulan ini
  - Mudah, tapi tidak tepat untuk bisnis dengan tagihan rutin

ACCRUAL BASIS (Level 2 — Kos):
  Income dicatat saat HAK TAGIH TIMBUL.
  Tanggal income = tanggal tagihan dibuat (bukan saat dibayar).

  Implikasi:
  - Ada piutang (receivable) — tagihan yang belum dibayar tercatat sebagai "income tertunda"
  - Laporan April = semua sewa April, meskipun belum semua bayar
  - Lebih akurat untuk bisnis subscription/recurring
```

Untuk kos, accrual basis lebih tepat karena:
- Sewa April adalah hak pendapatan April, bukan hak pendapatan saat pembayaran terjadi
- Owner perlu tahu berapa yang "seharusnya masuk" vs berapa yang "sudah masuk"
- Tracking siapa yang belum bayar adalah bagian dari operasional harian

### Langkah 2.2.1: Generate Tagihan Bulanan

Buat function PostgreSQL yang membuat tagihan untuk semua penghuni aktif:

```sql
CREATE OR REPLACE FUNCTION generate_monthly_invoices(
    p_property_id UUID,
    p_period      VARCHAR(7)  -- 'YYYY-MM'
) RETURNS INTEGER AS $$
DECLARE
    v_tenancy       RECORD;
    v_due_date      DATE;
    v_count         INTEGER := 0;
    v_first_day     DATE;
    v_last_day      DATE;
    v_invoice_id    UUID;
BEGIN
    -- Hitung tanggal jatuh tempo: tanggal 10 bulan tersebut
    v_first_day := (p_period || '-01')::DATE;
    v_last_day  := (DATE_TRUNC('MONTH', v_first_day) + INTERVAL '1 MONTH - 1 DAY')::DATE;
    v_due_date  := v_first_day + INTERVAL '9 DAYS';  -- tanggal 10

    -- Loop semua penghuni aktif di property ini
    FOR v_tenancy IN
        SELECT
            tp.id        AS tenancy_id,
            tp.tenant_id,
            tp.room_id,
            tp.check_in_date,
            r.monthly_rate
        FROM tenancy_periods tp
        JOIN rooms r ON tp.room_id = r.id
        WHERE r.property_id = p_property_id
          AND tp.is_active = TRUE
          AND tp.check_in_date <= v_last_day  -- sudah check-in sebelum akhir bulan
    LOOP
        -- Idempotency check: skip kalau sudah ada tagihan untuk period ini
        IF EXISTS (
            SELECT 1 FROM rent_invoices
            WHERE tenancy_id = v_tenancy.tenancy_id AND period = p_period
        ) THEN
            CONTINUE;
        END IF;

        -- Hitung pro-rata jika check-in di tengah bulan
        DECLARE
            v_amount NUMERIC(12,2);
            v_days_in_month INTEGER;
            v_days_active INTEGER;
        BEGIN
            v_days_in_month := EXTRACT(DAY FROM v_last_day);

            IF v_tenancy.check_in_date > v_first_day THEN
                -- Check-in di tengah bulan: hitung pro-rata
                v_days_active := v_last_day - v_tenancy.check_in_date + 1;
                v_amount := (v_tenancy.monthly_rate * v_days_active / v_days_in_month)::NUMERIC(12,2);
            ELSE
                v_amount := v_tenancy.monthly_rate;
            END IF;

            -- Buat tagihan
            INSERT INTO rent_invoices (tenancy_id, tenant_id, room_id, period, amount, due_date, issued_at)
            VALUES (v_tenancy.tenancy_id, v_tenancy.tenant_id, v_tenancy.room_id,
                    p_period, v_amount, v_due_date, v_first_day)
            RETURNING id INTO v_invoice_id;

            -- Buat receivable (piutang)
            INSERT INTO receivables (invoice_id, tenant_id, amount, due_date)
            VALUES (v_invoice_id, v_tenancy.tenant_id, v_amount, v_due_date);

            v_count := v_count + 1;
        END;
    END LOOP;

    RETURN v_count;  -- jumlah tagihan yang berhasil dibuat
END;
$$ LANGUAGE plpgsql;
```

Coba jalankan:
```sql
-- Generate tagihan untuk semua penghuni aktif bulan Maret 2026
SELECT generate_monthly_invoices('11111111-1111-1111-1111-111111111111', '2026-03');

-- Cek hasilnya
SELECT ri.period, t.full_name, r.room_number, ri.amount, ri.due_date, ri.status
FROM rent_invoices ri
JOIN tenants t ON ri.tenant_id = t.id
JOIN rooms r ON ri.room_id = r.id
WHERE ri.period = '2026-03';

-- Cek piutang
SELECT rv.amount, rv.status, t.full_name
FROM receivables rv JOIN tenants t ON rv.tenant_id = t.id;

-- Test idempotency: jalankan lagi, hasilnya harus 0 (tidak ada duplikasi)
SELECT generate_monthly_invoices('11111111-1111-1111-1111-111111111111', '2026-03');
-- ↑ harus return 0 karena semua sudah ada
```

### Langkah 2.2.2: Proses Pembayaran Sewa

```sql
CREATE OR REPLACE FUNCTION pay_rent(
    p_receivable_id UUID,
    p_amount        NUMERIC(12,2),
    p_method        payment_method_type,
    p_notes         TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
    v_receivable    receivables%ROWTYPE;
    v_invoice       rent_invoices%ROWTYPE;
    v_new_paid      NUMERIC(12,2);
    v_new_status    receivable_status;
BEGIN
    -- Ambil data receivable (lock baris untuk update)
    SELECT * INTO v_receivable FROM receivables WHERE id = p_receivable_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Receivable % not found', p_receivable_id;
    END IF;
    IF v_receivable.status = 'paid' THEN
        RAISE EXCEPTION 'Receivable % already fully paid', p_receivable_id;
    END IF;

    -- Validasi jumlah
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive';
    END IF;
    IF p_amount > (v_receivable.amount - v_receivable.paid_amount) THEN
        RAISE EXCEPTION 'Payment amount Rp % exceeds remaining balance Rp %',
            p_amount, (v_receivable.amount - v_receivable.paid_amount);
    END IF;

    -- Ambil data invoice
    SELECT * INTO v_invoice FROM rent_invoices WHERE id = v_receivable.invoice_id;

    -- Hitung saldo baru
    v_new_paid := v_receivable.paid_amount + p_amount;
    v_new_status := CASE
        WHEN v_new_paid >= v_receivable.amount THEN 'paid'
        ELSE 'partial'
    END;

    -- Record payment
    INSERT INTO rent_payments (receivable_id, invoice_id, amount, method, notes)
    VALUES (p_receivable_id, v_receivable.invoice_id, p_amount, p_method, p_notes);

    -- Update receivable
    UPDATE receivables
    SET paid_amount = v_new_paid,
        status = v_new_status,
        updated_at = NOW()
    WHERE id = p_receivable_id;

    -- Update invoice status
    UPDATE rent_invoices
    SET status = CASE WHEN v_new_paid >= v_receivable.amount THEN 'paid' ELSE 'partial' END
    WHERE id = v_receivable.invoice_id;

    -- Catat ke incomes (accrual: income terbukukan saat tagihan dibuat)
    -- Di sini kita buat model hybrid: income terbukukan saat pembayaran diterima
    -- Ini lebih praktis untuk kos kecil (mendekati cash basis tapi dengan tracking piutang)
    INSERT INTO incomes (property_id, reference_id, reference_type, amount, category,
                         fiscal_period, income_date, notes)
    VALUES (
        (SELECT property_id FROM rooms WHERE id = v_invoice.room_id),
        p_receivable_id,
        'rent_payment',
        p_amount,
        'rent',
        TO_CHAR(NOW(), 'YYYY-MM'),
        CURRENT_DATE,
        'Pembayaran sewa ' || v_invoice.period || ' - ' || p_notes
    );

END;
$$ LANGUAGE plpgsql;
```

Test:
```sql
-- Ambil receivable_id salah satu penghuni
SELECT rv.id, t.full_name, rv.amount, rv.status
FROM receivables rv JOIN tenants t ON rv.tenant_id = t.id;

-- Bayar sewa (misalnya kamar 1A)
SELECT pay_rent('<receivable_id>', 800000, 'transfer', 'Transfer BCA tanggal 5 Maret');

-- Cek update
SELECT rv.paid_amount, rv.status, ri.status AS invoice_status
FROM receivables rv
JOIN rent_invoices ri ON rv.invoice_id = ri.id
WHERE rv.id = '<receivable_id>';

-- Cek income tercatat
SELECT * FROM incomes ORDER BY created_at DESC LIMIT 1;
```

### Langkah 2.2.3: Update Status Overdue (Cron Job Harian)

Setiap hari, kita perlu update piutang yang sudah melewati due_date:

```sql
CREATE OR REPLACE FUNCTION update_overdue_receivables()
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    WITH updated AS (
        UPDATE receivables
        SET status = 'overdue',
            updated_at = NOW()
        WHERE status = 'outstanding'
          AND due_date < CURRENT_DATE
        RETURNING id
    )
    SELECT COUNT(*) INTO v_count FROM updated;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- Jalankan setiap hari via cron atau pg_cron
SELECT update_overdue_receivables();
```

### Langkah 2.2.4: Laporan Aging Piutang

```sql
-- Lihat aging piutang saat ini
SELECT
    aging_bucket,
    COUNT(*) AS jumlah_penghuni,
    SUM(sisa_hutang) AS total_piutang
FROM v_receivables_aging
GROUP BY aging_bucket
ORDER BY aging_bucket;

-- Detail per penghuni dengan aging
SELECT
    tenant_name,
    room_number,
    period,
    sisa_hutang,
    hari_overdue,
    aging_bucket
FROM v_receivables_aging
ORDER BY hari_overdue DESC NULLS LAST;
```

---

## MODUL 2.3 — Rekonsiliasi

### Apa Itu Rekonsiliasi?

Rekonsiliasi = **memverifikasi bahwa dua catatan yang seharusnya konsisten, benar-benar konsisten**.

Di kos, ada dua rekonsiliasi utama:

```
REKONSILIASI 1: Tagihan vs Penerimaan
  "Dari Rp 18.500.000 sewa yang seharusnya masuk bulan Maret,
   sudah berapa yang masuk?"

  Caranya: SUM(rent_invoices.amount WHERE period='2026-03')
         - SUM(rent_payments.amount jika sudah lunas)
         = sisa piutang

REKONSILIASI 2: Neraca Deposit
  "Dari semua deposit yang sedang ditahan, berapa total kewajiban kita?"

  Caranya: SUM(deposits.amount WHERE status='held')
         = total yang wajib dikembalikan kalau semua penghuni keluar besok
```

### Langkah 2.3.1: Query Rekonsiliasi Sewa Bulanan

```sql
-- Rekonsiliasi sewa Maret 2026
WITH tagihan AS (
    SELECT
        ri.id,
        t.full_name,
        r.room_number,
        ri.amount        AS tagihan_amount,
        COALESCE(SUM(rp.amount), 0) AS dibayar_amount
    FROM rent_invoices ri
    JOIN tenants t ON ri.tenant_id = t.id
    JOIN tenancy_periods tp ON ri.tenancy_id = tp.id
    JOIN rooms r ON tp.room_id = r.id
    LEFT JOIN rent_payments rp ON rp.invoice_id = ri.id
    WHERE ri.period = '2026-03'
    GROUP BY ri.id, t.full_name, r.room_number, ri.amount
)
SELECT
    full_name          AS penghuni,
    room_number        AS kamar,
    tagihan_amount     AS seharusnya,
    dibayar_amount     AS sudah_dibayar,
    tagihan_amount - dibayar_amount AS sisa_hutang,
    CASE
        WHEN dibayar_amount >= tagihan_amount THEN '✅ LUNAS'
        WHEN dibayar_amount > 0 THEN '⚠️ PARSIAL'
        ELSE '❌ BELUM BAYAR'
    END AS status
FROM tagihan
ORDER BY sisa_hutang DESC;

-- Summary
SELECT
    COUNT(*) AS total_penghuni,
    SUM(tagihan_amount) AS total_tagihan,
    SUM(dibayar_amount) AS total_diterima,
    SUM(tagihan_amount - dibayar_amount) AS total_piutang
FROM tagihan;
```

### Langkah 2.3.2: Neraca Deposit

```sql
-- Berapa kewajiban deposit yang sedang ditahan?
SELECT
    COUNT(*)        AS jumlah_deposit_aktif,
    SUM(amount)     AS total_kewajiban_deposit,
    MIN(amount)     AS deposit_terkecil,
    MAX(amount)     AS deposit_terbesar,
    AVG(amount)     AS rata_rata_deposit
FROM deposits
WHERE status = 'held';

-- Breakdown per status
SELECT
    status,
    COUNT(*) AS jumlah,
    SUM(amount) AS total
FROM deposits
GROUP BY status
ORDER BY total DESC;
```

### Langkah 2.3.3: Deteksi Anomali Keuangan

Ini skill paling berpraktis — query untuk menemukan data yang tidak beres:

```sql
-- ANOMALI 1: Income tanpa referensi yang valid
-- Harusnya tidak ada income dengan reference_id yang null selain opening_balance
SELECT id, amount, category, income_date, notes
FROM incomes
WHERE reference_id IS NULL
  AND category != 'other'
  AND is_active = TRUE;

-- ANOMALI 2: Receivable yang statusnya tidak sinkron dengan invoice
SELECT rv.id, rv.status AS rv_status, ri.status AS inv_status,
       rv.amount, rv.paid_amount, t.full_name
FROM receivables rv
JOIN rent_invoices ri ON rv.invoice_id = ri.id
JOIN tenants t ON rv.tenant_id = t.id
WHERE
    -- Receivable bilang paid tapi invoice belum
    (rv.status = 'paid' AND ri.status != 'paid')
    OR
    -- Invoice bilang paid tapi receivable belum
    (ri.status = 'paid' AND rv.status != 'paid');

-- ANOMALI 3: Deposit yang sudah settled tapi tidak ada expense
-- Setiap deposit yang 'returned' harus ada expense 'deposit_return' yang matching
SELECT d.id, d.amount, d.returned_amount, d.status, t.full_name
FROM deposits d
JOIN tenancy_periods tp ON d.tenancy_id = tp.id
JOIN tenants t ON tp.tenant_id = t.id
WHERE d.status = 'returned'
  AND NOT EXISTS (
    SELECT 1 FROM expenses e
    WHERE e.category = 'deposit_return'
      AND e.description LIKE '%' || t.full_name || '%'
  );

-- ANOMALI 4: Total income tidak cocok dengan total pembayaran
-- Seharusnya: SUM(incomes.amount) = SUM(rent_payments.amount) untuk period yang sama
SELECT
    period_check,
    total_dari_incomes,
    total_dari_payments,
    total_dari_incomes - total_dari_payments AS selisih
FROM (
    SELECT
        i.fiscal_period             AS period_check,
        SUM(i.amount)               AS total_dari_incomes,
        COALESCE(SUM(rp.amount), 0) AS total_dari_payments
    FROM incomes i
    LEFT JOIN rent_payments rp
        ON rp.id = i.reference_id AND i.reference_type = 'rent_payment'
    WHERE i.is_active = TRUE AND i.category = 'rent'
    GROUP BY i.fiscal_period
) t
WHERE ABS(total_dari_incomes - total_dari_payments) > 1;  -- toleransi Rp 1 untuk rounding
```

---

## PILAR 2 — Backend FastAPI untuk Kos

### Struktur Project

```
backend_kos/
├── app/
│   ├── main.py
│   ├── database.py
│   ├── routers/
│   │   ├── tenants.py            ← check-in, checkout
│   │   ├── deposits.py           ← settle deposit
│   │   ├── invoices.py           ← generate tagihan
│   │   ├── payments.py           ← bayar sewa
│   │   └── reports.py            ← aging, rekonsiliasi
│   └── schemas/
│       ├── deposit.py
│       ├── invoice.py
│       └── receivable.py
└── tests/
    ├── conftest.py
    ├── test_deposits.py
    ├── test_invoices.py
    └── test_payments.py
```

### Endpoint Utama

```python
# app/routers/tenants.py

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from datetime import date
from uuid import UUID
from decimal import Decimal

router = APIRouter(prefix="/tenants", tags=["tenants"])

class CheckInData(BaseModel):
    tenant_name: str
    phone: str
    room_id: UUID
    check_in_date: date
    deposit_amount: Decimal
    payment_method: str  # 'cash', 'transfer', dll

@router.post("/{tenant_id}/check-in")
async def check_in(request: CheckInData):
    """
    Check-in penghuni.
    PENTING: deposit TIDAK dicatat sebagai income — hanya dicatat di tabel deposits.
    """
    async with db_transaction() as conn:
        # Cek kamar tersedia
        room = await conn.fetchrow(
            "SELECT id, monthly_rate, is_available FROM rooms WHERE id = $1",
            request.room_id
        )
        if not room or not room['is_available']:
            raise HTTPException(400, "Room not available")

        # Buat tenancy
        tenancy = await conn.fetchrow("""
            INSERT INTO tenancy_periods (tenant_id, room_id, check_in_date)
            VALUES ($1, $2, $3) RETURNING id
        """, tenant_id, request.room_id, request.check_in_date)

        # Catat deposit sebagai kewajiban (BUKAN income)
        deposit = await conn.fetchrow("""
            INSERT INTO deposits (tenancy_id, tenant_id, property_id, amount, received_at)
            VALUES ($1, $2, $3, $4, $5) RETURNING id
        """, tenancy['id'], tenant_id, property_id,
            request.deposit_amount, request.check_in_date)

        # Update kamar jadi tidak tersedia
        await conn.execute(
            "UPDATE rooms SET is_available = FALSE WHERE id = $1", request.room_id
        )

    return {
        "tenancy_id": str(tenancy['id']),
        "deposit_id": str(deposit['id']),
        "message": "Check-in berhasil. Deposit dicatat sebagai kewajiban.",
        "warning": "Deposit BUKAN income — ini adalah hutang kita ke penghuni"
    }


# app/routers/deposits.py

class SettleDepositData(BaseModel):
    settle_type: str  # 'full_return', 'partial_use', 'full_forfeiture'
    damage_amount: Decimal = Decimal('0')
    damage_description: str = ''
    notes: str = ''

@router.post("/{deposit_id}/settle")
async def settle_deposit(deposit_id: UUID, data: SettleDepositData):
    """
    Proses pengembalian/penyitaan deposit saat checkout.
    Implementasi 3 skenario: return, partial, forfeit.
    """
    async with db_transaction() as conn:
        deposit = await conn.fetchrow(
            "SELECT * FROM deposits WHERE id = $1 FOR UPDATE", deposit_id
        )
        if not deposit:
            raise HTTPException(404, "Deposit not found")
        if deposit['status'] != 'held':
            raise HTTPException(400, f"Deposit already settled: {deposit['status']}")

        if data.damage_amount > deposit['amount']:
            raise HTTPException(400, "Damage amount cannot exceed deposit amount")

        returned_amount = deposit['amount'] - data.damage_amount

        if data.settle_type == 'full_return':
            # Skenario A: tidak ada kerusakan
            await conn.execute("""
                INSERT INTO expenses (property_id, amount, category, fiscal_period,
                                      expense_date, description)
                VALUES ($1, $2, 'deposit_return', $3, CURRENT_DATE, $4)
            """, deposit['property_id'], deposit['amount'],
                __current_period(), f"Pengembalian deposit - {data.notes}"
            )
            new_status = 'returned'
            returned_amount = deposit['amount']

        elif data.settle_type == 'partial_use':
            # Skenario B: ada kerusakan, sisa dikembalikan
            if data.damage_amount <= 0:
                raise HTTPException(400, "partial_use requires damage_amount > 0")

            # Expense untuk kerusakan
            await conn.execute("""
                INSERT INTO deposit_usages (deposit_id, amount, purpose, usage_date)
                VALUES ($1, $2, $3, CURRENT_DATE)
            """, deposit_id, data.damage_amount, data.damage_description)

            await conn.execute("""
                INSERT INTO expenses (property_id, amount, category, fiscal_period,
                                      expense_date, description)
                VALUES ($1, $2, 'repairs', $3, CURRENT_DATE, $4)
            """, deposit['property_id'], data.damage_amount,
                __current_period(), data.damage_description
            )

            # Expense untuk sisa deposit yang dikembalikan
            if returned_amount > 0:
                await conn.execute("""
                    INSERT INTO expenses (property_id, amount, category, fiscal_period,
                                          expense_date, description)
                    VALUES ($1, $2, 'deposit_return', $3, CURRENT_DATE, $4)
                """, deposit['property_id'], returned_amount,
                    __current_period(), f"Sisa deposit dikembalikan - {data.notes}"
                )
            new_status = 'partially_used'

        elif data.settle_type == 'full_forfeiture':
            # Skenario C: disita semua (kabur / kerusakan >= deposit)
            await conn.execute("""
                INSERT INTO incomes (property_id, reference_id, reference_type, amount,
                                     category, fiscal_period, income_date, notes)
                VALUES ($1, $2, 'deposit', $3, 'deposit_forfeiture', $4, CURRENT_DATE, $5)
            """, deposit['property_id'], deposit_id, deposit['amount'],
                __current_period(), data.notes
            )
            new_status = 'forfeited'
            returned_amount = 0

        # Update status deposit
        await conn.execute("""
            UPDATE deposits SET status = $1, returned_amount = $2,
                                settled_at = CURRENT_DATE, notes = $3
            WHERE id = $4
        """, new_status, returned_amount, data.notes, deposit_id)

    return {
        "status": new_status,
        "returned_amount": float(returned_amount),
        "damage_amount": float(data.damage_amount)
    }


# app/routers/invoices.py

@router.post("/generate/{period}")
async def generate_invoices(property_id: UUID, period: str):
    """
    Generate tagihan sewa bulanan untuk semua penghuni aktif.
    Endpoint ini IDEMPOTENT — aman dijalankan berkali-kali.
    """
    import re
    if not re.match(r"^\d{4}-\d{2}$", period):
        raise HTTPException(400, "Period format must be YYYY-MM")

    async with db_transaction() as conn:
        count = await conn.fetchval(
            "SELECT generate_monthly_invoices($1, $2)",
            property_id, period
        )

    return {
        "period": period,
        "invoices_created": count,
        "message": f"{count} tagihan baru dibuat. Idempotent: aman dijalankan ulang."
    }


# app/routers/reports.py

@router.get("/aging")
async def receivables_aging(property_id: UUID):
    """Laporan aging piutang"""
    async with db_transaction() as conn:
        rows = await conn.fetch("""
            SELECT tenant_name, room_number, period, sisa_hutang,
                   hari_overdue, aging_bucket, status
            FROM v_receivables_aging
            WHERE room_number IN (
                SELECT room_number FROM rooms WHERE property_id = $1
            )
            ORDER BY hari_overdue DESC NULLS LAST
        """, property_id)

        summary = await conn.fetch("""
            SELECT aging_bucket, COUNT(*) AS count, SUM(sisa_hutang) AS total
            FROM v_receivables_aging
            WHERE room_number IN (
                SELECT room_number FROM rooms WHERE property_id = $1
            )
            GROUP BY aging_bucket
        """, property_id)

    return {
        "detail": [dict(r) for r in rows],
        "summary": [dict(r) for r in summary]
    }
```

---

## PILAR 3 — Pytest untuk Kos

```python
# tests/conftest.py
import pytest
import asyncio
import asyncpg

TEST_DB_URL = "postgresql://localhost/kos_test"
PROPERTY_ID = "11111111-1111-1111-1111-111111111111"

@pytest.fixture
async def db():
    conn = await asyncpg.connect(TEST_DB_URL)
    tr = conn.transaction()
    await tr.start()
    yield conn
    await tr.rollback()
    await conn.close()

@pytest.fixture
async def seed(db):
    """Setup tenant, room, tenancy, deposit"""
    # Ambil room yang sudah ada dari seed data init.sql
    room = await db.fetchrow("SELECT id, monthly_rate FROM rooms WHERE room_number = '1A'")

    tenant = await db.fetchrow("""
        INSERT INTO tenants (full_name, phone, gender)
        VALUES ('Test Penghuni', '08100000001', 'male') RETURNING id
    """)

    tenancy = await db.fetchrow("""
        INSERT INTO tenancy_periods (tenant_id, room_id, check_in_date)
        VALUES ($1, $2, '2026-01-01') RETURNING id
    """, tenant['id'], room['id'])

    deposit = await db.fetchrow("""
        INSERT INTO deposits (tenancy_id, tenant_id, property_id, amount, received_at)
        VALUES ($1, $2, $3, 1600000, '2026-01-01') RETURNING id
    """, tenancy['id'], tenant['id'], PROPERTY_ID)

    return {
        "tenant_id": tenant['id'],
        "room_id": room['id'],
        "room_rate": room['monthly_rate'],
        "tenancy_id": tenancy['id'],
        "deposit_id": deposit['id'],
    }


# tests/test_deposits.py
import pytest
from decimal import Decimal

class TestDepositNotIncome:
    """
    PRINSIP UTAMA: Deposit BUKAN income.
    Semua test di kelas ini memverifikasi bahwa deposit tidak pernah
    masuk ke tabel incomes kecuali dalam kondisi tertentu.
    """

    async def test_deposit_not_recorded_as_income(self, db, seed):
        """
        Ketika penghuni check-in dan bayar deposit,
        tabel incomes harus tetap kosong.
        """
        # Deposit sudah dibuat di seed — cek incomes tetap kosong
        income_count = await db.fetchval(
            "SELECT COUNT(*) FROM incomes WHERE is_active = TRUE"
        )
        assert income_count == 0, (
            "Deposit tidak boleh masuk ke tabel incomes. "
            "Deposit adalah kewajiban (liability), bukan pendapatan."
        )

    async def test_deposit_recorded_in_deposits_table(self, db, seed):
        """Deposit harus ada di tabel deposits dengan status 'held'"""
        deposit = await db.fetchrow(
            "SELECT status, amount FROM deposits WHERE id = $1",
            seed['deposit_id']
        )
        assert deposit is not None
        assert deposit['status'] == 'held'
        assert deposit['amount'] == Decimal('1600000')

    async def test_full_return_creates_expense_not_income(self, db, seed):
        """
        Pengembalian deposit penuh → expense (kas keluar).
        Bukan reverse income, karena deposit tidak pernah dicatat sebagai income.
        """
        # Catat pengembalian deposit
        await db.execute("""
            INSERT INTO expenses (property_id, amount, category, fiscal_period,
                                   expense_date, description)
            VALUES ($1, 1600000, 'deposit_return', '2026-03', '2026-03-31', 'Return deposit')
        """, PROPERTY_ID)

        await db.execute("""
            UPDATE deposits SET status = 'returned', returned_amount = 1600000,
                                settled_at = '2026-03-31'
            WHERE id = $1
        """, seed['deposit_id'])

        # Verifikasi: expense ada
        expense = await db.fetchrow(
            "SELECT amount, category FROM expenses WHERE category = 'deposit_return'"
        )
        assert expense is not None
        assert expense['amount'] == Decimal('1600000')

        # Verifikasi: incomes masih kosong
        income_count = await db.fetchval(
            "SELECT COUNT(*) FROM incomes WHERE is_active = TRUE"
        )
        assert income_count == 0, "Pengembalian deposit tidak boleh membuat record di incomes"

    async def test_forfeiture_creates_income(self, db, seed):
        """
        SATU-SATUNYA skenario deposit masuk ke incomes:
        deposit DISITA karena penghuni kabur / kerusakan besar.
        """
        # Sita deposit
        await db.execute("""
            INSERT INTO incomes (property_id, reference_id, reference_type, amount,
                                  category, fiscal_period, income_date)
            VALUES ($1, $2, 'deposit', 1600000, 'deposit_forfeiture', '2026-03', CURRENT_DATE)
        """, PROPERTY_ID, seed['deposit_id'])

        await db.execute("""
            UPDATE deposits SET status = 'forfeited' WHERE id = $1
        """, seed['deposit_id'])

        # Verifikasi: income ada dengan kategori yang benar
        income = await db.fetchrow(
            "SELECT amount, category FROM incomes WHERE category = 'deposit_forfeiture'"
        )
        assert income is not None
        assert income['amount'] == Decimal('1600000')
        assert income['category'] == 'deposit_forfeiture'

    async def test_cannot_settle_twice(self, db, seed):
        """Deposit yang sudah settled tidak bisa diproses ulang"""
        # Settle pertama kali
        await db.execute(
            "UPDATE deposits SET status = 'returned' WHERE id = $1", seed['deposit_id']
        )

        # Coba settle lagi — status bukan 'held' lagi
        deposit = await db.fetchrow(
            "SELECT status FROM deposits WHERE id = $1", seed['deposit_id']
        )
        assert deposit['status'] != 'held', "Status harus sudah berubah"

        # Dalam aplikasi nyata: service layer harus raise error kalau status != 'held'


class TestGenerateInvoices:
    """
    Test untuk generate tagihan bulanan.
    Fokus pada idempotency — generate 2x = hasil sama.
    """

    async def test_generate_creates_invoice_and_receivable(self, db, seed):
        """Satu generate = satu rent_invoice + satu receivable"""
        count = await db.fetchval(
            "SELECT generate_monthly_invoices($1, '2026-03')", PROPERTY_ID
        )
        assert count >= 1

        invoice = await db.fetchrow(
            "SELECT id, amount FROM rent_invoices WHERE tenant_id = $1 AND period = '2026-03'",
            seed['tenant_id']
        )
        assert invoice is not None
        assert invoice['amount'] == seed['room_rate']

        receivable = await db.fetchrow(
            "SELECT id, amount FROM receivables WHERE invoice_id = $1", invoice['id']
        )
        assert receivable is not None
        assert receivable['amount'] == invoice['amount']

    async def test_generate_is_idempotent(self, db, seed):
        """Memanggil generate 2x tidak menduplikasi tagihan"""
        count_1 = await db.fetchval(
            "SELECT generate_monthly_invoices($1, '2026-03')", PROPERTY_ID
        )
        count_2 = await db.fetchval(
            "SELECT generate_monthly_invoices($1, '2026-03')", PROPERTY_ID
        )

        assert count_2 == 0, (
            f"Generate kedua harus return 0 (tidak ada duplikasi). Got: {count_2}"
        )

        total_invoices = await db.fetchval(
            "SELECT COUNT(*) FROM rent_invoices WHERE period = '2026-03'"
        )
        assert total_invoices == count_1, "Jumlah tagihan tidak boleh bertambah dari generate kedua"


class TestPayRent:
    """Test untuk pembayaran sewa"""

    async def test_pay_full_marks_receivable_paid(self, db, seed):
        """Bayar penuh → receivable.status = paid, invoice.status = paid"""
        # Generate tagihan dulu
        await db.execute(
            "SELECT generate_monthly_invoices($1, '2026-03')", PROPERTY_ID
        )
        receivable = await db.fetchrow(
            "SELECT id FROM receivables WHERE tenant_id = $1", seed['tenant_id']
        )

        await db.execute(
            "SELECT pay_rent($1, $2, 'cash', 'Test payment')",
            receivable['id'], seed['room_rate']
        )

        rv = await db.fetchrow("SELECT status, paid_amount FROM receivables WHERE id = $1",
                                receivable['id'])
        assert rv['status'] == 'paid'
        assert rv['paid_amount'] == seed['room_rate']

    async def test_partial_payment_marks_partial(self, db, seed):
        """Bayar sebagian → receivable.status = partial"""
        await db.execute(
            "SELECT generate_monthly_invoices($1, '2026-03')", PROPERTY_ID
        )
        receivable = await db.fetchrow(
            "SELECT id, amount FROM receivables WHERE tenant_id = $1", seed['tenant_id']
        )

        partial = Decimal('300000')
        await db.execute(
            "SELECT pay_rent($1, $2, 'cash', 'Cicilan pertama')",
            receivable['id'], partial
        )

        rv = await db.fetchrow("SELECT status, paid_amount FROM receivables WHERE id = $1",
                                receivable['id'])
        assert rv['status'] == 'partial'
        assert rv['paid_amount'] == partial

    async def test_overpayment_rejected(self, db, seed):
        """Bayar melebihi tagihan → ERROR"""
        await db.execute(
            "SELECT generate_monthly_invoices($1, '2026-03')", PROPERTY_ID
        )
        receivable = await db.fetchrow(
            "SELECT id, amount FROM receivables WHERE tenant_id = $1", seed['tenant_id']
        )

        with pytest.raises(Exception) as exc_info:
            await db.execute(
                "SELECT pay_rent($1, $2, 'cash', 'Overpayment test')",
                receivable['id'], receivable['amount'] + Decimal('500000')
            )

        assert "exceeds" in str(exc_info.value).lower()

    async def test_pay_records_income(self, db, seed):
        """Pembayaran sewa harus menciptakan record di tabel incomes"""
        await db.execute(
            "SELECT generate_monthly_invoices($1, '2026-03')", PROPERTY_ID
        )
        receivable = await db.fetchrow(
            "SELECT id FROM receivables WHERE tenant_id = $1", seed['tenant_id']
        )

        await db.execute(
            "SELECT pay_rent($1, $2, 'transfer', 'Test income recording')",
            receivable['id'], seed['room_rate']
        )

        income = await db.fetchrow(
            "SELECT amount, category FROM incomes WHERE reference_id = $1 AND is_active = TRUE",
            receivable['id']
        )
        assert income is not None
        assert income['category'] == 'rent'
        assert income['amount'] == seed['room_rate']


class TestAging:
    """Test untuk aging piutang"""

    async def test_overdue_update_changes_status(self, db, seed):
        """Receivable yang melewati due_date harus berubah ke overdue"""
        await db.execute(
            "SELECT generate_monthly_invoices($1, '2026-03')", PROPERTY_ID
        )

        # Set due_date ke masa lalu
        await db.execute("""
            UPDATE receivables SET due_date = '2026-01-01'
            WHERE tenant_id = $1
        """, seed['tenant_id'])

        await db.execute("SELECT update_overdue_receivables()")

        status = await db.fetchval(
            "SELECT status FROM receivables WHERE tenant_id = $1",
            seed['tenant_id']
        )
        assert status == 'overdue'

    async def test_paid_not_changed_to_overdue(self, db, seed):
        """Receivable yang sudah 'paid' tidak boleh berubah ke 'overdue'"""
        await db.execute(
            "SELECT generate_monthly_invoices($1, '2026-03')", PROPERTY_ID
        )
        receivable = await db.fetchrow(
            "SELECT id FROM receivables WHERE tenant_id = $1", seed['tenant_id']
        )

        # Bayar dulu
        await db.execute(
            "SELECT pay_rent($1, $2, 'cash', 'Full payment')",
            receivable['id'], seed['room_rate']
        )

        # Set due_date ke masa lalu + jalankan update overdue
        await db.execute("UPDATE receivables SET due_date = '2026-01-01' WHERE id = $1",
                          receivable['id'])
        await db.execute("SELECT update_overdue_receivables()")

        # Status harus tetap 'paid'
        status = await db.fetchval("SELECT status FROM receivables WHERE id = $1",
                                    receivable['id'])
        assert status == 'paid', "Status 'paid' tidak boleh diubah ke 'overdue'"
```

---

## Checklist Final Level 2

Jawab semua pertanyaan ini **tanpa melihat catatan**:

### Pertanyaan Konsep

```
□ Mengapa deposit BUKAN income? Apa konsekuensinya jika salah mencatat?

□ Kapan deposit BOLEH masuk ke tabel incomes?
  (Hint: skenario mana dari 3 skenario yang kita bahas?)

□ Apa bedanya cash basis dan accrual basis?
  Berikan contoh konkret dengan tanggal yang spesifik.

□ Di accrual basis, kapan income sewa April dicatat?
  Tanggal 1 April (tagihan dibuat) atau saat penghuni bayar?

□ Apa itu piutang (receivable)? Bedanya dengan invoice?

□ Mengapa generate tagihan harus IDEMPOTENT?
  Apa yang terjadi kalau tidak idempotent dan cron job jalan dua kali?

□ Apa itu aging piutang? Mengapa kita perlu bucket 30/60/90 hari?

□ Apa yang dimaksud rekonsiliasi? Sebutkan 2 rekonsiliasi yang penting di kos.
```

### Pertanyaan Teknis

```
□ Constraint UNIQUE (tenancy_id, period) di rent_invoices — apa fungsinya?

□ Kalau penghuni check-in 15 Maret 2026, berapa sewa pro-rata bulan Maret?
  (Kamar Rp 900.000/bulan, Maret ada 31 hari)

□ Di tabel deposits, kolom mana yang berubah saat deposit disita (forfeited)?

□ Query aging: hari_overdue negatif artinya apa?
  (Contoh: due_date = 10 April, sekarang 8 April, hari_overdue = -2)
```

### Mini Proyek — Wajib Diselesaikan

```
✅ POST /tenants/{id}/check-in         — check-in + buat deposit (BUKAN income)
✅ POST /invoices/generate/{period}    — generate tagihan bulanan (idempotent)
✅ POST /payments/rent/{id}/pay        — bayar sewa (update receivable + create income)
✅ POST /deposits/{id}/settle          — proses deposit: return/partial/forfeiture
✅ GET  /reports/aging                 — laporan aging piutang
✅ GET  /reports/reconciliation/{per}  — rekonsiliasi tagihan vs pembayaran bulan ini
```

Semua endpoint harus punya minimal 2 pytest yang pass (happy path + error case).

---

## Setelah Level 2 Selesai

Kalau kamu sudah bisa menjawab semua pertanyaan di checklist tanpa melihat
catatan, dan mini proyek sudah lengkap dengan test yang pass — kamu sudah
menguasai dua konsep terpenting di luar transaksi tunai:

**Yang sudah kamu kuasai di Level 2:**
- Deposit sebagai kewajiban: bisnis apapun yang menerima titipan (rental, event organizer, marketplace escrow)
- Accrual basis + piutang: bisnis subscription, kos, sekolah, SaaS
- Aging analysis: collections management
- Rekonsiliasi: validasi integritas data

**Yang belum bisa (perlu Level 3):**
- BPJS dan multi-payer (asuransi, korporat) ❌
- Double-entry bookkeeping penuh (jurnal, buku besar, neraca) ❌
- Laporan keuangan standar PSAK ❌
- Tax withholding (PPh 21 dokter, PPh 23) ❌

Lanjut ke `level-3-enterprise-finance.md` kalau sudah siap.

---

*Bagian dari seri: [akuntansi-untuk-developer.md](./akuntansi-untuk-developer.md) |
[kurikulum-belajar.md](./kurikulum-belajar.md) | [level-1-cash-business.md](./level-1-cash-business.md)*