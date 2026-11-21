# Putko – Flutter app (guest + host)

A native Android/iOS version of putko.sk: same design, same Slovak/English
texts, same backend. It talks to the existing Express API – **no backend
changes are needed** to run it.

## Run it

```powershell
cd mobile
powershell -ExecutionPolicy Bypass -File .\setup.ps1   # once: creates android/ + ios/, permissions, pub get
flutter run                                             # uses https://backend-9k3q.onrender.com/api
```

Local backend instead (Android emulator reaches your PC as 10.0.2.2):

```powershell
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:5000/api
```

Release builds:

```powershell
flutter build apk --release --obfuscate --split-debug-info=build/symbols
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols
flutter build ipa --release --obfuscate --split-debug-info=build/symbols   # on a Mac
```

Optional `--dart-define`s: `API_BASE_URL`, `SITE_URL` (where Stripe returns
to, default `https://putko.sk`), `CLOUDINARY_CLOUD`, `CLOUDINARY_PRESET`.

## What's in it

| Website page | App screen |
|---|---|
| `/` home (hero, savings strip, destinations, benefits, recommended, reviews, how it works, latest, list-your-property, FAQ, footer, sticky search) | `features/home` |
| `/mapa` search + map, filters, sort | `features/search` |
| `/listings/[slug]` gallery, info, amenities, availability & price, host, reviews, location, rules, similar, sticky booking bar | `features/listing` |
| `/Checkout` → Stripe → `/payment-success`, `/payment-cancel`, `/request-sent` | `features/checkout` |
| `/login`, `/registracia`, forgot / reset password | `features/auth` |
| `/guest` profile, saved stays, bookings (cancel with refund preview, receipt), trip history | `features/guest` |
| `/host` Today, Listings + 10-step editor, Calendar (blocks, iCal), Reservations (accept/decline), Messages, Profile, Payouts, Account | `features/host` |
| `/blog`, `/o-nas`, `/caste-otazky`, `/kontakt`, `/prirucka-hostitela`, `/ubytovanie`, `/host-detail`, `/Review` | `features/info`, `features/misc` |

The translations are the site's own `locales/en.js` and `locales/sk.js`
(exported to `assets/l10n/*.json`), and the option lists (property types,
amenities, policies) come from `host/accommodationOptions.js`. When the site's
copy changes, re-export them with the node one-liner in `tool/export_locales.mjs`.

## Why it is fast

* Public GETs (home sections, destinations, listing pages) are cached in memory
  for 1–30 minutes, so going back and forth is instant and the backend sees fewer calls.
* Search uses the API's `fields=card` mode and pages 12 at a time with infinite scroll.
* Every Cloudinary image is requested at the size it is shown (`w_…,f_webp`) and
  decoded at that size (`memCacheWidth`), never the full original.
* Destination photos, mascot, hero and logo ship inside the app (WebP, 1.4 MB total).
* Prices come from `GET /reservation/quote/:id` – the server's own calculation, so the
  app never re-implements pricing and never shows a total Stripe would not charge.

## Security

* The session token lives in the Keychain / Android Keystore (`flutter_secure_storage`),
  not plain storage. Booking capability tokens likewise.
* Release builds refuse a non-HTTPS `API_BASE_URL`.
* No secrets in the app: Stripe, the Cloudinary API secret and Google keys stay on the
  server. Maps use OpenStreetMap tiles, so no Google Maps key ships in the binary.
* The Stripe WebView only loads Stripe and Putko pages; it closes itself on the
  `payment-success` / `payment-cancel` redirect and verifies the session with the API.
* A 401 from the API clears the session once (same as the site's session-expired event).
* Build with `--obfuscate` (above).

See the chat summary for backend issues found while building this.
