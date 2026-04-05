Sistem Akuntansi Ada Dua Tingkatan
Tingkatan 1 — Pembukuan Sederhana (Single-Entry / Cash Basis)

Yang kita bangun untuk restoran ini masuk ke kategori ini. Prinsipnya:

Ada uang masuk → catat di incomes
Ada uang keluar → catat di expenses
Untung/Rugi = incomes - expenses
Ini persis seperti kalau kamu catat di buku kas harian: kolom pemasukan dan kolom pengeluaran. Tidak ada debet-kredit eksplisit.

Tingkatan 2 — Akuntansi Penuh (Double-Entry / Debet-Kredit)

Ini yang ada di Level 3 (SIMRS). Setiap transaksi dicatat dua sisi:

Bayar gaji → DR Beban Gaji / CR Kas
Terima payment → DR Kas / CR Pendapatan
Beli bahan hutang → DR Persediaan / CR Hutang Supplier
Persamaan yang harus selalu seimbang: ASET = KEWAJIBAN + EKUITAS. Dari sini bisa menghasilkan Neraca (Balance Sheet), bukan hanya L/R.

Apakah Sistem Kita Sudah Mewakili Prinsip Keuangan?
Jawabannya: Ya, untuk tujuan yang dimaksud — tapi dengan batas yang harus dipahami.

Setiap transaksi di sistem kita sebenarnya implicitly mengikuti debet-kredit, hanya tidak ditulis eksplisit:

Kejadian	Debet-Kredit Implisit	Yang Kita Simpan
Tamu bayar Rp 50.000 cash	DR Kas +50.000 / CR Pendapatan +50.000	incomes.amount = 50.000
Beli ayam 10kg dari supplier	DR Persediaan +350.000 / CR Kas -350.000	ingredients.current_stock += 10 + stock_movements
Inventory loss dari opname	DR Beban Loss +14.000 / CR Persediaan -14.000	expenses.category='inventory_loss' + current_stock dikoreksi
Gaji dibayar	DR Beban Gaji +3.500.000 / CR Kas -3.500.000	expenses.category='salary'
Sisi DR dan CR terjadi, tapi sistem kita hanya menyimpan salah satu sisi yang relevan untuk L/R — yaitu efek income/expense-nya. Sisi aset (kas, persediaan) dicatat secara terpisah di ingredients.current_stock (untuk persediaan) dan diasumsikan implisit untuk kas.

Apa yang Bisa dan Tidak Bisa Dihasilkan
Yang BISA dihasilkan dengan sistem ini:

✅ Laporan Laba Rugi (L/R) bulanan — persis seperti target laporan
✅ Food cost % per menu
✅ LOSS report harian
✅ Revenue per channel (dine-in, GrabFood, GoFood)
✅ Rekonsiliasi kas per shift
Yang TIDAK BISA dihasilkan (karena tidak double-entry):

❌ Neraca (Balance Sheet) — tidak tahu total aset, kewajiban, ekuitas
❌ Hutang supplier formal — kita tahu beli berapa, tapi tidak track sisa hutang per supplier secara akuntansi
❌ Arus Kas (Cash Flow Statement) formal
❌ Laporan untuk auditor atau investor eksternal
Apakah Ini Masalah untuk Restoran Satu Cabang?
Tidak. Dan ini keputusan arsitektur yang disengaja, bukan kelemahan.

Untuk restoran kecil yang dikelola sendiri, owner tidak butuh Neraca harian. Yang dibutuhkan adalah:

"Bulan ini untung berapa? Food cost-ku normal tidak? Platform fee GrabFood proporsional tidak? Bahan apa yang sering loss?"

Semua pertanyaan itu dijawab oleh L/R yang kita bangun.

Kalau someday restoran berkembang dan butuh:

Laporan untuk investor/bank (perlu Neraca)
Audit eksternal
Konsolidasi beberapa cabang secara akuntansi penuh
...baru naik ke Level 3 (double-entry dengan journal_entries dan chart_of_accounts seperti di arsitektur SIMRS). Dan fondasi yang kita bangun ini tidak perlu dibuang — incomes dan expenses tetap bisa menjadi feeder ke jurnal double-entry.

Analogi Sederhana
Sistem kita seperti speedometer di dasbor mobil: akurat, mudah dibaca, cukup untuk berkendara sehari-hari. Double-entry accounting seperti diagnostic komputer di bengkel: memberikan gambaran lengkap seluruh sistem, tapi tidak semua pengemudi perlu itu setiap hari.

Untuk restoran satu cabang SDM minimal → speedometer sudah cukup. Yang penting angkanya benar dan konsisten.