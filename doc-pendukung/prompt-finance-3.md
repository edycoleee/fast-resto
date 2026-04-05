# 📘 Level 3A — Enterprise Finance: Chart of Accounts & Double-Entry Bookkeeping

> **Proyek referensi:** Modul Keuangan SIMRS (Sistem Informasi Manajemen Rumah Sakit)
> **File ini:** Modul 3.1 (CoA) + Modul 3.2 (Double-Entry)
> **File lanjutan:** `level-3b-bpjs-tax-reports.md` (BPJS, PPh 21, Laporan Keuangan)
> **Prasyarat:** Level 1 + Level 2 selesai 100%

---

## Sebelum Mulai: Mengapa Level 3 Berbeda?

Di Level 1, kamu belajar mencatat income dan expense ke dua tabel terpisah.
Di Level 2, kamu menambahkan konsep kewajiban (deposit) dan piutang (receivable).

Di Level 3, kita masuk ke **akuntansi penuh** — sistem yang digunakan perusahaan
besar, rumah sakit, dan entitas yang perlu menghasilkan laporan keuangan standar
(Neraca, Laba Rugi, Arus Kas) sesuai PSAK (Pernyataan Standar Akuntansi Keuangan).

Perbedaan mendasar:

```
Level 1-2: "Catat income dan expense"
  → Tabel: incomes, expenses
  → Output: Laporan L/R sederhana

Level 3: "Catat setiap pergerakan nilai ke akun yang tepat, dua sisi sekaligus"
  → Tabel: chart_of_accounts, journal_entries, journal_entry_lines
  → Output: L/R, Neraca, Arus Kas — semuanya dari satu sumber data
```

Analogi untuk developer:

```
Level 1-2 adalah seperti log file:
  [INFO] Income: +300.000 (treatment)
  [INFO] Expense: -50.000 (operasional)

Level 3 adalah seperti event sourcing penuh:
  Event: bayar_pasien
    → Kas +300.000 (aset bertambah)
    → Pendapatan +300.000 (revenue bertambah)
  Event: gaji_dokter
    → Kas -8.000.000 (aset berkurang)
    → Beban Gaji +8.000.000 (expense bertambah)

Dari tumpukan event ini, kamu bisa reconstruct state sistem di titik mana pun.
Neraca hari ini = semua event dari awal hingga sekarang.
```

---

## MODUL 3.1 — Chart of Accounts (CoA)

### Apa Itu Chart of Accounts?

Chart of Accounts (CoA) adalah **katalog semua akun keuangan** yang digunakan
sebuah entitas. Setiap transaksi keuangan harus menggunakan akun-akun dari CoA
— tidak boleh ada transaksi ke akun yang tidak terdaftar.

Bayangkan CoA seperti `ENUM` di database, tapi dengan hierarki:

```sql
-- Konsep sederhana:
CREATE TYPE account_code AS ENUM (
    '1100', -- Kas
    '1110', -- Bank BCA
    '1120', -- Bank Mandiri
    '1200', -- Piutang Pasien Umum
    '1210', -- Piutang BPJS
    -- ... ratusan akun lainnya
);

-- Masalahnya: ENUM tidak support hierarki dan tidak bisa ditambah runtime.
-- Solusinya: tabel dengan self-referencing parent_id.
```

### Struktur Penomoran CoA

Standar umum untuk rumah sakit di Indonesia:

```
1xxx — ASET (Harta)
  11xx — Aset Lancar
    1100 — Kas dan Setara Kas
    1110 — Bank (per rekening)
    1200 — Piutang (per jenis payer)
    1300 — Persediaan (obat, BMHP, dll)
  12xx — Aset Tidak Lancar
    1210 — Peralatan Medis
    1220 — Gedung dan Infrastruktur
    1290 — Akumulasi Penyusutan (akun kontra)

2xxx — KEWAJIBAN (Hutang)
  21xx — Kewajiban Jangka Pendek
    2100 — Hutang Supplier/Vendor
    2110 — Hutang Gaji (belum dibayar)
    2120 — Hutang Pajak (PPh 21 yang dipotong)
    2130 — Hutang PPN (pajak yang dipungut)
    2140 — Pendapatan Diterima Dimuka (deposit pasien)
  22xx — Kewajiban Jangka Panjang
    2200 — Hutang Bank (pinjaman)

3xxx — EKUITAS (Modal)
  3100 — Modal Disetor
  3200 — Laba Ditahan
  3300 — Laba/Rugi Tahun Berjalan

4xxx — PENDAPATAN
  41xx — Pendapatan Layanan
    4100 — Pendapatan Rawat Jalan Umum
    4110 — Pendapatan Rawat Jalan BPJS
    4120 — Pendapatan Rawat Inap Umum
    4130 — Pendapatan Rawat Inap BPJS
    4140 — Pendapatan Farmasi
    4150 — Pendapatan Laboratorium
    4160 — Pendapatan Radiologi
  42xx — Pendapatan Non-Layanan
    4200 — Pendapatan Sewa (parkir, kantin)
    4210 — Pendapatan Bunga Bank
    4290 — Pendapatan Lain-lain

5xxx — BEBAN OPERASIONAL
  51xx — Beban Personalia
    5100 — Beban Gaji Dokter
    5110 — Beban Gaji Perawat
    5120 — Beban Gaji Administrasi
    5130 — Beban PPh 21 Ditanggung RS
  52xx — Beban Langsung Medis
    5200 — Beban Obat dan BMHP
    5210 — Beban Alat Habis Pakai
  53xx — Beban Operasional Umum
    5300 — Beban Listrik dan Air
    5310 — Beban Pemeliharaan Peralatan
    5320 — Beban Administrasi dan Umum
  54xx — Beban Non-Operasional
    5400 — Beban Bunga Pinjaman
    5410 — Beban Penyusutan Aset Tetap
    5490 — Beban Lain-lain
```

### Langkah 3.1.1: Buat Tabel CoA di Database

```sql
-- schema_simrs.sql (bagian CoA)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TYPE account_type AS ENUM (
    'asset',       -- 1xxx
    'liability',   -- 2xxx
    'equity',      -- 3xxx
    'revenue',     -- 4xxx
    'expense'      -- 5xxx
);

CREATE TYPE account_normal_balance AS ENUM (
    'debit',   -- aset, beban: naik saat debit
    'credit'   -- kewajiban, ekuitas, pendapatan: naik saat kredit
);

CREATE TABLE hospitals (
    id      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name    VARCHAR(200) NOT NULL,
    code    VARCHAR(10)  NOT NULL UNIQUE
);

CREATE TABLE chart_of_accounts (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id     UUID NOT NULL REFERENCES hospitals(id),
    code            VARCHAR(10) NOT NULL,
    name            VARCHAR(200) NOT NULL,
    account_type    account_type NOT NULL,
    normal_balance  account_normal_balance NOT NULL,
    parent_id       UUID REFERENCES chart_of_accounts(id),
    is_header       BOOLEAN DEFAULT FALSE,  -- TRUE = akun induk (tidak boleh diposting)
    is_active       BOOLEAN DEFAULT TRUE,
    description     TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (hospital_id, code)
);

-- Index untuk query hierarki
CREATE INDEX idx_coa_parent   ON chart_of_accounts(parent_id);
CREATE INDEX idx_coa_hospital ON chart_of_accounts(hospital_id, code);
```

### Langkah 3.1.2: Seed CoA Dasar

```sql
-- Seed hospital
INSERT INTO hospitals (id, name, code)
VALUES ('aaaabbbb-0000-0000-0000-000000000001', 'RS Harapan Sehat', 'RSHS');

-- Helper: function untuk insert akun lebih mudah
CREATE OR REPLACE FUNCTION add_account(
    p_hospital_id  UUID,
    p_code         VARCHAR,
    p_name         VARCHAR,
    p_type         account_type,
    p_parent_code  VARCHAR DEFAULT NULL,
    p_is_header    BOOLEAN DEFAULT FALSE
) RETURNS UUID AS $$
DECLARE
    v_parent_id UUID;
    v_normal    account_normal_balance;
    v_id        UUID;
BEGIN
    -- Tentukan normal balance berdasarkan type
    v_normal := CASE p_type
        WHEN 'asset'     THEN 'debit'
        WHEN 'expense'   THEN 'debit'
        WHEN 'liability' THEN 'credit'
        WHEN 'equity'    THEN 'credit'
        WHEN 'revenue'   THEN 'credit'
    END;

    -- Cari parent_id kalau ada
    IF p_parent_code IS NOT NULL THEN
        SELECT id INTO v_parent_id
        FROM chart_of_accounts
        WHERE hospital_id = p_hospital_id AND code = p_parent_code;
    END IF;

    INSERT INTO chart_of_accounts
        (hospital_id, code, name, account_type, normal_balance, parent_id, is_header)
    VALUES
        (p_hospital_id, p_code, p_name, p_type, v_normal, v_parent_id, p_is_header)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

-- Fungsi shortcut
CREATE OR REPLACE FUNCTION coa(p_code VARCHAR, p_hospital_id UUID DEFAULT 'aaaabbbb-0000-0000-0000-000000000001')
RETURNS UUID AS $$
    SELECT id FROM chart_of_accounts WHERE code = p_code AND hospital_id = p_hospital_id;
$$ LANGUAGE sql;

-- Seed ASET
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '1000', 'ASET', 'asset', NULL, TRUE);
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '1100', 'Aset Lancar', 'asset', '1000', TRUE);
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '1101', 'Kas - Kasir Umum', 'asset', '1100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '1102', 'Kas - Kasir BPJS', 'asset', '1100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '1110', 'Bank BCA', 'asset', '1100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '1111', 'Bank Mandiri', 'asset', '1100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '1200', 'Piutang Usaha', 'asset', '1100', TRUE);
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '1201', 'Piutang Pasien Umum', 'asset', '1200');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '1202', 'Piutang BPJS', 'asset', '1200');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '1203', 'Piutang Asuransi Swasta', 'asset', '1200');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '1300', 'Persediaan', 'asset', '1100', TRUE);
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '1301', 'Persediaan Obat', 'asset', '1300');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '1302', 'Persediaan BMHP', 'asset', '1300');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '1200', 'Aset Tidak Lancar', 'asset', '1000', TRUE);
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '1501', 'Peralatan Medis', 'asset', '1200');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '1502', 'Gedung', 'asset', '1200');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '1590', 'Akumulasi Penyusutan', 'asset', '1200');

-- Seed KEWAJIBAN
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '2000', 'KEWAJIBAN', 'liability', NULL, TRUE);
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '2100', 'Kewajiban Jangka Pendek', 'liability', '2000', TRUE);
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '2101', 'Hutang Supplier Obat', 'liability', '2100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '2102', 'Hutang Supplier Umum', 'liability', '2100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '2110', 'Hutang Gaji', 'liability', '2100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '2120', 'Hutang PPh 21', 'liability', '2100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '2121', 'Hutang PPN', 'liability', '2100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '2130', 'Deposit Pasien', 'liability', '2100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '2200', 'Kewajiban Jangka Panjang', 'liability', '2000', TRUE);
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '2201', 'Hutang Bank', 'liability', '2200');

-- Seed EKUITAS
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '3000', 'EKUITAS', 'equity', NULL, TRUE);
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '3100', 'Modal Disetor', 'equity', '3000');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '3200', 'Laba Ditahan', 'equity', '3000');

-- Seed PENDAPATAN
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '4000', 'PENDAPATAN', 'revenue', NULL, TRUE);
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '4100', 'Pendapatan Layanan Medis', 'revenue', '4000', TRUE);
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '4101', 'Pendapatan RJ Umum', 'revenue', '4100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '4102', 'Pendapatan RJ BPJS', 'revenue', '4100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '4103', 'Pendapatan RI Umum', 'revenue', '4100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '4104', 'Pendapatan RI BPJS', 'revenue', '4100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '4110', 'Pendapatan Farmasi', 'revenue', '4100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '4120', 'Pendapatan Laboratorium', 'revenue', '4100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '4130', 'Pendapatan Radiologi', 'revenue', '4100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '4200', 'Pendapatan Non-Medis', 'revenue', '4000', TRUE);
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '4201', 'Pendapatan Parkir dan Kantin', 'revenue', '4200');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '4202', 'Pendapatan Bunga Bank', 'revenue', '4200');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '4290', 'Pendapatan Lain-lain', 'revenue', '4200');

-- Seed BEBAN
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '5000', 'BEBAN', 'expense', NULL, TRUE);
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '5100', 'Beban Personalia', 'expense', '5000', TRUE);
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '5101', 'Beban Gaji Dokter', 'expense', '5100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '5102', 'Beban Jasa Medis Dokter', 'expense', '5100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '5103', 'Beban Gaji Perawat', 'expense', '5100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '5104', 'Beban Gaji Administrasi', 'expense', '5100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '5110', 'Beban PPh 21 Ditanggung RS', 'expense', '5100');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '5200', 'Beban Langsung Medis', 'expense', '5000', TRUE);
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '5201', 'Beban Obat', 'expense', '5200');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '5202', 'Beban BMHP', 'expense', '5200');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '5300', 'Beban Operasional', 'expense', '5000', TRUE);
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '5301', 'Beban Listrik', 'expense', '5300');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '5302', 'Beban Air', 'expense', '5300');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '5303', 'Beban Pemeliharaan', 'expense', '5300');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '5304', 'Beban Administrasi Umum', 'expense', '5300');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '5400', 'Beban Non-Operasional', 'expense', '5000', TRUE);
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '5401', 'Beban Bunga Pinjaman', 'expense', '5400');
SELECT add_account('aaaabbbb-0000-0000-0000-000000000001', '5402', 'Beban Penyusutan', 'expense', '5400');
```

### Langkah 3.1.3: Query Hierarki CoA

```sql
-- Tampilkan CoA sebagai pohon hierarki
WITH RECURSIVE coa_tree AS (
    -- Titik mulai: akun tanpa parent (root accounts)
    SELECT
        id, code, name, account_type, normal_balance,
        parent_id, is_header,
        0 AS level,
        code AS sort_path
    FROM chart_of_accounts
    WHERE parent_id IS NULL
      AND hospital_id = 'aaaabbbb-0000-0000-0000-000000000001'

    UNION ALL

    -- Rekursi: ambil anak-anak dari setiap akun
    SELECT
        c.id, c.code, c.name, c.account_type, c.normal_balance,
        c.parent_id, c.is_header,
        t.level + 1,
        t.sort_path || '.' || c.code
    FROM chart_of_accounts c
    JOIN coa_tree t ON c.parent_id = t.id
)
SELECT
    REPEAT('  ', level) || code AS kode,
    REPEAT('  ', level) || name AS nama,
    account_type,
    CASE WHEN is_header THEN '[HEADER]' ELSE '' END AS jenis
FROM coa_tree
ORDER BY sort_path;

-- Contoh output:
-- 1000  ASET
--   1100  Aset Lancar
--     1101  Kas - Kasir Umum
--     1102  Kas - Kasir BPJS
--     1110  Bank BCA
--     ...
--   1200  Aset Tidak Lancar
-- 2000  KEWAJIBAN
-- ...
```

### Langkah 3.1.4: Validasi Persamaan Dasar Akuntansi

```sql
-- Persamaan dasar: ASET = KEWAJIBAN + EKUITAS
-- Selalu harus seimbang. Kalau tidak, ada bug di jurnal.

CREATE OR REPLACE VIEW v_accounting_equation AS
WITH balances AS (
    SELECT
        jel.account_id,
        coa.account_type,
        coa.normal_balance,
        SUM(jel.debit)  AS total_debit,
        SUM(jel.credit) AS total_credit
    FROM journal_entry_lines jel
    JOIN chart_of_accounts coa ON jel.account_id = coa.id
    JOIN journal_entries je ON jel.journal_entry_id = je.id
    WHERE je.is_posted = TRUE
    GROUP BY jel.account_id, coa.account_type, coa.normal_balance
),
account_balance AS (
    SELECT
        account_type,
        SUM(CASE
            WHEN normal_balance = 'debit' THEN total_debit - total_credit   -- aset, beban
            ELSE total_credit - total_debit                                  -- liability, equity, revenue
        END) AS saldo
    FROM balances
    GROUP BY account_type
)
SELECT
    SUM(CASE WHEN account_type = 'asset'   THEN saldo ELSE 0 END) AS total_aset,
    SUM(CASE WHEN account_type = 'liability' THEN saldo ELSE 0 END) AS total_kewajiban,
    SUM(CASE WHEN account_type = 'equity'  THEN saldo ELSE 0 END) AS total_ekuitas,
    SUM(CASE WHEN account_type = 'revenue' THEN saldo ELSE 0 END) AS total_pendapatan,
    SUM(CASE WHEN account_type = 'expense' THEN saldo ELSE 0 END) AS total_beban,
    -- Persamaan: ASET = KEWAJIBAN + EKUITAS + (PENDAPATAN - BEBAN)
    SUM(CASE WHEN account_type = 'asset' THEN saldo ELSE 0 END) -
    SUM(CASE WHEN account_type IN ('liability','equity') THEN saldo ELSE 0 END) -
    (SUM(CASE WHEN account_type = 'revenue' THEN saldo ELSE 0 END) -
     SUM(CASE WHEN account_type = 'expense' THEN saldo ELSE 0 END))
    AS selisih  -- Harus = 0, kalau tidak ada bug
FROM account_balance;
```

---

## MODUL 3.2 — Full Double-Entry Bookkeeping

### Prinsip Double-Entry untuk Developer

Ini adalah konsep paling abstrak tapi paling powerful di Level 3.

**Aturan dasar:**
> Setiap transaksi keuangan melibatkan minimal **dua akun**.
> Total debit dari semua akun yang di-debit **harus selalu sama** dengan
> total kredit dari semua akun yang di-kredit.
> Ini selalu, tanpa pengecualian.

```
DEBIT  = sebelah kiri T-account
CREDIT = sebelah kanan T-account

Untuk akun ASET dan BEBAN:    saldo naik = DEBIT
For akun LIABILITY, EQUITY, REVENUE: saldo naik = CREDIT
```

Bukan positif/negatif. Bukan tambah/kurang. Debit dan kredit adalah **posisi**
dalam sistem pencatatan, bukan nilai plus/minus.

Tabel referensi:

| Tipe Akun | Normal Balance | Saldo Naik | Saldo Turun |
|---|---|---|---|
| Aset | Debit | DEBIT | credit |
| Beban | Debit | DEBIT | credit |
| Kewajiban | Credit | DEBIT | CREDIT |
| Ekuitas | Credit | DEBIT | CREDIT |
| Pendapatan | Credit | debit | CREDIT |

### Langkah 3.2.1: Buat Tabel Journal

```sql
-- Journal entry header (satu per transaksi)
CREATE TABLE journal_entries (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id     UUID NOT NULL REFERENCES hospitals(id),
    entry_number    VARCHAR(30) NOT NULL,   -- JE-2026-03-0001
    entry_date      DATE NOT NULL,
    description     TEXT NOT NULL,
    reference_type  VARCHAR(50),            -- 'patient_payment', 'payroll', 'purchase', dll
    reference_id    UUID,
    is_posted       BOOLEAN DEFAULT FALSE,  -- FALSE = draft, TRUE = final
    is_reversed     BOOLEAN DEFAULT FALSE,
    reversal_of     UUID REFERENCES journal_entries(id),
    fiscal_period   VARCHAR(7) NOT NULL,    -- 'YYYY-MM'
    created_by      UUID,
    posted_by       UUID,
    posted_at       TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Journal entry lines (minimal 2 per entry)
CREATE TABLE journal_entry_lines (
    id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    journal_entry_id UUID NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
    account_id       UUID NOT NULL REFERENCES chart_of_accounts(id),
    debit            NUMERIC(15,2) NOT NULL DEFAULT 0,
    credit           NUMERIC(15,2) NOT NULL DEFAULT 0,
    description      TEXT,
    CONSTRAINT chk_debit_or_credit
        CHECK (debit >= 0 AND credit >= 0 AND (debit > 0 OR credit > 0)),
    CONSTRAINT chk_not_both
        CHECK (NOT (debit > 0 AND credit > 0))  -- satu baris tidak bisa debit dan credit sekaligus
);

-- Constraint: total debit = total credit per journal entry
-- Ini ditegakkan via trigger, bukan constraint biasa (karena perlu aggregate)
CREATE OR REPLACE FUNCTION check_journal_balance()
RETURNS TRIGGER AS $$
DECLARE
    v_total_debit  NUMERIC;
    v_total_credit NUMERIC;
    v_is_posted    BOOLEAN;
BEGIN
    -- Hanya cek kalau entry sudah di-post
    SELECT is_posted INTO v_is_posted
    FROM journal_entries WHERE id = NEW.journal_entry_id;

    IF v_is_posted THEN
        SELECT
            COALESCE(SUM(debit), 0),
            COALESCE(SUM(credit), 0)
        INTO v_total_debit, v_total_credit
        FROM journal_entry_lines
        WHERE journal_entry_id = NEW.journal_entry_id;

        IF v_total_debit != v_total_credit THEN
            RAISE EXCEPTION
                'Journal entry % tidak seimbang: total debit % != total kredit %',
                NEW.journal_entry_id, v_total_debit, v_total_credit;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_journal_balance
    AFTER INSERT OR UPDATE ON journal_entry_lines
    FOR EACH ROW EXECUTE FUNCTION check_journal_balance();

-- Trigger balance saat posting
CREATE OR REPLACE FUNCTION post_journal_entry(p_entry_id UUID, p_posted_by UUID)
RETURNS VOID AS $$
DECLARE
    v_total_debit  NUMERIC;
    v_total_credit NUMERIC;
    v_is_header    BOOLEAN;
    v_account_id   UUID;
BEGIN
    -- Cek apakah semua akun bukan header
    FOR v_account_id IN
        SELECT account_id FROM journal_entry_lines WHERE journal_entry_id = p_entry_id
    LOOP
        SELECT is_header INTO v_is_header FROM chart_of_accounts WHERE id = v_account_id;
        IF v_is_header THEN
            RAISE EXCEPTION 'Tidak bisa posting ke akun header. Gunakan akun detail.';
        END IF;
    END LOOP;

    -- Cek balance
    SELECT
        COALESCE(SUM(debit), 0),
        COALESCE(SUM(credit), 0)
    INTO v_total_debit, v_total_credit
    FROM journal_entry_lines
    WHERE journal_entry_id = p_entry_id;

    IF v_total_debit = 0 AND v_total_credit = 0 THEN
        RAISE EXCEPTION 'Journal entry kosong — tidak ada lines';
    END IF;

    IF v_total_debit != v_total_credit THEN
        RAISE EXCEPTION
            'Journal entry tidak seimbang: debit % != kredit %',
            v_total_debit, v_total_credit;
    END IF;

    -- Post entry
    UPDATE journal_entries
    SET is_posted = TRUE,
        posted_by = p_posted_by,
        posted_at = NOW()
    WHERE id = p_entry_id;
END;
$$ LANGUAGE plpgsql;

-- Function untuk auto-generate nomor jurnal
CREATE OR REPLACE FUNCTION next_journal_number(p_hospital_id UUID)
RETURNS VARCHAR AS $$
DECLARE
    v_month  VARCHAR(7);
    v_seq    INTEGER;
BEGIN
    v_month := TO_CHAR(CURRENT_DATE, 'YYYY-MM');
    SELECT COALESCE(MAX(CAST(SPLIT_PART(entry_number, '-', 4) AS INTEGER)), 0) + 1
    INTO v_seq
    FROM journal_entries
    WHERE hospital_id = p_hospital_id
      AND fiscal_period = v_month;

    RETURN 'JE-' || v_month || '-' || LPAD(v_seq::TEXT, 4, '0');
END;
$$ LANGUAGE plpgsql;
```

### Langkah 3.2.2: Menjurnal 5 Transaksi Umum RS

Dalam double-entry, setiap transaksi harus dijurnal dengan format:

```
DEBIT  [nama akun]  [jumlah]
KREDIT [nama akun]  [jumlah]
```

Praktikkan 5 transaksi berikut di psql:

#### Transaksi 1: Pasien Umum Bayar Tunai

> Pasien Tono bayar biaya rawat jalan Rp 350.000 tunai.

```
Analisis:
  - Kas bertambah → DEBIT Kas (aset naik)
  - Pendapatan bertambah → KREDIT Pendapatan RJ Umum (revenue naik)
```

```sql
-- Buat journal entry
INSERT INTO journal_entries (hospital_id, entry_number, entry_date,
                              description, reference_type, fiscal_period)
VALUES (
    'aaaabbbb-0000-0000-0000-000000000001',
    next_journal_number('aaaabbbb-0000-0000-0000-000000000001'),
    '2026-03-11',
    'Penerimaan pembayaran RJ - Pasien Tono',
    'patient_payment',
    '2026-03'
) RETURNING id;  -- catat UUID ini sebagai je_id

-- Tambah lines
INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit) VALUES
    ('<je_id>', coa('1101'), 350000, 0),      -- DEBIT  Kas-Kasir Umum
    ('<je_id>', coa('4101'), 0, 350000);       -- KREDIT Pendapatan RJ Umum

-- Post (finalize)
SELECT post_journal_entry('<je_id>', '<user_id>');
```

#### Transaksi 2: Beli Obat Secara Hutang ke Supplier

> RS beli obat Rp 3.200.000 dari PT Kimia Farma, belum dibayar.

```
Analisis:
  - Persediaan obat bertambah → DEBIT Persediaan Obat (aset naik)
  - Hutang bertambah → KREDIT Hutang Supplier Obat (liability naik)
```

```sql
INSERT INTO journal_entries
    (hospital_id, entry_number, entry_date, description, reference_type, fiscal_period)
VALUES (
    'aaaabbbb-0000-0000-0000-000000000001',
    next_journal_number('aaaabbbb-0000-0000-0000-000000000001'),
    '2026-03-11',
    'Pembelian obat - PT Kimia Farma',
    'purchase',
    '2026-03'
) RETURNING id;

INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit) VALUES
    ('<je_id>', coa('1301'), 3200000, 0),      -- DEBIT  Persediaan Obat
    ('<je_id>', coa('2101'), 0, 3200000);       -- KREDIT Hutang Supplier Obat

SELECT post_journal_entry('<je_id>', '<user_id>');
```

#### Transaksi 3: Bayar Hutang Supplier

> RS transfer Rp 3.200.000 ke PT Kimia Farma untuk melunasi hutang di atas.

```
Analisis:
  - Hutang berkurang → DEBIT Hutang Supplier Obat (liability turun)
  - Kas bank berkurang → KREDIT Bank Mandiri (aset turun)
```

```sql
INSERT INTO journal_entries
    (hospital_id, entry_number, entry_date, description, fiscal_period)
VALUES (
    'aaaabbbb-0000-0000-0000-000000000001',
    next_journal_number('aaaabbbb-0000-0000-0000-000000000001'),
    '2026-03-11', 'Pelunasan hutang - PT Kimia Farma', '2026-03'
) RETURNING id;

INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit) VALUES
    ('<je_id>', coa('2101'), 3200000, 0),      -- DEBIT  Hutang Supplier Obat  (hutang berkurang)
    ('<je_id>', coa('1111'), 0, 3200000);       -- KREDIT Bank Mandiri          (kas keluar)

SELECT post_journal_entry('<je_id>', '<user_id>');
```

#### Transaksi 4: Gaji Dokter dengan PPh 21

> Dokter Andi, fee jasa medis Rp 10.000.000. PPh 21: 5% × 50% × 10.000.000 = Rp 250.000.
> RS transfer gaji nett Rp 9.750.000.

```
Analisis:
  - Beban jasa dokter Rp 10.000.000 → DEBIT Beban Jasa Medis Dokter
  - Hutang PPh 21 Rp 250.000 → KREDIT Hutang PPh 21 (kewajiban pajak)
  - Kas bank Rp 9.750.000 → KREDIT Bank BCA (gaji nett yang ditransfer)
```

```sql
INSERT INTO journal_entries
    (hospital_id, entry_number, entry_date, description, fiscal_period)
VALUES (
    'aaaabbbb-0000-0000-0000-000000000001',
    next_journal_number('aaaabbbb-0000-0000-0000-000000000001'),
    '2026-03-31', 'Jasa medis Dr. Andi - Maret 2026', '2026-03'
) RETURNING id;

INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit) VALUES
    ('<je_id>', coa('5102'), 10000000, 0),     -- DEBIT  Beban Jasa Medis Dokter
    ('<je_id>', coa('2120'), 0, 250000),        -- KREDIT Hutang PPh 21
    ('<je_id>', coa('1110'), 0, 9750000);       -- KREDIT Bank BCA (gaji nett)

SELECT post_journal_entry('<je_id>', '<user_id>');

-- Perhatikan: 3 baris, bukan 2
-- Total debit  = 10.000.000
-- Total kredit = 250.000 + 9.750.000 = 10.000.000 ✓
```

#### Transaksi 5: Pasien Masuk dan Bayar Deposit (Uang Muka)

> Pasien rawat inap bayar uang muka perawatan Rp 2.000.000.
> Belum bisa dicatat sebagai pendapatan karena pelayanan belum diberikan.

```
Analisis:
  - Kas bertambah → DEBIT Kas Kasir Umum (aset naik)
  - Kewajiban (deposit pasien) bertambah → KREDIT Deposit Pasien (liability naik)
  Ini BUKAN pendapatan dulu, sama seperti deposit kos di Level 2!
```

```sql
INSERT INTO journal_entries
    (hospital_id, entry_number, entry_date, description, fiscal_period)
VALUES (
    'aaaabbbb-0000-0000-0000-000000000001',
    next_journal_number('aaaabbbb-0000-0000-0000-000000000001'),
    '2026-03-11', 'Uang muka RI - Pasien Budi Santoso', '2026-03'
) RETURNING id;

INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit) VALUES
    ('<je_id>', coa('1101'), 2000000, 0),      -- DEBIT  Kas Kasir Umum
    ('<je_id>', coa('2130'), 0, 2000000);       -- KREDIT Deposit Pasien

SELECT post_journal_entry('<je_id>', '<user_id>');

-- Saat pasien pulang dan semua tagihan diselesaikan:
-- Deposit dialihkan ke pendapatan:
-- DEBIT  Deposit Pasien    2.000.000
-- KREDIT Pendapatan RI Umum 2.000.000
```

### Langkah 3.2.3: Melihat Buku Besar (General Ledger)

Buku besar = semua transaksi dikelompokkan per akun, dengan saldo running.

```sql
-- Buku besar akun Kas - Kasir Umum (1101) bulan Maret
WITH transactions AS (
    SELECT
        je.entry_date,
        je.entry_number,
        je.description,
        jel.debit,
        jel.credit
    FROM journal_entry_lines jel
    JOIN journal_entries je ON jel.journal_entry_id = je.id
    JOIN chart_of_accounts coa ON jel.account_id = coa.id
    WHERE coa.code = '1101'
      AND je.fiscal_period = '2026-03'
      AND je.is_posted = TRUE
    ORDER BY je.entry_date, je.entry_number
),
with_running_balance AS (
    SELECT
        entry_date,
        entry_number,
        description,
        debit,
        credit,
        SUM(debit - credit) OVER (ORDER BY entry_date, entry_number) AS saldo
    FROM transactions
)
SELECT
    entry_date    AS tanggal,
    entry_number  AS no_jurnal,
    description   AS keterangan,
    debit         AS debit,
    credit        AS kredit,
    saldo         AS saldo
FROM with_running_balance;

-- Contoh output:
-- tanggal    | no_jurnal     | keterangan                  | debit   | kredit  | saldo
-- 2026-03-11 | JE-2026-03-0001 | Penerimaan RJ Pasien Tono  | 350000  | 0       | 350000
-- 2026-03-11 | JE-2026-03-0004 | Uang muka RI Budi Santoso  | 2000000 | 0       | 2350000
-- 2026-03-31 | JE-2026-03-0005 | Gaji Dr. Andi (nett)       | 0       | 9750000 | -7400000
```

### Langkah 3.2.4: Trial Balance (Neraca Saldo)

Trial balance = daftar semua akun dengan total debit dan kredit, untuk verifikasi seimbang.

```sql
-- Neraca saldo per 31 Maret 2026
WITH account_totals AS (
    SELECT
        coa.code,
        coa.name,
        coa.account_type,
        coa.normal_balance,
        COALESCE(SUM(jel.debit), 0)  AS total_debit,
        COALESCE(SUM(jel.credit), 0) AS total_credit
    FROM chart_of_accounts coa
    LEFT JOIN journal_entry_lines jel ON jel.account_id = coa.id
    LEFT JOIN journal_entries je ON jel.journal_entry_id = je.id
        AND je.fiscal_period = '2026-03'
        AND je.is_posted = TRUE
    WHERE coa.is_header = FALSE
      AND coa.hospital_id = 'aaaabbbb-0000-0000-0000-000000000001'
    GROUP BY coa.code, coa.name, coa.account_type, coa.normal_balance
    HAVING COALESCE(SUM(jel.debit), 0) > 0
        OR COALESCE(SUM(jel.credit), 0) > 0
)
SELECT
    code, name, account_type,
    total_debit   AS sisi_debit,
    total_credit  AS sisi_kredit
FROM account_totals
ORDER BY code;

-- Baris terakhir: total harus seimbang
SELECT
    SUM(total_debit)  AS grand_debit,
    SUM(total_credit) AS grand_kredit,
    SUM(total_debit) - SUM(total_credit) AS selisih  -- wajib = 0
FROM (
    -- query di atas
) t;
```

### Langkah 3.2.5: Reversal Journal Entry

Kalau ada jurnal yang salah input setelah di-post, tidak bisa di-DELETE.
Solusinya: **reversal** — buat jurnal baru yang membalik entri lama.

```sql
CREATE OR REPLACE FUNCTION reverse_journal_entry(
    p_entry_id    UUID,
    p_reversed_by UUID,
    p_reason      TEXT
) RETURNS UUID AS $$
DECLARE
    v_original   journal_entries%ROWTYPE;
    v_new_id     UUID;
    v_line       journal_entry_lines%ROWTYPE;
BEGIN
    SELECT * INTO v_original FROM journal_entries WHERE id = p_entry_id;

    IF NOT v_original.is_posted THEN
        RAISE EXCEPTION 'Hanya jurnal yang sudah posted yang bisa di-reverse';
    END IF;
    IF v_original.is_reversed THEN
        RAISE EXCEPTION 'Jurnal ini sudah pernah di-reverse sebelumnya';
    END IF;

    -- Buat jurnal reversal
    INSERT INTO journal_entries (
        hospital_id, entry_number, entry_date, description,
        reference_type, reference_id, fiscal_period, reversal_of, created_by
    )
    VALUES (
        v_original.hospital_id,
        next_journal_number(v_original.hospital_id),
        CURRENT_DATE,
        'REVERSAL: ' || v_original.description || ' — ' || p_reason,
        'reversal',
        p_entry_id,
        TO_CHAR(CURRENT_DATE, 'YYYY-MM'),
        p_entry_id,
        p_reversed_by
    )
    RETURNING id INTO v_new_id;

    -- Copy semua lines, tapi swap debit/credit
    FOR v_line IN
        SELECT * FROM journal_entry_lines WHERE journal_entry_id = p_entry_id
    LOOP
        INSERT INTO journal_entry_lines
            (journal_entry_id, account_id, debit, credit, description)
        VALUES (
            v_new_id,
            v_line.account_id,
            v_line.credit,   -- ← swap
            v_line.debit,    -- ← swap
            v_line.description
        );
    END LOOP;

    -- Post jurnal reversal
    SELECT post_journal_entry(v_new_id, p_reversed_by);

    -- Tandai original sebagai sudah di-reverse
    UPDATE journal_entries SET is_reversed = TRUE WHERE id = p_entry_id;

    RETURN v_new_id;
END;
$$ LANGUAGE plpgsql;

-- Contoh: reverse jurnal yang salah
SELECT reverse_journal_entry('<entry_id>', '<user_id>', 'Salah akun, seharusnya RJ BPJS bukan RJ Umum');
```

### Langkah 3.2.6: Saldo Akun (Account Balance)

Fungsi untuk menghitung saldo satu akun pada tanggal tertentu:

```sql
CREATE OR REPLACE FUNCTION get_account_balance(
    p_account_code VARCHAR,
    p_hospital_id  UUID,
    p_as_of_date   DATE DEFAULT CURRENT_DATE
) RETURNS NUMERIC AS $$
DECLARE
    v_total_debit  NUMERIC;
    v_total_credit NUMERIC;
    v_normal       account_normal_balance;
BEGIN
    SELECT normal_balance INTO v_normal
    FROM chart_of_accounts
    WHERE code = p_account_code AND hospital_id = p_hospital_id;

    SELECT
        COALESCE(SUM(jel.debit), 0),
        COALESCE(SUM(jel.credit), 0)
    INTO v_total_debit, v_total_credit
    FROM journal_entry_lines jel
    JOIN journal_entries je ON jel.journal_entry_id = je.id
    JOIN chart_of_accounts coa ON jel.account_id = coa.id
    WHERE coa.code = p_account_code
      AND coa.hospital_id = p_hospital_id
      AND je.entry_date <= p_as_of_date
      AND je.is_posted = TRUE;

    RETURN CASE v_normal
        WHEN 'debit'  THEN v_total_debit - v_total_credit
        WHEN 'credit' THEN v_total_credit - v_total_debit
    END;
END;
$$ LANGUAGE plpgsql;

-- Contoh penggunaan:
SELECT get_account_balance('1101', 'aaaabbbb-0000-0000-0000-000000000001'); -- saldo Kas Kasir
SELECT get_account_balance('2120', 'aaaabbbb-0000-0000-0000-000000000001'); -- saldo Hutang PPh 21
SELECT get_account_balance('4101', 'aaaabbbb-0000-0000-0000-000000000001'); -- total Pendapatan RJ Umum
```

---

## Pytest untuk Modul 3.1 & 3.2

```python
# tests/test_coa.py
import pytest
from decimal import Decimal

HOSPITAL_ID = "aaaabbbb-0000-0000-0000-000000000001"

class TestChartOfAccounts:

    async def test_header_account_cannot_be_posted(self, db):
        """Akun header (is_header=TRUE) tidak bisa dijurnal"""
        # Buat jurnal dengan akun header '1000' (ASET header)
        je = await db.fetchrow("""
            INSERT INTO journal_entries
                (hospital_id, entry_number, entry_date, description, fiscal_period)
            VALUES ($1, 'TEST-001', '2026-03-01', 'Test header', '2026-03')
            RETURNING id
        """, HOSPITAL_ID)

        header_id = await db.fetchval(
            "SELECT id FROM chart_of_accounts WHERE code = '1000' AND hospital_id = $1",
            HOSPITAL_ID
        )

        # Insert lines ke akun header
        await db.execute("""
            INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit)
            VALUES ($1, $2, 100000, 0), ($1, $2, 0, 100000)
        """, je['id'], header_id)

        with pytest.raises(Exception) as exc_info:
            await db.execute("SELECT post_journal_entry($1, gen_random_uuid())", je['id'])

        assert "header" in str(exc_info.value).lower()

    async def test_coa_normal_balance_set_automatically(self, db):
        """normal_balance harus otomatis berdasarkan account_type"""
        # Asset harus debit
        asset_balance = await db.fetchval(
            "SELECT normal_balance FROM chart_of_accounts WHERE code = '1101' AND hospital_id = $1",
            HOSPITAL_ID
        )
        assert asset_balance == 'debit'

        # Revenue harus credit
        rev_balance = await db.fetchval(
            "SELECT normal_balance FROM chart_of_accounts WHERE code = '4101' AND hospital_id = $1",
            HOSPITAL_ID
        )
        assert rev_balance == 'credit'

        # Liability harus credit
        liab_balance = await db.fetchval(
            "SELECT normal_balance FROM chart_of_accounts WHERE code = '2101' AND hospital_id = $1",
            HOSPITAL_ID
        )
        assert liab_balance == 'credit'


class TestJournalEntry:

    async def _get_account_id(self, db, code):
        return await db.fetchval(
            "SELECT id FROM chart_of_accounts WHERE code = $1 AND hospital_id = $2",
            code, HOSPITAL_ID
        )

    async def _create_posted_journal(self, db, lines: list[tuple]) -> str:
        """lines = [(account_code, debit, credit), ...]"""
        je = await db.fetchrow("""
            INSERT INTO journal_entries
                (hospital_id, entry_number, entry_date, description, fiscal_period)
            VALUES ($1, gen_random_uuid()::text, '2026-03-11', 'Test entry', '2026-03')
            RETURNING id
        """, HOSPITAL_ID)
        je_id = je['id']

        for code, debit, credit in lines:
            acc_id = await self._get_account_id(db, code)
            await db.execute("""
                INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit)
                VALUES ($1, $2, $3, $4)
            """, je_id, acc_id, debit, credit)

        await db.execute("SELECT post_journal_entry($1, gen_random_uuid())", je_id)
        return str(je_id)

    async def test_balanced_journal_posts_successfully(self, db):
        """Jurnal seimbang harus berhasil di-post"""
        je_id = await self._create_posted_journal(db, [
            ('1101', 350000, 0),     # DEBIT  Kas
            ('4101', 0, 350000),     # KREDIT Pendapatan
        ])
        is_posted = await db.fetchval(
            "SELECT is_posted FROM journal_entries WHERE id = $1", je_id
        )
        assert is_posted == True

    async def test_unbalanced_journal_rejected(self, db):
        """Jurnal tidak seimbang harus ditolak saat posting"""
        je = await db.fetchrow("""
            INSERT INTO journal_entries
                (hospital_id, entry_number, entry_date, description, fiscal_period)
            VALUES ($1, gen_random_uuid()::text, '2026-03-11', 'Unbalanced test', '2026-03')
            RETURNING id
        """, HOSPITAL_ID)

        kas_id = await self._get_account_id(db, '1101')
        rev_id = await self._get_account_id(db, '4101')

        await db.execute("""
            INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit)
            VALUES ($1, $2, 350000, 0), ($1, $3, 0, 300000)  -- 350k != 300k
        """, je['id'], kas_id, rev_id)

        with pytest.raises(Exception) as exc_info:
            await db.execute("SELECT post_journal_entry($1, gen_random_uuid())", je['id'])

        assert "tidak seimbang" in str(exc_info.value).lower() or \
               "balance" in str(exc_info.value).lower()

    async def test_three_leg_journal_balances(self, db):
        """Jurnal 3 kaki (gaji + PPh + bank) harus seimbang"""
        je_id = await self._create_posted_journal(db, [
            ('5102', 10000000, 0),    # DEBIT  Beban Jasa Dokter
            ('2120', 0, 250000),      # KREDIT Hutang PPh 21
            ('1110', 0, 9750000),     # KREDIT Bank BCA
        ])
        # Total debit = 10.000.000, total kredit = 250.000 + 9.750.000 = 10.000.000
        totals = await db.fetchrow("""
            SELECT SUM(debit) AS total_d, SUM(credit) AS total_c
            FROM journal_entry_lines WHERE journal_entry_id = $1
        """, je_id)
        assert totals['total_d'] == totals['total_c'] == Decimal('10000000')

    async def test_reversal_negates_original(self, db):
        """Setelah reversal, saldo akun harus kembali ke semula"""
        # Catat saldo awal Kas
        before = await db.fetchval(
            "SELECT get_account_balance('1101', $1)", HOSPITAL_ID
        )

        # Buat dan post jurnal
        je_id = await self._create_posted_journal(db, [
            ('1101', 500000, 0),
            ('4101', 0, 500000),
        ])

        # Saldo setelah transaksi
        after_entry = await db.fetchval(
            "SELECT get_account_balance('1101', $1)", HOSPITAL_ID
        )
        assert after_entry == before + Decimal('500000')

        # Reverse jurnal
        await db.execute(
            "SELECT reverse_journal_entry($1, gen_random_uuid(), 'Test reversal')", je_id
        )

        # Saldo harus kembali ke semula
        after_reversal = await db.fetchval(
            "SELECT get_account_balance('1101', $1)", HOSPITAL_ID
        )
        assert after_reversal == before

    async def test_cannot_reverse_twice(self, db):
        """Jurnal tidak bisa di-reverse dua kali"""
        je_id = await self._create_posted_journal(db, [
            ('1101', 100000, 0),
            ('4101', 0, 100000),
        ])

        await db.execute(
            "SELECT reverse_journal_entry($1, gen_random_uuid(), 'First reversal')", je_id
        )

        with pytest.raises(Exception) as exc_info:
            await db.execute(
                "SELECT reverse_journal_entry($1, gen_random_uuid(), 'Second reversal')", je_id
            )

        assert "sudah pernah" in str(exc_info.value).lower() or \
               "already" in str(exc_info.value).lower()

    async def test_accounting_equation_always_balanced(self, db):
        """Persamaan ASET = KEWAJIBAN + EKUITAS + (PENDAPATAN - BEBAN) harus selalu = 0"""
        # Buat beberapa jurnal
        await self._create_posted_journal(db, [
            ('1101', 350000, 0),
            ('4101', 0, 350000),
        ])
        await self._create_posted_journal(db, [
            ('5101', 500000, 0),
            ('1110', 0, 500000),
        ])

        equation = await db.fetchrow("SELECT selisih FROM v_accounting_equation")
        assert equation['selisih'] == Decimal('0'), (
            f"Persamaan akuntansi tidak seimbang! Selisih: {equation['selisih']}"
        )
```

---

## Checklist Modul 3.1 & 3.2

```
□ Apa itu Chart of Accounts? Mengapa perlu hierarki (parent-child)?

□ Sebutkan 5 kelompok akun dan nomor rangenya (1xxx–5xxx).

□ Apa itu "normal balance"? Mengapa aset memiliki normal balance debit
  sementara kewajiban memiliki normal balance kredit?

□ Kalau kas bertambah, apakah kita DEBIT atau KREDIT akun kas? Mengapa?

□ Jurnal untuk: pasien bayar Rp 500.000 tunai — tulis 2 baris jurnal!

□ Jurnal untuk: RS beli obat hutang Rp 2.000.000 — tulis 2 baris jurnal!

□ Jurnal untuk: gaji dokter Rp 8.000.000, PPh 21 Rp 200.000,
  nett transfer Rp 7.800.000 — tulis 3 baris jurnal!

□ Mengapa jurnal tidak bisa di-DELETE kalau sudah di-post?
  Apa solusinya jika ada kesalahan?

□ Apa itu trial balance (neraca saldo)? Apa yang diverifikasi dari trial balance?

□ Persamaan dasar akuntansi adalah? (ASET = ?)
```

---

*Lanjut ke: [level-3b-bpjs-tax-reports.md](./level-3b-bpjs-tax-reports.md) — BPJS, PPh 21, Laporan Keuangan Standar*

*Kembali ke: [level-2-receivables.md](./level-2-receivables.md) | [kurikulum-belajar.md](./kurikulum-belajar.md)*