/**
 * Turns a Host workspace listing into a real `Accommodation` document.
 *
 * The workspace edits a free-form `HostListing.data` payload so a half-finished
 * draft can be saved without satisfying the Accommodation schema's `required`
 * fields. Publishing is the point where it has to become a real listing, and
 * this is the translation.
 *
 * Two shapes have to be bridged:
 *
 * 1. Flat editor fields vs the model's nested ones — `street`/`city` live under
 *    `locationDetails`, `guests` is `person`, `nightlyPrice` is `pricePerNight`.
 * 2. Single values vs the model's bilingual `{ en, sk }` pairs. The host picks
 *    in one language; both sides are validated against their own enum, so the
 *    counterpart has to be filled in.
 *
 * The language pairs are read off the schema itself rather than copied here:
 * each `{ en, sk }` enum is declared in the same order, so a value's index in
 * one is its index in the other. That way adding an amenity to the model needs
 * no change in this file, and the two can never drift.
 */

import mongoose from "mongoose";
import Accommodation from "../models/Accommodation.js";
import { slugify } from "./slugify.js";
import { preserveLegacyPlatformOffer } from "./hostListingCompletion.js";
import { toCalendarDateString } from "./timezone.js";

/** The enum values of a schema path, whether it is a String or an array. */
const enumsAt = (path) => {
  const schemaPath = Accommodation.schema.path(path);
  if (!schemaPath) return [];
  return schemaPath.caster?.enumValues || schemaPath.enumValues || [];
};

/**
 * The `{ en, sk }` pair for one value, matched against either language.
 * Returns null when the value is not in the enum at all, so an unknown string
 * is dropped rather than failing validation on save.
 */
const pairFor = (field, value) => {
  if (typeof value !== "string" || !value.trim()) return null;

  const en = enumsAt(`${field}.en`);
  const sk = enumsAt(`${field}.sk`);

  let index = en.indexOf(value);
  if (index === -1) index = sk.indexOf(value);
  if (index === -1) return null;

  return { en: en[index], sk: sk[index] };
};

/** The same, for a multi-select stored as two parallel arrays. */
const pairListFor = (field, values) => {
  const list = Array.isArray(values) ? values : [];
  const pairs = list.map((value) => pairFor(field, value)).filter(Boolean);
  return { en: pairs.map((p) => p.en), sk: pairs.map((p) => p.sk) };
};

const num = (value, fallback = undefined) => {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
};

const str = (value) => (typeof value === "string" && value.trim() ? value.trim() : undefined);

/**
 * The amenity groups, in the order the editor shows them.
 *
 * Declared once and used in BOTH directions so the two mappings cannot drift,
 * and so the flat `amenities` list the publish check counts is derived from the
 * same set the editor writes. Mirrors `AMENITY_GROUPS` in
 * `frontend/src/app/host/accommodationOptions.js`.
 */
export const AMENITY_GROUP_FIELDS = [
  "services",
  "bathroomAmenities",
  "kitchenDiningAmenities",
  "heatingCoolingAmenities",
  "safetyAmenities",
  "wellnessAmenities",
  "outdoorAmenities",
  "parkingFacilities",
];

/** `photoUrls` has held both bare strings and `{ url }` objects. */
const photoUrls = (photos) =>
  (Array.isArray(photos) ? photos : [])
    .map((photo) => (typeof photo === "string" ? photo : photo?.url))
    .filter((url) => typeof url === "string" && url.trim());

/** `YYYY-MM-DD` for a stored date, or "" when unset/unparseable. */
const dateString = (value) => (value ? toCalendarDateString(value) : "");

/** A positive whole number, or null for blank / 0 / garbage ("no limit"). */
const optionalCount = (value) => {
  if (value === null || value === undefined || value === "") return null;
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.round(n) : null;
};

/**
 * The editor's flexible-price offers as `Accommodation.flexiblePrices`.
 *
 * Returns undefined when the payload has no `flexiblePrices` key at all, so a
 * draft that never touched the section leaves the listing's existing offers
 * alone instead of clearing them. An offer is kept only with both dates and at
 * least one priced row, the same rule the pricing code applies.
 */
const flexiblePricesFrom = (offers) => {
  if (!Array.isArray(offers)) return undefined;

  return offers
    .map((offer) => {
      const tiers = (Array.isArray(offer?.tiers) ? offer.tiers : [])
        .map((tier) => ({
          minNights: optionalCount(tier?.minNights) ?? 1,
          maxNights: optionalCount(tier?.maxNights),
          minGuests: optionalCount(tier?.minGuests),
          maxGuests: optionalCount(tier?.maxGuests),
          price: num(tier?.price),
          weekendPrice: num(tier?.weekendPrice) > 0 ? num(tier.weekendPrice) : null,
        }))
        .filter((tier) => Number.isFinite(tier.price) && tier.price > 0);

      return {
        name: str(offer?.name) ?? "",
        start: str(offer?.start),
        end: str(offer?.end),
        note: str(offer?.note) ?? "",
        applyDiscounts: offer?.applyDiscounts !== false,
        // Blank = use the listing's extra-person price; 0 = extra beds free here.
        extraPerPerson: optionalAmount(offer?.extraPerPerson) ?? null,
        tiers,
      };
    })
    .filter((offer) => offer.start && offer.end && offer.tiers.length > 0);
};

/**
 * Weekend weekdays (0 = Sunday … 6 = Saturday), unique and sorted. Undefined
 * when the payload has no list, so an untouched draft leaves the listing alone;
 * an empty list means the default (Friday + Saturday nights).
 */
const weekendDaysFrom = (days) => {
  if (!Array.isArray(days)) return undefined;
  return [...new Set(days.map(Number).filter((day) => Number.isInteger(day) && day >= 0 && day <= 6))].sort(
    (a, b) => a - b,
  );
};

/**
 * Discount rows (`{ [key]: n, percent }`) as stored. Undefined when the payload
 * has no list at all, so a draft that never touched them leaves the listing's
 * rows alone. Incomplete rows are dropped; percent is capped at 90.
 */
const discountRowsFrom = (rows, key) => {
  if (!Array.isArray(rows)) return undefined;
  return rows
    .map((row) => ({
      [key]: optionalCount(row?.[key]),
      percent: Math.min(90, Math.max(0, num(row?.percent, 0))),
    }))
    .filter((row) => row[key] !== null && row.percent > 0);
};

/**
 * The editor's paid extras (`{ field, amenity, pricing, price }`) as stored.
 * Undefined when the payload has no list, so an untouched draft leaves the
 * listing's extras alone. A row is kept only for an amenity the listing still
 * has ticked in that group and with a price above 0.
 */
const paidExtrasFrom = (rows, d) => {
  if (!Array.isArray(rows)) return undefined;
  return rows
    .map((row) => {
      const field = AMENITY_GROUP_FIELDS.includes(row?.field) ? row.field : null;
      const amenity = field ? pairFor(field, row?.amenity) : null;
      const ticked = field && Array.isArray(d[field]) ? pairListFor(field, d[field]).en : [];
      if (!amenity || !ticked.includes(amenity.en)) return null;
      return { field, amenity, pricing: row?.pricing === "per_night" ? "per_night" : "per_stay", price: num(row?.price) };
    })
    .filter((row) => row && row.price > 0);
};

/** The way back: stored paid extras as editor rows. */
const paidExtrasOf = (rows) =>
  (Array.isArray(rows) ? rows : []).map((row) => ({
    field: row?.field,
    amenity: row?.amenity?.en,
    pricing: row?.pricing === "per_night" ? "per_night" : "per_stay",
    price: num(row?.price),
  }));

/** The way back: stored discount rows as editor rows. */
const discountRowsOf = (rows, key) =>
  (Array.isArray(rows) ? rows : []).map((row) => ({
    [key]: optionalCount(row?.[key]),
    percent: num(row?.percent),
  }));

/** The way back: stored offers as editor rows with `YYYY-MM-DD` dates. */
export const flexiblePricesOf = (periods) =>
  (Array.isArray(periods) ? periods : []).map((period) => ({
    name: str(period?.name) ?? "",
    start: dateString(period?.start),
    end: dateString(period?.end),
    note: str(period?.note) ?? "",
    applyDiscounts: period?.applyDiscounts !== false,
    extraPerPerson: optionalAmount(period?.extraPerPerson) ?? null,
    tiers: (Array.isArray(period?.tiers) ? period.tiers : []).map((tier) => ({
      minNights: num(tier?.minNights, 1),
      maxNights: optionalCount(tier?.maxNights),
      minGuests: optionalCount(tier?.minGuests),
      maxGuests: optionalCount(tier?.maxGuests),
      price: num(tier?.price),
      weekendPrice: num(tier?.weekendPrice) > 0 ? num(tier.weekendPrice) : null,
    })),
  }));

/** A whole number of at least 0, or undefined for blank ("use the listing's"). */
const optionalAmount = (value) => {
  if (value === null || value === undefined || value === "") return undefined;
  const n = Number(value);
  return Number.isFinite(n) && n >= 0 ? n : undefined;
};

/**
 * The editor's units as `Accommodation.units`.
 *
 * Undefined when the payload has no `units` key, so a draft that never opened
 * the Units step — every listing that existed before it — leaves the listing
 * alone. A unit without a name is dropped.
 *
 * The editor keeps each unit's id (an ObjectId string it generates), and it is
 * written as the unit's `_id`, so A1 stays the same A1 across republishes and
 * the bookings and calendar rows that point at it keep pointing at it.
 */
const unitsFrom = (units) => {
  if (!Array.isArray(units)) return undefined;

  return units
    .filter((unit) => str(unit?.name))
    .map((unit) => {
      const mapped = {
        _id: mongoose.isValidObjectId(unit.id) ? unit.id : new mongoose.Types.ObjectId(),
        name: str(unit.name),
        description: str(unit.description),
        person: optionalCount(unit.guests) ?? undefined,
        bedroom: optionalCount(unit.bedrooms) ?? undefined,
        beds: optionalCount(unit.beds) ?? undefined,
        extraBeds: optionalCount(unit.extraBeds) ?? undefined,
        singlebed: optionalCount(unit.singlebed) ?? undefined,
        doublebed: optionalCount(unit.doublebed) ?? undefined,
        bunkbed: optionalCount(unit.bunkbed) ?? undefined,
        bathroom: optionalCount(unit.bathrooms) ?? undefined,
        LivingRoom: optionalCount(unit.livingRoom) ?? undefined,
        kitchen: optionalCount(unit.kitchens) ?? undefined,
        pricePerNight: num(unit.nightlyPrice) > 0 ? num(unit.nightlyPrice) : undefined,
        pricePerPerson: optionalAmount(unit.pricePerPerson),
        weekendPricePerNight: optionalAmount(unit.weekendPricePerNight),
        includedGuests: optionalAmount(unit.includedGuests),
        cleaningFee: optionalAmount(unit.cleaningFee),
        flexiblePrices: flexiblePricesFrom(unit.flexiblePrices),
        ...Object.fromEntries(
          AMENITY_GROUP_FIELDS.map((field) => [field, pairListFor(field, unit[field])]),
        ),
        images: photoUrls(unit.photoUrls),
      };
      for (const [key, value] of Object.entries(mapped)) {
        if (value === undefined) delete mapped[key];
      }
      return mapped;
    });
};

/** The way back: stored units as editor units. */
const unitsOf = (units) =>
  (Array.isArray(units) ? units : []).map((unit) => {
    const mapped = {
      id: String(unit._id),
      name: str(unit.name) ?? "",
      description: str(unit.description),
      guests: num(unit.person),
      bedrooms: num(unit.bedroom),
      beds: num(unit.beds),
      extraBeds: num(unit.extraBeds),
      singlebed: num(unit.singlebed),
      doublebed: num(unit.doublebed),
      bunkbed: num(unit.bunkbed),
      bathrooms: num(unit.bathroom),
      livingRoom: num(unit.LivingRoom),
      kitchens: num(unit.kitchen),
      nightlyPrice: num(unit.pricePerNight),
      pricePerPerson: num(unit.pricePerPerson),
      weekendPricePerNight: num(unit.weekendPricePerNight),
      includedGuests: num(unit.includedGuests),
      cleaningFee: num(unit.cleaningFee),
      flexiblePrices:
        Array.isArray(unit.flexiblePrices) && unit.flexiblePrices.length
          ? flexiblePricesOf(unit.flexiblePrices)
          : undefined,
      ...Object.fromEntries(
        AMENITY_GROUP_FIELDS.map((field) => [field, valuesOfPairList(unit[field])]),
      ),
      photoUrls: photoUrls(unit.images),
    };
    for (const [key, value] of Object.entries(mapped)) {
      if (value === undefined) delete mapped[key];
    }
    return mapped;
  });

const calendarFeedsOf = (accommodation) =>
  (Array.isArray(accommodation?.calendarSync) ? accommodation.calendarSync : [])
    .filter((feed) => feed && typeof feed.url === "string" && feed.url.trim())
    .map((feed) => ({ label: str(feed.label) ?? "", url: feed.url.trim() }));

/**
 * A slug that is free.
 *
 * `slug` is uniquely indexed, and two hosts naming a place "Chata" is ordinary,
 * so a taken slug gets a numeric suffix. `excludeId` lets a republish keep its
 * own slug instead of treating it as a collision with itself.
 */
export const uniqueSlug = async (name, excludeId = null) => {
  const base = slugify(name) || "listing";

  for (let attempt = 0; attempt < 50; attempt += 1) {
    const candidate = attempt === 0 ? base : `${base}-${attempt + 1}`;
    const query = { slug: candidate };
    if (excludeId) query._id = { $ne: excludeId };

    if (!(await Accommodation.exists(query))) return candidate;
  }

  // Fifty collisions means something is wrong with the name, not the counter.
  return `${base}-${Date.now()}`;
};

/**
 * Map the editor payload onto Accommodation fields.
 *
 * Returns only the fields the workspace owns. Anything the model manages for
 * itself — reviews, ratings, reservations, Stripe and payout state, view and
 * click counters — is deliberately absent, so republishing never overwrites it.
 */
export const mapListingToAccommodation = (data = {}, { ownerId } = {}) => {
  const d = data && typeof data === "object" ? data : {};

  const mapped = {
    userId: ownerId,

    name: str(d.name),
    description: str(d.description),
    specialNote: str(d.specialNote),
    // English text; only written when the editor sent one, so a draft that
    // predates the fields cannot wipe translations from a live listing.
    ...(["nameEn", "descriptionEn", "specialNoteEn"].some((key) => key in d) && {
      translations: {
        en: { name: str(d.nameEn), description: str(d.descriptionEn), specialNote: str(d.specialNoteEn) },
      },
    }),
    virtualTourUrl: str(d.virtualTourUrl),
    propertyType: pairFor("propertyType", d.propertyType) || undefined,
    rentalform: pairFor("rentalform", d.rentalform) || undefined,

    // Address. The model lowercases several of these in its own setters, so
    // they are passed through as typed.
    locationDetails: {
      streetAndNumber: str(d.street),
      roomNumber: str(d.roomNumber),
      city: str(d.city),
      zipCode: str(d.zipCode),
      country: str(d.country),
      state: str(d.state),
    },
    location: {
      address: str(d.street),
      latitude: num(d.latitude),
      longitude: num(d.longitude),
    },
    phoneNumber: str(d.phoneNumber),

    // Capacity. `person`, `nightMin` and `nightMax` are required by the model,
    // so they fall back rather than being left undefined — the publish check
    // has already guaranteed guests and minNights are present.
    person: num(d.guests, 1),
    bedroom: num(d.bedrooms),
    beds: num(d.beds),
    bathroom: num(d.bathrooms),
    singlebed: num(d.singlebed),
    doublebed: num(d.doublebed),
    bunkbed: num(d.bunkbed, 0),
    Sofa: num(d.sofa),
    kitchen: num(d.kitchen),
    WCs: num(d.wcs),
    LivingRoom: num(d.livingRoom),
    CommonRoom: num(d.commonRoom),
    SocialRoom: num(d.socialRoom),
    acreage: str(d.acreage),

    // Money and stay length.
    pricePerNight: num(d.nightlyPrice),
    pricePerPerson: num(d.pricePerPerson),
    // Weekend rate and the weekdays it applies to; 0 = no weekend rate.
    weekendPricePerNight: Math.max(0, num(d.weekendPricePerNight, 0)),
    weekendDays: weekendDaysFrom(d.weekendDays),
    // Guests the nightly price covers; 0 = legacy per-person rule.
    includedGuests: Math.max(0, Math.round(num(d.includedGuests, 0))),
    // Optional extras; a blank field saves 0 (no fee).
    cleaningFee: Math.max(0, num(d.cleaningFee, 0)),
    localTaxPerPersonNight: Math.max(0, num(d.localTaxPerPersonNight, 0)),
    // Amenities the guest can add for a price. Undefined (left untouched)
    // unless the editor payload carries the list.
    paidExtras: paidExtrasFrom(d.paidExtras, d),
    discount: num(d.discount),
    // Seasonal / flexible offers. Undefined (left untouched) unless the editor
    // payload carries the list.
    flexiblePrices: flexiblePricesFrom(d.flexiblePrices),
    // Sub-units (A1, A2, …). Undefined (left untouched) unless the editor
    // payload carries the list.
    units: unitsFrom(d.units),
    lengthDiscounts: discountRowsFrom(d.lengthDiscounts, "minNights"),
    guestDiscounts: discountRowsFrom(d.guestDiscounts, "minGuests"),
    nightMin: num(d.minNights, 1),
    // 0 in the editor means "no limit"; the model requires a number, so an
    // unset maximum becomes a year rather than a zero that reads as "no nights".
    nightMax: num(d.nightMax) && num(d.nightMax) > 0 ? num(d.nightMax) : 365,
    // Only the "additional fee" option carries a fee; any other choice
    // (including "by arrangement with the owner") saves 0.
    petFeePerNight:
      pairFor("pet", d.pet)?.en === "Allowed with an additional fee" ? num(d.petFeePerNight, 0) : 0,
    cancellationPolicyType: str(d.cancellationPolicyType) || "standard",

    // Which connected Stripe account this property pays out to. Chosen in the
    // editor's payout step; the model decides bookability from it.
    payoutStripeAccountId: str(d.payoutStripeAccountId),

    // Arrival and departure. The editor's two required times are the earliest
    // arrival and the latest departure; the optional pair fills the other ends.
    arrivalFrom: str(d.checkIn),
    arrivalTo: str(d.arrivalTo),
    departureFrom: str(d.departureFrom),
    departureTo: str(d.checkOut),

    // Amenities, one field per group. The editor's flat `amenities` list is
    // deliberately NOT written back: it is a derived convenience for the
    // publish check and has no column on the model.
    ...Object.fromEntries(
      AMENITY_GROUP_FIELDS.map((field) => [field, pairListFor(field, d[field])]),
    ),

    // House rules.
    checkIn: pairListFor("checkIn", d.checkInMethods),
    meals: pairListFor("meals", d.meals),
    pet: pairFor("pet", d.pet) || undefined,
    smoking: pairFor("smoking", d.smoking) || undefined,
    partyOrganizing: pairFor("partyOrganizing", d.partyOrganizing) || undefined,

    images: photoUrls(d.photoUrls),
  };

  // Drop keys that came out undefined so they never clear a value the model
  // already holds when this is applied to an existing document.
  for (const [key, value] of Object.entries(mapped)) {
    if (value === undefined) delete mapped[key];
  }

  return mapped;
};

/* ------------------------------------------------------------------------ */
/* The way back                                                              */
/* ------------------------------------------------------------------------ */

/** The host-facing value of an `{ en, sk }` pair, or undefined. */
const valueOfPair = (pair) => {
  if (!pair || typeof pair !== "object") return undefined;
  return str(pair.en) ?? str(pair.sk);
};

/** The values of a multi-select stored as two parallel arrays. */
const valuesOfPairList = (pair) => {
  const list = Array.isArray(pair?.en) && pair.en.length ? pair.en : pair?.sk;
  return (Array.isArray(list) ? list : []).filter((value) => typeof value === "string" && value.trim());
};

/**
 * Turn an `Accommodation` back into an editor payload — the inverse of
 * `mapListingToAccommodation`.
 *
 * Needed to open a listing that has no workspace draft behind it: everything
 * added through the traveller-side Profile form, and everything that predates
 * the workspace editor. Those appeared in Listings as read-only "legacy" rows
 * offering nothing but a link to their calendar, because the wizard only knows
 * how to open a real draft. This builds one from the listing itself.
 *
 * Faithfulness matters more here than anywhere else in this file. A draft
 * adopted from a LIVE listing is mirrored straight back onto that document on
 * the host's first save (`updateHostAccommodation`), so a field this function
 * forgets is not merely missing from the editor — it is blanked on a listing
 * that is taking bookings. `mapListingToAccommodation` drops top-level
 * undefined keys, which covers the flat fields, but `locationDetails`,
 * `location` and every `pairListFor` group are rebuilt wholesale on the way
 * back, so anything omitted from those is actively cleared. The round-trip is
 * covered by a test for exactly that reason.
 *
 * Pairs are read back in the host's own language via their `.en` side, which
 * `pairFor` matches against either enum, so a value survives the round trip.
 */
export const mapAccommodationToListing = (accommodation = {}) => {
  const a = accommodation && typeof accommodation === "object" ? accommodation : {};
  const loc = a.locationDetails || {};
  const geo = a.location || {};
  const calendarFeeds = calendarFeedsOf(a);

  // Read once, then reused below for both the per-group fields and the flat
  // list the publish check counts.
  const amenityGroups = Object.fromEntries(
    AMENITY_GROUP_FIELDS.map((field) => [field, valuesOfPairList(a[field])]),
  );

  // The editor's two required times, which also decide `availabilityConfirmed`
  // below. Note the crossing described on `checkIn` in the payload.
  const checkInTime = str(a.arrivalFrom);
  const checkOutTime = str(a.departureTo);

  const mapped = {
    name: str(a.name),
    description: str(a.description),
    specialNote: str(a.specialNote),
    nameEn: str(a.translations?.en?.name),
    descriptionEn: str(a.translations?.en?.description),
    specialNoteEn: str(a.translations?.en?.specialNote),
    virtualTourUrl: str(a.virtualTourUrl),
    propertyType: valueOfPair(a.propertyType),
    rentalform: valueOfPair(a.rentalform),

    // Address: flat in the editor, nested on the model.
    street: str(loc.streetAndNumber) ?? str(geo.address),
    roomNumber: str(loc.roomNumber),
    city: str(loc.city),
    zipCode: str(loc.zipCode),
    country: str(loc.country),
    state: str(loc.state),
    latitude: num(geo.latitude),
    longitude: num(geo.longitude),
    phoneNumber: str(a.phoneNumber),

    // Capacity.
    guests: num(a.person),
    bedrooms: num(a.bedroom),
    beds: num(a.beds),
    bathrooms: num(a.bathroom),
    singlebed: num(a.singlebed),
    doublebed: num(a.doublebed),
    bunkbed: num(a.bunkbed, 0),
    sofa: num(a.Sofa),
    kitchen: num(a.kitchen),
    wcs: num(a.WCs),
    livingRoom: num(a.LivingRoom),
    commonRoom: num(a.CommonRoom),
    socialRoom: num(a.SocialRoom),
    acreage: str(a.acreage),

    // Money and stay length.
    nightlyPrice: num(a.pricePerNight),
    pricePerPerson: num(a.pricePerPerson),
    weekendPricePerNight: num(a.weekendPricePerNight),
    weekendDays: Array.isArray(a.weekendDays) && a.weekendDays.length ? weekendDaysFrom(a.weekendDays) : undefined,
    includedGuests: num(a.includedGuests),
    cleaningFee: num(a.cleaningFee),
    localTaxPerPersonNight: num(a.localTaxPerPersonNight),
    paidExtras: Array.isArray(a.paidExtras) && a.paidExtras.length ? paidExtrasOf(a.paidExtras) : undefined,
    discount: num(a.discount),
    // Only when the listing has offers, so an adopted draft without any keeps
    // no key and the first save leaves the field as it is.
    flexiblePrices:
      Array.isArray(a.flexiblePrices) && a.flexiblePrices.length
        ? flexiblePricesOf(a.flexiblePrices)
        : undefined,
    // Only when the listing has units, for the same reason as the offers.
    units: Array.isArray(a.units) && a.units.length ? unitsOf(a.units) : undefined,
    lengthDiscounts:
      Array.isArray(a.lengthDiscounts) && a.lengthDiscounts.length
        ? discountRowsOf(a.lengthDiscounts, "minNights")
        : undefined,
    guestDiscounts:
      Array.isArray(a.guestDiscounts) && a.guestDiscounts.length
        ? discountRowsOf(a.guestDiscounts, "minGuests")
        : undefined,
    minNights: num(a.nightMin),
    nightMax: num(a.nightMax),
    petFeePerNight: num(a.petFeePerNight),
    cancellationPolicyType: str(a.cancellationPolicyType),
    payoutStripeAccountId: str(a.payoutStripeAccountId),
    offeredOnOtherPlatforms: a.offeredOnOtherPlatforms,

    // Arrival and departure. Note the crossing: the editor's `checkIn` is a
    // TIME (the model's `arrivalFrom`), while the model's `checkIn` is the
    // pair-list of arrival METHODS (the editor's `checkInMethods`).
    checkIn: checkInTime,
    arrivalTo: str(a.arrivalTo),
    departureFrom: str(a.departureFrom),
    checkOut: checkOutTime,

    // Amenities, one group per field.
    ...amenityGroups,

    // The flat list `evaluateListing` counts for the "at least one amenity"
    // rule. The editor maintains it as a side effect of ticking a box
    // (EditorSteps.js -> Amenities.toggle), so a listing that was never built
    // in the editor — every bulk import, and everything added through the
    // traveller-side Profile form — arrived with all eight groups populated
    // and this list empty, and the amenities step reported "Select at least
    // one amenity" over a screen of ticked boxes. Deriving it here is what
    // makes an adopted listing agree with itself.
    amenities: [...new Set(Object.values(amenityGroups).flat())],

    // House rules.
    checkInMethods: valuesOfPairList(a.checkIn),
    meals: valuesOfPairList(a.meals),
    pet: valueOfPair(a.pet),
    smoking: valueOfPair(a.smoking),
    partyOrganizing: valueOfPair(a.partyOrganizing),

    photoUrls: photoUrls(a.images),

    // The iCal links the calendar section already holds, so the editor's
    // step 8 shows what is actually connected instead of an empty list that
    // would then be synced back as "the host removed every feed".
    calendarFeeds,

    // The wizard's two confirmation ticks.
    //
    // They are gates for a host BUILDING a listing — the point is to make
    // someone look at the arrival times and the payout account before going
    // live. Asked of a listing that already exists and is already taking
    // bookings, the same question has been answered by the listing itself, and
    // leaving them unticked is what held every adopted draft at 67% with
    // "Confirm that your availability is up to date" and "Acknowledge the
    // payout status" against a property that has been live for months.
    //
    // `availabilityConfirmed` follows the times rather than being asserted
    // flat: a listing genuinely missing an arrival or departure time has not
    // had its availability confirmed by anything, and the host should still be
    // asked. Both remain editable — this sets the starting value of a tick the
    // host can clear, it does not remove the step.
    availabilityConfirmed: checkInTime && checkOutTime ? true : undefined,
    payoutAcknowledged: true,
  };

  for (const [key, value] of Object.entries(mapped)) {
    if (value === undefined) delete mapped[key];
  }

  return preserveLegacyPlatformOffer(mapped);
};

/**
 * The list-row payload for a legacy Accommodation that has no HostListing yet.
 * Keep the editor-relevant integrations here too, so legacy rows can surface
 * existing calendars and payout selection without trying to infer either from
 * status or silently dropping the connected feeds.
 */
export const mapLegacyAccommodationData = (accommodation = {}) => {
  const a = accommodation && typeof accommodation === "object" ? accommodation : {};
  return preserveLegacyPlatformOffer({
    name: str(a.name) ?? "",
    photoUrls: Array.isArray(a.images) ? a.images : [],
    street: str(a.locationDetails?.streetAndNumber) ?? "",
    city: str(a.locationDetails?.city) ?? "",
    country: str(a.locationDetails?.country) ?? "",
    nightlyPrice: num(a.pricePerNight, 0),
    calendarFeeds: calendarFeedsOf(a),
    payoutStripeAccountId: str(a.payoutStripeAccountId) ?? null,
    offeredOnOtherPlatforms: a.offeredOnOtherPlatforms,
  });
};