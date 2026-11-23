// scripts/mergeUnits/plan.js
//
// Pure planning for "old style → unit style". A property stored as one Putko
// listing PER UNIT becomes ONE NEW parent listing, named after the Hauzi
// property, whose `units` are those old listings. No database access here, so
// every rule can be tested on plain objects; index.js loads the documents,
// calls planMerge, and applies the result.
//
// The old listings are retired (index.js moves them to DeletedAccommodation).
// Units state only what makes them different: their description is left unset,
// so each unit shows the parent's.
//
// A merge is BLOCKED (nothing written for that property) when a payment could
// still land on a listing that is about to disappear, or when the listings do
// not belong together. Things the unit shape cannot carry are WARNINGS.

import { UNIT_AMENITY_FIELDS } from "../../utils/listingUnits.js";

const fold = (s = "") => String(s).normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
const key = (s) => fold(s).replace(/[^a-z0-9]+/g, " ").trim();
const baseKey = key;
const sid = (v) => (v === null || v === undefined ? "" : String(v));
const num = (v) => (v === null || v === undefined || v === "" || !Number.isFinite(Number(v)) ? undefined : Number(v));
const isFuture = (d, now) => d && new Date(d).getTime() > now.getTime();
const periods = (xs) => (Array.isArray(xs) && xs.length ? xs : undefined);

/** Listing-level settings a unit cannot carry; a difference is shown, never silently lost. */
export const LISTING_LEVEL_FIELDS = [
  "cancellationPolicyType", "customPolicyTiers", "lengthDiscounts", "guestDiscounts", "discount",
  "specialPrice", "nightMin", "nightMax", "localTaxPerPersonNight", "stripeAccountId",
  "checkInTime", "checkOutTime",
];

/** Fields of a cloned listing that belong to the OLD listing, not to the new parent. */
const NOT_INHERITED = [
  "_id", "__v", "slug", "name", "description", "translations", "units", "occupancyCalendar", "calendarSync",
  "reviews", "averageRating", "views", "clicks", "customerInterest", "icalExportUrl", "contentUpdatedAt",
  "createdAt", "updatedAt", "date", "images", "unitId", "unitName",
];

/** "Apartmány Ľubika - Apartmán B" under "Apartmány Ľubika" → "Apartmán B". */
export const deriveUnitName = (parentName, oldName) => {
  const rest = String(oldName || "").trim();
  const prefix = String(parentName || "").trim();
  if (prefix && key(rest).startsWith(key(prefix)) && key(rest) !== key(prefix)) {
    const stripped = rest.slice(prefix.length).replace(/^[\s\-–—:|,.]+/, "").trim();
    if (stripped) return stripped;
  }
  return rest;
};

/**
 * Pair each listing with the Hauzi unit it is: the Hauzi unit whose name appears,
 * as whole words, in the listing's name ("Apartmán A" in "Lubika - Apartmán A").
 * Longest name wins; a Hauzi unit is used once; an ambiguous or missing match is
 * left out, and the caller falls back to the derived name.
 * @returns {{ names: {[slug]: string}, unmatched: object[] }}
 */
export const matchHauziNames = (listings, hauziNames) => {
  const names = {};
  const taken = new Set();
  // Hauzi names some units in English ("Apartment Tatranska B5"), Putko in Slovak ("Apartmán Tatranska B5").
  const key = (s) => baseKey(s).replace(/\bapartment(s)?\b/g, (_, p) => (p ? "apartmany" : "apartman"));
  // "Apartmán Deluxe 2" is the 2nd copy of a 4x unit (hauziUnitList); a listing
  // naming just the type ("…-apartman-deluxe") takes the first free copy.
  const cands = hauziNames.map((name) => ({ name, k: key(name), base: key(name).replace(/ \d+$/, "") })).filter((c) => c.k);
  const score = (c, hay) => (hay.includes(` ${c.k} `) ? c.k.length + 0.5 : hay.includes(` ${c.base} `) ? c.base.length : 0);
  for (const acc of listings) {
    // The name first; the slug when the name says nothing (two listings both called "Apartmán Luna").
    let hits = [];
    for (const text of [acc.name, acc.slug]) {
      const hay = ` ${key(text)} `;
      hits = cands.filter((c) => !taken.has(c.k)).map((c) => ({ ...c, s: score(c, hay) })).filter((c) => c.s);
      if (hits.length) break;
    }
    const top = Math.max(...hits.map((h) => h.s));
    let best = hits.filter((c) => c.s === top);
    if (best.length > 1 && best.every((c) => c.base === best[0].base && c.k !== c.base)) best = best.slice(0, 1);
    if (best.length === 1) {
      names[acc.slug] = best[0].name;
      taken.add(best[0].k);
    }
  }
  return { names, unmatched: listings.filter((a) => !names[a.slug]) };
};

const amenityGroup = (pair) => ({ en: [...(pair?.en || [])], sk: [...(pair?.sk || [])] });
const hasAmenities = (a) => UNIT_AMENITY_FIELDS.some((f) => a[f]?.en?.length || a[f]?.sk?.length);

/** One unit from an old listing's own values. No description: the unit shows the parent's. */
export const unitFromListing = (acc, name, _id) => {
  // A unit's `beds` is every bed; a listing's `beds` is extra beds only.
  const allBeds = (num(acc.doublebed) || 0) + (num(acc.singlebed) || 0) + (num(acc.bunkbed) || 0) + (num(acc.beds) || 0);
  const unit = { _id, name };
  const set = (k, v) => { if (v !== undefined && v !== null && v !== "") unit[k] = v; };
  set("person", num(acc.person));
  set("bedroom", num(acc.bedroom));
  set("beds", allBeds || undefined);
  set("extraBeds", num(acc.beds));
  set("singlebed", num(acc.singlebed));
  set("doublebed", num(acc.doublebed));
  set("bunkbed", num(acc.bunkbed));
  set("bathroom", num(acc.bathroom));
  set("LivingRoom", num(acc.LivingRoom));
  set("kitchen", num(acc.kitchen));
  set("pricePerNight", num(acc.pricePerNight));
  set("pricePerPerson", num(acc.pricePerPerson));
  set("cleaningFee", num(acc.cleaningFee));
  if (Array.isArray(acc.flexiblePrices) && acc.flexiblePrices.length) unit.flexiblePrices = acc.flexiblePrices;
  // A unit with any amenities REPLACES the listing's whole set, so copy all eight groups.
  if (hasAmenities(acc)) for (const f of UNIT_AMENITY_FIELDS) unit[f] = amenityGroup(acc[f]);
  if (Array.isArray(acc.images) && acc.images.length) unit.images = [...acc.images];
  return unit;
};

const stampRow = (row, unit) => ({ ...row, unitId: unit._id, unitName: unit.name });
const min = (xs) => (xs.length ? Math.min(...xs) : undefined);
const max = (xs) => (xs.length ? Math.max(...xs) : undefined);
const total = (olds, field) => {
  const values = olds.map((old) => num(old[field])).filter((value) => value !== undefined);
  return values.length ? values.reduce((sum, value) => sum + value, 0) : undefined;
};

/**
 * @param {object} input
 *   olds          lean Accommodation documents, in CSV order
 *   parent        { _id, name, slug, description, flexiblePrices } — the new listing's identity (from Hauzi)
 *   reservations  lean Reservations on any old listing
 *   hostListings  lean HostListing docs whose accommodationId is an old listing
 *   names         { [slug or id]: unitName } — explicit overrides, then Hauzi-matched names
 *   hauziUnits    [{ unitName, flexiblePrices }] — each Hauzi unit's own Cenník
 *   newId         () => a fresh ObjectId-like value
 *   now           Date
 */
export function planMerge({ olds, parent: identity, reservations = [], names = {}, hauziUnits = [], newId, now = new Date() }) {
  const blockers = [];
  const warnings = [];

  if (!olds?.length) return { ok: false, blockers: ["no Putko listing to merge"], warnings };
  if (!identity?.name) return { ok: false, blockers: ["the Hauzi property name is missing, so the parent has no name"], warnings };

  const ids = olds.map((a) => sid(a._id));
  if (new Set(ids).size !== ids.length) blockers.push("the same listing appears twice in the row");
  if (new Set(olds.map((a) => sid(a.userId))).size > 1) blockers.push("the listings belong to different hosts");

  // ── Payments that could still land on a listing about to be retired ───────
  for (const acc of olds) {
    const live = (acc.occupancyCalendar || []).filter((r) => r.status === "held" && isFuture(r.holdExpiresAt, now));
    if (live.length) blockers.push(`"${acc.name}" has ${live.length} active checkout hold(s); wait until they expire (checkout is in progress)`);
  }
  for (const r of reservations) {
    const unanswered = r.bookingMode === "request" && r.isApproved === "pending" && !r.requestDeclinedAt && !r.requestExpiredAt && isFuture(r.requestExpiresAt, now);
    const awaitingPayment = r.bookingMode === "request" && r.paymentStatus === "unpaid" && isFuture(r.paymentLinkExpiresAt, now);
    if (unanswered || awaitingPayment) blockers.push(`booking request ${sid(r._id)} is still open (the guest could still be sent to pay for the old listing)`);
  }

  // ── Units: Hauzi's names where they match, else the old name minus the parent's ──
  // A unit's seasonal offers: its Hauzi Cenník, else the old listing's own, else the
  // property's Hauzi periods. A unit with its own price ignores the parent's offers
  // (listingUnits.js), so without them the property's seasons would never apply.
  const hauziPeriods = (name) => periods(hauziUnits.find((h) => key(h.unitName) === key(name))?.flexiblePrices);
  const oldUnits = olds.map((old) => {
    const unit = unitFromListing(old, names[old.slug] || names[sid(old._id)] || deriveUnitName(identity.name, old.name), newId());
    const offers = hauziPeriods(unit.name) ?? unit.flexiblePrices ?? periods(identity.flexiblePrices);
    if (offers) unit.flexiblePrices = offers;
    // listingUnits.js ignores a unit's offers unless it has its own nightly price.
    if (unit.flexiblePrices && !unit.pricePerNight) warnings.push(`"${unit.name}" has seasonal prices but no nightly price, so they will not apply`);
    return { old, unit };
  });
  const units = oldUnits.map((x) => x.unit);

  const seen = new Set();
  for (const u of units) {
    const k = key(u.name);
    if (!k) blockers.push("a unit would have an empty name");
    else if (seen.has(k)) blockers.push(`two units would be named "${u.name}"; give them different names with --names`);
    seen.add(k);
  }

  // ── Calendar: every row of an old per-unit listing belongs to that unit ───
  let droppedHolds = 0;
  const keep = (rows) => (rows || []).filter((r) => {
    const expired = r.status === "held" && !isFuture(r.holdExpiresAt, now);
    if (expired) droppedHolds++;
    return !expired;
  });
  const occupancyCalendar = oldUnits.flatMap(({ old, unit }) => keep(old.occupancyCalendar).map((r) => stampRow(r, unit)));

  // iCal feeds follow their unit; their rows keep pointing at the same feed id.
  const calendarSync = [];
  for (const { old, unit } of oldUnits) {
    for (const f of old.calendarSync || []) {
      if (calendarSync.some((g) => key(g.url) === key(f.url))) warnings.push(`feed ${f.url} is on more than one listing; both kept, one per unit`);
      calendarSync.push({ ...f, unitId: unit._id });
    }
  }

  // ── Differences the unit shape cannot hold: the first listing's values apply to all ──
  const [first, ...rest] = olds;
  for (const old of rest) {
    const diff = LISTING_LEVEL_FIELDS.filter((f) => JSON.stringify(old[f] ?? null) !== JSON.stringify(first[f] ?? null));
    if (diff.length) warnings.push(`"${old.name}" differs from "${first.name}" in ${diff.join(", ")}; the first listing's values apply to every unit`);
    if (old.stripeAccountId && first.stripeAccountId && old.stripeAccountId !== first.stripeAccountId) {
      blockers.push(`"${old.name}" pays out to a different Stripe account than "${first.name}"`);
    }
  }

  // ── The parent: the first listing's address, policies and host, with a new identity ──
  const inherited = Object.fromEntries(Object.entries(first).filter(([k]) => !NOT_INHERITED.includes(k)));
  const images = [...new Set(olds.flatMap((o) => o.images || []))];
  const parent = {
    ...inherited,
    _id: identity._id,
    name: identity.name,
    slug: identity.slug,
    description: identity.description || first.description,
    // The whole property's totals; hauzi-sync then replaces them with Hauzi's own figures.
    person: max(olds.map((o) => num(o.person)).filter((n) => n !== undefined)) ?? first.person,
    // The parent describes all merged units. `beds` is extra beds only on a
    // listing; the unit entries also retain the separate bed types for detail.
    bedroom: total(olds, "bedroom") ?? first.bedroom,
    beds: total(olds, "beds") ?? first.beds,
    singlebed: total(olds, "singlebed") ?? first.singlebed,
    doublebed: total(olds, "doublebed") ?? first.doublebed,
    bunkbed: total(olds, "bunkbed") ?? first.bunkbed,
    kitchen: total(olds, "kitchen") ?? first.kitchen,
    LivingRoom: total(olds, "LivingRoom") ?? first.LivingRoom,
    pricePerNight: min(olds.map((o) => num(o.pricePerNight)).filter((n) => n > 0)) ?? first.pricePerNight,
    nightMin: min(olds.map((o) => num(o.nightMin)).filter((n) => n !== undefined)) ?? first.nightMin,
    // Hauzi's property-level Cenník (or day-by-day calendar), else the first listing's (inherited above).
    ...(periods(identity.flexiblePrices) ? { flexiblePrices: identity.flexiblePrices } : {}),
    images,
    units,
    occupancyCalendar,
    calendarSync,
    reviews: olds.flatMap((o) => o.reviews || []),
    createdAt: now,
    updatedAt: now,
  };

  return { ok: blockers.length === 0, blockers, warnings, parent, units, oldUnits, droppedHolds };
}
