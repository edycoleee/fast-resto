# 📘 Level 1 — Cash Business: Panduan Lengkap dari Nol

> **Proyek referensi:** Klinik Kecantikan Sultan Fatah
> **Durasi estimasi:** 4–6 minggu (santai tapi konsisten)
> **Yang kamu butuhkan:** PostgreSQL, Python/FastAPI, psql atau DBeaver, pytest
> **Yang TIDAK kamu butuhkan:** React, frontend, UI apapun

---

## Sebelum Mulai: Filosofi Belajar Level 1

### Jangan Tunggu Aplikasi Selesai

Bayangkan kamu belajar berenang. Kamu tidak perlu tunggu kolam renang olimpiade
selesai dibangun baru mulai belajar. Cukup kolam kecil, air setinggi lutut dulu
— yang penting kamu merasakan bagaimana air bekerja.

Begitu juga Level 1 ini. **Kamu tidak perlu tunggu Sultan Fatah selesai**.
Justru sebaliknya — kalau kamu memahami konsep keuangan sejak awal, kamu akan
membuat keputusan arsitektur yang jauh lebih baik saat membangun backend dan
frontend nanti.

### Frontend Bukan Bagian dari Belajar Akuntansi

Ini penting dan sering disalahpahami.

Frontend React adalah **lapisan presentasi** — ia hanya menampilkan angka yang
sudah dihitung di database dan backend. Kalau database-mu salah menghitung
income, apapun yang ditampilkan di React sudah salah dari awalnya. React tidak
bisa "memperbaiki" logika keuangan yang keliru di bawahnya.

Artinya: **seluruh inti akuntansi ada di database + backend**. Frontend hanya
membungkus. Jadi untuk belajar Level 1, kamu sama sekali tidak memerlukan React.

---

## Tiga Pilar Level 1

Level 1 selesai ketika kamu menguasai tiga hal ini:

```
Pilar 1: Database (PostgreSQL)
  → Tempat semua "hukum" keuangan ditegakkan
  → Trigger, function, constraint, view

Pilar 2: Backend (FastAPI)
  → Jembatan antara logic bisnis dan database
  → Service layer, endpoint, seed data

Pilar 3: Test (pytest)
  → Bukti bahwa kamu benar-benar paham, bukan sekadar hafal
  → Setiap skenario keuangan harus ada testnya
```

---

## Urutan Belajar

```
Minggu 1–2  : Database — baca, jalankan, eksperimen manual
Minggu 3    : Backend — bangun endpoint satu per satu
Minggu 4    : Pytest — tulis test untuk semua skenario keuangan
Minggu 5–6  : Integrasi + debug + review konsep yang masih bingung
```

Tidak harus sesuai jadwal persis. Yang penting **jangan loncat ke Pilar 2
sebelum Pilar 1 benar-benar paham**, dan jangan loncat ke Level 2 sebelum
Checkpoint Level 1 bisa dijawab tanpa melihat catatan.

---

## PILAR 1 — Database

### Langkah 1.1: Jalankan init.sql

Pertama, pastikan kamu bisa menjalankan `database/init.sql` dari awal sampai
akhir tanpa error.

```bash
# Buat database baru
createdb fast_clinic_dev

# Jalankan init.sql
psql -d fast_clinic_dev -f database/init.sql

# Verifikasi semua tabel ada
psql -d fast_clinic_dev -c "\dt"
```

Hasilnya harus ada 18 tabel:
`clinics`, `patients`, `practitioners`, `services`, `appointments`,
`appointment_status_history`, `invoices`, `invoice_items`, `payments`,
`incomes`, `expenses`, `fiscal_periods`, `roles`, `permissions`,
`role_permissions`, `users`, `user_sessions`, `audit_logs`.

Kalau ada error — baca pesannya, jangan skip. Error saat setup awal adalah
pelajaran paling berharga.

---

### Langkah 1.2: Baca init.sql Seperti Buku Cerita

Buka `database/init.sql` dan baca dari atas ke bawah. Jangan langsung
dijalankan semua — baca dulu, pahami setiap bagian. Untuk setiap tabel atau
function yang kamu temukan, jawab pertanyaan ini:

```
1. Tabel ini menyimpan apa?
2. Mengapa kolom ini ada? Bisa tidak tanpanya?
3. Mengapa ada constraint ini? Apa yang terjadi kalau tidak ada?
4. Siapa yang INSERT ke tabel ini? Siapa yang boleh DELETE?
```

**Bagian yang paling penting dibaca pertama kali:**

```
1. ENUM types (income_category, expense_category, payment_status)
   → Pahami: mengapa ENUM, bukan VARCHAR?

2. Tabel invoices
   → Perhatikan kolom: subtotal, discount, nett, tax_rate, tax, total
   → Tanya diri sendiri: mengapa ada kolom nett?

3. Tabel incomes
   → Perhatikan: tidak ada kolom total, hanya amount
   → Tanya: mengapa amount = nett saja, bukan total invoice?

4. Tabel fiscal_periods
   → Perhatikan: is_closed, opening_balance_income
   → Tanya: apa yang terjadi kalau is_closed = TRUE?

5. Function confirm_payment()
   → Baca pelan-pelan setiap baris
   → Ini adalah "jantung" sistem kasir

6. Function guard_fiscal_period()
   → Ini adalah "polisi" yang menjaga fiscal period
```

---

### Langkah 1.3: Eksperimen Manual di psql

Ini adalah sesi paling berharga. Buka psql dan coba skenario berikut satu per
satu. **Jangan hanya copy-paste** — ketik sendiri, perhatikan setiap hasilnya.

#### Skenario A: Alur Transaksi Normal (Happy Path)

```sql
-- Step 1: Lihat data seed yang sudah ada
SELECT id, name, code FROM clinics;
SELECT id, name FROM services LIMIT 5;
SELECT id, name FROM users WHERE email = 'admin@sultanfatah.com';

-- Catat UUID clinic, service, dan user untuk dipakai di bawah

-- Step 2: Buat pasien baru
INSERT INTO patients (clinic_id, full_name, phone, gender)
VALUES ('<clinic_id>', 'Siti Aminah', '08123456789', 'female')
RETURNING id, mrn;

-- Step 3: Buat appointment
INSERT INTO appointments (
    clinic_id, patient_id, service_id, scheduled_at, practitioner_id
) VALUES (
    '<clinic_id>', '<patient_id>', '<service_id>',
    NOW() + INTERVAL '1 hour', '<practitioner_id>'
) RETURNING id, status;

-- Amati: status = 'booked' secara default

-- Step 4: Jalankan state machine
SELECT change_appointment_status('<appointment_id>', 'checked_in', '<user_id>', NULL);
SELECT change_appointment_status('<appointment_id>', 'in_treatment', '<user_id>', NULL);
SELECT change_appointment_status('<appointment_id>', 'completed', '<user_id>', NULL);

-- Cek status history
SELECT * FROM appointment_status_history WHERE appointment_id = '<appointment_id>';

-- Step 5: Buat invoice
INSERT INTO invoices (
    clinic_id, patient_id, appointment_id,
    subtotal, discount, nett, tax_rate, tax, total, status
) VALUES (
    '<clinic_id>', '<patient_id>', '<appointment_id>',
    300000, 0, 300000, 0, 0, 300000, 'issued'
) RETURNING id, nett, total;

INSERT INTO invoice_items (invoice_id, description, unit_price, quantity, subtotal)
VALUES ('<invoice_id>', 'Facial Treatment', 300000, 1, 300000);

-- Step 6: Buat payment (pending)
INSERT INTO payments (
    invoice_id, amount, method, status
) VALUES (
    '<invoice_id>', 300000, 'cash', 'pending'
) RETURNING id;

-- Step 7: Konfirmasi payment
SELECT confirm_payment('<payment_id>', '<user_id>');

-- Step 8: Lihat hasilnya
SELECT * FROM payments WHERE id = '<payment_id>';
SELECT * FROM incomes WHERE payment_id = '<payment_id>';
SELECT status FROM invoices WHERE id = '<invoice_id>';

-- Pertanyaan: berapa incomes.amount? Sama dengan invoice.total atau invoice.nett?
```

#### Skenario B: Void Payment (Memahami Atomicity)

```sql
-- Lanjut dari skenario A, coba void payment yang sudah confirmed
SELECT void_payment('<payment_id>', '<user_id>', 'Test void', FALSE);

-- Lihat apa yang berubah
SELECT status FROM payments WHERE id = '<payment_id>';
SELECT is_active FROM incomes WHERE payment_id = '<payment_id>';
SELECT status FROM invoices WHERE id = '<invoice_id>';

-- Pertanyaan: apakah income terhapus? Atau hanya is_active = FALSE?
-- Pertanyaan: apakah bisa void lagi setelah sudah void?
```

#### Skenario C: Fiscal Period Locking

```sql
-- Tutup buku Maret 2026
SELECT close_fiscal_period('<clinic_id>', '2026-03', '<user_id>');

-- Cek status
SELECT * FROM fiscal_periods WHERE clinic_id = '<clinic_id>';

-- Coba insert income ke period yang sudah closed
INSERT INTO incomes (
    clinic_id, payment_id, amount, category, fiscal_period, income_date, created_by
) VALUES (
    '<clinic_id>', NULL, 100000, 'other', '2026-03', '2026-03-01', '<user_id>'
);
-- ↑ Harusnya ERROR dari trigger guard_fiscal_period()
-- Baca pesan errornya — apa yang dikatakannya?

-- Income ke period baru (April) harus berhasil
INSERT INTO incomes (
    clinic_id, payment_id, amount, category, fiscal_period, income_date, created_by
) VALUES (
    '<clinic_id>', NULL, 100000, 'other', '2026-04', '2026-04-01', '<user_id>'
);
-- ↑ Harusnya berhasil
```

#### Skenario D: Invoice dengan PPN

```sql
-- Invoice dengan diskon + PPN 11%
-- Kasus: Facial Rp 400.000, diskon 10%, PPN 11%

-- Hitung manual dulu:
-- subtotal = 400.000
-- discount = 40.000 (10%)
-- nett     = 360.000  ← yang harus masuk incomes
-- tax      = 39.600   (360.000 × 11%)
-- total    = 399.600  ← yang dibayar pasien

INSERT INTO invoices (
    clinic_id, patient_id,
    subtotal, discount, nett, tax_rate, tax, total, status
) VALUES (
    '<clinic_id>', '<patient_id>',
    400000, 40000, 360000, 0.11, 39600, 399600, 'issued'
) RETURNING id, nett, tax, total;

INSERT INTO payments (invoice_id, amount, method, status)
VALUES ('<invoice_id>', 399600, 'qris', 'pending')
RETURNING id;

SELECT confirm_payment('<payment_id>', '<user_id>');

-- Cek hasilnya
SELECT i.nett, i.tax, i.total, inc.amount AS income_amount
FROM invoices i
JOIN payments p ON p.invoice_id = i.id
JOIN incomes inc ON inc.payment_id = p.id
WHERE i.id = '<invoice_id>';

-- Pertanyaan kunci: income_amount = 360.000 (nett) atau 399.600 (total)?
-- Kalau 360.000 → BENAR, kamu mengerti prinsip tax
-- Kalau 399.600 → ada bug di function confirm_payment()
```

#### Skenario E: Opening Balance

```sql
-- Set saldo awal klinik di bulan April 2026
SELECT set_opening_balance(
    '<clinic_id>',
    '2026-04',
    5000000,   -- kas awal Rp 5 juta
    1500000,   -- hutang awal Rp 1.5 juta
    '<user_id>'
);

-- Cek hasilnya
SELECT * FROM fiscal_periods WHERE period = '2026-04';
SELECT * FROM incomes WHERE category = 'opening_balance';
SELECT * FROM expenses WHERE fiscal_period = '2026-04';

-- Coba panggil opening balance lagi di period yang sama
SELECT set_opening_balance('<clinic_id>', '2026-04', 5000000, 0, '<user_id>');
-- ↑ Harusnya ERROR (idempotency guard)
```

---

### Langkah 1.4: Pahami Prinsip Tax dan Nett

Ini satu konsep yang paling sering salah. Perlu waktu khusus untuk benar-benar
mengendap.

**Manual calculation exercise:**

Ambil kertas, hitung tanpa komputer:

```
Invoice 1:
  Produk   : Serum Vitamin C Rp 150.000
  Treatment: Facial Rp 250.000
  ───────────────────────────────────
  Subtotal : Rp 400.000
  Diskon 5%: Rp  20.000
  ───────────────────────────────────
  Nett     : Rp 380.000  ← BERAPA INCOMES.AMOUNT?
  PPN 11%  : Rp  41.800
  ───────────────────────────────────
  Total    : Rp 421.800  ← BERAPA YANG DITERIMA KASIR?

Jawaban:
  incomes.amount = 380.000  (nett saja, exclude PPN)
  kasir terima   = 421.800  (total termasuk PPN titipan ke negara)
  selisih        =  41.800  → bukan milik klinik, harus disetor ke DJP
```

Kalau kamu bisa menjelaskan *mengapa* angkanya berbeda tanpa melihat catatan,
kamu sudah lulus bagian ini.

---

### Langkah 1.5: Buat View Laporan Sendiri

Setelah eksperimen di atas, coba buat query laporan L/R dari nol **tanpa
melihat** `v_monthly_finance`:

```sql
-- Target output:
-- fiscal_period | total_income | total_expense | net_balance
-- 2026-03       | xxx          | xxx           | xxx

-- Coba buat sendiri dulu, baru bandingkan dengan v_monthly_finance
SELECT * FROM v_monthly_finance WHERE clinic_id = '<clinic_id>';
```

Kalau query kamu menghasilkan angka yang sama dengan view — kamu benar-benar
paham.

---

## PILAR 2 — Backend (FastAPI)

### Prinsip Backend Keuangan

Sebelum nulis satu baris kode pun, ingat dua aturan ini:

> **Aturan 1:** Jangan pernah INSERT/UPDATE tabel keuangan langsung dari service layer.
> Selalu panggil DB function (`confirm_payment()`, `void_payment()`, dll).
> Logic ada di DB, bukan di Python.

> **Aturan 2:** Endpoint keuangan harus return error yang informatif.
> Jangan tangkap exception lalu return `{"error": "Something went wrong"}`.
> User harus tahu *mengapa* gagal — "Fiscal period 2026-03 is closed", bukan "Internal Server Error".

### Struktur Project

```
backend/
├── app/
│   ├── main.py
│   ├── database.py          ← koneksi PostgreSQL (asyncpg / psycopg2)
│   ├── models/
│   │   ├── invoice.py
│   │   ├── payment.py
│   │   └── income.py
│   ├── repositories/
│   │   ├── invoice_repo.py
│   │   ├── payment_repo.py
│   │   └── report_repo.py
│   ├── services/
│   │   ├── billing_service.py
│   │   └── report_service.py
│   └── routers/
│       ├── invoices.py
│       ├── payments.py
│       └── reports.py
├── tests/
│   ├── conftest.py
│   ├── test_billing.py
│   └── test_reports.py
└── requirements.txt
```

### Langkah 2.1: Setup Database Connection

```python
# app/database.py
import os
import asyncpg
from contextlib import asynccontextmanager

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://localhost/fast_clinic_dev")

async def get_connection():
    return await asyncpg.connect(DATABASE_URL)

@asynccontextmanager
async def db_transaction():
    conn = await get_connection()
    async with conn.transaction():
        try:
            yield conn
        finally:
            await conn.close()
```

### Langkah 2.2: Endpoint Pertama — Buat Invoice

Mulai dari yang paling sederhana dulu. Bukan confirm_payment, tapi buat invoice.
Kenapa? Karena ini tidak ada logic keuangan kompleks — hanya INSERT dengan
validasi.

```python
# app/routers/invoices.py
from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel, validator
from decimal import Decimal
from uuid import UUID

router = APIRouter(prefix="/invoices", tags=["invoices"])

class InvoiceItemIn(BaseModel):
    description: str
    unit_price: Decimal
    quantity: int

    @validator('unit_price')
    def price_must_be_positive(cls, v):
        if v <= 0:
            raise ValueError('unit_price must be positive')
        return v

    @validator('quantity')
    def quantity_must_be_positive(cls, v):
        if v <= 0:
            raise ValueError('quantity must be positive')
        return v

class CreateInvoiceIn(BaseModel):
    clinic_id: UUID
    patient_id: UUID
    appointment_id: UUID | None = None
    items: list[InvoiceItemIn]
    discount: Decimal = Decimal('0')
    tax_rate: Decimal = Decimal('0')  # 0.11 untuk PPN 11%

@router.post("/")
async def create_invoice(data: CreateInvoiceIn):
    subtotal = sum(item.unit_price * item.quantity for item in data.items)
    discount = data.discount
    nett = subtotal - discount
    tax = (nett * data.tax_rate).quantize(Decimal('0.01'))
    total = nett + tax

    if nett <= 0:
        raise HTTPException(400, "Discount cannot exceed subtotal")

    async with db_transaction() as conn:
        # Insert invoice
        invoice = await conn.fetchrow("""
            INSERT INTO invoices (
                clinic_id, patient_id, appointment_id,
                subtotal, discount, nett, tax_rate, tax, total,
                status, created_by
            ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,'issued',$10)
            RETURNING id, invoice_number, nett, tax, total
        """, data.clinic_id, data.patient_id, data.appointment_id,
            subtotal, discount, nett, data.tax_rate, tax, total,
            data.clinic_id  # TODO: ganti dengan user dari JWT
        )

        # Insert items
        for item in data.items:
            await conn.execute("""
                INSERT INTO invoice_items (invoice_id, description, unit_price, quantity, subtotal)
                VALUES ($1, $2, $3, $4, $5)
            """, invoice['id'], item.description, item.unit_price,
                item.quantity, item.unit_price * item.quantity
            )

    return {
        "invoice_id": str(invoice['id']),
        "invoice_number": invoice['invoice_number'],
        "nett": float(invoice['nett']),
        "tax": float(invoice['tax']),
        "total": float(invoice['total'])
    }
```

Test manual dengan curl atau httpie:
```bash
http POST localhost:8000/invoices \
  clinic_id=<uuid> patient_id=<uuid> \
  items:='[{"description":"Facial","unit_price":300000,"quantity":1}]' \
  tax_rate=0.11
```

Kalau berhasil dan angkanya benar → lanjut ke endpoint berikutnya.

### Langkah 2.3: Endpoint confirm_payment (Yang Paling Penting)

```python
# app/routers/payments.py
from fastapi import APIRouter, HTTPException
from uuid import UUID

router = APIRouter(prefix="/payments", tags=["payments"])

class CreatePaymentIn(BaseModel):
    invoice_id: UUID
    amount: Decimal
    method: str  # 'cash', 'transfer', 'qris', 'debit_card', 'credit_card'

@router.post("/")
async def create_payment(data: CreatePaymentIn):
    """Buat payment dengan status pending"""
    valid_methods = {'cash', 'transfer', 'qris', 'debit_card', 'credit_card'}
    if data.method not in valid_methods:
        raise HTTPException(400, f"Invalid method. Must be one of: {valid_methods}")

    async with db_transaction() as conn:
        # Validasi invoice exist dan belum paid
        invoice = await conn.fetchrow(
            "SELECT id, total, status FROM invoices WHERE id = $1",
            data.invoice_id
        )
        if not invoice:
            raise HTTPException(404, "Invoice not found")
        if invoice['status'] == 'paid':
            raise HTTPException(400, "Invoice already paid")
        if invoice['status'] == 'void':
            raise HTTPException(400, "Cannot create payment for voided invoice")

        payment = await conn.fetchrow("""
            INSERT INTO payments (invoice_id, amount, method, status)
            VALUES ($1, $2, $3, 'pending')
            RETURNING id, receipt_number
        """, data.invoice_id, data.amount, data.method)

    return {
        "payment_id": str(payment['id']),
        "receipt_number": payment['receipt_number'],
        "status": "pending"
    }


@router.post("/{payment_id}/confirm")
async def confirm_payment(payment_id: UUID, confirmed_by: UUID):
    """
    Konfirmasi payment — memanggil DB function confirm_payment().
    Ini adalah operasi keuangan paling penting di sistem.
    INGAT: logic ada di DB, bukan di sini.
    """
    async with db_transaction() as conn:
        try:
            await conn.execute(
                "SELECT confirm_payment($1, $2)",
                payment_id, confirmed_by
            )
        except asyncpg.exceptions.RaiseError as e:
            # DB function raise exception dengan pesan yang informative
            raise HTTPException(400, str(e))

    return {"status": "confirmed", "message": "Payment confirmed, income recorded"}


@router.post("/{payment_id}/void")
async def void_payment(
    payment_id: UUID,
    voided_by: UUID,
    reason: str,
    create_refund_expense: bool = False
):
    """
    Void payment — memanggil DB function void_payment().
    Selalu pakai endpoint ini, jangan UPDATE status manual.
    """
    if not reason or len(reason.strip()) < 5:
        raise HTTPException(400, "Reason must be at least 5 characters")

    async with db_transaction() as conn:
        try:
            await conn.execute(
                "SELECT void_payment($1, $2, $3, $4)",
                payment_id, voided_by, reason, create_refund_expense
            )
        except asyncpg.exceptions.RaiseError as e:
            raise HTTPException(400, str(e))

    return {"status": "voided", "message": "Payment voided, income deactivated"}
```

Perhatikan pola di endpoint `confirm` dan `void`: **tidak ada logic keuangan di
Python**. Python hanya memanggil DB function dan menangani error. Logic
sepenuhnya di PostgreSQL.

### Langkah 2.4: Endpoint Laporan

```python
# app/routers/reports.py
from fastapi import APIRouter, Query
from uuid import UUID
import re

router = APIRouter(prefix="/reports", tags=["reports"])

@router.get("/monthly")
async def monthly_report(
    clinic_id: UUID,
    period: str = Query(..., regex="^\\d{4}-\\d{2}$")  # format YYYY-MM
):
    """
    Laporan keuangan bulanan dari v_monthly_finance.
    Ini adalah laporan utama — dibaca dari incomes + expenses saja.
    """
    async with db_transaction() as conn:
        row = await conn.fetchrow("""
            SELECT fiscal_period, is_closed, opening_balance,
                   total_income, total_expense, net_balance, closing_balance
            FROM v_monthly_finance
            WHERE clinic_id = $1 AND fiscal_period = $2
        """, clinic_id, period)

        if not row:
            return {
                "period": period,
                "is_closed": False,
                "total_income": 0,
                "total_expense": 0,
                "net_balance": 0,
                "message": "No transactions recorded for this period"
            }

        # Breakdown by category
        incomes = await conn.fetch("""
            SELECT category, SUM(amount) AS total
            FROM incomes
            WHERE clinic_id = $1 AND fiscal_period = $2 AND is_active = TRUE
            GROUP BY category ORDER BY total DESC
        """, clinic_id, period)

        expenses = await conn.fetch("""
            SELECT category, SUM(amount) AS total
            FROM expenses
            WHERE clinic_id = $1 AND fiscal_period = $2 AND is_active = TRUE
            GROUP BY category ORDER BY total DESC
        """, clinic_id, period)

    return {
        "period": row['fiscal_period'],
        "is_closed": row['is_closed'],
        "opening_balance": float(row['opening_balance'] or 0),
        "total_income": float(row['total_income'] or 0),
        "total_expense": float(row['total_expense'] or 0),
        "net_balance": float(row['net_balance'] or 0),
        "closing_balance": float(row['closing_balance'] or 0),
        "income_breakdown": [
            {"category": r['category'], "total": float(r['total'])}
            for r in incomes
        ],
        "expense_breakdown": [
            {"category": r['category'], "total": float(r['total'])}
            for r in expenses
        ]
    }


@router.post("/fiscal-periods/{period}/close")
async def close_fiscal_period(period: str, clinic_id: UUID, closed_by: UUID):
    """Tutup buku — setelah ini tidak ada transaksi baru ke period ini"""
    if not re.match(r"^\d{4}-\d{2}$", period):
        raise HTTPException(400, "Period format must be YYYY-MM")

    async with db_transaction() as conn:
        try:
            await conn.execute(
                "SELECT close_fiscal_period($1, $2, $3)",
                clinic_id, period, closed_by
            )
        except asyncpg.exceptions.RaiseError as e:
            raise HTTPException(400, str(e))

    return {"status": "closed", "period": period, "message": f"Period {period} is now locked"}
```

### Langkah 2.5: Seed Data untuk Testing

Buat file seed data yang bisa dijalankan sebelum test:

```python
# tests/seed.py
"""
Seed data untuk testing keuangan.
Bukan dummy data — ini adalah data realistis yang mewakili situasi nyata.
"""
import asyncio
import asyncpg
from decimal import Decimal

async def seed_test_data(conn):
    # Ambil data yang sudah ada dari init.sql
    clinic = await conn.fetchrow("SELECT id FROM clinics WHERE code = 'SFAT'")
    admin  = await conn.fetchrow("SELECT id FROM users WHERE email = 'admin@sultanfatah.com'")
    service = await conn.fetchrow("SELECT id FROM services LIMIT 1")

    clinic_id = clinic['id']
    admin_id  = admin['id']
    service_id = service['id']

    # Buat pasien test
    patient = await conn.fetchrow("""
        INSERT INTO patients (clinic_id, full_name, phone, gender)
        VALUES ($1, 'Test Patient Ayu', '08111222333', 'female')
        RETURNING id
    """, clinic_id)

    # Buat invoice siap pakai (status issued, nett exclude PPN)
    invoice = await conn.fetchrow("""
        INSERT INTO invoices (
            clinic_id, patient_id,
            subtotal, discount, nett, tax_rate, tax, total, status, created_by
        ) VALUES ($1, $2, 300000, 0, 300000, 0, 0, 300000, 'issued', $3)
        RETURNING id
    """, clinic_id, patient['id'], admin_id)

    await conn.execute("""
        INSERT INTO invoice_items (invoice_id, description, unit_price, quantity, subtotal)
        VALUES ($1, 'Facial Treatment', 300000, 1, 300000)
    """, invoice['id'])

    # Buat payment pending
    payment = await conn.fetchrow("""
        INSERT INTO payments (invoice_id, amount, method, status)
        VALUES ($1, 300000, 'cash', 'pending')
        RETURNING id
    """, invoice['id'])

    return {
        "clinic_id": clinic_id,
        "admin_id": admin_id,
        "patient_id": patient['id'],
        "invoice_id": invoice['id'],
        "payment_id": payment['id'],
    }
```

---

## PILAR 3 — Pytest

### Mengapa Test adalah Cara Terbaik Belajar Akuntansi

Ketika kamu menulis test, kamu dipaksa berpikir:
*"kalau saya void payment dua kali, apa yang seharusnya terjadi?"*

Saat kamu menjawab pertanyaan itu dan mengkodekannya sebagai assertion — kamu
sedang belajar akuntansi jauh lebih dalam dari sekadar membaca teori.

### Setup conftest.py

```python
# tests/conftest.py
import pytest
import asyncio
import asyncpg
from tests.seed import seed_test_data

TEST_DB_URL = "postgresql://localhost/fast_clinic_test"

@pytest.fixture(scope="session")
def event_loop():
    loop = asyncio.get_event_loop_policy().new_event_loop()
    yield loop
    loop.close()

@pytest.fixture
async def db():
    """
    Setiap test dapat koneksi dengan transaction yang di-rollback di akhir.
    Jadi setiap test mulai dari state yang bersih.
    """
    conn = await asyncpg.connect(TEST_DB_URL)
    tr = conn.transaction()
    await tr.start()
    yield conn
    await tr.rollback()  # semua perubahan dibuang setelah test selesai
    await conn.close()

@pytest.fixture
async def seed(db):
    """Seed data siap pakai"""
    return await seed_test_data(db)
```

### Test Suite Lengkap

```python
# tests/test_billing.py
import pytest
from decimal import Decimal

class TestConfirmPayment:
    """
    Test untuk confirm_payment() — operasi paling kritis di sistem.
    Setiap test mewakili satu skenario bisnis nyata.
    """

    async def test_confirm_creates_income_with_nett_amount(self, db, seed):
        """
        PRINSIP: income.amount harus = invoice.nett, BUKAN invoice.total
        Ini memastikan tax tidak masuk ke laporan pendapatan klinik.
        """
        # Buat invoice dengan PPN 11%
        invoice = await db.fetchrow("""
            INSERT INTO invoices (
                clinic_id, patient_id,
                subtotal, discount, nett, tax_rate, tax, total, status, created_by
            ) VALUES ($1, $2, 400000, 40000, 360000, 0.11, 39600, 399600, 'issued', $3)
            RETURNING id, nett, total
        """, seed['clinic_id'], seed['patient_id'], seed['admin_id'])

        payment = await db.fetchrow("""
            INSERT INTO payments (invoice_id, amount, method, status)
            VALUES ($1, 399600, 'qris', 'pending') RETURNING id
        """, invoice['id'])

        await db.execute("SELECT confirm_payment($1, $2)", payment['id'], seed['admin_id'])

        income = await db.fetchrow(
            "SELECT amount FROM incomes WHERE payment_id = $1 AND is_active = TRUE",
            payment['id']
        )

        assert income is not None, "Income harus terbuat setelah confirm_payment"
        assert income['amount'] == Decimal('360000'), (
            f"Income harus = nett (360000), bukan total (399600). "
            f"Got: {income['amount']}"
        )

    async def test_confirm_is_idempotent(self, db, seed):
        """
        PRINSIP: confirm_payment dipanggil 2x → ERROR, bukan duplikasi income.
        Ini melindungi dari double-click kasir atau retry request.
        """
        await db.execute(
            "SELECT confirm_payment($1, $2)",
            seed['payment_id'], seed['admin_id']
        )

        with pytest.raises(Exception) as exc_info:
            await db.execute(
                "SELECT confirm_payment($1, $2)",
                seed['payment_id'], seed['admin_id']
            )

        assert "already confirmed" in str(exc_info.value).lower(), (
            "Error message harus menyebutkan 'already confirmed'"
        )

        # Pastikan tidak ada duplikasi income
        count = await db.fetchval(
            "SELECT COUNT(*) FROM incomes WHERE payment_id = $1",
            seed['payment_id']
        )
        assert count == 1, f"Harus ada tepat 1 income record, bukan {count}"

    async def test_confirm_sets_invoice_to_paid(self, db, seed):
        """Invoice harus berubah ke 'paid' setelah payment dikonfirmasi"""
        await db.execute(
            "SELECT confirm_payment($1, $2)",
            seed['payment_id'], seed['admin_id']
        )

        status = await db.fetchval(
            "SELECT status FROM invoices WHERE id = $1",
            seed['invoice_id']
        )
        assert status == 'paid'

    async def test_confirm_pending_only(self, db, seed):
        """Tidak boleh confirm payment yang sudah void"""
        # Void dulu
        await db.execute(
            "SELECT confirm_payment($1, $2)",
            seed['payment_id'], seed['admin_id']
        )
        await db.execute(
            "SELECT void_payment($1, $2, $3, $4)",
            seed['payment_id'], seed['admin_id'], 'Test void', False
        )

        with pytest.raises(Exception):
            await db.execute(
                "SELECT confirm_payment($1, $2)",
                seed['payment_id'], seed['admin_id']
            )


class TestVoidPayment:
    """Test untuk void_payment() — harus atomik dan tidak merusak data"""

    async def test_void_deactivates_income_not_delete(self, db, seed):
        """
        PRINSIP: void tidak menghapus income — hanya is_active = FALSE.
        Data keuangan tidak pernah di-DELETE.
        """
        await db.execute("SELECT confirm_payment($1, $2)", seed['payment_id'], seed['admin_id'])
        await db.execute(
            "SELECT void_payment($1, $2, $3, $4)",
            seed['payment_id'], seed['admin_id'], 'Test void reason', False
        )

        # Income masih ada, tapi is_active = FALSE
        income = await db.fetchrow(
            "SELECT id, is_active FROM incomes WHERE payment_id = $1",
            seed['payment_id']
        )
        assert income is not None, "Income tidak boleh di-DELETE, harus tetap ada"
        assert income['is_active'] == False, "is_active harus FALSE setelah void"

    async def test_void_returns_invoice_to_issued(self, db, seed):
        """Invoice harus kembali ke 'issued' setelah payment di-void"""
        await db.execute("SELECT confirm_payment($1, $2)", seed['payment_id'], seed['admin_id'])
        await db.execute(
            "SELECT void_payment($1, $2, $3, $4)",
            seed['payment_id'], seed['admin_id'], 'Test void reason', False
        )

        status = await db.fetchval(
            "SELECT status FROM invoices WHERE id = $1", seed['invoice_id']
        )
        assert status == 'issued', "Invoice harus kembali ke 'issued' setelah void"

    async def test_void_requires_reason(self, db, seed):
        """Void tanpa alasan yang jelas harus ditolak"""
        await db.execute("SELECT confirm_payment($1, $2)", seed['payment_id'], seed['admin_id'])

        with pytest.raises(Exception):
            await db.execute(
                "SELECT void_payment($1, $2, $3, $4)",
                seed['payment_id'], seed['admin_id'], '', False  # reason kosong
            )

    async def test_void_income_not_counted_in_report(self, db, seed):
        """
        PRINSIP: income yang sudah void tidak boleh masuk laporan keuangan.
        Laporan hanya membaca incomes WHERE is_active = TRUE.
        """
        await db.execute("SELECT confirm_payment($1, $2)", seed['payment_id'], seed['admin_id'])

        # Cek sebelum void
        before = await db.fetchval("""
            SELECT SUM(amount) FROM incomes
            WHERE clinic_id = $1 AND is_active = TRUE AND fiscal_period = $2
        """, seed['clinic_id'], '2026-03')

        await db.execute(
            "SELECT void_payment($1, $2, $3, $4)",
            seed['payment_id'], seed['admin_id'], 'Test void for report', False
        )

        # Cek setelah void — harus berkurang
        after = await db.fetchval("""
            SELECT COALESCE(SUM(amount), 0) FROM incomes
            WHERE clinic_id = $1 AND is_active = TRUE AND fiscal_period = $2
        """, seed['clinic_id'], '2026-03')

        assert after < before, "Total income harus berkurang setelah void"


class TestFiscalPeriod:
    """
    Test untuk fiscal period locking.
    Ini memastikan laporan historis tidak bisa dimodifikasi.
    """

    async def test_cannot_insert_income_to_closed_period(self, db, seed):
        """
        PRINSIP: period yang sudah closed harus reject INSERT baru.
        Guard ada di DB trigger, bukan hanya di service layer.
        """
        # Tutup buku Maret
        await db.execute(
            "SELECT close_fiscal_period($1, $2, $3)",
            seed['clinic_id'], '2026-03', seed['admin_id']
        )

        # Coba insert income ke Maret yang sudah closed → harus ERROR
        with pytest.raises(Exception) as exc_info:
            await db.execute("""
                INSERT INTO incomes (
                    clinic_id, amount, category, fiscal_period, income_date, created_by
                ) VALUES ($1, 100000, 'other', '2026-03', '2026-03-01', $2)
            """, seed['clinic_id'], seed['admin_id'])

        assert "closed" in str(exc_info.value).lower(), (
            "Error harus menyebutkan bahwa period sudah closed"
        )

    async def test_can_insert_to_open_period(self, db, seed):
        """Period yang masih open harus bisa menerima INSERT baru"""
        # Insert ke April (period baru, belum ditutup)
        await db.execute("""
            INSERT INTO incomes (
                clinic_id, amount, category, fiscal_period, income_date, created_by
            ) VALUES ($1, 100000, 'other', '2026-04', '2026-04-01', $2)
        """, seed['clinic_id'], seed['admin_id'])

        count = await db.fetchval(
            "SELECT COUNT(*) FROM incomes WHERE fiscal_period = '2026-04'",
        )
        assert count > 0

    async def test_close_period_twice_raises_error(self, db, seed):
        """Period tidak bisa ditutup dua kali"""
        await db.execute(
            "SELECT close_fiscal_period($1, $2, $3)",
            seed['clinic_id'], '2026-03', seed['admin_id']
        )

        with pytest.raises(Exception):
            await db.execute(
                "SELECT close_fiscal_period($1, $2, $3)",
                seed['clinic_id'], '2026-03', seed['admin_id']
            )

    async def test_auto_creates_fiscal_period_on_first_insert(self, db, seed):
        """
        Jika period belum ada di tabel fiscal_periods,
        trigger harus otomatis membuatnya (open).
        """
        # Pastikan period Mei belum ada
        count = await db.fetchval(
            "SELECT COUNT(*) FROM fiscal_periods WHERE period = '2026-05' AND clinic_id = $1",
            seed['clinic_id']
        )
        assert count == 0, "Setup: period Mei belum boleh ada"

        # Insert income ke Mei
        await db.execute("""
            INSERT INTO incomes (
                clinic_id, amount, category, fiscal_period, income_date, created_by
            ) VALUES ($1, 50000, 'other', '2026-05', '2026-05-01', $2)
        """, seed['clinic_id'], seed['admin_id'])

        # Cek fiscal_periods Mei otomatis terbuat
        period = await db.fetchrow(
            "SELECT period, is_closed FROM fiscal_periods WHERE period = '2026-05' AND clinic_id = $1",
            seed['clinic_id']
        )
        assert period is not None, "fiscal_periods Mei harus otomatis terbuat"
        assert period['is_closed'] == False, "Period baru harus open (is_closed = FALSE)"


class TestOpeningBalance:
    """Test untuk set_opening_balance()"""

    async def test_set_opening_balance_creates_income_and_expense(self, db, seed):
        """Opening balance harus membuat income (kas) dan expense (hutang) sekaligus"""
        await db.execute(
            "SELECT set_opening_balance($1, $2, $3, $4, $5)",
            seed['clinic_id'], '2026-04', 5000000, 1500000, seed['admin_id']
        )

        income = await db.fetchrow(
            "SELECT amount, category FROM incomes WHERE category = 'opening_balance' AND fiscal_period = '2026-04'"
        )
        expense = await db.fetchrow(
            "SELECT amount FROM expenses WHERE fiscal_period = '2026-04'"
        )

        assert income is not None
        assert income['amount'] == Decimal('5000000')
        assert expense is not None
        assert expense['amount'] == Decimal('1500000')

    async def test_opening_balance_is_idempotent(self, db, seed):
        """Memanggil set_opening_balance dua kali di period yang sama → ERROR"""
        await db.execute(
            "SELECT set_opening_balance($1, $2, $3, $4, $5)",
            seed['clinic_id'], '2026-04', 5000000, 0, seed['admin_id']
        )

        with pytest.raises(Exception) as exc_info:
            await db.execute(
                "SELECT set_opening_balance($1, $2, $3, $4, $5)",
                seed['clinic_id'], '2026-04', 5000000, 0, seed['admin_id']
            )

        assert "already" in str(exc_info.value).lower() or "exist" in str(exc_info.value).lower()


class TestReport:
    """Test untuk laporan keuangan"""

    async def test_report_only_counts_active_incomes(self, db, seed):
        """
        PRINSIP SINGLE SOURCE OF TRUTH:
        Laporan hanya membaca incomes WHERE is_active = TRUE.
        Income yang di-void tidak boleh terhitung.
        """
        # Confirm 3 payments
        amounts = [200000, 300000, 150000]
        for amount in amounts:
            inv = await db.fetchrow("""
                INSERT INTO invoices (clinic_id, patient_id, subtotal, discount, nett,
                                      tax_rate, tax, total, status, created_by)
                VALUES ($1, $2, $3, 0, $3, 0, 0, $3, 'issued', $4) RETURNING id
            """, seed['clinic_id'], seed['patient_id'], amount, seed['admin_id'])

            pay = await db.fetchrow(
                "INSERT INTO payments (invoice_id, amount, method, status) VALUES ($1,$2,'cash','pending') RETURNING id",
                inv['id'], amount
            )
            await db.execute("SELECT confirm_payment($1,$2)", pay['id'], seed['admin_id'])

        # Void payment ke-3
        last_pay = await db.fetchrow(
            "SELECT id FROM payments WHERE amount = 150000 AND status = 'confirmed'"
        )
        await db.execute(
            "SELECT void_payment($1,$2,$3,$4)",
            last_pay['id'], seed['admin_id'], 'Test void for report check', False
        )

        # Total income aktif harus = 200.000 + 300.000 = 500.000 (tanpa yang void)
        total = await db.fetchval("""
            SELECT COALESCE(SUM(amount), 0) FROM incomes
            WHERE clinic_id = $1 AND fiscal_period = '2026-03' AND is_active = TRUE
        """, seed['clinic_id'])

        assert total == Decimal('500000'), (
            f"Total income harus 500.000 (150.000 sudah void). Got: {total}"
        )
```

### Jalankan Test

```bash
# Pastikan ada database test terpisah
createdb fast_clinic_test
psql -d fast_clinic_test -f database/init.sql

# Jalankan semua test
pytest tests/ -v

# Jalankan dengan detail output
pytest tests/test_billing.py -v --tb=short

# Target: semua test PASSED
```

Saat semua test hijau dan kamu mengerti **mengapa** setiap assertion itu perlu
ada — kamu sudah menyelesaikan 90% dari Level 1.

---

## Checklist Final Level 1

Jawab semua pertanyaan ini **tanpa melihat catatan atau file**:

### Pertanyaan Konsep

```
□ Mengapa incomes tidak boleh di-DELETE? Apa dampaknya kalau di-DELETE?

□ Apa perbedaan antara invoices, payments, dan incomes?
  (Hint: tagihan vs bukti bayar vs jurnal)

□ Mengapa income.amount = invoice.nett, bukan invoice.total?
  (Hint: apa itu PPN? Milik siapa PPN itu?)

□ Apa itu fiscal period? Mengapa guard-nya harus di DB trigger,
  bukan hanya di service layer Python?
  (Hint: apa yang terjadi kalau ada 2 service memanggil DB bersamaan?)

□ Kapan set_opening_balance() dipanggil? Apa yang terjadi kalau dipanggil 2x?

□ Bagaimana cara void payment yang benar? Mengapa tidak boleh UPDATE manual?
  (Hint: atomicity — berapa tabel yang harus berubah sekaligus?)

□ Dari tabel mana laporan keuangan harus dibaca? Mengapa tidak dari invoices?
  (Hint: CANCELLED invoice masuk tidak? Invoice yang belum dibayar masuk tidak?)

□ Apa itu cash basis? Kapan income_date diisi — saat invoice dibuat atau saat bayar?
```

### Pertanyaan Teknis

```
□ Apa yang terjadi kalau confirm_payment() dipanggil dua kali untuk payment yang sama?

□ Apa yang terjadi kalau staff mencoba INSERT income ke fiscal period yang sudah closed?

□ Kalau invoice nett = 360.000 dan tax = 39.600 (total 399.600),
  berapa yang masuk ke tabel incomes?

□ Auth guard di RBAC: siapa yang boleh reopen fiscal period?
  Siapa yang boleh tutup buku?
```

### Mini Proyek — Wajib Diselesaikan

Bangun dan pastikan semua endpoint ini berjalan dengan test yang passing:

```
✅ POST   /invoices                    — buat invoice (hitung nett + tax otomatis)
✅ POST   /payments                   — buat payment pending
✅ POST   /payments/{id}/confirm      — konfirmasi (panggil DB function)
✅ POST   /payments/{id}/void         — void atomik (panggil DB function)
✅ GET    /reports/monthly            — laporan L/R dari incomes + expenses
✅ POST   /fiscal-periods/{p}/close   — tutup buku
✅ GET    /reports/cashier-today      — ringkasan kasir hari ini
```

Semua endpoint harus punya minimal 1 pytest yang pass.

---

## Setelah Level 1 Selesai

Kalau kamu sudah bisa menjawab semua pertanyaan di checklist dan mini proyek
sudah jalan — selamat, kamu sudah menguasai fondasi keuangan untuk bisnis
tunai.

Yang bisa kamu bangun sekarang:
- Klinik kecantikan, salon, spa ✅
- Kasir sederhana (warung, kantin) ✅
- Apotek kecil ✅
- Workshop / lab dengan jasa per-sesi ✅

Yang belum bisa (perlu Level 2):
- Aplikasi kos (piutang, deposit) ❌
- Sekolah (cicilan SPP) ❌
- SIMRS (BPJS, klaim) ❌

Lanjut ke `level-2-receivables.md` kalau sudah siap.

---

*Bagian dari seri: [akuntansi-untuk-developer.md](./akuntansi-untuk-developer.md) |
[kurikulum-belajar.md](./kurikulum-belajar.md)*