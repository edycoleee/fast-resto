# 📝 Filosofi Simplifikasi — Sistem Keuangan Restoran

> Dokumen ini menjelaskan MENGAPA sistem dibuat sesederhana ini,
> dan MENGAPA itu adalah keputusan yang benar — bukan karena malas,
> tapi karena memahami realita operasional restoran.

---

## 1. Sistem yang Benar adalah Sistem yang Dipakai

Sebelum membahas teknis apapun, ada satu prinsip yang harus selalu diingat:

> **Sistem keuangan yang sempurna di atas kertas tapi tidak dipakai setiap hari
> jauh lebih berbahaya dari sistem sederhana yang konsisten dijalankan.**

Restoran kecil satu cabang dengan SDM minimal bukan perusahaan publik. Tidak ada
kewajiban menyerahkan laporan ke BAPEPAM, tidak ada auditor eksternal, tidak ada
investor yang minta Neraca setiap kuartal. Yang dibutuhkan owner adalah:

- Bulan ini untung atau rugi?
- Menu mana yang paling cuan?
- Bahan apa yang sering hilang?
- GrabFood worth it tidak setelah potong komisi?

Empat pertanyaan itu sudah bisa dijawab penuh oleh sistem L/R sederhana yang
kita bangun. Tidak perlu double-entry, tidak perlu Chart of Accounts, tidak perlu
jurnal debet-kredit.

---

## 2. Tentang Debet-Kredit: Sudah Ada, Hanya Tidak Eksplisit

Pertanyaan yang sering muncul: *"Apakah sistem ini sudah mengikuti prinsip
keuangan yang benar? Di akuntansi kan ada debet dan kredit?"*

Jawabannya: **Ya, prinsipnya sudah terpenuhi — hanya tidak ditulis eksplisit.**

Setiap transaksi di sistem kita sebenarnya implicitly mengikuti debet-kredit:

| Kejadian | Debet-Kredit Implisit | Yang Tersimpan di Sistem |
|---|---|---|
| Tamu bayar Rp 50.000 cash | DR Kas / CR Pendapatan | `incomes.amount = 50.000` |
| Beli ayam 10kg | DR Persediaan / CR Kas | `stock += 10kg` + `stock_movements` |
| Loss dari opname | DR Beban Loss / CR Persediaan | `expenses.category='inventory_loss'` |
| Gaji dibayar | DR Beban Gaji / CR Kas | `expenses.category='salary'` |

Kedua sisi terjadi — sistem hanya menyimpan sisi yang relevan untuk L/R.
Ini bukan kekeliruan arsitektur. Ini adalah **pilihan sadar** untuk tidak
membebani operator dengan konsep akuntansi yang tidak mereka butuhkan sehari-hari.

**Analogi:** Speedometer di dasbor mobil tidak menampilkan tekanan oli,
suhu transmisi, dan tegangan alternator sekaligus — bukan karena informasi itu
tidak ada, tapi karena pengemudi sehari-hari tidak perlu semua itu untuk berkendara.
Double-entry adalah diagnostic komputer bengkel: lengkap, tapi tidak untuk dipakai
setiap hari oleh kasir restoran.

Kalau suatu saat restoran berkembang dan butuh Neraca formal untuk bank atau
investor, fondasi `incomes` dan `expenses` ini tidak perlu dibuang — ia bisa
menjadi *feeder* ke jurnal double-entry di atasnya.

---

## 3. Masalah Terberat Restoran Tradisional: HPP yang Tidak Bisa Presisi 100%

Ini topik paling jujur yang perlu dibahas. Dan sering dihindari oleh
dokumentasi teknis karena tidak ada jawaban yang sempurna.

### Realita Dapur Restoran

Di restoran, ada bahan yang **dipakai bersamaan untuk banyak menu**:

```
Minyak goreng:
  → dipakai untuk goreng ayam
  → dipakai untuk goreng tempe
  → dipakai untuk tumis sayur
  → dipakai untuk oseng bumbu
  → dipakai untuk memanaskan wajan (tanpa produk jadi)

Bawang merah & putih (bumbu dasar):
  → masuk ke hampir semua masakan
  → kadang dipakai langsung, kadang dihaluskan jadi bumbu
  → satu tumisan bumbu bisa untuk 5–10 porsi menu berbeda

Gas / LPG:
  → tidak bisa diukur per menu sama sekali
  → dipakai semua kompor sekaligus
  → satu tabung 12kg bisa habis dalam 3–5 hari tergantung volume

Air untuk rebus / steam:
  → hampir tidak mungkin diukur per porsi
```

Kalau kita paksa semua bahan ini masuk ke resep per-porsi secara presisi,
yang terjadi adalah:

1. **Waktu setup awal yang tidak masuk akal** — menentukan berapa ml minyak
   per porsi ayam goreng membutuhkan pengukuran berulang yang tidak realistis
   untuk dapur komersil

2. **Resep yang "salah" sejak awal** — minyak untuk goreng ayam berbeda
   tergantung suhu wajan, ukuran ayam, dan kondisi minyak (baru vs sudah
   dipakai). Angka di resep akan selalu jadi estimasi

3. **Maintenance resep yang melelahkan** — setiap kali harga minyak naik atau
   formula bumbu berubah, semua resep harus diupdate satu per satu

4. **False precision** — sistem menampilkan HPP = Rp 7.234 per porsi dengan
   ketelitian sampai rupiah, padahal angka aslinya bisa ±20% dari itu.
   Ini berbahaya karena memberi rasa aman yang palsu.

### Solusinya: Pisahkan Bahan Utama dan Bahan Overhead

Best practice industri F&B yang pragmatis adalah membagi bahan ke dua kategori:

```
KATEGORI A — Bahan Utama (masuk resep per-porsi)
  → Bahan yang dominan dan bisa diukur per menu
  → Contoh: daging, ayam, ikan, sayuran utama, nasi
  → Ini yang benar-benar menentukan HPP per menu
  → Resepnya bisa akurat hingga ±5%

KATEGORI B — Bahan Overhead (tidak masuk resep, dicatat sebagai biaya operasional)
  → Bahan yang dipakai bersama dan tidak bisa diatribusikan per menu
  → Contoh: minyak goreng, bumbu dasar, gas, garam, gula, kecap
  → Dicatat sebagai: expenses.category = 'kitchen_overhead'
  → Dimasukkan sebagai komponen HPP secara agregat, bukan per-menu
```

Dengan pembagian ini, sistem tetap bisa menghitung HPP yang bermakna:

```
HPP Total = Food cost dari resep (bahan utama Kategori A)
           + Kitchen overhead bulan ini (Kategori B, dari pembelian)
           + Waste & spoilage (dari opname)
```

Dan food cost % tetap bisa dihitung:

```
Food cost % = HPP Total / Revenue × 100%

Target industri restoran Indonesia:
  Food cost %  : 28% – 35% (ideal)
  Gross profit : 65% – 72%
```

Kalau food cost % bulan ini 38%, owner tahu ada masalah — entah itu
harga bahan naik, porsi berlebih, atau overhead melonjak. Tanpa perlu
tahu persisnya per-menu, angka agregat ini sudah actionable.

---

## 4. Update Dinamis: Mengapa Resep Tidak Perlu Real-Time Perfect

Pertanyaan lanjutan yang kemudian muncul: *"Kalau harga minyak naik minggu ini,
HPP-nya otomatis update tidak?"*

Jawaban sistem kita: **Ya, untuk bahan Kategori A — via weighted average cost.**

```
Pembelian 1 (Januari): Ayam 10kg @ Rp 33.000/kg
  → avg_cost = Rp 33.000/g → HPP Ayam Goreng = Rp 6.600

Pembelian 2 (Februari): Ayam 10kg @ Rp 38.000/kg (naik)
  → avg_cost baru = (10×33.000 + 10×38.000) / 20 = Rp 35.500/kg
  → HPP Ayam Goreng otomatis update = Rp 7.100

Tidak perlu edit resep. Cukup input pembelian yang benar.
```

Untuk bahan Kategori B (overhead), update-nya cukup bulanan:
saat input pembelian minyak, gas, bumbu → masuk sebagai `kitchen_overhead` expense
→ otomatis masuk ke HPP bulan itu.

### Yang Tidak Perlu Diupdate Real-Time

Yang sering orang pikirkan tapi ternyata tidak perlu:

- **Qty bahan per resep** — tidak perlu berubah kecuali ada perubahan resep yang disengaja
- **Harga jual menu** — ini keputusan bisnis, bukan kalkulasi otomatis
- **Yield factor** — diset sekali di awal, direvisi hanya jika berganti supplier atau metode masak

Dengan kata lain: **menginput pembelian dengan harga yang benar sudah cukup
untuk menjaga akurasi HPP secara dinamis.** Tidak perlu maintenance tambahan.

---

## 5. Trade-off yang Disengaja: Akurasi vs Operabilitas

Ini keputusan arsitektur yang perlu didokumentasikan secara eksplisit
agar tidak dipertanyakan ulang di masa depan.

| Aspek | Sistem Presisi Penuh | Sistem Kita (Pragmatis) |
|---|---|---|
| HPP per menu | Akurat hingga ±2% | Akurat hingga ±10–15% untuk overhead |
| Waktu setup resep | 2–4 minggu | 1–3 hari |
| Maintenance bulanan | Tinggi (update setiap harga berubah) | Rendah (cukup input pembelian) |
| SDM yang diperlukan | Perlu staf khusus inventory | Bisa dilakukan kasir/owner sendiri |
| Laporan L/R | Sangat detail per bahan | Detail per kategori, cukup untuk keputusan |
| Risiko data salah | Tinggi (banyak input manual) | Rendah (input minimal, otomasi maksimal) |
| Cocok untuk | Chain restoran 10+ cabang | Restoran 1 cabang, SDM 3–8 orang |

**Keputusan:** Sistem ini secara sadar memilih kolom kanan.

Alasannya sederhana: **data yang 80% akurat tapi konsisten dijalankan setiap hari
lebih berharga dari sistem 99% akurat yang ditinggalkan setelah dua minggu
karena terlalu rumit.**

---

## 6. Kapan Harus Naik ke Sistem yang Lebih Kompleks?

Sistem ini cukup selama kondisi berikut terpenuhi:
- Restoran satu cabang atau maksimal dua cabang
- Owner masih terlibat langsung dalam operasional
- Tidak ada kewajiban laporan ke pihak eksternal (bank, investor, pajak korporasi)
- Jumlah menu tidak lebih dari ~80 item aktif

**Sinyal untuk naik level:**
- Ada investor masuk yang minta Neraca (Balance Sheet)
- Buka cabang ke-3 ke atas dengan kepemilikan berbeda
- Revenue bulanan melampaui Rp 500 juta (kena PKP / PPN)
- Ada franchisee yang butuh laporan standar

Saat itu tiba, sistem ini menjadi fondasi — bukan dibuang dari nol.
`incomes`, `expenses`, `stock_movements`, dan `orders` tetap relevan;
yang ditambahkan adalah lapisan `journal_entries` dan `chart_of_accounts`
di atasnya, persis seperti arsitektur Level 3 di `prompt-finance-3.md`.

---

## Kesimpulan

> Sistem terbaik untuk restoran kecil bukan yang paling canggih,
> tapi yang paling **konsisten bisa dijalankan** oleh SDM yang ada.
>
> HPP tidak akan pernah 100% presisi di dapur manapun.
> Yang bisa dikontrol adalah: **seberapa cepat kamu mendeteksi anomali**
> dan **seberapa mudah kamu membaca laporan untuk mengambil keputusan.**
>
> Itulah tujuan sistem ini.
