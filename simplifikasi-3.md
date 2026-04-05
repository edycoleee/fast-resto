# 📝 Template Input Data Menu — Dari Kertas ke Database

> Dokumen ini adalah panduan praktis: apa yang perlu disiapkan,
> urutan yang benar, dan format template yang langsung sejalan
> dengan struktur database.

---

## Jawaban Pertama: Ya, Master Bahan Harus Ada Dulu

Ini seperti membangun rumah — fondasi dulu, baru dinding, baru atap.
Tidak bisa terbalik.

```
URUTAN YANG BENAR:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

TAHAP 1 — Master Bahan Baku (ingredients)
  → Daftar semua bahan yang dipakai di dapur
  → Tentukan satuan (gram / ml / pcs)
  → Isi harga beli terkini per satuan
  ↓
TAHAP 2 — Master Menu (menus)
  → Daftar semua menu yang dijual
  → Tentukan harga jual
  → Tentukan kategori (makanan / minuman / snack)
  ↓
TAHAP 3 — Resep Per Menu (menu_recipes)
  → Untuk setiap menu: bahan apa + berapa qty
  → Tidak bisa diisi sebelum Tahap 1 selesai
  ↓
TAHAP 4 — Sistem Hitung Otomatis
  → HPP per menu = qty × harga bahan
  → Food cost % = HPP / harga jual × 100%
  → Tidak perlu input manual lagi

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Mengapa urutan ini tidak bisa dibalik?**

Karena tabel `menu_recipes` menyimpan referensi ke `ingredient_id`.
Kalau bahan belum ada di database, resep tidak bisa dibuat —
sama seperti kamu tidak bisa tulis "200g ayam" di resep kalau
"ayam" belum terdaftar sebagai bahan.

---

## TEMPLATE 1 — Master Bahan Baku

### Cara Mengisi

1. Kumpulkan semua nota belanja 1–2 bulan terakhir
2. List semua bahan yang pernah dibeli
3. Pisahkan: Kategori A (masuk resep) vs Kategori B (overhead)
4. Tentukan satuan yang konsisten (pilih satu, tidak boleh campur)
5. Isi harga per satuan dari nota terbaru

### Template (isi sebelum input ke sistem)

```
══════════════════════════════════════════════════════════════════
MASTER BAHAN BAKU — [Nama Restoran]
Tanggal Update: _______________
══════════════════════════════════════════════════════════════════

KATEGORI A — BAHAN UTAMA (masuk resep per porsi)
──────────────────────────────────────────────────────────────────
No | Nama Bahan          | Satuan | Harga Beli    | Harga per Satuan
──────────────────────────────────────────────────────────────────
01 | Ayam potong         | gram   | Rp 38.000/kg  | Rp 38 / gram
02 | Daging sapi         | gram   | Rp 130.000/kg | Rp 130 / gram
03 | Ikan lele           | gram   | Rp 28.000/kg  | Rp 28 / gram
04 | Ikan gurame         | gram   | Rp 55.000/kg  | Rp 55 / gram
05 | Udang sedang        | gram   | Rp 65.000/kg  | Rp 65 / gram
06 | Cumi-cumi           | gram   | Rp 55.000/kg  | Rp 55 / gram
07 | Telur ayam          | pcs    | Rp 28.000/kg  | Rp 2.000 / butir
   |                     |        | (14 butir/kg) |
08 | Tahu putih          | gram   | Rp 4.000/bj   | Rp 5 / gram
   |                     |        | (1 bj = 80g)  |
09 | Tempe               | gram   | Rp 4.000/200g | Rp 20 / gram
10 | Beras               | gram   | Rp 14.000/kg  | Rp 14 / gram
11 | Mie kuning basah    | gram   | Rp 12.000/kg  | Rp 12 / gram
12 | Mie kering          | gram   | Rp 18.000/kg  | Rp 18 / gram
13 | Bihun / soun        | gram   | Rp 18.000/kg  | Rp 18 / gram
14 | Tepung terigu       | gram   | Rp 10.000/kg  | Rp 10 / gram
15 | Tepung beras        | gram   | Rp 12.000/kg  | Rp 12 / gram
16 | Santan kelapa       | ml     | Rp 18.000/L   | Rp 18 / ml
17 | Sayur bayam         | gram   | Rp 5.000/ikat | Rp 6 / gram
   |                     |        | (1 ikat=80g)  |
18 | Kangkung            | gram   | Rp 4.000/ikat | Rp 5 / gram
19 | Kol / kubis         | gram   | Rp 6.000/kg   | Rp 6 / gram
20 | Wortel              | gram   | Rp 8.000/kg   | Rp 8 / gram
21 | Tauge               | gram   | Rp 6.000/kg   | Rp 6 / gram
22 | Tomat               | gram   | Rp 8.000/kg   | Rp 8 / gram
── | (MINUMAN)           |        |               |
23 | Kopi bubuk          | gram   | Rp 60.000/kg  | Rp 60 / gram *
24 | Teh celup           | gram   | Rp 40.000/kg  | Rp 40 / gram *
   |                     |        | (1 kantong=2g)|
25 | Susu UHT full cream | ml     | Rp 18.000/L   | Rp 18 / ml
26 | Susu kental manis   | gram   | Rp 15.000/385g| Rp 39 / gram *
   |                     |        | (1 sachet=14g)| Rp 545 / sachet
27 | Jeruk nipis         | pcs    | Rp 800 / buah | Rp 800 / pcs
28 | Jeruk manis         | pcs    | Rp 1.200/buah | Rp 1.200 / pcs
29 | Sirup merah         | ml     | Rp 24.000/600ml| Rp 40 / ml
30 | Gula pasir (minuman)| gram   | Rp 16.000/kg  | Rp 16 / gram
31 | Nata de coco        | gram   | Rp 15.000/kg  | Rp 15 / gram
32 | Kolang-kaling       | gram   | Rp 12.000/kg  | Rp 12 / gram
33 | _______________     |        |               |
34 | _______________     |        |               |
35 | _______________     |        |               |

* Catatan: kopi specialty / single origin harganya bisa 3–5x lebih mahal,
  sesuaikan dengan kualitas yang dipakai di restoran.

──────────────────────────────────────────────────────────────────
KATEGORI B — OVERHEAD DAPUR (tidak masuk resep, catat sebagai expense)
──────────────────────────────────────────────────────────────────
No | Nama Bahan          | Satuan Beli    | Estimasi Biaya/Bulan
──────────────────────────────────────────────────────────────────
B1 | Minyak goreng       | 18 liter/bulan | Rp 630.000
B2 | Bawang merah        | 3 kg/bulan     | Rp 90.000
B3 | Bawang putih        | 2 kg/bulan     | Rp 60.000
B4 | Cabai merah         | 2 kg/bulan     | Rp 80.000
B5 | Cabai rawit         | 1 kg/bulan     | Rp 50.000
B6 | Kemiri              | 0.5 kg/bulan   | Rp 20.000
B7 | Kunyit, jahe, serai | 1 paket/bulan  | Rp 30.000
B8 | Kecap manis         | 2 botol/bulan  | Rp 32.000
B9 | Saus tiram          | 1 botol/bulan  | Rp 20.000
B10| Garam dapur         | 1 kg/bulan     | Rp 8.000
B11| Merica bubuk        | 0.2 kg/bulan   | Rp 20.000
B12| Gas LPG 12kg        | 2 tabung/bulan | Rp 150.000
B13| _______________     |                |
B14| _______________     |                |
──────────────────────────────────────────────────────────────────
TOTAL ESTIMASI OVERHEAD/BULAN: Rp ________________
══════════════════════════════════════════════════════════════════
```

---

## TEMPLATE 2 — Master Menu

### Template

```
══════════════════════════════════════════════════════════════════
MASTER MENU — [Nama Restoran]
══════════════════════════════════════════════════════════════════

MAKANAN UTAMA
──────────────────────────────────────────────────────────────────
Kode | Nama Menu                | Kategori    | Harga Jual | Tersedia?
──────────────────────────────────────────────────────────────────
M001 | Nasi Putih               | makanan     | Rp  5.000  | Ya
M002 | Nasi Goreng Biasa        | makanan     | Rp 18.000  | Ya
M003 | Nasi Goreng Spesial      | makanan     | Rp 28.000  | Ya
M004 | Ayam Goreng Biasa        | makanan     | Rp 22.000  | Ya
M005 | Ayam Goreng Kremes       | makanan     | Rp 25.000  | Ya
M006 | Ayam Bakar               | makanan     | Rp 27.000  | Ya
M007 | Lele Goreng              | makanan     | Rp 20.000  | Ya
M008 | Gurame Goreng            | makanan     | Rp 45.000  | Ya
M009 | Mie Goreng               | makanan     | Rp 20.000  | Ya
M010 | Mie Goreng Spesial       | makanan     | Rp 28.000  | Ya
M011 | Soto Ayam                | makanan     | Rp 20.000  | Ya
M012 | Bakso                    | makanan     | Rp 18.000  | Ya
M013 | Cap Cay Goreng           | makanan     | Rp 18.000  | Ya
M014 | Sayur Lodeh              | makanan     | Rp 12.000  | Ya

LAUK TAMBAHAN
──────────────────────────────────────────────────────────────────
L001 | Tempe Goreng             | lauk        | Rp  5.000  | Ya
L002 | Tahu Goreng              | lauk        | Rp  5.000  | Ya
L003 | Telur Ceplok             | lauk        | Rp  7.000  | Ya
L004 | Telur Dadar              | lauk        | Rp  8.000  | Ya
L005 | Perkedel                 | lauk        | Rp  6.000  | Ya

MINUMAN
──────────────────────────────────────────────────────────────────
D001 | Es Teh Manis             | minuman     | Rp  5.000  | Ya
D002 | Teh Manis Panas          | minuman     | Rp  4.000  | Ya
D003 | Es Jeruk Peras           | minuman     | Rp 10.000  | Ya
D004 | Es Jeruk Nipis           | minuman     | Rp  8.000  | Ya
D005 | Kopi Hitam Panas         | minuman     | Rp  8.000  | Ya
D006 | Kopi Susu Panas          | minuman     | Rp 12.000  | Ya
D007 | Kopi Susu Es             | minuman     | Rp 15.000  | Ya
D008 | Es Campur                | minuman     | Rp 15.000  | Ya
D009 | Air Mineral Botol        | minuman     | Rp  5.000  | Ya
D010 | Es Coklat                | minuman     | Rp 15.000  | Ya
──────────────────────────────────────────────────────────────────
══════════════════════════════════════════════════════════════════
```

---

## TEMPLATE 3 — Resep Per Menu (Plate Costing Sheet)

Ini template utama — satu lembar per menu. Isi satu per satu saat
melakukan plate costing di dapur.

```
══════════════════════════════════════════════════════════════════
PLATE COSTING SHEET
══════════════════════════════════════════════════════════════════
Kode Menu   : M004
Nama Menu   : Ayam Goreng Biasa
Kategori    : Makanan Utama
Harga Jual  : Rp 22.000
Tanggal     : _______________
Diisi oleh  : _______________
──────────────────────────────────────────────────────────────────

BAHAN UTAMA (Kategori A — masuk resep)
──────────────────────────────────────────────────────────────────
No | Nama Bahan    | Qty  | Satuan | Yield  | Harga/Sat | Total
──────────────────────────────────────────────────────────────────
1  | Ayam potong   | 200  | gram   | 0.90   | Rp 38     | Rp 7.600
   | (mentah, ada  |      |        |        |           |
   |  trimming)    |      |        |        |           |
2  | Tepung terigu | 15   | gram   | 1.00   | Rp 10     | Rp   150
3  | Telur ayam    | 0.25 | pcs    | 1.00   | Rp 2.000  | Rp   500
4  |               |      |        |        |           |
5  |               |      |        |        |           |
──────────────────────────────────────────────────────────────────
                              TOTAL COGS BAHAN UTAMA: Rp  8.250
──────────────────────────────────────────────────────────────────

BAHAN OVERHEAD (Kategori B — TIDAK dimasukkan, catatan saja)
  Minyak goreng ± 30ml, bumbu (bawang, kemiri, kunyit, garam, merica)

──────────────────────────────────────────────────────────────────
KALKULASI
  Harga Jual            : Rp 22.000
  COGS Bahan Utama      : Rp  8.250
  Food Cost %           : 37.5%   (target: 28–35%)
  Status                : ⚠️ Perlu perhatian — pertimbangkan naik ke Rp 25.000

CATATAN KHUSUS:
  - Yield 0.90 pada ayam = ada ~20g tulang/lemak yang dibuang saat prep
  - Jika harga ayam naik ke > Rp 42/g, food cost = 43%+ → wajib review harga jual
══════════════════════════════════════════════════════════════════
```

### Sheet Kosong (fotokopi untuk setiap menu baru)

```
══════════════════════════════════════════════════════════════════
PLATE COSTING SHEET
══════════════════════════════════════════════════════════════════
Kode Menu   : ___________
Nama Menu   : _________________________________
Kategori    : [ ] Makanan  [ ] Lauk  [ ] Minuman  [ ] Snack
Harga Jual  : Rp ___________
Tanggal     : _______________
Diisi oleh  : _______________
──────────────────────────────────────────────────────────────────

BAHAN UTAMA (Kategori A — masuk resep)
──────────────────────────────────────────────────────────────────
No | Nama Bahan    | Qty  | Satuan | Yield  | Harga/Sat | Total
──────────────────────────────────────────────────────────────────
1  |               |      |        |        |           |
2  |               |      |        |        |           |
3  |               |      |        |        |           |
4  |               |      |        |        |           |
5  |               |      |        |        |           |
6  |               |      |        |        |           |
──────────────────────────────────────────────────────────────────
                              TOTAL COGS BAHAN UTAMA: Rp _________
──────────────────────────────────────────────────────────────────

BAHAN OVERHEAD (tidak dihitung, catatan saja):
  _______________________________________________________________

──────────────────────────────────────────────────────────────────
KALKULASI
  Harga Jual            : Rp ___________
  COGS Bahan Utama      : Rp ___________
  Food Cost %           : ________%  (target: 28–35%)
  Status                : [ ] OK  [ ] Perlu review harga jual

CATATAN KHUSUS:
  _______________________________________________________________
══════════════════════════════════════════════════════════════════
```

---

## TEMPLATE 4 — Rekapitulasi Semua Menu (Ringkasan)

Setelah semua sheet diisi, pindahkan ke tabel ini sebagai overview:

```
══════════════════════════════════════════════════════════════════
REKAPITULASI FOOD COST SEMUA MENU
Tanggal     : _______________
══════════════════════════════════════════════════════════════════
Kode | Nama Menu          | Harga Jual | COGS   | FC%   | Status
──────────────────────────────────────────────────────────────────
M001 | Nasi Putih         | Rp  5.000  | Rp1.400|  28%  | ✅
M002 | Nasi Goreng Biasa  | Rp 18.000  | Rp     |       |
M003 | Nasi Goreng Spl    | Rp 28.000  | Rp8.990|  32%  | ✅
M004 | Ayam Goreng Biasa  | Rp 22.000  | Rp8.250|  37%  | ⚠️
M005 | Ayam Goreng Kremes | Rp 25.000  | Rp8.530|  34%  | ✅
...  | ...                | ...        | ...    | ...   |
──────────────────────────────────────────────────────────────────
RATA-RATA FOOD COST KESELURUHAN:                | _____% |
(weighted average berdasarkan qty terjual)
══════════════════════════════════════════════════════════════════

PANDUAN STATUS:
  ✅ OK          : Food cost < 35%
  ⚠️ Perhatikan  : Food cost 35–40% → review harga atau porsi
  ❌ Masalah     : Food cost > 40% → harus ada tindakan (naikkan harga /
                                      kurangi porsi / ganti supplier)
```

---

## Alur Input ke Database: Langkah Demi Langkah

```
LANGKAH 1 — Input Master Bahan (dari Template 1)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Dari setiap baris Template 1 Kategori A:
  → Menjadi 1 baris di tabel `ingredients`
  → Field yang diisi:
     name             = "Ayam potong"
     unit             = "gram"
     avg_cost_per_unit = 38        ← harga per gram
     current_stock    = 0         ← akan diisi saat input stok awal
     reorder_point    = 1000      ← alert jika stok < 1000g

LANGKAH 2 — Input Master Menu (dari Template 2)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Dari setiap baris Template 2:
  → Menjadi 1 baris di tabel `menus`
  → Field yang diisi:
     name          = "Ayam Goreng Biasa"
     category      = "makanan"
     selling_price = 22000
     is_available  = true

LANGKAH 3 — Input Resep (dari Template 3, satu per menu)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Dari setiap baris bahan di Template 3:
  → Menjadi 1 baris di tabel `menu_recipes`
  → Field yang diisi:
     menu_id           = <id menu Ayam Goreng Biasa>
     ingredient_id     = <id bahan Ayam potong>
     qty_per_portion   = 200      ← gram yang dipakai per porsi
     yield_factor      = 0.90     ← dari kolom Yield di template

  Ulangi untuk setiap bahan di menu yang sama.

LANGKAH 4 — Sistem Hitung Otomatis
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Setelah Langkah 1–3 selesai, view `v_menu_cogs` otomatis menampilkan:
  menu_name        | selling_price | theoretical_cogs | food_cost_pct
  Ayam Goreng Biasa| 22000         | 8250.00          | 37.5
  (tidak perlu input apapun lagi)
```

---

## Yield Factor — Panduan Referensi Cepat

Yield factor sering membingungkan. Ini panduan nilainya untuk bahan umum:

```
══════════════════════════════════════════════════════════════════
YIELD FACTOR REFERENSI
══════════════════════════════════════════════════════════════════
Bahan                    | Yield | Keterangan
──────────────────────────────────────────────────────────────────
Ayam potong              | 0.90  | Buang lemak berlebih, tulang kecil
Ayam fillet (tanpa kulit)| 0.95  | Minimal trimming
Daging sapi (has dalam)  | 0.85  | Ada lemak, urat yang dibuang
Ikan lele (utuh)         | 0.55  | Buang kepala, isi perut, tulang
Ikan fillet              | 0.95  | Minimal loss
Udang (kupas)            | 0.70  | Buang kepala, kulit, ekor
Cumi-cumi                | 0.75  | Buang tulang, kulit luar
Telur                    | 1.00  | Pakai semuanya
Tahu / Tempe             | 1.00  | Tidak ada loss
Beras                    | 1.00  | Ukur beras mentah (nasi jadi 3x berat)
Mie basah                | 1.00  | Langsung pakai
Tepung                   | 1.00  | Tidak ada loss
Sayuran berdaun          | 0.75  | Buang batang keras, daun kuning
Wortel                   | 0.85  | Buang kulit, ujung
Kentang                  | 0.80  | Buang kulit, mata kentang
Kol / kubis              | 0.80  | Buang daun luar, batang
Tomat                    | 0.90  | Buang tangkai
Jeruk (untuk diperas)    | 0.85  | Loss dari biji, ampas tidak ikut
Buah-buahan              | 0.70  | Rata-rata buang kulit + biji
Susu UHT                 | 1.00  | Tuang semua
Kopi bubuk               | 1.00  | Semua masuk air
──────────────────────────────────────────────────────────────────

CARA BACA:
  yield 0.90 berarti: dari 200g bahan mentah yang dibeli/ditimbang,
  hanya 180g yang benar-benar masuk ke piring.
  Sistem otomatis hitung: qty_dibutuhkan = qty_per_porsi / yield_factor
  = 200g / 0.90 = 222g bahan mentah yang harus tersedia
  Sehingga stok teoritis berkurang 222g, bukan 200g.
══════════════════════════════════════════════════════════════════
```

---

## Checklist: Siap Input ke Database?

```
SEBELUM MULAI INPUT KE SISTEM
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

TEMPLATE 1 — Master Bahan:
  [ ] Semua bahan Kategori A sudah ditulis
  [ ] Satuan sudah dipilih dan konsisten (gram / ml / pcs)
  [ ] Harga per satuan sudah dihitung (bukan harga per kg saja)
  [ ] Bahan Kategori B sudah diestimasi total / bulan

TEMPLATE 2 — Master Menu:
  [ ] Semua menu aktif sudah ditulis beserta harga jual
  [ ] Kategori sudah ditentukan
  [ ] Menu yang sudah tidak dijual ditandai "Tidak Tersedia"

TEMPLATE 3 — Resep:
  [ ] Minimal 10 menu terlaris sudah diisi resepnya
  [ ] Semua bahan di resep sudah ada di Master Bahan
  [ ] Yield factor sudah diisi (gunakan tabel referensi di atas)
  [ ] Food cost % sudah dihitung dan diperiksa

BAHAN DARURAT (bisa input setelah sistem jalan):
  [kemudian] Sisa menu yang belum diisi resepnya
  [kemudian] Stok awal (current_stock) tiap bahan
  [kemudian] Resep diperbarui setelah plate costing berikutnya

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Kalau 3 checklist di atas selesai → sistem bisa mulai dijalankan.
Tidak perlu menunggu semua sempurna.
```

---

*Dokumen terkait: [simplifikasi-1.md](./simplifikasi-1.md) | [simplifikasi-2.md](./simplifikasi-2.md) | [resto-finance-1.md](./resto-finance-1.md)*
