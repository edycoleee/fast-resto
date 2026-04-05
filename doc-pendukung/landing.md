# Prompt: Landing Page & CMS Klinik (Best Practice — Codebase fast-klinik)

Dokumen ini adalah panduan lengkap implementasi **Landing Page dinamis** dan **CMS Admin**
di codebase `fast-klinik`. Semua pola di sini sudah diverifikasi dari implementasi nyata.
Gunakan sebagai referensi wajib saat mengerjakan fitur landing page dan CMS.

---

## Stack & Konvensi Wajib

| Item | Nilai |
|------|-------|
| Framework | React + Vite (JS bukan TS) |
| CSS | Tailwind CSS — gunakan custom token `clinic-*` (lihat di bawah) |
| Path alias | `@/` → `src/` (dikonfigurasi di `vite.config.js`) |
| Router | `react-router-dom` v7 — pakai `<Link>` dan `ROUTES` constants |
| State fetch | hook `useFetch` dari `@/domain/hooks` — JANGAN pakai `axios` langsung |
| Repository | Factory functions dari `@/data/repositories` — JANGAN buat `fetch()` inline |
| Auth context | `useAuth()` dari `@/domain/contexts/AuthContext` |
| Notif | `useNotif()` dari `@/presentation/components/layout` |
| Common UI | `Button`, `Input`, `Loading`, `Modal`, `ImageUploadField` dari `@/presentation/components/common` |
| Format tanggal | `formatDate`, `formatDateTime` dari `@/presentation/utils/format` — selalu WIB (Asia/Jakarta) |

### Tailwind Color Tokens (tailwind.config.js)

```js
clinic: {
  primary:   '#2FB8B2',   // warna utama teal
  secondary: '#6EDBD2',   // teal muda
  accent:    '#1F8E88',   // teal gelap (hero background)
  bg:        '#F4FBFB',   // background putih kehijauan
  text:      '#2C3E50',   // teks utama
}
```

Contoh pakai: `bg-clinic-bg`, `text-clinic-primary`, `border-clinic-secondary/40`

---

## Arsitektur: Public vs Patient

Ada **dua jalur booking** — pahami bedanya:

| Jalur | URL | Auth | Endpoint |
|-------|-----|------|----------|
| Booking publik (tamu) | `/booking` | Tidak perlu | `POST /api/v1/appointment-requests` |
| Booking pasien terdaftar | `/patient/booking` | OTP / JWT | `POST /api/v1/appointments/patient-book` |

Landing page (`/`) menggunakan `PublicLayout` dan mengarahkan tamu ke `/booking`.
Pasien yang sudah login diarahkan ke `/patient/booking` via `ROUTES.PATIENT_BOOKING`.

---

## PublicRepository — Sumber Data Landing Page

Semua data landing page diambil tanpa auth via `PublicRepository()`:

```js
import { PublicRepository } from '@/data/repositories'
const pub = PublicRepository()

// Semua method yang tersedia:
pub.getSiteSettings(clinicId)         // → { key: value, ... }
pub.getBanners(clinicId)              // → BannerResponse[]
pub.getPromotions(clinicId)           // → PromotionResponse[]
pub.getTestimonials(clinicId, limit)  // → TestimonialResponse[] (featured first)
pub.getBeforeAfters(clinicId)         // → BeforeAfterResponse[]
pub.getServices(clinicId, limit)      // → ServiceResponse[] — limit max 50 (backend le=100)
pub.getPractitioners(clinicId)        // → PractitionerResponse[]
```

**PENTING limit services:** Jangan melebihi `50` saat memanggil `getServices` — backend
memvalidasi `le=100` tapi default aman adalah `50`. Jika `limit` terlalu besar, backend
akan 422 dan `.catch(() => {})` di landing page tanpa error visible (graceful degradation
= section tidak tampil sama sekali).

```js
// BENAR — selalu explicit limit
pub.getServices(null, 50)

// SALAH — limit 60 akan 422 jika backend le < 60
pub.getServices(null, 60)
```

### Filter service_type di landing page

```js
// Hanya tampilkan treatment (punya harga) di section layanan landing page
// Jangan tampilkan 'session' — itu untuk slot booking bukan display publik
pub.getServices(clinicId, 50)
// Backend sudah support filter: GET /public/services?service_type=treatment
```

---

## CMS-Driven Site Settings

Konten teks landing page dikontrol melalui `site_settings` di DB, bukan hardcode.
Ambil dengan `pub.getSiteSettings()` → object `{ key: value }`.

Keys yang sudah terdefinisi di `SiteSettingsPage.jsx`:

```js
// Kontak & Lokasi
whatsapp_number   // → link wa.me/
address           // → teks alamat
opening_hours     // → teks jam buka
maps_embed_url    // → src iframe Google Maps (user bisa paste full <iframe> — otomatis di-strip)
instagram_url
tiktok_url

// Hero
hero_tagline      // → teks di atas headline hero

// Trust Bar
stats_doctors     // contoh: '20+'
stats_patients    // contoh: '5.000+'
stats_years       // contoh: '8'
stats_treatments  // contoh: '50+'

// Section titles
services_title / services_subtitle
promos_title / promos_subtitle
ba_title / ba_subtitle
doctors_title / doctors_subtitle
testimonials_title / testimonials_subtitle
location_title

// CTA
cta_title
cta_subtitle
```

Pattern penggunaan di `LandingPage.jsx`:

```jsx
const s = settings  // dari pub.getSiteSettings()
const waNumber = s.whatsapp_number || '62812345678'
const waLink = `https://wa.me/${waNumber}`

// Selalu sediakan fallback hardcode untuk UX saat belum ada data di DB
const ctaTitle = s.cta_title || 'Siap Merawat Kecantikan Anda?'
```

### Parser maps_embed_url (WAJIB)

User sering paste full `<iframe>` tag dari Google Maps — frontend HARUS strip ke `src` saja,
jangan render raw string karena iframe tidak akan muncul:

```js
const rawMapsEmbed = s.maps_embed_url || ''
const mapsEmbed = (() => {
  if (!rawMapsEmbed) return ''
  const m = rawMapsEmbed.match(/src=["']([^"']+)["']/)
  return m ? m[1] : rawMapsEmbed  // fallback: anggap sudah berupa URL
})()

// Render
{mapsEmbed && (
  <iframe src={mapsEmbed} className="w-full h-72 rounded-xl border-0" allowFullScreen loading="lazy" />
)}
```

### CSP Nginx untuk Google Maps iframe

Pastikan `deploy/nginx-klinik.conf` sudah include `frame-src` dan `img-src`:

```nginx
add_header Content-Security-Policy "
  default-src 'self';
  frame-src 'self' https://www.google.com https://maps.google.com https://maps.googleapis.com;
  img-src 'self' data: blob: https://*.gstatic.com https://maps.googleapis.com https://maps.gstatic.com;
  ...
" always;
```

Tanpa `frame-src`, browser memblokir iframe Google Maps secara diam-diam (CSP fallback
ke `default-src 'self'`) → peta tidak muncul meskipun URL benar.

---

## Pola Fetch Data di LandingPage

LandingPage menggunakan `useEffect` biasa (bukan `useFetch`) karena semua data di-fetch
paralel saat mount dan masing-masing punya state sendiri:

```jsx
const [banners, setBanners]       = useState([])
const [settings, setSettings]     = useState({})
const [services, setServices]     = useState([])
// ... dst

useEffect(() => {
  const pub = PublicRepository()
  pub.getBanners().then(setBanners).catch(() => {})
  pub.getPromotions().then(setPromos).catch(() => {})
  pub.getServices(null, 50).then(setServices).catch(() => {})
  pub.getSiteSettings().then(s => setSettings(s ?? {})).catch(() => {})
  // ... semua paralel, error diabaikan (graceful degradation)
}, [])
```

Pola render section — **hanya tampil jika ada data**:

```jsx
{services.length > 0 && (
  <section id="layanan">
    {/* ... */}
  </section>
)}
```

Halaman admin yang membaca satu endpoint lebih baik pakai `useFetch`:

```jsx
const fetchFn = useMemo(
  () => () => CMSRepository().getSiteSettings({ clinic_id: user?.clinic_id }),
  [user?.clinic_id]
)
const { data, loading, refetch } = useFetch(fetchFn)
```

---

## Carousel Before/After — Bug Duplikasi (PENTING)

Circular wrap carousel harus punya guard `items.length > 3`, jika tidak item akan
duplikat ketika jumlah item kecil:

```jsx
// BENAR — circular wrap hanya jika data cukup
const visibleItems = beforeAfters.length > 3
  ? beforeAfters.slice(baIdx, baIdx + 3).concat(
      beforeAfters.slice(0, Math.max(0, baIdx + 3 - beforeAfters.length))
    )
  : beforeAfters

// SALAH — tanpa guard, 1 item → tampil 2x, 2 item → tampil 3x
```

Tombol navigasi (prev/next) juga hanya tampil jika `beforeAfters.length > 3`.

---

## Struktur Section Landing Page

Urutan section di `LandingPage.jsx`:

```
PublicLayout (Navbar sticky + Outlet + Footer)
  └─ LandingPage.jsx
        1. Hero         → banner CMS + auto-rotate 5s + slide indicator dots
        2. Trust Bar    → stats_* dari site_settings, fallback 4 angka default
        3. Layanan      → pub.getServices(null, 50) — treatment only, hanya jika ada data
        4. Promo        → pub.getPromotions() — badge diskon, expired dimmed
        5. Before/After → pub.getBeforeAfters() — carousel 3-item, touch swipe, guard duplikat
        6. Dokter       → pub.getPractitioners() — foto atau inisial fallback
        7. Testimoni    → pub.getTestimonials() — Stars, featured first
        8. CTA          → gradient accent→primary, WA + booking button
        9. Lokasi       → Google Maps iframe (src dari maps_embed_url) + kontak + sosmed
       10. Footer       → PublicLayout
   (floating) WhatsApp button kanan bawah
```

### Navbar — route khusus halaman non-landing

Halaman seperti `/queue` menggunakan `PublicLayout` yang sama tapi tidak perlu nav anchor
(`#layanan`, `#promo`, dll.) karena section tidak ada di halaman tersebut:

```jsx
// PublicLayout.jsx — sembunyikan nav links di non-landing pages
import { useLocation } from 'react-router-dom'
const { pathname } = useLocation()
const isLanding = pathname === '/'
// nav links hanya render jika isLanding
```

### Route yang terlibat (ROUTES constants)

```js
ROUTES.HOME              // '/'       → LandingPage
ROUTES.BOOKING_PUBLIC    // '/booking' → BookingEntryPage (tamu tanpa login)
ROUTES.LOGIN             // '/login'
ROUTES.PATIENT_DASHBOARD // '/patient' → setelah OTP login
```

---

## BookingEntryPage.jsx (Tamu — Tanpa Auth)

Form sederhana untuk tamu. Mengirim ke `BookingRequestRepository().submit()`:

```js
// POST /api/v1/appointment-requests
{
  req_name, req_phone, req_service,
  req_date_pref, req_notes
}
```

Setelah submit: tampilkan pesan sukses, staf konfirmasi via WhatsApp.

---

## Backend Public Endpoints

Semua endpoint di `backend/api/v1/endpoints/public.py`, **tanpa autentikasi**:

```
GET  /api/v1/public/site-settings   ?clinic_id=
GET  /api/v1/public/banners         ?clinic_id=
GET  /api/v1/public/promotions      ?clinic_id=
GET  /api/v1/public/testimonials    ?clinic_id= &limit=9
GET  /api/v1/public/before-afters   ?clinic_id=
GET  /api/v1/public/services        ?clinic_id= &service_type= &limit=50
GET  /api/v1/public/practitioners   ?clinic_id=
GET  /api/v1/public/slots           ?service_id= &date= &clinic_id=
```

Pola response semua endpoint:

```json
{
  "success": true,
  "message": "...",
  "data": { "items": [...], "total": N }
}
```

`getSiteSettings` berbeda — mengembalikan `data = { key: value, ... }` (flat object).

---

## service_type — Aturan Tampilan

| service_type | Tampil di | Field penting |
|--------------|-----------|---------------|
| `session`    | BookingPage (pasien) — slot picker | `duration_minutes` |
| `treatment`  | Landing page (layanan publik), InvoicePage (item) | `price` |

Di landing page section Layanan: tampilkan `treatment` saja (punya harga).
Jangan tampilkan `session` kecuali ada tombol "Lihat Jadwal" → arahkan ke booking.

---

## Slot Engine (Booking Pasien Terdaftar)

Endpoint `/public/slots` memanggil `SlotEngine.get_slots_with_practitioners()`:

- Input: `clinic_id`, `service_id` (type=session), `date` (YYYY-MM-DD)
- Output: `[{ time, start_iso, end_iso, practitioner_id, practitioner_name }]`
- Jam operasional: 09:00–21:00, step 30 menit
- Conflict check: slot di-skip jika practitioner sudah ada appointment
- `clinic_id` di-resolve otomatis dari `service.clinic_id` jika tidak dikirim

Di frontend (`BookingPage.jsx`), slot ini ditampilkan sebagai grid waktu.
Auto-assign bed: `practitioner_id = slot.beds[0].practitioner_id`

### Timezone Booking — WAJIB +07:00

Saat admin memilih jam konfirmasi appointment, payload HARUS menyertakan offset WIB:

```js
// BookingRequestsPage.jsx — saat admin konfirmasi dan set jadwal
const appointmentStart = `${apptDate}T${apptTime}:00+07:00`  // ← WAJIB offset

// SALAH — tanpa offset, PostgreSQL TIMESTAMPTZ anggap UTC
// → jam 11:00 disimpan UTC → saat render +7 jam = 18:00 WIB Yang Salah
const appointmentStart = `${apptDate}T${apptTime}:00`  // ← JANGAN
```

---

## Upload & Pengelolaan Gambar CMS

### Endpoint Upload

```
POST /api/v1/cms/upload/{image_type}
```

- Memerlukan JWT + permission `manage_landing_page`
- `image_type` valid: `banner`, `promo`, `testimonial`, `before_after`, `avatar`
- Response: `{ "data": { "url": "/uploads/banners/abc123.jpg" } }`

### Pemrosesan Otomatis di Backend (`backend/utils/image_processor.py`)

Backend **otomatis resize, compress, dan convert ke JPEG** setiap gambar yang diupload:

| image_type | Max resolusi | JPEG quality |
|------------|-------------|--------------|
| `banner` | 1920 × 640 px | 82% |
| `promo` | 1200 × 1200 px | 85% |
| `testimonial` | 800 × 800 px | 85% |
| `before_after` | 1280 × 960 px | 80% |
| `avatar` | 800 × 800 px | 85% |

- Preserves aspect ratio (`thumbnail()` = hanya downscale, tidak upscale)
- Konversi mode: RGBA/palette → RGB sebelum save
- Output selalu JPEG (bukan PNG/WebP) untuk konsistensi
- Max upload: **10 MB** per file
- Format input diterima: JPEG, PNG, WebP, GIF

### Hapus Gambar Lama (`delete_image`)

Saat update record CMS dengan gambar baru, hapus gambar lama dari disk:

```python
# backend/utils/image_processor.py
from utils.image_processor import delete_image

# Sebelum save URL baru, hapus file lama
delete_image(old_record.image_url)  # best-effort, tidak raise error
new_url = save_image(file_bytes, image_type)
```

### Komponen Frontend — `ImageUploadField`

```jsx
import { ImageUploadField } from '@/presentation/components/common'

// Props:
// imageType   – "banner" | "promo" | "testimonial" | "before_after" | "avatar"
// label       – label field
// value       – URL saat ini (dari form state)
// onChange    – callback(newUrl: string)
// aspectClass – Tailwind aspect ratio (default: "aspect-video")

<ImageUploadField
  imageType="banner"
  label="Gambar Banner"
  value={form.image_url}
  onChange={url => setForm(f => ({ ...f, image_url: url }))}
  aspectClass="aspect-[3/1]"
/>
```

Komponen ini sudah handle:
- Upload ke `POST /api/v1/cms/upload/{imageType}` via `apiClient`
- Preview setelah upload
- Loading state saat mengupload
- Reset input setelah berhasil (bisa re-upload file sama)
- Size hint per tipe (tampil di bawah tombol)

### Membaca URL Gambar di Frontend (WAJIB `toAbsUrl`)

Backend mengembalikan path relatif: `/uploads/banners/abc123.jpg`.
Gunakan helper `toAbsUrl` untuk konversi ke URL absolut:

```js
// Pattern ini sudah ada di ImageUploadField — gunakan pola yang sama
function toAbsUrl(urlPath) {
  if (!urlPath) return null
  if (urlPath.startsWith('http')) return urlPath
  const base = (import.meta.env.VITE_API_BASE_URL || 'http://localhost:8000/api/v1')
    .replace(/\/api\/v1\/?$/, '')
  return `${base}${urlPath}`
}

// Contoh di LandingPage / komponen manapun
<img src={toAbsUrl(banner.image_url)} alt={banner.title} />
```

**Jangan** hardcode base URL backend — selalu baca dari `import.meta.env.VITE_API_BASE_URL`.

---

## Format Tanggal & Waktu — Selalu WIB

Gunakan utility dari `@/presentation/utils/format`:

```js
import { formatDate, formatDateTime } from '@/presentation/utils/format'

formatDate('2026-04-03T07:00:00Z')     // → "3 Apr 2026"
formatDateTime('2026-04-03T07:00:00Z') // → "3 Apr 2026, 07.00"
```

Kedua fungsi ini sudah disetel `timeZone: 'Asia/Jakarta'` — aman di server/browser UTC.
**Jangan** pakai `toLocaleDateString()` / `toLocaleTimeString()` tanpa `timeZone` eksplisit.

---

## CMS Pages — Arsitektur Admin

File ada di `src/presentation/pages/cms/`:

| File | Konten |
|------|--------|
| `BannerPage.jsx` | CRUD banner — urutan, aktif/nonaktif, upload gambar |
| `PromotionPage.jsx` | CRUD promo — diskon, tanggal mulai/selesai |
| `TestimonialPage.jsx` | CRUD testimoni — approve, featured toggle |
| `BeforeAfterPage.jsx` | CRUD before/after — dua gambar (before + after) |
| `SiteSettingsPage.jsx` | Edit site settings per key — WAjib parse `maps_embed_url` |

Semua pakai tab nav `CmsTabNav` yang sama dan pola `useFetch + CMSRepository`.

### Backend CMS Endpoints (Perlu Auth + `manage_landing_page`)

```
POST /api/v1/cms/upload/{image_type}   — upload gambar

GET    /api/v1/cms/banners
POST   /api/v1/cms/banners
PUT    /api/v1/cms/banners/{id}
DELETE /api/v1/cms/banners/{id}        — soft-delete via is_active=False

GET    /api/v1/cms/promotions
POST   /api/v1/cms/promotions
PUT    /api/v1/cms/promotions/{id}
DELETE /api/v1/cms/promotions/{id}

GET    /api/v1/cms/testimonials
POST   /api/v1/cms/testimonials
PUT    /api/v1/cms/testimonials/{id}
DELETE /api/v1/cms/testimonials/{id}

GET    /api/v1/cms/before-afters
POST   /api/v1/cms/before-afters
PUT    /api/v1/cms/before-afters/{id}
DELETE /api/v1/cms/before-afters/{id}

GET    /api/v1/cms/site-settings
PUT    /api/v1/cms/site-settings/{key}
```

---

## Wireframe Visual

```
┌─────────────────────────────────────────────────────────┐
│ NAVBAR (sticky)                                         │
│  Logo │ [Layanan] [Promo] [Dokter] [Testimoni] [Lokasi] │
│       │                    [🔢 Antrian] [Booking] [Login]│
│       (nav links hidden di /queue dan halaman non-/)    │
├─────────────────────────────────────────────────────────┤
│  HERO   banner CMS (auto-slide 5s, indicator dots)      │
│         hero_tagline + H1 banner.title                  │
│         [Booking Sekarang] [WhatsApp] [Layanan ↓]       │
├─────────────────────────────────────────────────────────┤
│  TRUST BAR  👨‍⚕️ stats_doctors │ 😊 stats_patients        │
│             🏆 stats_years   │ 💆 stats_treatments      │
├─────────────────────────────────────────────────────────┤
│  LAYANAN   getServices(null, 50), type=treatment         │
│            card grid: nama + deskripsi + harga          │
│            [Booking Layanan →]                           │
├─────────────────────────────────────────────────────────┤
│  PROMO     card grid 3 kol, badge diskon, expired dimmed│
├─────────────────────────────────────────────────────────┤
│  BEFORE/AFTER  carousel 3-item, touch swipe             │
│                guard duplikat: wrap hanya jika >3 items │
├─────────────────────────────────────────────────────────┤
│  DOKTER    avatar grid — foto (toAbsUrl) / inisial      │
├─────────────────────────────────────────────────────────┤
│  TESTIMONI  grid 3 kol — Stars + rating + review_text   │
│             featured first, avatar inisial              │
├─────────────────────────────────────────────────────────┤
│  CTA   gradient clinic-accent→clinic-primary            │
│        cta_title / cta_subtitle dari settings           │
│        [Booking Sekarang] [Chat WhatsApp]               │
├─────────────────────────────────────────────────────────┤
│  LOKASI    info kiri + Google Maps iframe kanan         │
│            src dari maps_embed_url (strip <iframe> tag) │
│            alamat, jam, WA, Instagram, TikTok           │
├─────────────────────────────────────────────────────────┤
│  FOOTER   via PublicLayout                              │
└─────────────────────────────────────────────────────────┘
                  💬 floating WhatsApp kanan bawah
```

---

## Checklist Pengembangan Landing Page & CMS

### Landing Page
- [ ] Semua teks dari `site_settings` — tidak hardcode konten
- [ ] Section hanya render jika ada data (`{items.length > 0 && <section>...}`)
- [ ] Error fetch diabaikan dengan `.catch(() => {})` — graceful degradation
- [ ] Pakai `clinic-*` color token, bukan hex langsung
- [ ] `maps_embed_url` selalu di-parse untuk ekstrak `src` saja
- [ ] `PublicRepository` untuk semua fetch — tidak ada `axios.get` inline
- [ ] `Link` dari react-router-dom + `ROUTES` constants, tidak hardcode string URL
- [ ] `ROUTES.BOOKING_PUBLIC` untuk tamu — bukan `/patient/booking`
- [ ] Semua gambar melalui `toAbsUrl()` — tidak hardcode base URL
- [ ] Carousel before/after: guard `items.length > 3` sebelum circular wrap
- [ ] Section layanan: pakai `getServices(null, 50)` — tidak melebihi limit backend
- [ ] Format tanggal pakai `formatDate`/`formatDateTime` — tidak raw `toLocaleString`

### CMS / Upload Gambar
- [ ] Upload via `ImageUploadField` — endpoint `/api/v1/cms/upload/{imageType}`
- [ ] `imageType` sesuai: `banner`, `promo`, `testimonial`, `before_after`, `avatar`
- [ ] Hapus gambar lama (`delete_image`) sebelum simpan URL baru di backend
- [ ] Tidak perlu compress/resize di frontend — backend sudah handle via Pillow
- [ ] `maps_embed_url` di `SiteSettingsPage`: tampilkan preview iframe setelah save
- [ ] Permission `manage_landing_page` di semua route CMS admin

### Nginx / CSP
- [ ] `frame-src` include `https://www.google.com https://maps.google.com` di CSP
- [ ] `img-src` include `https://*.gstatic.com https://maps.googleapis.com`
- [ ] Route `/uploads/` di-serve nginx langsung (bukan lewat backend app)

### Timezone
- [ ] Semua datetime render via `formatDate`/`formatDateTime` (WIB enforced)
- [ ] Payload appointment dari frontend pakai `+07:00` suffix: `${date}T${time}:00+07:00`


# Spesifikasi Implementasi Landing Page CMS (Banner, Promo, Testimonial)

Dokumen ini berisi spesifikasi kebutuhan (*requirements*) untuk tim **Backend (FastAPI)** dan **Frontend (React JS + Vite)** dalam mengimplementasikan fitur Landing Page dinamis (*Content Management System* mini) di aplikasi Fast-Klinik.

Basis database untuk fitur ini (tabel `banners`, `promotions`, dan `testimonials`) telah ditambahkan ke dalam skema PostgreSQL utama (`init.sql`).

---

## 1. Spesifikasi Backend (FastAPI)

Tim Backend bertugas membuat RESTful API (CRUD) untuk masing-masing entitas CMS, serta menyediakan _endpoint_ khusus untuk akses publik (tanpa token).

### A. Endpoint Publik (Akses Pasien / Guest)
Endpoint ini **wajib bersifat publik (tanpa autentikasi JWT)** karena akan diakses bebas oleh siapa pun yang membuka halaman depan (`/`) website Fast-Klinik.

- `GET /api/v1/public/cms/banners`
  - **Logic**: Ambil data dari tabel `banners` di mana `is_active = TRUE` dan waktu saat ini (WIB) berada di antara `start_date` dan `end_date` (atau jika tanggal `null` dibolehkan tampil terus).
  - **Sort**: Urutkan berdasarkan kolom `sequence` (ASC).
- `GET /api/v1/public/cms/promotions`
  - **Logic**: Ambil dari tabel `promotions` di mana `is_active = TRUE` dan waktu saat ini berada dalam rentang `start_date` dan `end_date`.
  - **Sort**: Tampilkan promo terbaru (opsional, `created_at` DESC) atau yang mau habis masa berlakunya duluan (`end_date` ASC).
- `GET /api/v1/public/cms/testimonials`
  - **Logic**: Ambil dari tabel `testimonials` di mana `is_active = TRUE`. Tampilkan prioritas untuk yang `is_featured = TRUE` terlebih dahulu.
  - **Limit**: Idealnya dibatasi (misal: top 10 *reviews*) agar halaman depan tidak berat.

### B. Endpoint Dashboard Admin (Role `manage_landing_page`)
Endpoint ini akan diamankan dengan JWT (*Authentication*) dan cek *RBAC Permissions* (khusus user yang punya permission `manage_landing_page`, seperti `clinic_admin` / `marketing`).

Setiap CMS controller (Banners, Promotions, Testimonials) membutuhkan CRUD standar:
- `GET /api/v1/admin/cms/{entity}` (Dengan fitur Pagination, Search, Filter status `is_active`)
- `POST /api/v1/admin/cms/{entity}`
- `PUT /api/v1/admin/cms/{entity}/{id}`
- `DELETE /api/v1/admin/cms/{entity}/{id}` (Sebaiknya *Soft Delete*: ubah `is_active = FALSE`)

### C. File Upload (Penting!)
Tim backend juga harus menyediakan utilitas upload gambar untuk banner, promo, dan foto testimoni.
- Sediakan endpoint seperti `POST /api/v1/admin/upload/image`.
- Simpan file fisik di storage server/cloud (misal AWS S3 atau lokal folder `/static/uploads`).
- Return *path URL* penuh dari gambar tersebut, lalu simpan URL tersebut ke kolom `image_url` saat melakukan POST/PUT ke entitas CMS.

---

## 2. Spesifikasi Frontend (React JS + Vite)

Tim Frontend (Customer / Public Face) dan Tim Dashboard Internal akan bekerja di dua halaman yang terpisah.

### A. Halaman Publik (Landing Page Klinik)
Halaman ini adalah _homepage_ (`/`) dari website klinik.
Disarankan menggunakan komponen **Carousel** (misal: SwiperJS atau Slick) dan *Grid Layout* yang estetik.

1. **Section Hero (Banners)**
   - Panggil endpoint `GET /api/v1/public/cms/banners`.
   - Render sebagai *slider* otomatis (Carousel) yang mengisi bagian atas halaman.
   - Pedomani urutan kemunculan dari *response* field `sequence`.
   - Tombol klik (jika field `action_url` ada) arahkan ke promo/service terkait.
2. **Section Promo / Paket Khusus**
   - Panggil endpoint `GET /api/v1/public/cms/promotions`.
   - Render sebagai kumpulan _Card_ dinamis (misal grid 3 kolom di desktop, 1 kolom di mobile).
   - Card harus punya status estetika desain *Modern & Premium*, menonjolkan persentase/potongan diskon.
3. **Section Social Proof (Testimonials)**
   - Panggil `GET /api/v1/public/cms/testimonials`.
   - Tampilkan dengan rating bintang (`rating` 1-5 bintang).

### B. Halaman Dashboard Internal (Admin Panel)

Bagi role staf `clinic_admin` atau bagian Marketing:

1. **Menu Pengelolaan CMS** di _Sidebar_ Dashboard. Sub-menunya:
   - *Kelola Banner* (Drag-and-drop _ordering_ untuk value `sequence` amat disarankan!).
   - *Kelola Promo* (Form kalender penentuan `start_date` dan `end_date`).
   - *Kelola Testimoni* (Tabel _approval_ untuk memilih mana yang akan di-*Featured* ke homepage).
2. **Form Input**
   - Mendukung integrasi *Image Uploader* (koneksi ke endpoint Upload Backend) ketika memasukkan banner atau foto promo.
   - Toggle "Aktif / Non-Aktif" (untuk men-set `is_active`).

---

### Tips Optimasi Bersama
- Cache respon dari Endpoint Publik (`/public/cms/*`) menggunakan Redis di sisi backend, atau implementasi React Query (`@tanstack/react-query`) dengan `staleTime` yang agak lama di web Frontend, karena konten landing page tidak berubah sekuensial tiap millisecond. Ini mengurangi beban query di database.


