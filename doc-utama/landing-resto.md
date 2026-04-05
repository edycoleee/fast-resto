# Landing Resto: Landing Page, CMS, & QR Self-Order

**Tanggal:** 5 April 2026
**Adopsi dari:** `landing.md` (Fast-Klinik proven patterns) + `simplifikasi-4.md`
**Stack:** React + Vite (JS), Tailwind CSS, FastAPI, PostgreSQL

---

## Stack & Konvensi Wajib

| Item | Nilai |
|---|---|
| Framework | React + Vite (JS bukan TS) |
| CSS | Tailwind CSS — gunakan custom token `resto-*` (lihat di bawah) |
| Path alias | `@/` → `src/` (dikonfigurasi di `vite.config.js`) |
| Router | `react-router-dom` v7 — pakai `<Link>` dan `ROUTES` constants |
| State fetch | hook `useFetch` dari `@/domain/hooks` — JANGAN pakai `axios` langsung |
| Repository | Factory functions dari `@/data/repositories` |
| Auth context | `useAuth()` dari `@/domain/contexts/AuthContext` |
| Format uang | `formatRupiah` dari `@/presentation/utils/format` |
| Format tanggal | `formatDate`, `formatDateTime` dari `@/presentation/utils/format` — selalu WIB |
| Notif | `useNotif()` dari `@/presentation/components/layout` |

### Tailwind Color Tokens — Warna Restoran (Hangat)

```js
// tailwind.config.js
module.exports = {
  theme: {
    extend: {
      colors: {
        resto: {
          primary:   '#D4521A',   // oranye terra cotta — hangat, selera makan
          secondary: '#F0A060',   // oranye muda — aksen
          accent:    '#9B3A10',   // coklat gelap — hero, hover
          bg:        '#FFF8F3',   // krem hangat — background utama
          text:      '#2C1A0E',   // coklat gelap — teks utama
          muted:     '#8B6E5A',   // coklat muted — teks sekunder
          card:      '#FFFFFF',   // putih — card background
          border:    '#F0D8C0',   // border hangat
        }
      }
    }
  }
}
```

Contoh: `bg-resto-bg`, `text-resto-primary`, `border-resto-border`

### ROUTES Constants

```js
// src/constants/routes.js
export const ROUTES = {
  HOME:           '/',                    // Landing page publik
  MENU:           '/menu',               // QR self-order customer (public)
  ADMIN_DASHBOARD: '/admin',
  ADMIN_MENUS:    '/admin/menus',
  ADMIN_TABLES:   '/admin/tables',
  ADMIN_CMS:      '/admin/cms',
  ADMIN_ORDERS:   '/admin/orders',
  LOGIN:          '/login',
}
```

---

## Skema DB yang Perlu Ditambahkan

Semua ini masuk ke `resto-finance-2.md` dan `init.sql` sebelum deploy.

### Tambahan ke Tabel `menus` (yang sudah ada)

```sql
-- Kolom baru — nullable, tidak merusak logika existing
ALTER TABLE menus ADD COLUMN IF NOT EXISTS
    description TEXT,               -- deskripsi singkat untuk menu card di landing
    image_url   VARCHAR(500),       -- URL gambar menu (CDN atau /uploads/menus/)
    sort_order  INTEGER DEFAULT 0;  -- urutan tampil per kategori
```

### Tabel Baru: `cms_site_settings`

```sql
CREATE TABLE cms_site_settings (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id UUID NOT NULL REFERENCES restaurants(id),
    key           VARCHAR(100) NOT NULL,
    value         TEXT,
    updated_at    TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (restaurant_id, key)
);

-- Index untuk lookup per restoran
CREATE INDEX idx_site_settings_restaurant
    ON cms_site_settings(restaurant_id);
```

**Keys yang dipakai (seed awal):**

| Key | Contoh Value | Keterangan |
|---|---|---|
| `restaurant_name` | Warung Makan Pak Budi | Nama tampil di struk & landing |
| `tagline` | Enak, Cepat, Terjangkau | Tagline di hero section |
| `address` | Jl. Merdeka No. 5, Jakarta | Alamat fisik |
| `opening_hours` | 08.00 – 21.00 WIB | Jam operasional |
| `whatsapp_number` | 6281234567890 | Tanpa + atau spasi |
| `instagram_url` | https://instagram.com/warungpakbudi | Optional |
| `maps_embed_url` | (paste full `<iframe>` ok) | Auto-strip ke src saja |
| `hero_title` | Nikmatnya Masakan Rumahan | H1 di hero |
| `hero_subtitle` | Pesan dari meja, makanan langsung datang! | Subtext hero |
| `footer_text` | © 2026 Warung Makan Pak Budi | Footer copyright |

### Tabel Baru: `cms_banners`

```sql
CREATE TABLE cms_banners (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id UUID NOT NULL REFERENCES restaurants(id),
    title         VARCHAR(150),
    subtitle      VARCHAR(300),
    image_url     VARCHAR(500) NOT NULL,
    action_url    VARCHAR(500),          -- link ke section atau promo
    sequence      INTEGER DEFAULT 0,     -- urutan slide
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    start_date    DATE,                  -- NULL = selalu tampil
    end_date      DATE,
    created_at    TIMESTAMPTZ DEFAULT NOW()
);
```

### Tabel Baru: `cms_promotions`

```sql
CREATE TABLE cms_promotions (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    restaurant_id UUID NOT NULL REFERENCES restaurants(id),
    title         VARCHAR(150) NOT NULL,
    description   TEXT,
    image_url     VARCHAR(500),
    discount_pct  INTEGER,              -- 0-100, null jika promo bukan persen
    discount_label VARCHAR(50),         -- "Beli 2 Gratis 1", "Hemat 30%"
    start_date    DATE NOT NULL,
    end_date      DATE NOT NULL,
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ DEFAULT NOW()
);
```

### Index Tambahan

```sql
-- Banner aktif yang sedang berlaku
CREATE INDEX idx_cms_banners_active
    ON cms_banners(restaurant_id, sequence)
    WHERE is_active = TRUE;

-- Promo aktif yang sedang berlaku
CREATE INDEX idx_cms_promos_active
    ON cms_promotions(restaurant_id, end_date)
    WHERE is_active = TRUE;
```

---

## Backend API Endpoints

### A. Endpoint Publik (Tanpa Auth)

```
GET  /api/v1/public/site-settings    ?restaurant_id=
GET  /api/v1/public/banners          ?restaurant_id=
GET  /api/v1/public/promotions       ?restaurant_id=
GET  /api/v1/public/menus            ?restaurant_id= &category= &is_available=true
GET  /api/v1/public/tables/{qr_token}   — lookup meja dari QR scan
POST /api/v1/public/orders/self-order   — customer submit order (tanpa auth)
GET  /api/v1/public/orders/{order_number}/status — customer tracking status order
```

**Response pattern WAJIB seragam:**
```json
{ "success": true, "data": { ... } }
```

`site-settings` return flat object: `{ "restaurant_name": "...", "tagline": "..." }`
Semua lainnya return `{ "items": [...], "total": N }`

### B. CMS Admin (Butuh Auth + role `manager` atau `owner`)

```
GET    /api/v1/cms/site-settings
PUT    /api/v1/cms/site-settings/{key}

GET    /api/v1/cms/banners
POST   /api/v1/cms/banners
PUT    /api/v1/cms/banners/{id}
DELETE /api/v1/cms/banners/{id}         — soft delete (is_active=False)

GET    /api/v1/cms/promotions
POST   /api/v1/cms/promotions
PUT    /api/v1/cms/promotions/{id}
DELETE /api/v1/cms/promotions/{id}

POST   /api/v1/cms/upload/image         — upload gambar, return { url }
```

### C. Menu Admin (sudah ada, perlu update field)

```
GET    /api/v1/admin/menus             — tambahkan description, image_url, sort_order
PUT    /api/v1/admin/menus/{id}        — termasuk update field baru
PATCH  /api/v1/admin/menus/{id}/toggle — toggle is_available
```

### D. Tables Admin (QR Management)

```
GET    /api/v1/admin/tables
POST   /api/v1/admin/tables
PUT    /api/v1/admin/tables/{id}
DELETE /api/v1/admin/tables/{id}
GET    /api/v1/admin/tables/{id}/qr    — generate QR code image (PNG/SVG)
```

---

## PublicRestoRepository — Pattern Fetch Frontend

Adopsi dari `PublicRepository` Fast-Klinik:

```js
// src/data/repositories/PublicRestoRepository.js
import { apiClient } from '@/data/api/apiClient'

export const PublicRestoRepository = () => {
  const getSiteSettings = () =>
    apiClient.get('/public/site-settings').then(r => r.data.data ?? {})

  const getBanners = () =>
    apiClient.get('/public/banners').then(r => r.data.data?.items ?? [])

  const getPromotions = () =>
    apiClient.get('/public/promotions').then(r => r.data.data?.items ?? [])

  const getMenus = (category = null) => {
    const params = { is_available: true }
    if (category) params.category = category
    return apiClient.get('/public/menus', { params }).then(r => r.data.data?.items ?? [])
  }

  const getTableByQrToken = (qrToken) =>
    apiClient.get(`/public/tables/${qrToken}`).then(r => r.data.data)

  const submitSelfOrder = (payload) =>
    apiClient.post('/public/orders/self-order', payload).then(r => r.data.data)

  const getOrderStatus = (orderNumber) =>
    apiClient.get(`/public/orders/${orderNumber}/status`).then(r => r.data.data)

  return { getSiteSettings, getBanners, getPromotions, getMenus, getTableByQrToken, submitSelfOrder, getOrderStatus }
}
```

**Helper `toAbsUrl` — wajib untuk semua gambar dari backend:**
```js
// src/presentation/utils/format.js — tambahkan:
export function toAbsUrl(urlPath) {
  if (!urlPath) return null
  if (urlPath.startsWith('http')) return urlPath
  const base = (import.meta.env.VITE_API_BASE_URL || 'http://localhost:8000/api/v1')
    .replace(/\/api\/v1\/?$/, '')
  return `${base}${urlPath}`
}

export function formatRupiah(amount) {
  if (!amount && amount !== 0) return '—'
  return new Intl.NumberFormat('id-ID', {
    style: 'currency',
    currency: 'IDR',
    minimumFractionDigits: 0,
  }).format(amount)
}
```

---

## Halaman 1: Landing Page (`/`)

### Struktur & Urutan Section

```
PublicLayout (Navbar sticky + Footer)
  └─ LandingPage.jsx
       1. Hero         → banner CMS auto-slide 5 detik + dots indicator
       2. Tentang      → tagline + deskripsi singkat restoran (site_settings)
       3. Menu Unggulan → 6–8 menu terpilih (sort_order terkecil, is_available=true)
       4. Promo        → cms_promotions aktif, badge diskon
       5. Cara Pesan   → 3 langkah: scan QR → pilih menu → tunggu
       6. CTA          → tombol lihat menu lengkap + WA
       7. Lokasi       → Google Maps iframe + jam buka + kontak
  (floating) WhatsApp button kanan bawah
```

### LandingPage.jsx — Pola Fetch Data

```jsx
// src/presentation/pages/public/LandingPage.jsx
import { useState, useEffect } from 'react'
import { PublicRestoRepository } from '@/data/repositories'
import { toAbsUrl, formatRupiah } from '@/presentation/utils/format'

export default function LandingPage() {
  const [settings, setSettings] = useState({})
  const [banners, setBanners]   = useState([])
  const [menus, setMenus]       = useState([])
  const [promos, setPromos]     = useState([])
  const [bannerIdx, setBannerIdx] = useState(0)

  useEffect(() => {
    const pub = PublicRestoRepository()
    pub.getSiteSettings().then(d => setSettings(d ?? {})).catch(() => {})
    pub.getBanners().then(setBanners).catch(() => {})
    pub.getMenus().then(d => setMenus(d.slice(0, 8))).catch(() => {}) // max 8 di landing
    pub.getPromotions().then(setPromos).catch(() => {})
  }, [])

  // Auto-slide banner setiap 5 detik
  useEffect(() => {
    if (banners.length <= 1) return
    const id = setInterval(() => setBannerIdx(i => (i + 1) % banners.length), 5000)
    return () => clearInterval(id)
  }, [banners.length])

  // Fallback jika site_settings belum ada
  const s = settings
  const restaurantName = s.restaurant_name || 'Warung Makan'
  const heroTitle      = s.hero_title      || 'Masakan Rumahan yang Bikin Rindu'
  const heroSubtitle   = s.hero_subtitle   || 'Pesan dari meja lewat scan QR, makanan langsung datang!'
  const waNumber       = s.whatsapp_number || ''
  const waLink         = waNumber ? `https://wa.me/${waNumber}` : '#'

  // Parse maps_embed_url — user mungkin paste full <iframe> tag
  const rawMaps = s.maps_embed_url || ''
  const mapsEmbedUrl = (() => {
    if (!rawMaps) return ''
    const m = rawMaps.match(/src=["']([^"']+)["']/)
    return m ? m[1] : rawMaps
  })()

  return (
    <div className="bg-resto-bg text-resto-text">
      {/* 1. HERO */}
      <section className="relative min-h-[70vh] bg-resto-accent overflow-hidden">
        {banners.length > 0 ? (
          <>
            <img
              src={toAbsUrl(banners[bannerIdx]?.image_url)}
              alt={banners[bannerIdx]?.title}
              className="absolute inset-0 w-full h-full object-cover opacity-60"
            />
            {/* Overlay text dari banner CMS */}
            <div className="relative z-10 flex flex-col items-center justify-center min-h-[70vh] text-white text-center px-6">
              <h1 className="text-4xl md:text-5xl font-bold mb-4">
                {banners[bannerIdx]?.title || heroTitle}
              </h1>
              <p className="text-lg md:text-xl mb-8 max-w-xl">
                {banners[bannerIdx]?.subtitle || heroSubtitle}
              </p>
              <div className="flex gap-4 flex-wrap justify-center">
                <a href="#menu" className="bg-resto-primary text-white px-8 py-3 rounded-full font-semibold hover:bg-resto-accent transition">
                  Lihat Menu
                </a>
                {waLink !== '#' && (
                  <a href={waLink} target="_blank" rel="noreferrer"
                    className="border-2 border-white text-white px-8 py-3 rounded-full font-semibold hover:bg-white hover:text-resto-accent transition">
                    WhatsApp
                  </a>
                )}
              </div>
            </div>
            {/* Dots indicator */}
            {banners.length > 1 && (
              <div className="absolute bottom-4 left-0 right-0 flex justify-center gap-2 z-10">
                {banners.map((_, i) => (
                  <button key={i} onClick={() => setBannerIdx(i)}
                    className={`w-2.5 h-2.5 rounded-full transition ${i === bannerIdx ? 'bg-white' : 'bg-white/40'}`}
                  />
                ))}
              </div>
            )}
          </>
        ) : (
          /* Fallback jika belum ada banner di CMS */
          <div className="flex flex-col items-center justify-center min-h-[70vh] text-white text-center px-6">
            <h1 className="text-4xl md:text-5xl font-bold mb-4">{heroTitle}</h1>
            <p className="text-lg md:text-xl mb-8 max-w-xl">{heroSubtitle}</p>
            <a href="#menu" className="bg-white text-resto-accent px-8 py-3 rounded-full font-semibold hover:bg-resto-bg transition">
              Lihat Menu
            </a>
          </div>
        )}
      </section>

      {/* 2. CARA PESAN — 3 Langkah */}
      <section className="py-16 px-6 bg-white">
        <h2 className="text-2xl font-bold text-center text-resto-text mb-10">
          Cara Pesan Mudah
        </h2>
        <div className="max-w-3xl mx-auto grid grid-cols-1 md:grid-cols-3 gap-8 text-center">
          {[
            { icon: '📱', step: '1', title: 'Scan QR di Meja', desc: 'Arahkan kamera ke QR code di atas meja Anda' },
            { icon: '🍽️', step: '2', title: 'Pilih Menu', desc: 'Browse menu lengkap, tambah ke keranjang' },
            { icon: '✅', step: '3', title: 'Konfirmasi', desc: 'Kirim pesanan — kasir langsung terima notifikasi' },
          ].map(c => (
            <div key={c.step} className="flex flex-col items-center gap-3">
              <div className="w-16 h-16 bg-resto-primary/10 rounded-full flex items-center justify-center text-3xl">
                {c.icon}
              </div>
              <span className="text-xs font-bold bg-resto-primary text-white rounded-full w-6 h-6 flex items-center justify-center">
                {c.step}
              </span>
              <h3 className="font-bold text-resto-text">{c.title}</h3>
              <p className="text-sm text-resto-muted">{c.desc}</p>
            </div>
          ))}
        </div>
      </section>

      {/* 3. MENU UNGGULAN */}
      {menus.length > 0 && (
        <section id="menu" className="py-16 px-6 bg-resto-bg">
          <h2 className="text-2xl font-bold text-center text-resto-text mb-2">Menu Favorit</h2>
          <p className="text-center text-resto-muted mb-10">Pilihan terlaris di tempat kami</p>
          <div className="max-w-5xl mx-auto grid grid-cols-2 md:grid-cols-4 gap-4">
            {menus.map(menu => (
              <div key={menu.id} className="bg-white rounded-2xl overflow-hidden shadow-sm border border-resto-border hover:shadow-md transition">
                {menu.image_url ? (
                  <img src={toAbsUrl(menu.image_url)} alt={menu.name}
                    className="w-full h-36 object-cover" />
                ) : (
                  <div className="w-full h-36 bg-resto-primary/10 flex items-center justify-center text-4xl">🍽️</div>
                )}
                <div className="p-3">
                  <p className="font-semibold text-sm text-resto-text line-clamp-2">{menu.name}</p>
                  {menu.description && (
                    <p className="text-xs text-resto-muted mt-1 line-clamp-2">{menu.description}</p>
                  )}
                  <p className="text-resto-primary font-bold text-sm mt-2">{formatRupiah(menu.selling_price)}</p>
                  {!menu.is_available && (
                    <span className="text-xs bg-gray-100 text-gray-500 px-2 py-0.5 rounded-full">Habis</span>
                  )}
                </div>
              </div>
            ))}
          </div>
        </section>
      )}

      {/* 4. PROMO */}
      {promos.length > 0 && (
        <section id="promo" className="py-16 px-6 bg-white">
          <h2 className="text-2xl font-bold text-center text-resto-text mb-2">Promo Spesial</h2>
          <p className="text-center text-resto-muted mb-10">Penawaran terbatas untuk Anda</p>
          <div className="max-w-4xl mx-auto grid grid-cols-1 md:grid-cols-3 gap-6">
            {promos.map(promo => {
              const isExpired = new Date(promo.end_date) < new Date()
              return (
                <div key={promo.id} className={`relative bg-white rounded-2xl overflow-hidden shadow border border-resto-border ${isExpired ? 'opacity-50' : ''}`}>
                  {promo.image_url && (
                    <img src={toAbsUrl(promo.image_url)} alt={promo.title}
                      className="w-full h-40 object-cover" />
                  )}
                  {promo.discount_label && (
                    <span className="absolute top-3 right-3 bg-resto-primary text-white text-xs font-bold px-3 py-1 rounded-full">
                      {promo.discount_label}
                    </span>
                  )}
                  <div className="p-4">
                    <h3 className="font-bold text-resto-text">{promo.title}</h3>
                    {promo.description && <p className="text-sm text-resto-muted mt-1">{promo.description}</p>}
                    <p className="text-xs text-resto-muted mt-2">s/d {new Date(promo.end_date).toLocaleDateString('id-ID')}</p>
                    {isExpired && <p className="text-xs text-red-500 font-medium mt-1">Promo telah berakhir</p>}
                  </div>
                </div>
              )
            })}
          </div>
        </section>
      )}

      {/* 5. CTA */}
      <section className="py-20 px-6 bg-gradient-to-r from-resto-accent to-resto-primary text-white text-center">
        <h2 className="text-3xl font-bold mb-4">Lapar? Yuk Pesan Sekarang!</h2>
        <p className="mb-8 text-white/80">Scan QR di meja Anda atau hubungi kami via WhatsApp</p>
        <div className="flex gap-4 justify-center flex-wrap">
          {waLink !== '#' && (
            <a href={waLink} target="_blank" rel="noreferrer"
              className="bg-white text-resto-accent px-8 py-3 rounded-full font-semibold hover:bg-resto-bg transition">
              Chat WhatsApp
            </a>
          )}
        </div>
      </section>

      {/* 6. LOKASI */}
      <section id="lokasi" className="py-16 px-6 bg-resto-bg">
        <h2 className="text-2xl font-bold text-center text-resto-text mb-10">Temukan Kami</h2>
        <div className="max-w-5xl mx-auto grid grid-cols-1 md:grid-cols-2 gap-8 items-start">
          {/* Info */}
          <div className="space-y-4">
            {s.address && (
              <div>
                <p className="font-semibold text-resto-text">📍 Alamat</p>
                <p className="text-resto-muted mt-1">{s.address}</p>
              </div>
            )}
            {s.opening_hours && (
              <div>
                <p className="font-semibold text-resto-text">🕐 Jam Buka</p>
                <p className="text-resto-muted mt-1">{s.opening_hours}</p>
              </div>
            )}
            {waNumber && (
              <div>
                <p className="font-semibold text-resto-text">📱 WhatsApp</p>
                <a href={waLink} target="_blank" rel="noreferrer"
                  className="text-resto-primary hover:underline mt-1 block">
                  +{waNumber}
                </a>
              </div>
            )}
            {s.instagram_url && (
              <div>
                <p className="font-semibold text-resto-text">📸 Instagram</p>
                <a href={s.instagram_url} target="_blank" rel="noreferrer"
                  className="text-resto-primary hover:underline mt-1 block">
                  {s.instagram_url.replace('https://instagram.com/', '@')}
                </a>
              </div>
            )}
          </div>
          {/* Map */}
          {mapsEmbedUrl && (
            <iframe src={mapsEmbedUrl} className="w-full h-72 rounded-2xl border-0 shadow"
              allowFullScreen loading="lazy" title="Lokasi Restoran" />
          )}
        </div>
      </section>

      {/* Floating WhatsApp */}
      {waLink !== '#' && (
        <a href={waLink} target="_blank" rel="noreferrer"
          className="fixed bottom-6 right-6 w-14 h-14 bg-green-500 text-white rounded-full flex items-center justify-center text-2xl shadow-lg hover:bg-green-600 transition z-50">
          💬
        </a>
      )}
    </div>
  )
}
```

---

## Halaman 2: QR Self-Order (`/menu?t={qr_token}`)

Ini adalah halaman utama yang customer lihat setelah scan QR.
**Mobile-first, touch-friendly, cepat.**

### Alur State

```
URL: /menu?t=abc123
       ↓
  [loadingMeja]
  GET /public/tables/abc123
       ├── 404 → QRInvalidPage (token tidak dikenal)
       └── 200 → { table_id, table_number, restaurant_id }
                    ↓
             [menuPage]
             GET /public/menus
             Tampil: kategori tabs + menu grid
                    ↓
             Customer tambah ke cart
                    ↓
             [checkoutForm]
             Input nama + nomor HP (opsional)
             Tap "Kirim Pesanan"
                    ↓
             POST /public/orders/self-order
                    ↓
             [orderConfirmed]
             Tampil nomor order + estimasi
             "Pesanan kamu sudah kami terima!"
```

### MenuPage.jsx (QR Self-Order)

```jsx
// src/presentation/pages/public/MenuPage.jsx
import { useState, useEffect, useRef } from 'react'
import { useSearchParams } from 'react-router-dom'
import { PublicRestoRepository } from '@/data/repositories'
import { toAbsUrl, formatRupiah } from '@/presentation/utils/format'

// Kategori yang ada di sistem (sesuai menus.category VARCHAR(50))
const CATEGORIES = [
  { key: 'semua',   label: 'Semua' },
  { key: 'makanan', label: '🍱 Makanan' },
  { key: 'lauk',    label: '🍗 Lauk' },
  { key: 'snack',   label: '🍟 Snack' },
  { key: 'minuman', label: '🥤 Minuman' },
]

export default function MenuPage() {
  const [params] = useSearchParams()
  const qrToken  = params.get('t')

  const [table, setTable]         = useState(null)
  const [tableError, setTableError] = useState(false)
  const [allMenus, setAllMenus]   = useState([])
  const [category, setCategory]   = useState('semua')
  const [cart, setCart]           = useState({})        // { menu_id: { menu, qty } }
  const [phase, setPhase]         = useState('menu')    // menu | checkout | confirmed
  const [orderNumber, setOrderNumber] = useState('')
  const [form, setForm]           = useState({ customer_name: '', customer_phone: '', notes: '' })
  const [submitting, setSubmitting] = useState(false)
  const [settings, setSettings]   = useState({})

  const pub = PublicRestoRepository()

  // Load meja dari QR token
  useEffect(() => {
    if (!qrToken) { setTableError(true); return }
    pub.getTableByQrToken(qrToken)
      .then(setTable)
      .catch(() => setTableError(true))
  }, [qrToken])

  // Load menu & settings
  useEffect(() => {
    pub.getMenus().then(setAllMenus).catch(() => {})
    pub.getSiteSettings().then(d => setSettings(d ?? {})).catch(() => {})
  }, [])

  // Filter menu berdasarkan kategori
  const visibleMenus = category === 'semua'
    ? allMenus
    : allMenus.filter(m => m.category === category)

  // Cart operations
  const addToCart = (menu) => {
    setCart(c => ({
      ...c,
      [menu.id]: { menu, qty: (c[menu.id]?.qty || 0) + 1 }
    }))
  }
  const removeFromCart = (menuId) => {
    setCart(c => {
      const next = { ...c }
      if (next[menuId]?.qty > 1) next[menuId] = { ...next[menuId], qty: next[menuId].qty - 1 }
      else delete next[menuId]
      return next
    })
  }

  const cartItems   = Object.values(cart)
  const cartTotal   = cartItems.reduce((s, { menu, qty }) => s + menu.selling_price * qty, 0)
  const cartCount   = cartItems.reduce((s, { qty }) => s + qty, 0)

  // Submit order
  const handleSubmit = async () => {
    setSubmitting(true)
    try {
      const result = await pub.submitSelfOrder({
        table_id:       table.table_id,
        customer_name:  form.customer_name || null,
        customer_phone: form.customer_phone || null,
        notes:          form.notes || null,
        items: cartItems.map(({ menu, qty }) => ({
          menu_id: menu.id,
          qty,
          notes: null,
        })),
      })
      setOrderNumber(result.order_number)
      setPhase('confirmed')
    } catch (e) {
      alert('Gagal mengirim pesanan, coba lagi.')
    } finally {
      setSubmitting(false)
    }
  }

  // ─── QR Invalid ───────────────────────────────────────
  if (tableError) return (
    <div className="min-h-screen bg-resto-bg flex flex-col items-center justify-center p-8 text-center">
      <div className="text-6xl mb-4">🔍</div>
      <h1 className="text-xl font-bold text-resto-text mb-2">QR Code Tidak Valid</h1>
      <p className="text-resto-muted">Pastikan Anda scan QR yang ada di meja restoran ini.</p>
    </div>
  )

  if (!table) return (
    <div className="min-h-screen bg-resto-bg flex items-center justify-center">
      <div className="text-resto-muted">Memuat...</div>
    </div>
  )

  // ─── Order Confirmed ───────────────────────────────────
  if (phase === 'confirmed') return (
    <div className="min-h-screen bg-resto-bg flex flex-col items-center justify-center p-8 text-center">
      <div className="text-7xl mb-4">✅</div>
      <h1 className="text-2xl font-bold text-resto-text mb-2">Pesanan Diterima!</h1>
      <p className="text-resto-muted mb-4">
        Nomor pesananmu: <strong className="text-resto-primary text-lg">#{orderNumber}</strong>
      </p>
      <div className="bg-white border border-resto-border rounded-2xl p-5 max-w-xs w-full text-left mb-6">
        <p className="text-sm font-semibold text-resto-text mb-3">Ringkasan Pesanan</p>
        {cartItems.map(({ menu, qty }) => (
          <div key={menu.id} className="flex justify-between text-sm py-1">
            <span className="text-resto-text">{qty}× {menu.name}</span>
            <span className="text-resto-muted">{formatRupiah(menu.selling_price * qty)}</span>
          </div>
        ))}
        <div className="border-t border-resto-border mt-2 pt-2 flex justify-between font-bold">
          <span>Total</span>
          <span className="text-resto-primary">{formatRupiah(cartTotal)}</span>
        </div>
      </div>
      <p className="text-sm text-resto-muted">
        {form.customer_phone
          ? 'Struk akan dikirim ke WhatsApp Anda setelah pembayaran.'
          : 'Silakan bayar ke kasir saat selesai makan.'}
      </p>
      <p className="text-xs text-resto-muted mt-2">Meja {table.table_number}</p>
    </div>
  )

  // ─── Checkout Form ─────────────────────────────────────
  if (phase === 'checkout') return (
    <div className="min-h-screen bg-resto-bg">
      <div className="sticky top-0 bg-white border-b border-resto-border px-4 py-3 flex items-center gap-3 z-10">
        <button onClick={() => setPhase('menu')} className="text-resto-muted">←</button>
        <h1 className="font-bold text-resto-text">Konfirmasi Pesanan</h1>
      </div>

      <div className="p-4 max-w-lg mx-auto space-y-4">
        {/* Ringkasan */}
        <div className="bg-white rounded-2xl border border-resto-border p-4">
          <p className="font-semibold text-sm text-resto-text mb-3">
            Pesanan — Meja {table.table_number}
          </p>
          {cartItems.map(({ menu, qty }) => (
            <div key={menu.id} className="flex items-center justify-between py-2 border-b border-resto-border/50 last:border-0">
              <div className="flex items-center gap-3">
                {menu.image_url
                  ? <img src={toAbsUrl(menu.image_url)} className="w-10 h-10 rounded-lg object-cover" alt="" />
                  : <div className="w-10 h-10 bg-resto-bg rounded-lg flex items-center justify-center text-lg">🍽️</div>
                }
                <div>
                  <p className="text-sm font-medium text-resto-text">{menu.name}</p>
                  <p className="text-xs text-resto-muted">{formatRupiah(menu.selling_price)} × {qty}</p>
                </div>
              </div>
              <p className="text-sm font-semibold text-resto-text">
                {formatRupiah(menu.selling_price * qty)}
              </p>
            </div>
          ))}
          <div className="flex justify-between font-bold pt-3 text-resto-primary">
            <span>Total</span>
            <span>{formatRupiah(cartTotal)}</span>
          </div>
        </div>

        {/* Form customer (opsional) */}
        <div className="bg-white rounded-2xl border border-resto-border p-4 space-y-3">
          <p className="font-semibold text-sm text-resto-text">
            Info Pemesan <span className="text-resto-muted font-normal">(opsional — untuk struk WA)</span>
          </p>
          <input
            type="text" placeholder="Nama kamu"
            className="w-full border border-resto-border rounded-xl px-4 py-3 text-sm focus:outline-none focus:border-resto-primary"
            value={form.customer_name}
            onChange={e => setForm(f => ({ ...f, customer_name: e.target.value }))}
          />
          <input
            type="tel" placeholder="Nomor WhatsApp (628xxx)"
            className="w-full border border-resto-border rounded-xl px-4 py-3 text-sm focus:outline-none focus:border-resto-primary"
            value={form.customer_phone}
            onChange={e => setForm(f => ({ ...f, customer_phone: e.target.value }))}
          />
          <textarea
            placeholder="Catatan khusus (misal: tidak pakai bawang)"
            rows={2}
            className="w-full border border-resto-border rounded-xl px-4 py-3 text-sm focus:outline-none focus:border-resto-primary resize-none"
            value={form.notes}
            onChange={e => setForm(f => ({ ...f, notes: e.target.value }))}
          />
        </div>

        <button
          onClick={handleSubmit}
          disabled={submitting}
          className="w-full bg-resto-primary text-white py-4 rounded-2xl font-bold text-base hover:bg-resto-accent transition disabled:opacity-60"
        >
          {submitting ? 'Mengirim...' : `Kirim Pesanan • ${formatRupiah(cartTotal)}`}
        </button>

        <p className="text-xs text-center text-resto-muted">
          Pembayaran dilakukan ke kasir setelah selesai makan.
        </p>
      </div>
    </div>
  )

  // ─── Menu Page (utama) ─────────────────────────────────
  return (
    <div className="min-h-screen bg-resto-bg">
      {/* Header */}
      <div className="sticky top-0 bg-white border-b border-resto-border z-20">
        <div className="px-4 py-3">
          <h1 className="font-bold text-lg text-resto-text">
            {settings.restaurant_name || 'Menu Kami'}
          </h1>
          <p className="text-xs text-resto-muted">Meja {table.table_number}</p>
        </div>
        {/* Category Tabs — horizontal scroll */}
        <div className="flex gap-2 px-4 pb-3 overflow-x-auto scrollbar-hide">
          {CATEGORIES.map(cat => (
            <button
              key={cat.key}
              onClick={() => setCategory(cat.key)}
              className={`flex-shrink-0 px-4 py-1.5 rounded-full text-sm font-medium transition whitespace-nowrap
                ${category === cat.key
                  ? 'bg-resto-primary text-white'
                  : 'bg-resto-bg text-resto-muted border border-resto-border hover:border-resto-primary'
                }`}
            >
              {cat.label}
            </button>
          ))}
        </div>
      </div>

      {/* Menu Grid */}
      <div className="p-4 pb-32 max-w-2xl mx-auto">
        {visibleMenus.length === 0 ? (
          <div className="text-center py-16 text-resto-muted">Tidak ada menu di kategori ini.</div>
        ) : (
          <div className="grid grid-cols-2 gap-3">
            {visibleMenus.map(menu => {
              const qty = cart[menu.id]?.qty || 0
              return (
                <div key={menu.id} className={`bg-white rounded-2xl overflow-hidden border border-resto-border shadow-sm
                  ${!menu.is_available ? 'opacity-60' : ''}`}>
                  {/* Gambar */}
                  {menu.image_url ? (
                    <img src={toAbsUrl(menu.image_url)} alt={menu.name}
                      className="w-full h-32 object-cover" />
                  ) : (
                    <div className="w-full h-32 bg-resto-primary/10 flex items-center justify-center text-4xl">
                      {menu.category === 'minuman' ? '🥤' : '🍽️'}
                    </div>
                  )}
                  <div className="p-3">
                    <p className="font-semibold text-sm text-resto-text line-clamp-2 leading-snug">{menu.name}</p>
                    {menu.description && (
                      <p className="text-xs text-resto-muted mt-1 line-clamp-2">{menu.description}</p>
                    )}
                    <p className="text-resto-primary font-bold text-sm mt-1.5">{formatRupiah(menu.selling_price)}</p>

                    {/* Tombol add/remove */}
                    {menu.is_available ? (
                      qty === 0 ? (
                        <button
                          onClick={() => addToCart(menu)}
                          className="w-full mt-2 bg-resto-primary text-white py-1.5 rounded-xl text-sm font-medium hover:bg-resto-accent transition"
                        >
                          + Tambah
                        </button>
                      ) : (
                        <div className="flex items-center justify-between mt-2 bg-resto-bg rounded-xl px-2 py-1">
                          <button onClick={() => removeFromCart(menu.id)}
                            className="w-8 h-8 flex items-center justify-center text-resto-primary font-bold text-lg">−</button>
                          <span className="font-bold text-resto-text text-sm">{qty}</span>
                          <button onClick={() => addToCart(menu)}
                            className="w-8 h-8 flex items-center justify-center text-white bg-resto-primary rounded-lg font-bold">+</button>
                        </div>
                      )
                    ) : (
                      <p className="text-xs text-center text-gray-400 mt-2 bg-gray-50 rounded-xl py-1.5">Habis</p>
                    )}
                  </div>
                </div>
              )
            })}
          </div>
        )}
      </div>

      {/* Floating Cart Button */}
      {cartCount > 0 && (
        <div className="fixed bottom-0 left-0 right-0 p-4 bg-white border-t border-resto-border z-30">
          <button
            onClick={() => setPhase('checkout')}
            className="w-full max-w-lg mx-auto flex items-center justify-between bg-resto-primary text-white px-6 py-4 rounded-2xl font-bold text-base hover:bg-resto-accent transition"
          >
            <span className="bg-white text-resto-primary text-sm font-bold w-7 h-7 rounded-full flex items-center justify-center">
              {cartCount}
            </span>
            <span>Lihat Pesanan</span>
            <span>{formatRupiah(cartTotal)}</span>
          </button>
        </div>
      )}
    </div>
  )
}
```

---

## Halaman 3: CMS Admin — Kelola Konten Restoran

### Halaman yang Perlu Dibuat

```
/admin/cms                → tab nav: Banner | Promo | Pengaturan
/admin/menus              → CRUD menu + upload gambar + sort order
/admin/tables             → CRUD meja + generate QR per meja
```

### CMS Tab Nav

```jsx
// src/presentation/pages/admin/cms/CmsTabNav.jsx
const TABS = [
  { key: 'banner',     label: 'Banner',      path: '/admin/cms/banner' },
  { key: 'promo',      label: 'Promo',        path: '/admin/cms/promo' },
  { key: 'pengaturan', label: 'Pengaturan',   path: '/admin/cms/pengaturan' },
]
```

### BannerPage.jsx — Pola dari Fast-Klinik

```jsx
// src/presentation/pages/admin/cms/BannerPage.jsx
// Pola IDENTIK dengan fast-klinik BannerPage, hanya ganti:
// - CMSRepository() → RestoCMSRepository()
// - token 'clinic-*' → 'resto-*'
// - ImageUploadField imageType="banner"
// Fitur: drag-and-drop sequence, toggle aktif, date range, preview
```

### PromotionPage.jsx — Sama Persis

Sama dengan `BannerPage` tapi endpoint promotions dan field tambahan `discount_label`.

### SiteSettingsPage.jsx — Konfigurasi Restoran

```jsx
// Form per key — sama persis pola fast-klinik
// Keys yang ditampilkan: semua keys dari tabel cms_site_settings
// maps_embed_url: tambahkan preview iframe setelah save (sama persis pola klinik)
```

### MenuAdminPage.jsx — CRUD Menu + Gambar

```jsx
// Tambahan dari existing menu management:
// - ImageUploadField imageType="menu"
// - Input sort_order (angka)
// - Textarea description
// - Toggle is_available (sold-out tanpa hapus)
// - Toggle is_active (soft delete)
// - Preview gambar menggunakan toAbsUrl()
```

### TableAdminPage.jsx — Kelola Meja & QR

```jsx
// src/presentation/pages/admin/tables/TableAdminPage.jsx

// Fitur:
// - Tabel daftar meja (table_number, capacity, is_active, qr_token)
// - Tambah meja baru (auto-generate qr_token di backend)
// - Tombol "Download QR" → GET /admin/tables/{id}/qr → download PNG
// - Toggle aktif/nonaktif meja
// - Preview URL QR: https://domain.com/menu?t={qr_token}

// Contoh render QR link:
const qrUrl = `${window.location.origin}/menu?t=${table.qr_token}`
// Tampilkan sebagai link yang bisa diklik untuk test
// Backend generate QR image via library: qrcode (Python)
```

**Backend — Generate QR Image:**
```python
# utils/qr_generator.py
import qrcode
import io

def generate_qr_png(url: str) -> bytes:
    qr = qrcode.QRCode(version=1, box_size=10, border=4)
    qr.add_data(url)
    qr.make(fit=True)
    img = qr.make_image(fill_color="#2C1A0E", back_color="white")
    buf = io.BytesIO()
    img.save(buf, format='PNG')
    return buf.getvalue()

# Di endpoint:
@router.get("/admin/tables/{table_id}/qr")
async def get_table_qr(table_id: UUID, request: Request, db: Session = Depends(get_db)):
    table = db.query(Table).filter_by(id=table_id).first()
    qr_url = f"{settings.FRONTEND_URL}/menu?t={table.qr_token}"
    png_bytes = generate_qr_png(qr_url)
    return Response(content=png_bytes, media_type="image/png",
        headers={"Content-Disposition": f"attachment; filename=meja-{table.table_number}.png"})
```

---

## Dashboard Kasir — Notif Order Masuk (Self-Order)

Kasir perlu tahu real-time saat order baru masuk dari QR customer.

```jsx
// src/presentation/pages/admin/orders/OrderDashboard.jsx
// Polling setiap 5 detik untuk order dengan status 'open' dan order_source='self_order'

const [selfOrders, setSelfOrders] = useState([])
const hasPending = selfOrders.some(o => o.status === 'open')

useEffect(() => {
  const fetch = () =>
    AdminRepository().getSelfOrders({ status: 'open' }).then(setSelfOrders).catch(() => {})
  fetch() // initial
  const id = setInterval(fetch, 5000)  // polling 5 detik
  return () => clearInterval(id)
}, [])

// Tampilkan badge merah di nav sidebar saat ada self-order pending
// Badge: jumlah order open yang order_source = 'self_order'
```

---

## Seed Data CMS (init.sql)

```sql
-- Seed cms_site_settings (default kosong, owner isi via UI)
INSERT INTO cms_site_settings (restaurant_id, key, value)
SELECT r.id, k.key, k.value
FROM restaurants r,
(VALUES
    ('restaurant_name', 'Warung Makan'),
    ('tagline',         'Masakan Rumahan yang Bikin Rindu'),
    ('hero_title',      'Selamat Datang!'),
    ('hero_subtitle',   'Pesan dari meja — scan QR, pilih menu, tunggu sebentar.'),
    ('opening_hours',   '08.00 – 21.00 WIB'),
    ('whatsapp_number', ''),
    ('address',         ''),
    ('maps_embed_url',  ''),
    ('instagram_url',   ''),
    ('footer_text',     '© 2026 Warung Makan')
) AS k(key, value)
LIMIT 1;  -- hanya untuk 1 restoran pertama

-- Seed wa_message_templates (untuk nota WA)
INSERT INTO wa_message_templates (code, title, body) VALUES
('ORDER_RECEIPT',
 'Struk Pesanan',
 'Halo {{customer_name}}! 👋

Terima kasih sudah makan di {{restaurant_name}}.

Struk Pesanan #{{order_number}}
Meja: {{table_number}} | {{datetime}}

{{items_list}}
─────────────────
Total: {{total}}
Bayar: {{payment_method}}

Selamat menikmati! 🍽️'),

('ORDER_CONFIRM',
 'Konfirmasi Pesanan Diterima',
 'Halo {{customer_name}}! 👋

Pesanan kamu di Meja {{table_number}} sudah kami terima.
Nomor pesanan: #{{order_number}}

Makanan sedang disiapkan ya! ⏰

Pembayaran dilakukan ke kasir setelah selesai makan.

{{restaurant_name}}');
```

---

## Nginx & CSP — Setting Tambahan

```nginx
# nginx.conf — tambahkan untuk Google Maps + gambar upload
add_header Content-Security-Policy "
  default-src 'self';
  frame-src 'self' https://www.google.com https://maps.google.com https://maps.googleapis.com;
  img-src 'self' data: blob: https://*.gstatic.com https://maps.googleapis.com https://maps.gstatic.com;
  script-src 'self' 'unsafe-inline';
  style-src 'self' 'unsafe-inline';
" always;

# Serve upload files langsung dari nginx (tidak lewat FastAPI)
location /uploads/ {
    alias /app/uploads/;
    expires 7d;
    add_header Cache-Control "public, immutable";
}
```

---

## Upload Gambar — Pola dari Fast-Klinik

Backend auto-resize + compress, persis sama dengan klinik:

| `image_type` | Max Resolusi | JPEG Quality |
|---|---|---|
| `banner` | 1920 × 640 px | 82% |
| `promo` | 1200 × 900 px | 85% |
| `menu` | 800 × 800 px | 85% |

```python
# POST /api/v1/cms/upload/image?image_type=menu
# Response: { "data": { "url": "/uploads/menus/abc123.jpg" } }
# Backend: Pillow auto-resize + compress, output JPEG
# Max upload: 5 MB per file
# Format diterima: JPEG, PNG, WebP
```

Komponen frontend — sama persis dari Fast-Klinik:
```jsx
<ImageUploadField
  imageType="menu"
  label="Foto Menu"
  value={form.image_url}
  onChange={url => setForm(f => ({ ...f, image_url: url }))}
  aspectClass="aspect-square"
/>
```

---

## Checklist Implementasi

### DB & Backend
```
□ Tambah kolom ke menus: description, image_url, sort_order
□ CREATE TABLE cms_site_settings
□ CREATE TABLE cms_banners
□ CREATE TABLE cms_promotions
□ CREATE TABLE tables (dengan qr_token UNIQUE)
□ Seed cms_site_settings dengan default keys
□ Seed wa_message_templates: ORDER_RECEIPT + ORDER_CONFIRM
□ Endpoint publik: site-settings, banners, promotions, menus, tables/{qr_token}
□ Endpoint CMS admin: CRUD banner + promo + site-settings
□ Endpoint POST /public/orders/self-order (tanpa auth)
□ Endpoint GET /admin/tables/{id}/qr → PNG QR code (via qrcode library)
□ Upload endpoint: POST /cms/upload/image?image_type= (Pillow auto-resize)
□ maps_embed_url: backend simpan as-is, frontend yang parse src= nya
```

### Landing Page (`/`)
```
□ Warna token resto-* di tailwind.config.js
□ PublicRestoRepository dengan semua method
□ Helper toAbsUrl() dan formatRupiah() di format.js
□ LandingPage.jsx — semua section render hanya jika ada data
□ Banner auto-slide 5 detik + dots indicator
□ Fallback semua section (graceful degradation jika CMS belum diisi)
□ maps_embed_url: parse src dari <iframe> tag secara otomatis
□ Floating WhatsApp button (hanya jika whatsapp_number ada)
□ Navbar sticky, responsive, link anchor ke section (#menu, #promo, #lokasi)
□ CSP nginx sudah include frame-src Google Maps
```

### QR Self-Order (`/menu?t=`)
```
□ Route /menu dengan useSearchParams() untuk baca ?t=
□ Loading + error state untuk QR invalid (token tidak dikenal)
□ Category tabs: horizontal scroll, mobile-friendly
□ Menu grid: 2 kolom, gambar + nama + harga + add/remove button
□ is_available=false → tampilkan "Habis" (disabled, tidak bisa ditambah)
□ Cart: state per menu_id, qty counter, total terakumulasi
□ Floating cart button: hanya muncul saat cartCount > 0
□ Checkout form: nama + HP opsional + notes
□ POST /public/orders/self-order → tampilkan order confirmed screen
□ Order confirmed: tampilkan nomor order, ringkasan, info pembayaran ke kasir
□ Mobile-first: touch target minimal 44px, tidak ada hover-only interaction
```

### CMS Admin (`/admin/cms`)
```
□ Tab nav: Banner | Promo | Pengaturan
□ BannerPage: CRUD + ImageUploadField + toggle aktif + sequence/drag
□ PromotionPage: CRUD + discount_label + date range picker
□ SiteSettingsPage: form per key + maps preview iframe
□ MenuAdminPage: tambah field description, image_url, sort_order ke form existing
□ TableAdminPage: CRUD + tombol Download QR per meja
□ QR preview link: tampilkan URL `/menu?t={qr_token}` sebagai link test
□ toAbsUrl() untuk semua preview gambar
```

### Kasir Dashboard
```
□ Polling 5 detik untuk self-order dengan status='open'
□ Badge notif di sidebar saat ada order masuk dari customer
□ Tampilkan nama meja + daftar item untuk kasir review
□ Kasir bisa tambah/hapus item sebelum proses bayar
□ Setelah complete_order() → NotificationService kirim nota WA (jika ada phone)
```

### Deployment
```
□ VITE_API_BASE_URL di .env frontend
□ FRONTEND_URL di .env backend (untuk generate QR URL yang benar)
□ /uploads/ route di nginx (tidak lewat FastAPI)
□ pip install qrcode pillow (backend)
□ Test QR: scan dari HP berbeda → halaman menu muncul dengan nama meja benar
□ Test callback WA (dari container gateway) sebelum production
```
