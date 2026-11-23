// utils/listingUnits.js
//
// Sub-units of a listing: "Apartments A" offering "A1" and "A2", each with its
// own price, capacity, amenities, photos and calendar.
//
// A unit only states what makes it different. Anything it leaves unset is the
// listing's, so `applyUnit` produces an ordinary listing-shaped object and every
// existing price and stay-length rule (utils/pricing.js) works on it unchanged.
//
// A listing without units is untouched by all of this: `listingUnits` is empty,
// no unit is ever applied, and every calendar row blocks it exactly as before.
//
// Mirrored in `frontend/src/app/utlis/listingUnits.js` so the guest is shown
// the figure the booking is charged. If the two diverge, this file wins.

export const UNIT_AMENITY_FIELDS = [
  "services",
  "bathroomAmenities",
  "kitchenDiningAmenities",
  "heatingCoolingAmenities",
  "safetyAmenities",
  "wellnessAmenities",
  "outdoorAmenities",
  "parkingFacilities",
];

const set = (value) => value !== null && value !== undefined && value !== "";
const positive = (value) => set(value) && Number.isFinite(Number(value)) && Number(value) > 0;
const nonNegative = (value) => set(value) && Number.isFinite(Number(value)) && Number(value) >= 0;

const plain = (doc) => (doc && typeof doc.toObject === "function" ? doc.toObject() : doc);

/** The listing's units that can be booked (named ones). */
export const listingUnits = (listing) =>
  (Array.isArray(listing?.units) ? listing.units : []).filter(
    (unit) => unit && typeof unit.name === "string" && unit.name.trim(),
  );

export const hasUnits = (listing) => listingUnits(listing).length > 0;

export const findUnit = (listing, unitId) => {
  if (!set(unitId)) return null;
  return listingUnits(listing).find((unit) => String(unit._id) === String(unitId)) || null;
};

const unitHasAmenities = (unit) =>
  UNIT_AMENITY_FIELDS.some((field) => {
    const pair = unit?.[field];
    return (Array.isArray(pair?.en) && pair.en.length) || (Array.isArray(pair?.sk) && pair.sk.length);
  });

/**
 * Does a calendar row take this unit's dates?
 *
 * A row without a unit belongs to the whole listing — a manual block, a night
 * imported from another platform, or any row on a listing without units — so
 * it takes every unit. A row for a unit takes only that unit. With no unit
 * asked about (a listing without units), every row counts, as it always has.
 */
export const rowBlocksUnit = (entry, unitId) => {
  if (!set(unitId)) return true;
  if (!set(entry?.unitId)) return true;
  return String(entry.unitId) === String(unitId);
};

/**
 * The unit fields a row imported from `feed` carries.
 *
 * A feed assigned to a unit stamps its rows with that unit, so they block only
 * it. A feed with no unit, or whose unit has since been removed from the
 * listing, stamps nothing and its rows block the whole listing — the safe side
 * when in doubt, and exactly what every feed did before units could be chosen.
 */
export const feedUnitStamp = (listing, feed) => {
  const unit = findUnit(listing, feed?.unitId);
  return unit ? { unitId: unit._id, unitName: unit.name } : {};
};

/**
 * The listing as the chosen unit is booked: the unit's own values where it has
 * them, the listing's everywhere else.
 *
 * A unit with its own nightly price is priced by its own seasonal offers only —
 * the listing's offers were set against the listing's price, so applying them to
 * a different unit would replace that unit's price with someone else's.
 */
export function applyUnit(listing, unit) {
  const base = plain(listing) || {};
  if (!unit) return base;
  const u = plain(unit);

  const ownPrice = positive(u.pricePerNight);
  const merged = {
    ...base,
    unitId: String(u._id),
    unitName: u.name,
    unitDescription: u.description || "",
    pricePerNight: ownPrice ? Number(u.pricePerNight) : base.pricePerNight,
    pricePerPerson: nonNegative(u.pricePerPerson) ? Number(u.pricePerPerson) : base.pricePerPerson,
    // The listing's weekend rate was set against the listing's price, so a unit
    // with its own price only gets a weekend rate it states itself.
    weekendPricePerNight: nonNegative(u.weekendPricePerNight)
      ? Number(u.weekendPricePerNight)
      : ownPrice ? 0 : base.weekendPricePerNight,
    includedGuests: nonNegative(u.includedGuests) ? Number(u.includedGuests) : base.includedGuests,
    cleaningFee: nonNegative(u.cleaningFee) ? Number(u.cleaningFee) : base.cleaningFee,
    flexiblePrices: ownPrice
      ? Array.isArray(u.flexiblePrices) ? u.flexiblePrices : []
      : base.flexiblePrices,
    person: positive(u.person) ? Number(u.person) : base.person,
    bedroom: positive(u.bedroom) ? Number(u.bedroom) : base.bedroom,
    beds: positive(u.beds) ? Number(u.beds) : base.beds,
    extraBeds: nonNegative(u.extraBeds) ? Number(u.extraBeds) : undefined,
    singlebed: nonNegative(u.singlebed) ? Number(u.singlebed) : undefined,
    doublebed: nonNegative(u.doublebed) ? Number(u.doublebed) : undefined,
    bunkbed: nonNegative(u.bunkbed) ? Number(u.bunkbed) : undefined,
    bathroom: positive(u.bathroom) ? Number(u.bathroom) : base.bathroom,
    LivingRoom: nonNegative(u.LivingRoom) ? Number(u.LivingRoom) : undefined,
    kitchen: nonNegative(u.kitchen) ? Number(u.kitchen) : undefined,
    occupancyCalendar: (Array.isArray(base.occupancyCalendar) ? base.occupancyCalendar : []).filter(
      (entry) => rowBlocksUnit(entry, u._id),
    ),
  };

  // Amenities: the unit's list replaces the listing's when it has one.
  if (unitHasAmenities(u)) {
    for (const field of UNIT_AMENITY_FIELDS) {
      merged[field] = {
        en: Array.isArray(u[field]?.en) ? u[field].en : [],
        sk: Array.isArray(u[field]?.sk) ? u[field].sk : [],
      };
    }
  }

  // Photos: the unit's first, then the shared ones.
  const unitImages = Array.isArray(u.images) ? u.images.filter(Boolean) : [];
  if (unitImages.length) {
    const shared = (Array.isArray(base.images) ? base.images : []).filter((url) => !unitImages.includes(url));
    merged.images = [...unitImages, ...shared];
  }

  return merged;
}
