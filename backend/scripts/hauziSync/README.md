# Hauzi → Putko sync

Compares Putko listings with their Hauzi.sk originals field by field. With
`--apply` it updates Putko and refreshes the host panel (Listings → Manage) so it shows the same data.

All commands are run from the `backend/` folder.

Two tools use the same input CSV: **hauzi-sync** (this page, top) and
**merge-units** (see [Merging old per-unit listings](#merging-old-per-unit-listings-merge-units) at the end).

---

## Commands

| Command | What it does | Changes data? |
|---|---|---|
| `npm run hauzi-sync` | Dry run. Writes the **plan** report: what `--apply` would change and add. | No |
| `npm run hauzi-sync -- --apply` | Updates listings and their units, refreshes the host panel. Writes the **result** report. | **Yes** |
| `npm run hauzi-sync -- --apply --prices` | Same, and also updates nightly/person prices and `flexiblePrices` when Hauzi publishes them. | **Yes** |
| `npm run hauzi-sync -- --apply --flexible-prices-only` | Updates only `flexiblePrices` on existing listings; does not change other fields, units, images or host-panel data. | **Yes** |
| `npm run hauzi-sync -- --apply --images` | Same, and replaces photos when the photo count differs (Hauzi → Cloudinary → listing). | **Yes** |
| `npm run hauzi-sync -- --apply --prices --images` | All of the above. | **Yes** |
| `npm run hauzi-sync:samples` | Reads the saved pages in `samples/` only. No network, no database. | No |
| `npm run hauzi-sync -- my_input.csv` | Dry run with a different input CSV. | No |
| `npm run hauzi-sync -- my_input.csv --apply` | Apply with a different input CSV. | **Yes** |

Keep the `--` after `npm run hauzi-sync`; without it npm keeps the options for
itself and the script never sees them.

The same without npm:

```
node scripts/hauziSync/index.js [input.csv] [options]
```

### Options

| Option | Meaning |
|---|---|
| *(none)* | Dry run: report only, nothing is written. |
| `--apply` | Write to Putko: update fields, sync units, refresh the host panel. |
| `--prices` | With `--apply`: also update `pricePerNight`, `pricePerPerson`, and Hauzi's seasonal/calendar `flexiblePrices`. Without it price differences are reported (`SKIPPED`). |
| `--flexible-prices-only` | With `--apply`: update only `flexiblePrices` for existing listings. Does not touch units or other fields. |
| `--images` | With `--apply`: replace a listing's (and each unit's) photos when the count differs from Hauzi. Also needed to give a newly added unit its own photos. |
| `--parse-only` | No database: only show what was read from each Hauzi page. |
| `--output FILE` | Report path. Default: next to the input CSV (see [Reports](#reports)). |
| `--delay MS` | Pause between Hauzi requests. Default `1500`. |

---

## Recommended workflow

1. **Plan**: `npm run hauzi-sync`
2. Open `scripts/hauziSync/hauzi_sync_plan_<time>.csv` and check every
   `MISMATCH` and `WOULD_ADD` row.
3. **Apply**: `npm run hauzi-sync -- --apply` (add `--prices` / `--images` if wanted)
4. Open `scripts/hauziSync/hauzi_sync_result_<time>.csv` to see what was done.

---

## Input CSV

Default: `scripts/hauziSync/hauzi_sync_input.csv`. One Hauzi property per row:

```
hauziUrl,putkoUrl,hostEmail
https://www.hauzi.sk/chata-oxy,https://putko.sk/listings/chata-oxy,owner@example.com
```

| Column | Content |
|---|---|
| `hauziUrl` | Hauzi page link, **or** a path to a saved Hauzi `.html` page (relative to the CSV or the working directory). |
| `putkoUrl` | The Putko listing link. Only the first link is used when Hauzi has several units (see below). |
| `hostEmail` | The host who owns the Putko listing. Listings of another host are never changed. |

Header names are matched loosely (`Hauzi URL`, `hauzi_link`, … all work).

### Hauzi units → listing units

A Hauzi property is **one** Putko listing. When Hauzi shows several units
(apartment A, cottage B, …) they become the listing's `units` (the same units
the host editor's Units step edits), not separate listings.

| Hauzi | What happens |
|---|---|
| 1 unit | The listing is compared with the property. No units are touched. |
| Several units | The listing is compared with the **whole property**, and each Hauzi unit is synced into `listing.units`. |
| Several units, several links in the cell | Only the first link is the listing. The others are old one-listing-per-unit listings: reported `SKIPPED`, not changed. Retire them by hand once bookings are moved. |

Unit rules:

- A Hauzi unit is matched to a Putko unit **by name** (ignoring case and accents). No match → the unit is added (`WOULD_ADD` / `ADDED`) with a new id.
- "2x Dvojlôžková izba" (two identical rooms) becomes two units, "… 1" and "… 2".
- Putko units Hauzi does not list are **never removed** (they may have bookings, see `unitRemovalGuard`); they are reported `NOT_ON_HAUZI`.
- Synced per unit: guests, bedrooms, bathrooms, single/double/bunk beds, extra beds, living rooms, the 8 amenity groups, nightly price and seasonal offers `flexiblePrices` (`--prices`; `--flexible-prices-only` updates just the offers), photos (`--images`). The unit's total `beds` remains available for capacity display; its bed types and extra-bed count are stored separately. A unit that has any amenities replaces the listing's whole set, so a group Hauzi says nothing about (safety equipment) is copied from the listing.
- A unit's prices come from its own Cenník (the price table in its Hauzi modal, as `hazui.py` reads it): `flexiblePrices` are its periods, and `pricePerNight` is the period covering today (else the lowest one, so the offers apply). A unit with no table of its own gets its price from Hauzi's booking form instead.
- `--flexible-prices-only` never adds a unit or touches anything but `flexiblePrices`.
- Renaming a unit on Putko breaks the match: the next run adds a second unit under the Hauzi name. Keep the Hauzi unit names, or rename on Hauzi first.

---

## Reports

| Run | File |
|---|---|
| Dry run | `hauzi_sync_plan_<time>.csv` |
| `--apply` | `hauzi_sync_result_<time>.csv` |
| `--parse-only` | `hauzi_sync_parsed_<time>.csv` |

Written next to the input CSV and saved after every row, so a crash still leaves
a usable report. The first row (`_about`) explains how to read it.

### Columns

| Column | Meaning |
|---|---|
| `listing` | Putko listing name (or the new listing's name). |
| `field` | Putko field, or a special row (see below). |
| `status` | See the tables below. |
| `hauziValue` | What Hauzi says. |
| `putkoOldValue` | Putko before the run. |
| `putkoNewValue` | Putko after `--apply` (the old value when it is kept). |
| `why` | Why the field has this status. |

### Status: existing listings

| Status | Meaning |
|---|---|
| `MATCH` | Same on Hauzi and Putko; nothing to change. |
| `MISMATCH` | Dry run: differs; `--apply` will replace the Putko value with the Hauzi value. |
| `UPDATED` | `--apply`: Putko value replaced with the Hauzi value. |
| `NOT_ON_HAUZI` | Hauzi has no value; Putko value kept. |
| `SKIPPED` | Differs, but not updated (e.g. price without `--prices`); Putko value kept. |
| `ERROR` | Nothing written for this row (see `why`). |

### Status: units (several-unit Hauzi pages)

| Status | Meaning |
|---|---|
| `MATCHED` | `_unit` row: the Hauzi unit was found on the listing by name. |
| `WOULD_ADD` | Dry run: the listing has no such unit; `--apply` adds it. Its field rows show the values it will get. |
| `ADDED` | `--apply`: unit added to the listing. |
| `NOT_ON_HAUZI` | `_unit` row: a Putko unit Hauzi does not list; kept. Field rows: as for listings. |

Field rows of a unit use the same `MATCH` / `MISMATCH` / `UPDATED` / `SKIPPED` / `ERROR` as listings; `listing` reads "<listing> › <unit>".

### Special rows

| `field` | Meaning |
|---|---|
| `_about` | How to read the report. |
| `_unit` | A Hauzi unit on the listing: matched, added, or a Putko unit not on Hauzi. |
| `_unitsSummary` | Counts per status for the units of one listing. |
| `_hostPanel` | Whether the host panel (Manage) shows the same data as the listing; refreshed with `--apply`. |
| `_summary` | Counts per status for one listing. |
| `_listing` | Errors about the input row (no host, no listing, wrong host, …). |

---

## Rules worth knowing

- **Hauzi is the source of truth.** A value Hauzi does not publish is never
  blanked on Putko; it is reported `NOT_ON_HAUZI` and kept.
- **Beds** come from Hauzi's own counts per unit:

  | Hauzi | Putko |
  |---|---|
  | manželská posteľ | `doublebed` |
  | posteľ | `singlebed` |
  | poschodová posteľ | `bunkbed` |
  | prístelka | `beds` (extra beds only) |

  "2x spálňa: 2x posteľ" = 2 bedrooms × 2 beds = 4 single beds.
- **Area:** Hauzi area (m²) → Putko `acreage`.
- **Photos of a unit:** the unit's own photos, in Hauzi's order. Fewer than 5 →
  topped up to 5 from the shared outdoor photos, then the property gallery.
- **Host panel:** Manage edits its own copy of a listing. `--apply` refreshes
  that copy so it matches the listing; otherwise a Save in Manage would write
  old values back.

---

## Fetching Hauzi pages

Pages are fetched with axios, then curl, then ScraperAPI (`SCRAPERAPI_KEY` in
`backend/.env`) when Cloudflare blocks the first two. If all are blocked (e.g.
ScraperAPI credits used up), save the page from the browser as `.html` and put
its path in the `hauziUrl` column.

---

## Files

| File | Content |
|---|---|
| `index.js` | Runs the script. |
| `helpers.js` | Options, text helpers, Putko translations, CSV in/out. |
| `parse.js` | Reads a Hauzi page: rooms, beds, amenities, rules, area, photos. |
| `fetch.js` | Downloads Hauzi pages and booking details (unit prices, min stay, pet fee). |
| `sync.js` | Compares with Putko, updates the listing and its units, refreshes the host panel. |
| `hauzi_sync_input.csv` | Default input. |
| `samples/` | Saved Hauzi pages + `sample_input.csv` for `npm run hauzi-sync:samples`. |

---

## Merging old per-unit listings (merge-units)

Properties once stored as **one Putko listing per unit** become **one new parent
listing** whose `units` are those old listings. In the CSV:

| Column | Content |
|---|---|
| `hauziUrl` | The property on Hauzi. Its **name** becomes the parent's name, its **slug** is made from that name (`-2` if taken), its text becomes the parent's description. |
| `putkoUrl` | **All** the old per-unit Putko listings (comma or space separated). There is no "main" link: every link becomes a unit. |
| `hostEmail` | The host who owns all of them. |

Units are named as Hauzi names them (a listing is matched to the Hauzi unit whose
name appears in the listing's name). A unit has no description of its own, so it
shows the parent's. Code: `scripts/mergeUnits/` (`plan.js` rules, `index.js` runner, `plan.test.js` tests).

### Commands

| Command | What it does | Changes data? |
|---|---|---|
| `npm run merge-units` | Dry run on `hauzi_sync_input.csv`. Reads the database and the Hauzi page. Writes `merge_units_plan_<time>.csv` (`WOULD_MERGE`, `BLOCKED`, `WARNING`, `ERROR`). | No |
| `npm run merge-units -- my_input.csv` | Dry run on a different CSV. | No |
| `npm run merge-units -- --apply` | Per property, in one transaction: creates the parent (with Hauzi's flexible prices, no `--prices` needed), moves everything, retires the old listings; writes a backup first and `merge_units_result_<time>.csv`; then runs hauzi-sync on the parent. | **Yes** |
| `npm run merge-units -- my_input.csv --apply` | Apply with a different CSV. | **Yes** |
| `npm run merge-units -- --apply --prices --images` | Same, and the hauzi-sync that follows also updates nightly / per-person prices and photos (see Options above). | **Yes** |
| `npm run hauzi-sync -- --apply --flexible-prices-only` | For a property merged **before** flexible prices were part of the merge: refreshes only its `flexiblePrices`. | **Yes** |
| `npm run merge-units -- --apply --no-hauzi-sync` | Merge only; run `npm run hauzi-sync -- --apply` yourself later. | **Yes** |
| `npm run merge-units -- --names names.json` | Your own unit names instead of the Hauzi-matched ones (with or without `--apply`). | No / Yes with `--apply` |
| `npm run merge-units -- --output FILE` | Report path. Default: next to the input CSV. | No |
| `npm run merge-units -- --rollback BACKUP.json` | Dry run of an undo: shows what the backup holds. | No |
| `npm run merge-units -- --rollback BACKUP.json --apply` | Deletes the parent and brings the old listings, bookings, reviews and favorites back from the backup. | **Yes** |
| `npm run merge-units:test` | Runs the planner tests on fake in-memory data. No database. | No |

Keep the `--` after `npm run merge-units`. The same without npm:
`node scripts/mergeUnits/index.js [input.csv] [--apply] [--names FILE] [--no-hauzi-sync] [--prices] [--images] [--output FILE] [--rollback BACKUP.json]`.

`names.json` maps an old listing's slug (or id) to the unit name:

```json
{ "apartmany-lubika-apartman-a": "Apartmán A", "apartmany-lubika-apartman-b": "Apartmán B" }
```

### Status file (JSON)

Every run, dry or `--apply`, also writes `merge_units_<plan|result>_<time>.status.json`
next to the CSV report. One entry per CSV row:

| Key | Meaning |
|---|---|
| `status` | `WOULD_MERGE`, `MERGED`, `BLOCKED` or `ERROR` |
| `parent` | The new listing: `id`, `name`, `slug`, `url` |
| `unitsAdded` | Each unit and the old listing it came from (`unit`, `unitId`, `fromListing`) |
| `listingsRemoved` | Old listings taken out of the live catalogue: `id`, `slug`, `name`, `movedTo: "DeletedAccommodation"`, `redirectTo` |
| `moved` | Counts moved to the parent: `bookings`, `deletedBookings`, `reviews`, `favoritesUsers`, `calendarRows`, `calendarFeeds`, `hostPanelRows` |
| `expiredHoldsDropped` | Expired checkout holds not carried over |
| `flexiblePrices` | Price periods written: `parent` (count) and `units` (`{ unit name: count }`) |
| `warnings`, `blockers`, `error` | Why a property was warned about, blocked or failed |
| `backupFile` | The backup to pass to `--rollback` (apply only) |
| `hauziSync` | After `--apply`: `counts` per status, `units` (each Hauzi unit and whether hauzi-sync `ADDED` or `MATCHED` it), `errors` |

### What `--apply` does for each property (all or nothing)

- **Creates the parent** from the first listing's address, host and policies; name, slug and description from Hauzi; guests = the most any unit takes, price = the lowest unit price.
- **Old listings become units**, each with its own price, guests, bed types, extra-bed count, living rooms, amenities and photos. The new parent sums the old listings' room-layout counts, including extra beds.
- **Flexible prices** (no `--prices` needed): the parent gets Hauzi's property-level `flexiblePrices` (its Cenník table, else the day-by-day calendar, as `hazui.py` reads them); each unit gets the Cenník in its Hauzi modal, else keeps its old listing's offers, else gets the parent's Hauzi periods (a unit with its own nightly price ignores the parent's offers, so it needs its own copy). Counts per unit are in the report and in the status file's `flexiblePrices` key.
- Puts every calendar row and iCal feed on its unit.
- Moves bookings, deleted bookings, reviews and favorites to the parent.
- Moves host-panel reservations, blocks and messages to one host-panel copy of the parent.
- **Moves each old listing to `DeletedAccommodation`** (kept, restorable from the backup).
- Adds permanent redirects from each old `/listings/<slug>` URL to the parent in `frontend/listing-redirects.json`. Next.js reads this file at build time, so deploy/rebuild the frontend after a merge for the redirects to go live.
- Then **hauzi-sync** fills the rest from Hauzi: the parent's fields and each unit's guests, beds and amenities.

### A property is BLOCKED (nothing written) when

- a link is not a live listing (one already in the deleted listings is named as such), or the listings belong to another host or to different hosts;
- two units would get the same name (use `--names`);
- a checkout hold or an open booking request could still pay for an old listing;
- the old listings pay out to different Stripe accounts.

Differences a unit cannot carry (cancellation policy, discounts, minimum stay, …)
are `WARNING`s: the first listing's values apply to every unit.

### Recommended workflow

1. `npm run merge-units`, then read `merge_units_plan_<time>.csv` and fix every `BLOCKED` / `ERROR` row.
2. `npm run merge-units -- --apply`. Keep the `merge_units_backup_*.json` file it writes.
3. The apply run adds redirects to `frontend/listing-redirects.json`; deploy/rebuild the frontend to activate them.
4. Something wrong: `npm run merge-units -- --rollback <backup.json> --apply`.

A second run on the same CSV stops with an error: the old links are already in the
deleted listings. After a rollback the same CSV works again.
