# Arsitektur Keuangan - Fast-Klinik

Dokumen ini menjelaskan prinsip, pola, dan keputusan desain yang digunakan dalam
perhitungan keuangan aplikasi Fast-Klinik. Gunakan sebagai referensi ketika mengembangkan
fitur keuangan baru.

---

## 1. Prinsip Utama

### Single Source of Truth - Tabel `incomes`

> **Semua pemasukan dihitung dari satu tempat: tabel `incomes`.**

Sistem ini memiliki beberapa tabel yang berkaitan dengan penerimaan uang:

| Tabel | Fungsi | Digunakan untuk |
|---|---|---|
| `invoices` | Tagihan ke pasien (bisa multi-item) | Tracking status: draft > issued > paid > void |
| `invoice_items` | Rincian item di invoice (service / produk) | Detail subtotal per item |
| `payments` | Pembayaran tunai/transfer untuk satu invoice | Tracking status: pending > confirmed > void |
| `incomes` | **Jurnal pemasukan resmi** | Laporan keuangan, dashboard, statistik |
| `expenses` | Pengeluaran klinik | Laporan keuangan |
| `fiscal_periods` | Periode buku per bulan | Tutup buku, opening balance |

Setiap kali pembayaran dikonfirmasi (`confirm_payment`), sistem otomatis membuat satu
`Income` record. **Dashboard dan semua laporan HANYA membaca dari `incomes`**,
tidak dari `payments` maupun `invoices` untuk menghitung nilai uang.

**Mengapa ini penting:**
- Jika pembayaran di-void, income-nya dinonaktifkan -> laporan langsung terupdate
- Tidak ada risiko double counting
- Satu invoice yang dibayar dengan dua cara tetap 1 income per payment

### Anti-Pattern yang Dihindari

```python
# JANGAN -- menghitung dari dua tabel sekaligus
total = sum_from_income(month) + sum_from_payments(month)

# JANGAN -- menghitung dari invoice yang sudah paid
total = db.query(func.sum(Invoice.total)).filter(Invoice.status == 'paid').scalar()

# BENAR -- satu sumber, filter is_active
total = db.execute(
    select(func.sum(Income.amount))
    .where(Income.fiscal_period == month, Income.is_active == True)
).scalar() or 0
```

---

## 2. Alur Transaksi Lengkap

```
Appointment selesai (status: completed)
    |
    v
Kasir klik "Buat Invoice" -> POST /billing/appointments/{id}/from-appointment
    |   invoice_number: INV-YYYYMMDD-NNNN
    |   status: draft
    |
    +-- (opsional) edit item, ubah discount/tax di InvoiceDetailPage
    |
    v
Kasir klik "Terbitkan" -> POST /billing/invoices/{id}/issue
    |   invoice.status: draft -> issued
    |   invoice.issued_at: now()
    |
    v
Kasir catat pembayaran -> POST /billing/payments
    |   payment.status: pending
    |   payment.receipt_number: RCP-YYYYMMDD-NNNN
    |
    v
Kasir konfirmasi -> POST /billing/payments/{id}/confirm
    |
    +-- payment.status: confirmed
    +-- payment.confirmed_at: now()
    +-- invoice.status: paid
    +-- invoice.paid_at: now()
    +-- INSERT INTO incomes (payment_id=payment.id, is_active=True, ...)
         fiscal_period = YYYY-MM dari confirmed_at
         income_date   = DATE dari confirmed_at   <- cash basis
```

---

## 3. Pembatalan / Void

### Void Payment (pembayaran salah / refund)

```
POST /billing/payments/{id}/void  { reason: "..." }
    |
    +-- payment.status = "void"
    +-- payment.void_reason = reason
    +-- UPDATE incomes SET is_active = false WHERE payment_id = payment.id
    +-- invoice.status kembali ke "issued"  (siap dibayar ulang)
```

**Implementasi ada di `billing_repository.void_payment()` - semua operasi
di atas dalam SATU `db.commit()`.**

### Invoice yang sudah paid tidak bisa langsung dihapus

```python
# billing.py endpoint
if invoice.status == "paid":
    raise HTTPException(400, "Invoice yang sudah paid tidak dapat dihapus")
```

Untuk membatalkan invoice paid: void payment dulu -> invoice kembali ke issued ->
baru bisa dihapus atau di-void manual.

**Aturan void:**
- Payment `void` tidak bisa di-void ulang (cek status dulu)
- Income yang terhubung **selalu** ikut dinonaktifkan secara atomik
- Invoice dikembalikan ke `issued` agar bisa dibayar ulang

---

## 4. Penomoran Transaksi

Setiap transaksi punya nomor unik yang di-generate saat dibuat:

| Format | Contoh | Digunakan di |
|---|---|---|
| `INV-YYYYMMDD-NNNN` | `INV-20260320-0001` | `Invoice.invoice_number` |
| `RCP-YYYYMMDD-NNNN` | `RCP-20260320-0001` | `Payment.receipt_number`, `Income.receipt_ref` |

```python
# Implementasi di billing_repository.py
def generate_invoice_number(self) -> str:
    date_str = datetime.now(timezone.utc).strftime("%Y%m%d")
    stmt = select(Invoice.invoice_number)\
        .where(Invoice.invoice_number.like(f"INV-{date_str}-%"))\
        .order_by(Invoice.invoice_number.desc()).limit(1)
    last = self.db.execute(stmt).scalar()
    seq = int(last.split("-")[2]) + 1 if last else 1
    return f"INV-{date_str}-{seq:04d}"
```

---

## 5. Query Laporan - Cara Membaca Data

### Pendapatan bulan ini (single source of truth)

```python
# finance.py -- get_finance_summary()
total_revenue = db.execute(
    select(func.sum(Income.amount))
    .where(
        Income.clinic_id == clinic_id,
        Income.fiscal_period == month,   # 'YYYY-MM'
        Income.is_active == True,
    )
).scalar() or 0
```

### Pengeluaran bulan ini

```python
total_expense = db.execute(
    select(func.sum(Expense.amount))
    .where(
        Expense.clinic_id == clinic_id,
        Expense.fiscal_period == month,
        Expense.is_active == True,
    )
).scalar() or 0
```

### Saldo bersih

```python
balance = total_revenue - total_expense
```

### Breakdown per metode pembayaran (boleh dari Payment)

```python
# Ini bukan untuk total revenue -- hanya breakdown informatif
by_method = db.execute(
    select(Payment.payment_method, func.sum(Payment.amount))
    .where(Payment.status == 'confirmed', ...)
    .group_by(Payment.payment_method)
).all()
```

> **Catatan:** Query `by_payment_method` di `finance.py` membaca dari `payments`
> yang sudah confirmed. Ini boleh karena digunakan sebagai data analitik/breakdown,
> bukan sebagai total pendapatan. Total pendapatan tetap dari `incomes`.

---

## 6. Struktur Tabel - Kolom Penting

### `invoices`

| Kolom | Tipe | Keterangan |
|---|---|---|
| `invoice_number` | String UNIQUE | `INV-YYYYMMDD-NNNN` |
| `status` | String | `draft` > `issued` > `paid` > `void` |
| `subtotal` | Numeric(12,2) | Sebelum diskon |
| `discount` | Numeric(12,2) | Nominal diskon |
| `nett` | Numeric(12,2) | `subtotal - discount` |
| `tax_rate` | Numeric(5,4) | misal `0.11` untuk PPN 11% |
| `tax` | Numeric(12,2) | `nett * tax_rate` |
| `total` | Numeric(12,2) | `nett + tax` -- yang dibayar pasien |
| `issued_at` | DateTime TZ | Waktu diterbitkan |
| `paid_at` | DateTime TZ | Waktu konfirmasi pembayaran |
| `appointment_id` | FK nullable | Asal appointment |

### `payments`

| Kolom | Tipe | Keterangan |
|---|---|---|
| `receipt_number` | String UNIQUE | `RCP-YYYYMMDD-NNNN` |
| `payment_method` | String | `cash` / `transfer` / `qris` / dll |
| `amount` | Numeric(12,2) | Jumlah dibayar |
| `status` | String | `pending` > `confirmed` > `void` |
| `confirmed_at` | DateTime TZ | Waktu konfirmasi -- jadi `income_date` |
| `voided_at` | DateTime TZ | Waktu void |
| `void_reason` | Text | Alasan void (wajib untuk audit) |

### `incomes`

| Kolom | Tipe | Keterangan |
|---|---|---|
| `fiscal_period` | String `YYYY-MM` | Period untuk laporan bulanan |
| `income_date` | Date | Tanggal cash diterima (dari `confirmed_at`) |
| `payment_id` | FK -> payments.id | Link ke payment asalnya (untuk void) |
| `invoice_ref` | String | Copy `invoice_number` -- untuk audit tanpa JOIN |
| `receipt_ref` | String | Copy `receipt_number` -- untuk audit tanpa JOIN |
| `category` | String | Saat ini selalu `'treatment_service'` |
| `amount` | Numeric(12,2) | Sama dengan `payment.amount` |
| `is_active` | Boolean | `False` = dibatalkan, tidak dihitung di laporan |

### `expenses`

| Kolom | Tipe | Keterangan |
|---|---|---|
| `fiscal_period` | String `YYYY-MM` | Period untuk laporan bulanan |
| `expense_date` | Date | Tanggal pengeluaran |
| `category` | String | `'gaji'` / `'operasional'` / `'bahan'` / dll |
| `amount` | Numeric(12,2) | Nilai pengeluaran |
| `reference` | String | No. referensi / nota / bukti |
| `is_active` | Boolean | `False` = soft delete |

### `fiscal_periods`

| Kolom | Tipe | Keterangan |
|---|---|---|
| `period` | String `YYYY-MM` | Periode buku |
| `is_closed` | Boolean | Periode tutup -- tidak bisa input transaksi baru |
| `opening_balance_income` | Numeric(12,2) | Saldo awal income periode ini |
| `opening_balance_expense` | Numeric(12,2) | Saldo awal expense periode ini |
| `closed_at` / `closed_by` | DateTime / UUID | Siapa yang tutup buku |

---

## 7. Prinsip Akuntansi yang Diterapkan

### Cash Basis

Pendapatan diakui pada saat uang diterima (tanggal konfirmasi pembayaran),
bukan pada saat invoice dibuat atau diterbitkan.

```python
income_date = payment.confirmed_at.date()   # cash basis
fiscal_period = payment.confirmed_at.strftime("%Y-%m")
```

### Soft Delete, bukan Hard Delete

Data keuangan **tidak pernah dihapus** dari database. Record yang dibatalkan
di-nonaktifkan (`is_active=False`). Ini memungkinkan:
- Audit trail lengkap
- Pemulihan data jika terjadi kesalahan
- Rekonsiliasi di masa depan

```python
# Soft delete -- jangan gunakan db.delete()
income.is_active = False
db.commit()
```

### Atomisitas Void

Void payment, nonaktifkan income, dan rollback invoice status harus dalam
**satu transaksi database**:

```python
# billing_repository.void_payment()
payment.status = "void"
income.is_active = False        # wajib, atau laporan tetap hitung income ini
invoice.status = "issued"       # rollback agar bisa dibayar ulang
db.commit()   # semua berhasil atau semua gagal
```

### Tidak Ada Nilai Negatif di `incomes`

Pengembalian uang **tidak** dicatat sebagai income negatif.
Gunakan `void_payment()` untuk membatalkan, atau buat `Expense(category='refund')`
untuk refund tunai. Ini menjaga `incomes` selalu berisi nilai positif.

---

## 8. Checklist untuk Fitur Keuangan Baru

Ketika menambahkan fitur yang melibatkan transaksi keuangan, pastikan:

- [ ] Konfirmasi pembayaran -> INSERT satu `Income` record dengan `is_active=True`
- [ ] `Income.payment_id` = FK ke `payments.id` -- wajib, untuk void atomik
- [ ] `Income.fiscal_period` = `YYYY-MM` dari `confirmed_at`
- [ ] Void payment -> set `payment.status = 'void'` **dan** `income.is_active = False` dalam satu `db.commit()`
- [ ] Rollback invoice ke `issued` saat void (bukan ke `draft`)
- [ ] Query laporan **selalu** filter `Income.is_active == True`
- [ ] Query total revenue **dari `incomes`**, bukan dari `payments` atau `invoices`
- [ ] `Expense` untuk pengeluaran/refund, bukan income negatif
- [ ] Cek `FiscalPeriod.is_closed` sebelum insert transaksi baru di periode tersebut

---

## 9. Gap & To-Do (Known Issues)

### Status ringkas

| Item | Status | File yang perlu diubah |
|---|---|---|
| `void_payment()` tidak nonaktifkan income | FIXED 2026-03-20 | `billing_repository.py` |
| Stok tidak di-restore saat appointment cancel | FIXED 2026-03-20 | `booking_service.py` |
| Void payment tidak buat Expense refund | FIXED 2026-03-20 | `billing_repository.py`, `billing.py`, `schemas/billing.py` |
| Expense CRUD endpoint | FIXED 2026-03-20 | `finance.py` |
| FiscalPeriod CRUD + enforcement | BELUM | `finance.py` + `billing_repository.py` |
| Expense category enum | FIXED 2026-03-20 | `finance.py` validasi |
| Income category expansion | Hanya `treatment_service` | `billing_repository.py` |

---

### ITEM 1 - Stok tidak di-restore saat appointment di-cancel

**File:** `backend/services/booking_service.py` — fungsi `change_status()`

**Masalah:** Saat appointment di-cancel, stok produk yang sudah dipakai di
treatment items TIDAK dikembalikan. `_restore_stock()` hanya dipanggil
saat hapus item manual, tidak saat cancel appointment.

| Kondisi | Stok di-restore? |
|---|---|
| Hapus item manual via UI (`DELETE /treatment-items/{id}`) | YA |
| `POST /appointments/{id}/cancel` | TIDAK (BUG) |

**Yang perlu ditambahkan** di `change_status()` setelah update status:

```python
# Di booking_service.py, tambah setelah: appointment = self.repository.update(...)
if new_status == 'cancelled':
    from models.treatment_item import TreatmentItem
    from models.product import Inventory, StockMovement
    # Ambil semua treatment item produk yang belum masuk invoice
    items = db.query(TreatmentItem).filter(
        TreatmentItem.appointment_id == appointment.id,
        TreatmentItem.item_type == 'product',
        TreatmentItem.copied_to_invoice == False,
    ).all()
    for ti in items:
        inv = db.query(Inventory).filter_by(
            product_id=ti.product_id, clinic_id=appointment.clinic_id
        ).with_for_update().first()
        if inv:
            old_qty = float(inv.stock_quantity)
            new_qty = old_qty + float(ti.quantity)
            db.add(StockMovement(
                clinic_id=appointment.clinic_id,
                product_id=ti.product_id,
                movement_type='in',
                quantity=float(ti.quantity),
                stock_before=old_qty,
                stock_after=new_qty,
                reference_type='treatment_usage',
                reference_id=appointment.id,
                notes='Rollback: appointment dibatalkan',
                created_by=uuid.UUID(user_id),
            ))
            inv.stock_quantity = new_qty
    db.commit()
```

---

### ITEM 2 - Void Payment tidak membuat Expense refund

**File:** `backend/repositories/billing_repository.py` + `backend/api/v1/endpoints/billing.py`

**Masalah:** Void payment ada dua skenario:
- **Koreksi input salah** (uang belum pernah diterima) → cukup void, tidak perlu Expense
- **Refund ke pasien** (uang sudah diterima, dikembalikan secara fisik) → wajib catat Expense

Saat ini sistem tidak bisa membedakan keduanya dan tidak pernah membuat Expense.

**Yang perlu dilakukan:**

*Di endpoint `billing.py` — tambah field `is_refund` di VoidRequest:*
```python
# Schema VoidRequest perlu field baru (di schemas/billing.py):
class VoidRequest(BaseModel):
    reason: str
    is_refund: bool = False   # True = uang sudah diterima dan dikembalikan ke pasien
```

*Di `billing_repository.void_payment()` — setelah nonaktifkan income, cek is_refund:*
```python
def void_payment(self, payment_id, voided_by, reason, is_refund=False):
    # ... kode void yang sudah ada ...

    # Jika refund fisik, catat sebagai pengeluaran
    if is_refund and payment:
        now = datetime.now(timezone.utc)
        self.db.execute(text("""
            INSERT INTO expenses (id, clinic_id, fiscal_period, category,
                                  description, amount, expense_date,
                                  reference, is_active, created_by, created_at, updated_at)
            VALUES (:id, :clinic_id, :period, 'refund',
                    :desc, :amount, :today,
                    :ref, true, :user, now(), now())
        """), {
            'id': str(uuid.uuid4()),
            'clinic_id': str(payment.clinic_id),
            'period': now.strftime('%Y-%m'),
            'desc': f'Refund pembayaran {payment.receipt_number} - {reason}',
            'amount': float(payment.amount),
            'today': now.date(),
            'ref': payment.receipt_number,
            'user': str(uid),
        })
    self.db.commit()
```

*Di endpoint void_payment (`billing.py`), teruskan `is_refund` ke service:*
```python
obj = service.void_payment(str(id), request.reason, str(current_user.id),
                           is_refund=request.is_refund)
```

---

### ITEM 3 - Expense CRUD belum ada endpoint

**File:** `backend/api/v1/endpoints/finance.py`

**Masalah:** Model `Expense` dan tabel `expenses` sudah ada di DB, tapi tidak
ada endpoint untuk mengelola pengeluaran operasional klinik. Laporan keuangan
tidak akan pernah menampilkan pengeluaran.

**Endpoint yang perlu dibuat** (tambahkan di `finance.py`):

```
GET    /finance/expenses?month=YYYY-MM&category=    list pengeluaran
POST   /finance/expenses                             catat pengeluaran baru
PATCH  /finance/expenses/{id}                        edit (hanya jika periode belum tutup)
DELETE /finance/expenses/{id}                        soft delete (is_active=False)
```

**Kategori baku (hardcode sebagai enum):**
```python
EXPENSE_CATEGORIES = [
    'gaji',        # Gaji / honor staf
    'operasional', # Listrik, air, internet
    'bahan',       # Pembelian bahan habis pakai
    'peralatan',   # Beli/service alat
    'refund',      # Refund ke pasien (otomatis dari void payment)
    'lain-lain',   # Pengeluaran tidak terkategori
]
```

**Schema POST body:**
```python
class ExpenseCreate(BaseModel):
    category: str           # harus masuk EXPENSE_CATEGORIES
    description: str
    amount: Decimal
    expense_date: date      # tanggal pengeluaran (cash basis)
    reference: Optional[str] = None  # no. nota / bukti
```

**Query di summary (tambahkan ke `get_finance_summary`):**
```python
total_expense = db.execute(
    select(func.sum(Expense.amount))
    .where(
        Expense.clinic_id == clinic_id,
        Expense.fiscal_period == month,
        Expense.is_active == True,
    )
).scalar() or 0

net_balance = float(total_revenue) - float(total_expense)
```

---

### ITEM 4 - FiscalPeriod: CRUD + Enforcement

**File:** `backend/api/v1/endpoints/finance.py` (endpoint baru) +
`backend/repositories/billing_repository.py` (guard di confirm_payment)

**Masalah:**
- Tidak ada endpoint untuk tutup/buka buku
- `confirm_payment()` tidak cek apakah periode sudah closed
- Bisa saja kasir entry pembayaran bulan lalu yang sudah ditutup

**Endpoint yang perlu dibuat:**
```
GET    /finance/fiscal-periods              list semua periode + status
POST   /finance/fiscal-periods/{period}/close   tutup buku (finance.manage)
POST   /finance/fiscal-periods/{period}/reopen  buka kembali (super_admin only)
```

**Guard di `billing_repository.confirm_payment()`** — tambah sebelum INSERT income:
```python
from models.billing import FiscalPeriod
fp = self.db.query(FiscalPeriod).filter_by(
    clinic_id=payment.clinic_id,
    period=fiscal_period,
).first()
if fp and fp.is_closed:
    raise Exception(f"Periode {fiscal_period} sudah ditutup. Hubungi admin untuk membuka kembali.")
```

**Aturan tutup buku:**
- Saat tutup buku: hitung `opening_balance_income` dan `opening_balance_expense`
  sebagai snapshot saldo akhir periode tersebut
- Periode yang sudah closed tidak bisa: confirm_payment, add expense, edit expense
- Hanya `super_admin` / `finance.manage` yang bisa reopen

---

### Urutan Kerja yang Disarankan

```
Minggu ini (berdampak ke data integrity):
  [x] ITEM 1 -- Restore stok saat appointment cancel         DONE 2026-03-20
                File: backend/services/booking_service.py

  [x] ITEM 3 -- Expense CRUD endpoint                       DONE 2026-03-20
                File: backend/api/v1/endpoints/finance.py

  [x] ITEM 2 -- Void payment + opsi refund expense          DONE 2026-03-20
                File: backend/repositories/billing_repository.py
                      backend/api/v1/endpoints/billing.py
                      backend/schemas/billing.py

Bulan depan:
  [ ] ITEM 4 -- FiscalPeriod CRUD + enforcement
                File: backend/api/v1/endpoints/finance.py
                      backend/repositories/billing_repository.py
```

---

## 10. Ringkasan Arsitektur

```
+--------------------------------------------------------------+
|                     TRANSAKSI MASUK                          |
|                                                              |
|  Appointment selesai                                         |
|       |                                                      |
|       v                                                      |
|   [ invoices ] <- invoice_items (service / produk)          |
|   status: draft -> issued                                    |
|       |                                                      |
|       v                                                      |
|   [ payments ]  (RCP-YYYYMMDD-NNNN)                         |
|   status: pending -> confirmed -> void                       |
|       |                                                      |
|       | confirm_payment()                                    |
|       v                                                      |
|   [ incomes ]                                                |
|   is_active=True                                             |
|   payment_id -> payments.id  (untuk void)                   |
|   invoice_ref / receipt_ref (untuk audit tanpa JOIN)        |
|   fiscal_period = 'YYYY-MM'                                  |
|       |                                                      |
|   void_payment() -> is_active=False                         |
|                     invoice status -> issued                 |
+------------------------------+-------------------------------+
                               |
                               v
               Dashboard / Laporan / Statistik
          (HANYA baca incomes WHERE is_active=True)

+--------------------------------------------------------------+
|                    TRANSAKSI KELUAR                          |
|                                                              |
|   Manual input kasir / admin                                 |
|       |                                                      |
|       v                                                      |
|   [ expenses ]                                               |
|   is_active=True                                             |
|   fiscal_period = 'YYYY-MM'                                  |
|                                                              |
|   Batal? -> is_active=False                                  |
+--------------------------------------------------------------+

+--------------------------------------------------------------+
|                    PERIODE BUKU                              |
|                                                              |
|   [ fiscal_periods ]                                         |
|   is_closed=False  -> transaksi boleh masuk                  |
|   is_closed=True   -> periode terkunci (tutup buku)          |
+--------------------------------------------------------------+
```