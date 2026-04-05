# 📋 Best Practice: Contoh HPP Menu Makanan & Minuman

> Dokumen ini menunjukkan cara mengisi resep per menu secara pragmatis —
> hanya bahan utama yang diukur, overhead dicatat terpisah.
> Semua angka menggunakan harga pasar April 2026 sebagai referensi.

---

## Prinsip Pengisian Resep

Sebelum melihat contoh, ingat dua aturan ini:

```
MASUK RESEP (Kategori A — bahan utama terukur per porsi):
  ✅ Daging, ayam, ikan, seafood
  ✅ Sayuran utama (bukan bumbu)
  ✅ Beras / mie / pasta (bahan pokok)
  ✅ Telur
  ✅ Tahu, tempe
  ✅ Keju, susu, cream (untuk minuman/dessert)
  ✅ Buah-buahan (untuk minuman/dessert)
  ✅ Kopi, teh (bahan dasar minuman)
  ✅ Gula (signifikan untuk minuman — per minuman bisa 20–30g)

TIDAK MASUK RESEP → Kitchen Overhead (Kategori B):
  ❌ Minyak goreng (dipakai bersama)
  ❌ Bumbu dasar: bawang merah, bawang putih, cabai, jahe, kunyit
  ❌ Kecap, saus tiram, saus tomat
  ❌ Garam, gula pasir, merica (untuk masakan — qty sangat kecil)
  ❌ Gas LPG
  ❌ Air mineral / es batu (kecuali untuk minuman yang signifikan)
  ❌ Daun salam, serai, lengkuas, dll
```

**Target food cost per menu:** 28–38% dari harga jual (standar restoran Indonesia)

---

## BAGIAN A — MENU MAKANAN

---

### Menu 1: Ayam Goreng Biasa

**Harga jual: Rp 22.000**

**Plate costing:**

| Bahan | Qty | Unit | Harga/Unit | Total |
|---|---|---|---|---|
| Ayam potong (mentah) | 200 | gram | Rp 38/g | Rp 7.600 |
| Tepung terigu serbaguna | 15 | gram | Rp 10/g | Rp 150 |
| Telur ayam | 0.25 | butir | Rp 2.000/butir | Rp 500 |
| **Total COGS Bahan Utama** | | | | **Rp 8.250** |

*Overhead (minyak goreng ~30ml, bumbu, garam, merica) → kitchen overhead*

```
Food Cost % = Rp 8.250 / Rp 22.000 × 100% = 37.5%
→ Masih dalam batas, tapi perlu diperhatikan jika harga ayam naik
→ Pertimbangkan naik harga jual ke Rp 25.000 jika ayam > Rp 42/g
```

**Input ke sistem `menu_recipes`:**
```
menu: Ayam Goreng Biasa
  - ayam_potong     : 200g   yield_factor: 0.90  (ada sedikit trimming)
  - tepung_terigu   : 15g    yield_factor: 1.0
  - telur_ayam      : 0.25   yield_factor: 1.0
```

---

### Menu 2: Ayam Goreng Kremes

**Harga jual: Rp 25.000**

Ayam goreng dengan tambahan kremes tepung renyah — porsi sama, value perception lebih tinggi.

| Bahan | Qty | Unit | Harga/Unit | Total |
|---|---|---|---|---|
| Ayam potong (mentah) | 200 | gram | Rp 38/g | Rp 7.600 |
| Tepung terigu | 25 | gram | Rp 10/g | Rp 250 |
| Tepung beras | 15 | gram | Rp 12/g | Rp 180 |
| Telur ayam | 0.25 | butir | Rp 2.000 | Rp 500 |
| **Total COGS Bahan Utama** | | | | **Rp 8.530** |

```
Food Cost % = Rp 8.530 / Rp 25.000 × 100% = 34.1%
→ Lebih baik dari ayam goreng biasa meski bahan hampir sama
→ Efek persepsi nilai dari kremes meningkatkan margin
```

---

### Menu 3: Nasi Putih (porsi)

**Harga jual: Rp 5.000**

| Bahan | Qty | Unit | Harga/Unit | Total |
|---|---|---|---|---|
| Beras (mentah) | 100 | gram | Rp 14/g | Rp 1.400 |
| **Total COGS** | | | | **Rp 1.400** |

```
Food Cost % = Rp 1.400 / Rp 5.000 × 100% = 28%
→ Baik. Nasi adalah item margin tinggi yang menopang menu utama.
→ Catatan: 100g beras mentah menghasilkan ~300g nasi matang (yield 3x)
```

**Catatan yield:**
```
menu_recipes:
  - beras: 100g, yield_factor: 1.0
  (yield nasi matang tidak perlu dicatat karena kita ukur beras mentah)
```

---

### Menu 4: Nasi Goreng Spesial

**Harga jual: Rp 28.000**

| Bahan | Qty | Unit | Harga/Unit | Total |
|---|---|---|---|---|
| Beras (nasi matang ekuivalen mentah) | 150 | gram | Rp 14/g | Rp 2.100 |
| Ayam suwir / fillet | 60 | gram | Rp 45/g | Rp 2.700 |
| Telur ayam | 1 | butir | Rp 2.000 | Rp 2.000 |
| Udang (sedang) | 30 | gram | Rp 65/g | Rp 1.950 |
| Sayuran (wortel, kol) | 30 | gram | Rp 8/g | Rp 240 |
| **Total COGS Bahan Utama** | | | | **Rp 8.990** |

*Overhead: minyak, kecap manis, saus tiram, bumbu → kitchen overhead*

```
Food Cost % = Rp 8.990 / Rp 28.000 × 100% = 32.1%
→ Sangat baik. Menu "spesial" multi-bahan justru lebih efisien
   karena harga jualnya bisa premium.
```

---

### Menu 5: Mie Goreng

**Harga jual: Rp 20.000**

| Bahan | Qty | Unit | Harga/Unit | Total |
|---|---|---|---|---|
| Mie kuning basah | 150 | gram | Rp 12/g | Rp 1.800 |
| Telur ayam | 1 | butir | Rp 2.000 | Rp 2.000 |
| Ayam suwir | 40 | gram | Rp 45/g | Rp 1.800 |
| Sayuran (kol, wortel) | 40 | gram | Rp 8/g | Rp 320 |
| **Total COGS Bahan Utama** | | | | **Rp 5.920** |

```
Food Cost % = Rp 5.920 / Rp 20.000 × 100% = 29.6%
→ Sangat efisien. Mie adalah salah satu menu margin terbaik.
→ Perhatikan harga mie basah: fluktuatif, cek tiap bulan.
```

---

### Menu 6: Soto Ayam (dengan nasi)

**Harga jual: Rp 20.000**

| Bahan | Qty | Unit | Harga/Unit | Total |
|---|---|---|---|---|
| Ayam (untuk kuah + suwir) | 150 | gram | Rp 38/g | Rp 5.700 |
| Beras | 100 | gram | Rp 14/g | Rp 1.400 |
| Tauge | 20 | gram | Rp 8/g | Rp 160 |
| Telur rebus | 0.5 | butir | Rp 2.000 | Rp 1.000 |
| Soun/bihun | 15 | gram | Rp 18/g | Rp 270 |
| **Total COGS Bahan Utama** | | | | **Rp 8.530** |

*Overhead: santan/kuah, bumbu soto lengkap, daun salam, serai → kitchen overhead*

```
Food Cost % = Rp 8.530 / Rp 20.000 × 100% = 42.7%
→ PERHATIAN: Di atas batas ideal!
→ Masalah: kuah soto butuh banyak ayam + rempah overhead yang tinggi
→ Solusi 1: Naikkan harga ke Rp 23.000–25.000
→ Solusi 2: Kurangi porsi ayam ke 120g
→ Solusi 3: Bundling dengan minum (paket soto + teh Rp 25.000)
```

**Insight penting:** Menu berkuah seperti soto, bakso, rawon punya food cost inherently lebih tinggi karena overhead kuah (tulang ayam/sapi untuk kaldu, rempah, gas lebih lama). Ini yang sering tidak tertangkap kalau hanya hitung bahan utama.

---

### Menu 7: Tempe & Tahu Goreng (lauk)

**Harga jual: Rp 5.000 (per potong besar)**

| Bahan | Qty | Unit | Harga/Unit | Total |
|---|---|---|---|---|
| Tempe | 60 | gram | Rp 6/g | Rp 360 |
| **Total COGS** | | | | **Rp 360** |

atau:

| Bahan | Qty | Unit | Harga/Unit | Total |
|---|---|---|---|---|
| Tahu putih | 80 | gram | Rp 5/g | Rp 400 |
| **Total COGS** | | | | **Rp 400** |

```
Food Cost % Tempe = 360 / 5.000 = 7.2%  ← margin luar biasa
Food Cost % Tahu  = 400 / 5.000 = 8.0%  ← margin luar biasa

→ Tempe & tahu adalah "margin hero" — selalu sertakan di menu
→ Mereka mensubsidi margin menu protein utama yang lebih tipis
```

---

## BAGIAN B — MENU MINUMAN

Minuman punya karakteristik berbeda: bahan lebih sedikit, overhead lebih kecil
(hanya es batu yang masuk overhead), dan margin biasanya lebih tinggi dari makanan.

---

### Menu 8: Es Teh Manis

**Harga jual: Rp 5.000**

| Bahan | Qty | Unit | Harga/Unit | Total |
|---|---|---|---|---|
| Teh celup / teh curah | 2 | gram | Rp 8/g | Rp 16 |
| Gula pasir | 25 | gram | Rp 16/g | Rp 400 |
| **Total COGS** | | | | **Rp 416** |

*Overhead: es batu, air mineral → kitchen overhead (sangat kecil)*

```
Food Cost % = Rp 416 / Rp 5.000 × 100% = 8.3%
→ Margin tertinggi di menu minuman
→ Teh manis adalah "silent profit engine" restoran
→ Jika 100 gelas per hari: revenue Rp 500.000, COGS hanya Rp 41.600
```

---

### Menu 9: Es Jeruk Peras

**Harga jual: Rp 10.000**

| Bahan | Qty | Unit | Harga/Unit | Total |
|---|---|---|---|---|
| Jeruk nipis / jeruk manis | 3 | buah | Rp 800/buah | Rp 2.400 |
| Gula pasir | 20 | gram | Rp 16/g | Rp 320 |
| **Total COGS** | | | | **Rp 2.720** |

```
Food Cost % = Rp 2.720 / Rp 10.000 × 100% = 27.2%
→ Baik. Jeruk adalah bahan yang fluktuatif musiman.
→ Monitor: saat harga jeruk naik ke Rp 1.500/buah,
   COGS = Rp 4.820 → food cost = 48.2% → harus naik harga atau ganti resep
```

**Input ke sistem — penting mencatat dalam satuan `buah` bukan gram:**
```
menu_recipes:
  - jeruk          : 3 pcs    yield_factor: 0.85  (ada buang biji/ampas)
  - gula_pasir     : 20g      yield_factor: 1.0
```

---

### Menu 10: Kopi Hitam / Kopi Tubruk

**Harga jual: Rp 8.000**

| Bahan | Qty | Unit | Harga/Unit | Total |
|---|---|---|---|---|
| Kopi bubuk | 10 | gram | Rp 30/g | Rp 300 |
| Gula pasir | 15 | gram | Rp 16/g | Rp 240 |
| **Total COGS** | | | | **Rp 540** |

```
Food Cost % = Rp 540 / Rp 8.000 × 100% = 6.75%
→ Margin tertinggi setelah teh. Kopi hitam adalah produk margin premium.
→ Jangan pernah hapus dari menu meski penjualan sepi —
   setiap cangkir yang terjual sangat menguntungkan.
```

---

### Menu 11: Kopi Susu (Kopi Latte Sederhana)

**Harga jual: Rp 18.000**

| Bahan | Qty | Unit | Harga/Unit | Total |
|---|---|---|---|---|
| Kopi bubuk / espresso blend | 15 | gram | Rp 40/g | Rp 600 |
| Susu UHT full cream | 150 | ml | Rp 18/ml | Rp 2.700 |
| Gula pasir | 10 | gram | Rp 16/g | Rp 160 |
| **Total COGS** | | | | **Rp 3.460** |

```
Food Cost % = Rp 3.460 / Rp 18.000 × 100% = 19.2%
→ Sangat baik. Susu terlihat mahal tapi harga jual kopi susu
   bisa premium sehingga margin tetap lebar.
→ Variasi: jika pakai susu kental manis 2 sachet (28g × Rp 15/g = Rp 420)
   → COGS = Rp 1.180 → food cost = 6.6% (tapi rasa berbeda)
```

---

### Menu 12: Es Campur / Es Buah

**Harga jual: Rp 15.000**

| Bahan | Qty | Unit | Harga/Unit | Total |
|---|---|---|---|---|
| Pepaya | 50 | gram | Rp 5/g | Rp 250 |
| Semangka | 50 | gram | Rp 6/g | Rp 300 |
| Nata de coco | 30 | gram | Rp 15/g | Rp 450 |
| Kolang-kaling | 20 | gram | Rp 10/g | Rp 200 |
| Sirup merah | 15 | ml | Rp 8/ml | Rp 120 |
| Susu kental manis | 14 | gram (0.5 sachet) | Rp 15/g | Rp 210 |
| **Total COGS** | | | | **Rp 1.530** |

```
Food Cost % = Rp 1.530 / Rp 15.000 × 100% = 10.2%
→ Sangat baik. Menu "visual" dengan perceived value tinggi.
→ Kunci: buah lokal musiman → harga bisa sangat murah
→ Fleksibel: ganti isi sesuai buah murah bulan ini tanpa ubah harga jual
```

---

## BAGIAN C — Rekapitulasi & Analisis

### Ranking Menu Berdasarkan Food Cost %

| Rank | Menu | Harga Jual | COGS | Food Cost % | Status |
|---|---|---|---|---|---|
| 1 | Kopi Hitam | Rp 8.000 | Rp 540 | 6.8% | ⭐ Terbaik |
| 2 | Es Teh Manis | Rp 5.000 | Rp 416 | 8.3% | ⭐ Terbaik |
| 3 | Tempe Goreng | Rp 5.000 | Rp 360 | 7.2% | ⭐ Terbaik |
| 4 | Tahu Goreng | Rp 5.000 | Rp 400 | 8.0% | ⭐ Terbaik |
| 5 | Es Campur | Rp 15.000 | Rp 1.530 | 10.2% | ✅ Sangat Baik |
| 6 | Kopi Susu | Rp 18.000 | Rp 3.460 | 19.2% | ✅ Baik |
| 7 | Nasi Putih | Rp 5.000 | Rp 1.400 | 28.0% | ✅ Baik |
| 8 | Mie Goreng | Rp 20.000 | Rp 5.920 | 29.6% | ✅ Baik |
| 9 | Es Jeruk | Rp 10.000 | Rp 2.720 | 27.2% | ✅ Baik |
| 10 | Nasi Goreng Spesial | Rp 28.000 | Rp 8.990 | 32.1% | ✅ Normal |
| 11 | Ayam Goreng Kremes | Rp 25.000 | Rp 8.530 | 34.1% | ✅ Normal |
| 12 | Ayam Goreng Biasa | Rp 22.000 | Rp 8.250 | 37.5% | ⚠️ Perhatikan |
| 13 | Soto Ayam | Rp 20.000 | Rp 8.530 | 42.7% | ❌ Perlu Revisi |

**Insight dari tabel ini:**

- **Minuman dan lauk nabati** adalah penyeimbang margin terbaik
- **Menu ayam** membutuhkan perhatian karena harga ayam fluktuatif
- **Soto dan menu berkuah** harus dihitung ulang atau dinaikkan harganya
- **Strategi bundling:** pairing soto (FC 42%) dengan teh manis (FC 8%) → rata-rata FC ~25%

---

### Cara Menggunakan Data Ini untuk Set Harga

Rumus idealnya:

```
Harga Jual Ideal = COGS Bahan Utama / Target Food Cost %

Contoh Ayam Goreng Biasa:
  COGS = Rp 8.250
  Target FC = 30%
  Harga Ideal = Rp 8.250 / 0.30 = Rp 27.500

  Harga sekarang Rp 22.000 → FC 37.5% → ada ruang untuk naik harga
  atau: tambah nilai menu (lalapan, sambal premium) untuk justifikasi harga lebih tinggi
```

---

### Kitchen Overhead: Cara Mencatatnya di Sistem

Semua bahan Kategori B dicatat sebagai satu expense bulanan:

```sql
-- Contoh input akhir bulan April
INSERT INTO expenses (
    restaurant_id, amount, category,
    fiscal_period, expense_date, description
) VALUES
    -- Semua pembelian minyak goreng April
    (resto_id, 850000, 'kitchen_overhead', '2026-04', '2026-04-30',
     'Minyak goreng April: 25 liter × Rp 34.000'),

    -- Semua bumbu dasar April
    (resto_id, 420000, 'kitchen_overhead', '2026-04', '2026-04-30',
     'Bumbu dasar April: bawang, cabai, rempah, kecap, dll'),

    -- Gas LPG April
    (resto_id, 180000, 'kitchen_overhead', '2026-04', '2026-04-30',
     'Gas LPG April: 3 tabung 12kg × Rp 60.000');
```

Kemudian di laporan L/R, kitchen overhead ditambahkan ke blok HPP:

```
HPP (Harga Pokok Penjualan)
  Food cost dari resep (Kategori A)    Rp  4.200.000   (31.1%)
  Kitchen overhead (Kategori B)        Rp  1.450.000   (10.7%)
  Waste & spoilage                     Rp    320.000    (2.4%)
                                       ──────────────
  Total HPP                            Rp  5.970.000   (44.2%)
```

Dengan overhead masuk, food cost % total menjadi lebih realistis.

---

### Panduan Operasional: Plate Costing dalam 1 Jam

Untuk restoran yang sudah berjalan dan ingin mulai mengisi resep ke sistem:

```
SESI PLATE COSTING (lakukan satu kali per menu, saat dapur tidak sibuk)

Alat yang dibutuhkan:
  ✅ Timbangan digital dapur (akurasi 1g) — Rp 50.000 di Shopee
  ✅ Gelas ukur untuk cairan
  ✅ Catatan / HP untuk foto

Langkah:
  1. Minta dapur siapkan bahan untuk SATU porsi menu, belum diolah
  2. Timbang dan catat setiap komponen (tanpa bumbu overhead)
  3. Foto hasilnya sebagai dokumentasi
  4. Input ke sistem menu_recipes

Estimasi waktu per menu: 5–10 menit
Target: 10 menu terlaris dalam 1–2 hari

Setelah 2 minggu: 40–50 menu selesai →
sistem sudah bisa hitung HPP per-menu secara otomatis.
```

---

*Dokumen terkait: [simplifikasi-1.md](./simplifikasi-1.md) | [resto-finance-1.md](./resto-finance-1.md)*
