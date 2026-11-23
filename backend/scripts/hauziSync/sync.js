// scripts/hauziSync/sync.js
//
// Comparing a Putko listing with Hauzi field by field, and updating it with --apply.

import mongoose from "mongoose";
import Accommodation from "../../models/Accommodation.js";
import Host from "../../models/Host.js";
import HostListing from "../../models/HostListing.js";
import { UNIT_AMENITY_FIELDS } from "../../utils/listingUnits.js";
import { mapAccommodationToListing } from "../../utils/accommodationMapper.js";
import { uploadAccommodationImages } from "../../utils/uploadUrlToCloudinary.js";
import { addBookingDetails, loadHauziHtml } from "./fetch.js";
import { UPDATE_PRICES, FLEXIBLE_PRICES_ONLY, fold, squash, toNumber, SK, bilingualList, bilingualOne, APPLY, UPDATE_IMAGES, PARSE_ONLY } from "./helpers.js";
import { parseAreaText, formatArea, parseHauziPage, PET_BY_ARRANGEMENT } from "./parse.js";

// ─── Comparison ──────────────────────────────────────────────────────────────

export const sameSet = (a = [], b = []) => {
  const x = [...new Set(a)].sort();
  const y = [...new Set(b)].sort();
  return x.length === y.length && x.every((v, i) => v === y[i]);
};

export const sameText = (a, b) => fold(squash(a)) === fold(squash(b));

export const sameNumber = (a, b, tolerance = 0) =>
  a !== null && a !== undefined && b !== null && b !== undefined && Math.abs(Number(a) - Number(b)) <= tolerance;

/**
 * Field-by-field plan. Each entry knows how to read the Hauzi value, read the
 * Putko value, compare them and produce the $set to make Putko match.
 */
export const FIELDS = [
  { field: "name", hauzi: (h) => h.name, putko: (a) => a.name, same: sameText, set: (v) => ({ name: v }) },
  { field: "description", hauzi: (h) => h.description, putko: (a) => a.description, same: sameText, set: (v) => ({ description: v }) },
  {
    field: "propertyType",
    hauzi: (h) => h.propertyType,
    putko: (a) => a.propertyType?.en,
    same: (x, y) => x === y,
    set: (v) => ({ propertyType: bilingualOne(v) }),
    bilingual: true,
  },
  {
    field: "rentalform",
    hauzi: (h) => h.rentalform,
    putko: (a) => a.rentalform?.en,
    same: (x, y) => x === y,
    set: (v) => ({ rentalform: bilingualOne(v) }),
    bilingual: true,
  },
  ...["person", "bedroom", "bathroom", "WCs", "kitchen", "LivingRoom", "SocialRoom", "CommonRoom", "beds", "doublebed", "singlebed", "bunkbed", "Sofa", "nightMin", "nightMax"].map((key) => ({
    field: key,
    hauzi: (h) => h[key],
    putko: (a) => a[key],
    same: (x, y) => sameNumber(x, y),
    set: (v) => ({ [key]: v }),
  })),
  {
    // Hauzi "area" → Putko "acreage", a string holding the m² number ("24").
    field: "acreage",
    hauzi: (h) => h.area,
    putko: (a) => a.acreage,
    same: (x, y) => sameNumber(x, parseAreaText(y) ?? toNumber(String(y ?? "").match(/\d+(?:[.,]\d+)?/)?.[0])),
    set: (v) => ({ acreage: String(v) }),
    format: formatArea,
  },
  ...["arrivalFrom", "arrivalTo", "departureFrom", "departureTo"].map((key) => ({
    field: key,
    hauzi: (h) => h[key],
    putko: (a) => a[key],
    same: (x, y) => String(x || "").padStart(5, "0") === String(y || "").padStart(5, "0"),
    set: (v) => ({ [key]: v }),
  })),
  ...["pet", "partyOrganizing", "smoking"].map((key) => ({
    field: key,
    hauzi: (h) => h[key],
    putko: (a) => a[key]?.en,
    same: (x, y) => x === y,
    set: (v) => ({ [key]: bilingualOne(v) }),
    bilingual: true,
  })),
  ...[
    "services", "bathroomAmenities", "kitchenDiningAmenities", "heatingCoolingAmenities",
    "safetyAmenities", "wellnessAmenities", "outdoorAmenities", "parkingFacilities", "meals",
  ].map((key) => ({
    field: key,
    hauzi: (h) => h[key],
    putko: (a) => a[key]?.en || [],
    same: (x, y) => sameSet(x, y),
    set: (v) => ({ [key]: bilingualList(v) }),
    bilingual: true,
    // Hauzi never lists safety equipment, so an empty Hauzi set there means
    // "not published", not "none" — Putko's value is kept.
    unknownWhen: (h) => key === "safetyAmenities" && (!h[key] || h[key].length === 0),
  })),
  {
    field: "latitude",
    hauzi: (h) => h.latitude,
    putko: (a) => a.location?.latitude,
    same: (x, y) => sameNumber(x, y, 0.0005),
    set: (v) => ({ "location.latitude": v }),
  },
  {
    field: "longitude",
    hauzi: (h) => h.longitude,
    putko: (a) => a.location?.longitude,
    same: (x, y) => sameNumber(x, y, 0.0005),
    set: (v) => ({ "location.longitude": v }),
  },
  {
    field: "address",
    hauzi: (h) => h.address?.full || null,
    putko: (a) => a.location?.address,
    same: sameText,
    set: (v) => ({ "location.address": v }),
  },
  {
    field: "streetAndNumber",
    hauzi: (h) => h.address?.street || null,
    putko: (a) => a.locationDetails?.streetAndNumber,
    same: sameText,
    set: (v) => ({ "locationDetails.streetAndNumber": v.toLowerCase() }),
  },
  {
    field: "city",
    hauzi: (h) => h.address?.city || null,
    putko: (a) => a.locationDetails?.city,
    same: sameText,
    set: (v) => ({ "locationDetails.city": v.toLowerCase() }),
  },
  {
    field: "zipCode",
    hauzi: (h) => h.address?.zipCode || null,
    putko: (a) => a.locationDetails?.zipCode,
    same: (x, y) => String(x || "").replace(/\s/g, "") === String(y || "").replace(/\s/g, ""),
    set: (v) => ({ "locationDetails.zipCode": v }),
  },
  {
    field: "virtualTourUrl",
    hauzi: (h) => h.virtualTourUrl,
    putko: (a) => a.virtualTourUrl,
    same: (x, y) => String(x || "") === String(y || ""),
    set: (v) => ({ virtualTourUrl: v }),
  },
  {
    field: "petFeePerNight",
    hauzi: (h) => h.petFeePerNight,
    putko: (a) => a.petFeePerNight,
    same: (x, y) => sameNumber(x, y ?? 0),
    set: (v) => ({ petFeePerNight: v }),
  },
  {
    field: "pricePerNight",
    hauzi: (h) => h.pricePerNight,
    putko: (a) => a.pricePerNight,
    same: (x, y) => sameNumber(x, y),
    set: (v) => ({ pricePerNight: v }),
    gate: () => (UPDATE_PRICES || FLEXIBLE_PRICES_ONLY ? null : "not updated without --prices"),
  },
  {
    field: "pricePerPerson",
    hauzi: (h) => h.pricePerPerson,
    putko: (a) => a.pricePerPerson,
    same: (x, y) => sameNumber(x, y),
    set: (v) => ({ pricePerPerson: v }),
    gate: () => (UPDATE_PRICES || FLEXIBLE_PRICES_ONLY ? null : "not updated without --prices"),
  },
  {
    field: "flexiblePrices",
    hauzi: (h) => h.flexiblePrices,
    putko: (a) => a.flexiblePrices,
    same: (x, y) => JSON.stringify(normalizeFlexiblePrices(x)) === JSON.stringify(normalizeFlexiblePrices(y)),
    set: (v) => ({ flexiblePrices: v }),
    unknownWhen: (h) => !Array.isArray(h.flexiblePrices) || h.flexiblePrices.length === 0,
    gate: () => (UPDATE_PRICES || FLEXIBLE_PRICES_ONLY ? null : "not updated without --prices"),
  },
];

const normalizeFlexiblePrices = (periods) => (Array.isArray(periods) ? periods : []).map((period) => ({
  name: period.name || "",
  start: period.start ? new Date(period.start).toISOString().slice(0, 10) : "",
  end: period.end ? new Date(period.end).toISOString().slice(0, 10) : "",
  note: period.note || "",
  applyDiscounts: period.applyDiscounts !== false,
  tiers: (period.tiers || []).map((tier) => ({
    minNights: Number(tier.minNights ?? 1), maxNights: tier.maxNights ?? null,
    minGuests: tier.minGuests ?? null, maxGuests: tier.maxGuests ?? null, price: Number(tier.price),
  })),
}));

export const describe = (v) => (Array.isArray(v)
  ? (v.some((item) => item && typeof item === "object") ? JSON.stringify(v) : v.join(" | "))
  : v ?? "");

// Enum fields are shown in both languages, e.g. "Cottages (SK: Chaty)".
export const show = (spec, v) => {
  if (spec.format && v !== null && v !== undefined && v !== "") return spec.format(toNumber(v) ?? v);
  if (!spec.bilingual || v === null || v === undefined || v === "") return describe(v);
  const list = Array.isArray(v) ? v : [v];
  if (!list.length) return "";
  return `${list.join(" | ")} (SK: ${list.map((x) => SK[x] ?? x).join(" | ")})`;
};

export const slugFromPutkoUrl = (url) => {
  const clean = String(url || "").trim().split(/[?#]/)[0].replace(/\/+$/, "");
  return decodeURIComponent(clean.split("/").pop() || "");
};

export const escapeRegex = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

export const slugify = (s = "") =>
  fold(s).trim().replace(/[\s_]+/g, "-").replace(/[^a-z0-9-]/g, "").replace(/-+/g, "-").replace(/^-+|-+$/g, "");

export const putkoListingUrl = (slug) => `https://putko.sk/listings/${slug}`;

// ─── Units ───────────────────────────────────────────────────────────────────
//
// A Hauzi page with several units is ONE Putko listing whose `units` array
// holds one entry per Hauzi unit (see utils/listingUnits.js). The listing's own
// fields are compared with the whole property; each unit only states what makes
// it different, and anything it leaves unset is the listing's.

/** "2x Dvojlôžková izba" = two identical rooms → "Dvojlôžková izba 1", "… 2". */
export const hauziUnitList = (hauzi) =>
  hauzi.units.flatMap((u) =>
    u.unitCount > 1 ? Array.from({ length: u.unitCount }, (_, i) => ({ ...u, unitName: `${u.unitName} ${i + 1}` })) : [u],
  );

/**
 * The unit fields the sync writes. `hauzi(u, acc)` is the wanted value. A unit
 * with any amenities REPLACES the listing's whole set (applyUnit), so a group
 * Hauzi says nothing about (safety equipment, always) is copied from the
 * listing instead of being blanked.
 */
export const UNIT_FIELDS = [
  ...["person", "bedroom", "bathroom", "kitchen"].map((key) => ({
    field: key, hauzi: (u) => u[key], putko: (p) => p[key], same: sameNumber, set: (v) => ({ [key]: v }),
  })),
  {
    // A unit's `beds` is every bed; the listing's `beds` is extra beds only.
    field: "beds",
    hauzi: (u) => (u.doublebed || 0) + (u.singlebed || 0) + (u.bunkbed || 0) + (u.beds || 0) || null,
    putko: (p) => p.beds,
    same: sameNumber,
    set: (v) => ({ beds: v }),
  },
  ...["singlebed", "doublebed", "bunkbed"].map((key) => ({
    field: key,
    hauzi: (u) => u[key],
    putko: (p) => p[key],
    same: sameNumber,
    set: (v) => ({ [key]: v }),
  })),
  {
    // The accommodation-level `beds` field means extra beds; units keep that
    // count separately from their total `beds` count.
    field: "extraBeds",
    hauzi: (u) => u.beds,
    putko: (p) => p.extraBeds,
    same: sameNumber,
    set: (v) => ({ extraBeds: v }),
  },
  {
    field: "LivingRoom",
    hauzi: (u) => u.LivingRoom,
    putko: (p) => p.LivingRoom,
    same: sameNumber,
    set: (v) => ({ LivingRoom: v }),
  },
  ...UNIT_AMENITY_FIELDS.map((key) => ({
    field: key,
    hauzi: (u, acc) => (u[key]?.length ? u[key] : acc[key]?.en || []),
    putko: (p) => p[key]?.en || [],
    same: sameSet,
    set: (v) => ({ [key]: bilingualList(v) }),
    bilingual: true,
  })),
  {
    field: "pricePerNight",
    hauzi: (u) => u.pricePerNight,
    putko: (p) => p.pricePerNight,
    same: sameNumber,
    set: (v) => ({ pricePerNight: v }),
    gate: () => (UPDATE_PRICES ? null : "not updated without --prices"),
  },
  {
    // The unit's own seasonal offers (its Cenník); they only apply while the unit has its own price.
    field: "flexiblePrices",
    hauzi: (u) => u.flexiblePrices,
    putko: (p) => p.flexiblePrices,
    same: (x, y) => JSON.stringify(normalizeFlexiblePrices(x)) === JSON.stringify(normalizeFlexiblePrices(y)),
    set: (v) => ({ flexiblePrices: v }),
    gate: () => (UPDATE_PRICES || FLEXIBLE_PRICES_ONLY ? null : "not updated without --prices"),
  },
];

const isBlank = (v) => v === null || v === undefined || v === "" || (Array.isArray(v) && !v.length);

/**
 * Syncs `acc.units` with the Hauzi units: matched by name, missing ones added,
 * Putko units Hauzi does not list are kept (they may have bookings). Writes the
 * whole array with --apply. Returns { changed, failed } for the host panel and
 * the final report.
 */
export const syncUnits = async (hauzi, acc, push) => {
  const next = (acc.units || []).map((u) => ({ ...(u.toObject ? u.toObject() : u) }));
  const claimed = new Set();
  const pending = [];
  const counts = {};
  let changed = false;
  const log = (r) => { counts[r.status] = (counts[r.status] || 0) + 1; push(r); return r; };

  for (const hu of hauziUnitList(hauzi)) {
    const label = `${acc.name} › ${hu.unitName}`;
    let at = next.findIndex((p, i) => !claimed.has(i) && sameText(p.name, hu.unitName));
    const isNew = at < 0;
    // Flexible-prices-only mode never adds a unit.
    if (isNew && FLEXIBLE_PRICES_ONLY) {
      log({ listing: label, field: "_unit", hauziValue: hu.unitName, status: "SKIPPED", note: "Putko listing has no such unit; flexible-prices-only mode never adds units" });
      continue;
    }
    if (isNew) {
      next.push({ _id: new mongoose.Types.ObjectId(), name: hu.unitName });
      at = next.length - 1;
    }
    claimed.add(at);
    const unit = next[at];
    log({
      listing: label, field: "_unit", hauziValue: hu.unitName, status: isNew ? (APPLY ? "ADDED" : "WOULD_ADD") : "MATCHED",
      note: isNew
        ? `Putko listing has no unit "${hu.unitName}"; ${APPLY ? "added" : "--apply adds it"} to the listing's units`
        : `compared with Putko unit "${unit.name}"`,
    });

    for (const spec of UNIT_FIELDS) {
      const hv = spec.hauzi(hu, acc);
      const pv = spec.putko(unit);
      const entry = { listing: label, field: spec.field, hauziValue: show(spec, hv), putkoValue: show(spec, pv), putkoNewValue: show(spec, pv) };
      if (isBlank(hv)) {
        log({ ...entry, status: "NOT_ON_HAUZI", note: hu.notes?.[spec.field] || "Hauzi has no value; Putko value kept" });
        continue;
      }
      if (!isNew && spec.same(hv, pv)) {
        log({ ...entry, status: "MATCH", note: "same on Hauzi and Putko; nothing to change" });
        continue;
      }
      const blocked = FLEXIBLE_PRICES_ONLY && spec.field !== "flexiblePrices" ? "flexible-prices-only mode" : spec.gate?.();
      if (blocked) {
        log({ ...entry, status: "SKIPPED", note: `differs from Hauzi, but ${blocked}; Putko value kept` });
        continue;
      }
      Object.assign(unit, spec.set(hv));
      changed = true;
      pending.push(log({
        ...entry, putkoNewValue: show(spec, hv), status: isNew ? (APPLY ? "ADDED" : "WOULD_ADD") : APPLY ? "UPDATED" : "MISMATCH",
        note: isNew ? "value of the new unit" : APPLY ? "differed from Hauzi; Putko value replaced with the Hauzi value" : "differs from Hauzi; --apply will replace the Putko value with the Hauzi value",
      }));
    }

    // Photos: compared by count only (Cloudinary copies cannot be compared by content).
    if (FLEXIBLE_PRICES_ONLY) continue;
    const have = unit.images || [];
    const imageEntry = {
      listing: label, field: "images", hauziValue: `${hu.images.length} photo(s): ${hu.images.join(" | ")}`,
      putkoValue: `${have.length} photo(s)`, putkoNewValue: `${have.length} photo(s)`,
    };
    if (!hu.images.length) {
      log({ ...imageEntry, status: "NOT_ON_HAUZI", note: "Hauzi has no photos; the unit shows the listing's photos" });
    } else if (!isNew && hu.images.length === have.length) {
      log({ ...imageEntry, status: "MATCH", note: "same photo count (content not compared)" });
    } else if (!(APPLY && UPDATE_IMAGES)) {
      log({
        ...imageEntry, status: APPLY ? "SKIPPED" : "MISMATCH",
        note: "photo count differs; --apply --images copies the Hauzi photos to Cloudinary and saves them on the unit",
      });
    } else {
      try {
        unit.images = await uploadAccommodationImages(hu.images.join(","), `${acc.slug}-${slugify(hu.unitName)}`);
        changed = true;
        pending.push(log({ ...imageEntry, putkoNewValue: `${unit.images.length} Cloudinary photo(s)`, status: "UPDATED", note: "Hauzi photos copied to Cloudinary and saved on the unit" }));
      } catch (err) {
        log({ ...imageEntry, status: "ERROR", note: `image upload failed: ${err.message}`.slice(0, 300) });
      }
    }
  }

  next.forEach((p, i) => {
    if (claimed.has(i) || FLEXIBLE_PRICES_ONLY) return;
    log({
      listing: `${acc.name} › ${p.name}`, field: "_unit", status: "NOT_ON_HAUZI",
      note: "Putko unit is not on Hauzi; kept (a unit with bookings is never removed by the sync)",
    });
  });

  let failed = false;
  if (APPLY && changed) {
    try {
      await Accommodation.updateOne({ _id: acc._id }, { $set: { units: next } }, { runValidators: true });
    } catch (err) {
      failed = true;
      for (const r of pending) {
        r.status = "ERROR";
        r.putkoNewValue = r.putkoValue;
        r.note = `update failed: ${err.message}`.slice(0, 300);
      }
    }
  }
  push({ listing: acc.name, field: "_unitsSummary", status: failed ? "ERROR" : "DONE", note: Object.entries(counts).map(([k, n]) => `${k}: ${n}`).join(", ") });
  return { changed, failed };
};

/**
 * Compares (and with --apply updates) one input row. Returns report rows.
 * `outcomes` ({ created, updated, skipped, failed }), when given, collects one
 * entry { name, id, url, … } per listing for the final report.
 */
export const syncOne = async (input, rowNo, outcomes = null) => {
  const base = { row: rowNo, hostEmail: input.hostEmail, hauziUrl: input.hauziUrl, putkoUrl: input.putkoUrl };
  const report = [];
  const push = (r) => report.push({ ...base, ...r });
  const record = (kind, entry) => outcomes?.[kind]?.push({ row: rowNo, hauziUrl: input.hauziUrl, ...entry });
  // An ERROR row for a whole listing, also listed as failed in the final report.
  const fail = (r) => {
    push({ ...r, field: "_listing", status: "ERROR" });
    record("failed", { name: r.listing || null, id: null, url: r.putkoUrl || input.putkoUrl || null, note: r.note });
  };

  if (!input.hauziUrl) {
    fail({ note: "hauziUrl is empty" });
    return report;
  }

  const hauzi = parseHauziPage(await loadHauziHtml(input.hauziUrl), input.hauziUrl);
  await addBookingDetails(hauzi, input.hauziUrl);
  // Pets for a fee, but no per-night amount on Hauzi → "by arrangement with
  // the owner" (both languages), with no fee on Putko.
  for (const view of [hauzi, ...hauzi.units]) {
    if (view.pet === "Allowed with an additional fee" && (view.petFeePerNight === null || view.petFeePerNight === undefined)) {
      view.pet = PET_BY_ARRANGEMENT;
    }
    if (view.pet === PET_BY_ARRANGEMENT) view.petFeePerNight = 0;
  }
  const multiUnit = hauzi.units.length > 1;

  // ── Parse-only: just show what Hauzi says ────────────────────────────────
  if (PARSE_ONLY) {
    const views = [{ label: hauzi.name, view: hauzi, fields: FIELDS }];
    if (multiUnit) hauziUnitList(hauzi).forEach((u) => views.push({ label: `${hauzi.name} › unit: ${u.unitName}`, view: u, fields: UNIT_FIELDS }));
    for (const { label, view, fields } of views) {
      for (const spec of fields) {
        const value = spec.hauzi(view, {});
        const missing = isBlank(value);
        push({ listing: label, field: spec.field, hauziValue: show(spec, value), status: "PARSED", note: missing ? view.notes?.[spec.field] || "" : "" });
      }
      push({ listing: label, field: "images", hauziValue: view.images.join(" | "), status: "PARSED", note: `${view.images.length} photo(s)` });
      push({ listing: label, field: "_amenityText", hauziValue: view.rawAmenityText, status: "PARSED", note: "text the amenities were detected from" });
    }
    return report;
  }

  // ── Resolve host + listing, and make sure they belong together ───────────
  if (!input.hostEmail) {
    fail({ listing: hauzi.name, note: "hostEmail is empty" });
    return report;
  }
  const host = await Host.findOne({ email: new RegExp(`^${escapeRegex(input.hostEmail)}$`, "i") }).select("_id email");
  if (!host) {
    fail({ listing: hauzi.name, note: `no host with email ${input.hostEmail}` });
    return report;
  }

  // The putkoUrl cell may hold several links (comma, space, ; or new line).
  const putkoUrls = String(input.putkoUrl || "").split(/[\s,;]+/).filter(Boolean);
  if (!putkoUrls.length) {
    fail({ listing: hauzi.name, note: "putkoUrl is empty" });
    return report;
  }

  const listings = [];
  for (const url of putkoUrls) {
    const key = slugFromPutkoUrl(url);
    const acc = /^[a-f0-9]{24}$/i.test(key)
      ? await Accommodation.findById(key)
      : await Accommodation.findOne({ slug: key });
    if (!acc) {
      fail({ putkoUrl: url, listing: hauzi.name, note: `no Putko listing for "${key}"` });
      continue;
    }
    if (String(acc.userId) !== String(host._id)) {
      fail({ putkoUrl: url, listing: acc.name, note: `listing belongs to another host, not ${input.hostEmail} — nothing changed` });
      continue;
    }
    listings.push({ url, acc });
  }

  // One Hauzi unit (or none): every link is compared with the whole property.
  // Several Hauzi units: the FIRST link is the listing, and the units are
  // synced into its `units`. Further links are old one-listing-per-unit
  // listings; they are left alone.
  const stand = multiUnit ? listings.slice(0, 1) : listings;
  for (const { url, acc } of listings.slice(stand.length)) {
    const note = `this Hauzi property has ${hauzi.units.length} units and they live in ONE listing ("${stand[0].acc.name}"); this old per-unit listing is left unchanged`;
    push({ putkoUrl: url, listing: acc.name, field: "_listing", status: "SKIPPED", note });
    record("skipped", { name: acc.name, id: String(acc._id), url: putkoListingUrl(acc.slug), unit: null, note });
  }

  for (const { url, acc } of stand) {
    const rowPush = (r) => push({ putkoUrl: url, ...r });
    // Units first, so the host panel copy refreshed by compareListing includes them.
    const units = multiUnit ? await syncUnits(hauzi, acc, rowPush) : { changed: false, failed: false };
    const result = await compareListing(hauzi, acc, rowPush, units.changed);
    const failed = result.failed || units.failed;
    record(failed ? "failed" : "updated", { name: hauzi.name || acc.name, id: String(acc._id), url: putkoListingUrl(acc.slug), unit: null, note: result.note });
  }
  return report;
};


/**
 * The host panel does not read the Accommodation: pressing Manage copies it
 * once into a HostListing draft (`data`), and the editor shows — and on Save
 * writes back — that copy. A listing changed here would therefore still show
 * the old values in the host panel, and a Save there would undo the sync. So
 * the draft is refreshed from the Accommodation after every write (and any
 * draft that is already out of date, e.g. from an earlier run, is refreshed
 * too). Fields the editor owns that the Accommodation does not (feeds, …) are
 * kept. A listing never opened with Manage has no draft; the host panel builds
 * one from the Accommodation when it is first opened.
 */
export const draftDifferences = (draftData = {}, mapped = {}) =>
  Object.keys(mapped).filter((key) => JSON.stringify(draftData?.[key]) !== JSON.stringify(mapped[key]));

const refreshHostPanelDraft = async (accId, listingName, push, willChange = false) => {
  const draft = await HostListing.findOne({ accommodationId: accId });
  if (!draft) return;
  const fresh = await Accommodation.findById(accId).lean();
  if (!fresh) return;
  const mapped = mapAccommodationToListing(fresh);
  const changed = draftDifferences(draft.data, mapped);
  const entry = { listing: listingName, field: "_hostPanel", hauziValue: "", putkoValue: "", putkoNewValue: "" };
  if (!APPLY && willChange) {
    push({ ...entry, status: "MISMATCH", note: "--apply changes this listing, then refreshes the host panel (Manage) copy so it shows the same data" });
    return;
  }
  if (!changed.length) {
    push({ ...entry, status: "MATCH", note: "host panel (Manage) already shows the same data as the listing" });
    return;
  }
  if (!APPLY) {
    push({ ...entry, status: "MISMATCH", note: `host panel (Manage) shows old data for: ${changed.join(", ")}; --apply refreshes it from the listing` });
    return;
  }
  try {
    await HostListing.updateOne({ _id: draft._id }, { $set: { data: { ...draft.data, ...mapped } } });
    push({ ...entry, status: "UPDATED", note: `host panel (Manage) refreshed from the listing: ${changed.join(", ")}` });
  } catch (err) {
    push({ ...entry, status: "ERROR", note: `host panel not refreshed: ${err.message}`.slice(0, 300) });
  }
};

/**
 * Compares (and with --apply updates) one Putko listing against one Hauzi view.
 * `unitsChanged`: the listing's units were (or, in a dry run, will be) changed too.
 * Returns { counts, failed, note } for the final report.
 */
export const compareListing = async (hauzi, acc, push, unitsChanged = false) => {
  const $set = {};
  const pending = [];
  const counts = { MATCH: 0, MISMATCH: 0, UPDATED: 0, NOT_ON_HAUZI: 0, SKIPPED: 0 };

  for (const spec of FIELDS) {
    const hv = spec.hauzi(hauzi);
    const pv = spec.putko(acc);
    // putkoNewValue is what Putko holds after --apply (the old value when kept).
    const entry = { listing: acc.name, field: spec.field, hauziValue: show(spec, hv), putkoValue: show(spec, pv), putkoNewValue: show(spec, pv) };

    if (hv === null || hv === undefined || hv === "" || spec.unknownWhen?.(hauzi)) {
      push({ ...entry, status: "NOT_ON_HAUZI", note: hauzi.notes?.[spec.field] || "Hauzi has no value; Putko value kept" });
      counts.NOT_ON_HAUZI++;
      continue;
    }
    if (spec.same(hv, pv)) {
      push({ ...entry, status: "MATCH", note: "same on Hauzi and Putko; nothing to change" });
      counts.MATCH++;
      continue;
    }
    const blocked = FLEXIBLE_PRICES_ONLY && spec.field !== "flexiblePrices"
      ? "flexible-prices-only mode"
      : spec.gate?.();
    if (blocked) {
      push({ ...entry, status: "SKIPPED", note: `differs from Hauzi, but ${blocked}; Putko value kept` });
      counts.SKIPPED++;
      continue;
    }
    Object.assign($set, spec.set(hv));
    const r = {
      ...entry,
      putkoNewValue: show(spec, hv),
      status: APPLY ? "UPDATED" : "MISMATCH",
      note: APPLY
        ? "differed from Hauzi; Putko value replaced with the Hauzi value"
        : "differs from Hauzi; --apply will replace the Putko value with the Hauzi value",
    };
    pending.push(r);
    push(r);
  }

  // ── Images: Cloudinary copies cannot be compared by content, only by count ──
  const putkoImages = acc.images || [];
  const imageEntry = {
    listing: acc.name,
    field: "images",
    hauziValue: `${hauzi.images.length} photo(s): ${hauzi.images.join(" | ")}`,
    putkoValue: `${putkoImages.length} photo(s)`,
    putkoNewValue: `${putkoImages.length} photo(s)`,
  };
  if (!hauzi.images.length) {
    push({ ...imageEntry, status: "NOT_ON_HAUZI", note: "Hauzi has no photos; Putko images kept" });
    counts.NOT_ON_HAUZI++;
  } else if (hauzi.images.length === putkoImages.length) {
    push({ ...imageEntry, status: "MATCH", note: "same photo count (content not compared)" });
    counts.MATCH++;
  } else if (FLEXIBLE_PRICES_ONLY || !(APPLY && UPDATE_IMAGES)) {
    push({
      ...imageEntry, status: APPLY ? "SKIPPED" : "MISMATCH",
      note: FLEXIBLE_PRICES_ONLY
        ? "photo count differs; images are not changed in flexible-prices-only mode"
        : "photo count differs; --apply --images copies the Hauzi photos to Cloudinary and replaces the Putko ones",
    });
    counts[APPLY ? "SKIPPED" : "MISMATCH"]++;
  } else {
    try {
      $set.images = await uploadAccommodationImages(hauzi.images.join(","), acc.slug);
      const r = {
        ...imageEntry, putkoNewValue: `${$set.images.length} Cloudinary photo(s)`, status: "UPDATED",
        note: `photo count differed; ${$set.images.length} Hauzi photo(s) copied to Cloudinary and saved on the listing`,
      };
      pending.push(r);
      push(r);
    } catch (err) {
      push({ ...imageEntry, status: "ERROR", note: `image upload failed: ${err.message}` });
      counts.ERROR = (counts.ERROR || 0) + 1;
    }
  }

  // ── Write ────────────────────────────────────────────────────────────────
  if (APPLY && Object.keys($set).length) {
    try {
      await Accommodation.updateOne({ _id: acc._id }, { $set }, { runValidators: true });
    } catch (err) {
      // Nothing was written — the updateOne is all-or-nothing — so every row
      // that claimed UPDATED is corrected to ERROR.
      for (const r of pending) {
        r.status = "ERROR";
        r.putkoNewValue = r.putkoValue;
        r.note = `update failed: ${err.message}`.slice(0, 300);
      }
    }
  }
  for (const r of pending) counts[r.status] = (counts[r.status] || 0) + 1;

  // Keep the host panel's copy (Manage) in step with the listing.
  if (!FLEXIBLE_PRICES_ONLY) {
    await refreshHostPanelDraft(acc._id, acc.name, push, Object.keys($set).length > 0 || unitsChanged);
  }

  const note = Object.entries(counts).filter(([, n]) => n).map(([k, n]) => `${k}: ${n}`).join(", ");
  push({ listing: acc.name, field: "_summary", status: "DONE", note });
  return { counts, failed: (counts.ERROR || 0) > 0, note };
};
