// utils/pricing.js
//
// Authoritative booking price. Until this existed the amount came straight from
// the request body (`new Reservation(req.body)`), so a guest could book a 500
// EUR stay for 1 EUR and every downstream number — platform fee, host payout,
// refund, DAC7 consideration — inherited the forged figure.
//
// The rules below deliberately mirror the browser's calculation in
// `frontend/src/app/Checkout/page.js` so the guest is never charged something
// different from what they were shown. If the two ever diverge, THIS file wins
// and the divergence is logged: the listing's own configuration is the truth,
// not whatever the client posted.
//
// Precedence for a single night, highest first:
//   1. flexiblePrices  — seasonal period + length-of-stay tier (+ optional
//      guest range, counted as paying guests: adults + children)
//   2. effective nightly rate — max(pricePerNight, pricePerPerson x paying guests)
//
// Weekend nights: a night whose weekday is in `weekendDays` (0 = Sunday …
// 6 = Saturday, the day the night STARTS; default Friday + Saturday) is charged
// `weekendPricePerNight` instead of `pricePerNight`, and inside an offer the
// row's `weekendPrice` instead of its `price`. Unset or 0 means no weekend rate.
//
// Guests included in the price: when `includedGuests` is above 0 the nightly
// price (regular or offer) covers that many paying guests, and each guest above
// it pays an extra-bed rate per night on top — the offer's `extraPerPerson`
// when it has one, otherwise the listing's `pricePerPerson`. Listings without
// `includedGuests` keep the max(...) rule above, so nothing already live changes.
//
// On top of the nights: the pet fee (per night, only with a pet — never
// multiplied by the number of pets), the cleaning fee (once per stay) and the
// local tax (per paying guest per night).
//
// The legacy `specialPrice` offer is intentionally NOT applied: the checkout
// page builds its offer list as an empty array, so honouring it here would
// produce a total the guest never saw.

import { calendarDateUtc } from "./timezone.js";

/**
 * The calendar day a value represents, as UTC midnight.
 *
 * Uses the shared calendar-date helper rather than re-reading the instant in the
 * business timezone: a guest whose browser serialised local midnight would
 * otherwise have every night of their stay shifted a day, which moves seasonal
 * rates onto the wrong dates.
 *
 * Returns null for anything unparseable — a missing or malformed date must
 * surface as a refused quote, not a 500 from deep inside date-fns.
 */
const dateOnly = (value) => {
  if (value === null || value === undefined || value === "") return null;
  return calendarDateUtc(value);
};

/**
 * Nights between two dates. A one-night stay is check-out minus check-in = 1.
 * Returns 0 when either date is missing or unparseable, which callers treat as
 * an unpriceable stay.
 */
export function nightsBetween(checkIn, checkOut) {
  const start = dateOnly(checkIn);
  const end = dateOnly(checkOut);
  if (!start || !end) return 0;

  return Math.max(0, Math.round((end - start) / 86400000));
}

const hasValue = (value) => value !== null && value !== undefined && value !== "";

/** Nights that start on these weekdays are weekend nights unless the host picks others. */
export const DEFAULT_WEEKEND_DAYS = [5, 6]; // Friday and Saturday nights

/** The listing's weekend weekdays (0 = Sunday … 6 = Saturday). */
export function weekendDaysOf(listing) {
  const days = (Array.isArray(listing?.weekendDays) ? listing.weekendDays : [])
    .map(Number)
    .filter((day) => Number.isInteger(day) && day >= 0 && day <= 6);
  return days.length ? [...new Set(days)] : DEFAULT_WEEKEND_DAYS;
}

/** Whether the night starting on `day` (UTC midnight) is a weekend night. */
const isWeekendNight = (listing, day) => weekendDaysOf(listing).includes(day.getUTCDay());

/**
 * Paying guests above what the nightly price covers. 0 for listings without
 * `includedGuests`, which use the legacy per-person rule instead.
 */
export function extraGuestsFor(listing, guests) {
  const included = Number(listing?.includedGuests) || 0;
  if (!(included > 0)) return 0;
  return Math.max(0, (Number(guests) || 0) - included);
}

/**
 * Price of one night outside every offer: the weekday or weekend base, plus
 * extra guests (with `includedGuests`) or the legacy per-person floor.
 */
export function regularNightPrice(listing, date, guests) {
  const day = dateOnly(date);
  const weekendRate = Number(listing?.weekendPricePerNight) || 0;
  const base =
    day && weekendRate > 0 && isWeekendNight(listing, day) ? weekendRate : Number(listing?.pricePerNight) || 0;
  const perPerson = Number(listing?.pricePerPerson) || 0;
  const payingGuests = Number(guests) || 0;

  if (Number(listing?.includedGuests) > 0) {
    return base + perPerson * extraGuestsFor(listing, payingGuests);
  }
  return perPerson > 0 && payingGuests > 0 ? Math.max(base, perPerson * payingGuests) : base;
}

/**
 * Whether `guests` falls inside a tier's optional guest range. A tier with no
 * range applies to any party size; an unknown party size (0) only matches
 * tiers without a range, so a guest-limited offer is never applied blind.
 */
function tierMatchesGuests(tier, guests) {
  const hasMin = hasValue(tier?.minGuests) && Number(tier.minGuests) > 0;
  const hasMax = hasValue(tier?.maxGuests) && Number(tier.maxGuests) > 0;
  if (!hasMin && !hasMax) return true;
  if (!(guests > 0)) return false;

  const min = hasMin ? Number(tier.minGuests) : 1;
  const max = hasMax ? Number(tier.maxGuests) : Infinity;
  return guests >= min && guests <= max;
}

/**
 * Pick the tier whose night range contains `totalNights` (no max = unbounded),
 * preferring one whose guest range, if any, contains `guests`.
 */
function findTierForStay(tiers, totalNights, guests) {
  if (!Array.isArray(tiers)) return null;

  const fitsNights = (tier) => {
    const price = Number(tier?.price);
    if (!Number.isFinite(price) || price <= 0) return false;

    const min = Number(tier?.minNights) || 1;
    const max = hasValue(tier?.maxNights) ? Number(tier.maxNights) : Infinity;
    return totalNights >= min && totalNights <= max;
  };

  // Dates inside an offer always get the offer's price. The stay length and
  // party size only choose BETWEEN its rows: best is a row that fits both, then
  // one that fits the stay length, then (a stay longer or shorter than every
  // row) the closest row by nights, preferring one meant for this party. A stay
  // that fits no row is refused at booking by the offer's night rules, but its
  // nights are still shown at the offer's price, never the regular one.
  const priced = tiers.filter((tier) => Number(tier?.price) > 0);
  const nightsDistance = (tier) => {
    const min = Number(tier?.minNights) || 1;
    const max = hasValue(tier?.maxNights) ? Number(tier.maxNights) : Infinity;
    return totalNights < min ? min - totalNights : totalNights > max ? totalNights - max : 0;
  };
  const closest = (rows) =>
    rows.reduce((best, tier) => (!best || nightsDistance(tier) < nightsDistance(best) ? tier : best), null);

  return (
    priced.find((tier) => fitsNights(tier) && tierMatchesGuests(tier, guests)) ||
    priced.find(fitsNights) ||
    closest(priced.filter((tier) => tierMatchesGuests(tier, guests))) ||
    closest(priced) ||
    null
  );
}

/**
 * Resolver for one booking: date -> seasonal rate, or null.
 * The tier depends on the length of the WHOLE stay and the party size, not on
 * where the night falls within it, so it is resolved once per period rather
 * than per night.
 */
export function buildFlexiblePriceResolver(listing, totalNights, guests = 0) {
  const periods = Array.isArray(listing?.flexiblePrices) ? listing.flexiblePrices : [];
  const nights = Number(totalNights) || 0;
  const partySize = Number(guests) || 0;

  if (!periods.length || nights <= 0) return () => null;

  const resolved = periods
    .map((period) => {
      if (!period?.start || !period?.end) return null;

      const tier = findTierForStay(period.tiers, nights, partySize);
      if (!tier) return null;

      // Extra-bed rate inside this offer: its own when set (0 = free), else the listing's.
      const extraRate = hasValue(period.extraPerPerson)
        ? Math.max(0, Number(period.extraPerPerson) || 0)
        : Number(listing?.pricePerPerson) || 0;

      return {
        name: period.name || "",
        weekdayPrice: Number(tier.price),
        weekendPrice: Number(tier.weekendPrice) > 0 ? Number(tier.weekendPrice) : Number(tier.price),
        extraCharge: extraRate * extraGuestsFor(listing, partySize),
        // Missing on offers saved before the flag existed: discounts apply.
        applyDiscounts: period.applyDiscounts !== false,
        startDate: dateOnly(period.start),
        endDate: dateOnly(period.end),
      };
    })
    .filter(Boolean);

  if (!resolved.length) return () => null;

  return (date) => {
    const day = dateOnly(date);
    if (!day) return null;
    // End date is inclusive: a period ending 31 Aug covers the night of 31 Aug.
    const match = resolved.find((p) => day >= p.startDate && day <= p.endDate);
    if (!match) return null;
    // `price` is THIS night's full price: weekday or weekend row price plus extra beds.
    const nightly = isWeekendNight(listing, day) ? match.weekendPrice : match.weekdayPrice;
    return { ...match, price: nightly + match.extraCharge };
  };
}

/**
 * Decide a stay length against a list of rules, each `{ offerName, ranges }`
 * where a range is `[minNights, maxNights]`. The stay must fit one range of
 * EVERY rule. Shared by the server and (as a copy) the browser.
 */
export function judgeStayLength(nights, rules) {
  for (const rule of rules) {
    if (rule.ranges.some(([min, max]) => nights >= min && nights <= max)) continue;

    const min = Math.min(...rule.ranges.map(([low]) => low));
    const max = Math.max(...rule.ranges.map(([, high]) => high));
    return {
      ok: false,
      reason: nights < min ? "too_short" : nights > max ? "too_long" : "not_offered",
      min,
      max,
      offerName: rule.offerName,
      ranges: rule.ranges,
    };
  }
  return { ok: true };
}

/**
 * The stay-length rule for one booking.
 *
 * A flexible-price offer replaces the listing's own min/max nights for every
 * stay that has at least one night inside the offer's dates: the stay must fit
 * one of that offer's price rows (min..max nights). A row's blank max falls
 * back to the listing's maximum. Guest ranges only decide the price, not the
 * stay length, so every priced row counts whatever the party size. A stay
 * touching two offers must fit both. Stays touching no offer keep the
 * listing's `nightMin`..`nightMax`.
 *
 * @returns {{ ok: boolean, reason?: "too_short"|"too_long"|"not_offered", min?, max?, offerName?, ranges? }}
 */
// `guests` is accepted for symmetry with the price helpers but deliberately
// unused: an offer's night rules apply to every party.
// eslint-disable-next-line no-unused-vars
export function checkStayLength(listing, checkIn, checkOut, guests, listingMin, listingMax) {
  const nights = nightsBetween(checkIn, checkOut);
  const first = dateOnly(checkIn);
  const listingRule = { offerName: null, ranges: [[listingMin, listingMax]] };
  if (nights <= 0 || !first) return judgeStayLength(nights, [listingRule]);

  const lastNight = new Date(first.getTime() + (nights - 1) * 86400000);
  const periods = Array.isArray(listing?.flexiblePrices) ? listing.flexiblePrices : [];

  const offerRules = periods
    .map((period) => {
      const start = dateOnly(period?.start);
      const end = dateOnly(period?.end);
      if (!start || !end || lastNight < start || first > end) return null;

      const ranges = (Array.isArray(period.tiers) ? period.tiers : [])
        .filter((tier) => Number(tier?.price) > 0)
        .map((tier) => [
          Number(tier?.minNights) || 1,
          hasValue(tier?.maxNights) && Number(tier.maxNights) > 0 ? Number(tier.maxNights) : listingMax,
        ]);
      return ranges.length ? { offerName: period.name || "", ranges } : null;
    })
    .filter(Boolean);

  return judgeStayLength(nights, offerRules.length ? offerRules : [listingRule]);
}

/** Cap on a length + guest discount together. */
export const MAX_STAY_DISCOUNT_PERCENT = 90;

/** Percent of the row with the highest `key` threshold that `value` reaches. */
function bestDiscountPercent(rows, key, value) {
  let best = null;
  for (const row of Array.isArray(rows) ? rows : []) {
    const threshold = Number(row?.[key]);
    const percent = Number(row?.percent);
    if (!(threshold > 0) || !(percent > 0) || value < threshold) continue;
    if (!best || threshold > best.threshold || (threshold === best.threshold && percent > best.percent)) {
      best = { threshold, percent };
    }
  }
  return best ? Math.min(best.percent, MAX_STAY_DISCOUNT_PERCENT) : 0;
}

/**
 * The host's length-of-stay and guest-count discounts for one stay.
 *
 * Applies to the nights' price only. In each list the row with the highest
 * threshold reached wins; the two percentages add up, capped at 90 %. A
 * listing without discount rows gets 0 %, so it is priced exactly as before.
 * Mirrored in `frontend/src/app/utlis/stayDiscount.js`.
 *
 * @returns {{ percent, nightPercent, guestPercent, amount }} amount in euros, 2 dp
 */
export function stayDiscount(listing, nights, guests, accommodationTotal) {
  const nightPercent = bestDiscountPercent(listing?.lengthDiscounts, "minNights", Number(nights) || 0);
  const guestPercent = bestDiscountPercent(listing?.guestDiscounts, "minGuests", Number(guests) || 0);
  const percent = Math.min(nightPercent + guestPercent, MAX_STAY_DISCOUNT_PERCENT);
  const amount = percent > 0 ? Math.round((Number(accommodationTotal) || 0) * percent) / 100 : 0;
  return { percent, nightPercent, guestPercent, amount };
}

/**
 * The paid extras (hot tub, sauna, …) the guest picked, priced from the
 * listing. `selected` holds amenity values in either language; anything not
 * offered for a price is ignored, so a client cannot invent an extra or its
 * price. Per night × nights, or once per stay. Mirrored in
 * `frontend/src/app/utlis/paidExtras.js`.
 *
 * @returns {{ lines: object[], totalCents: number }}
 */
export function paidExtrasQuote(listing, selected, nights) {
  const wanted = new Set((Array.isArray(selected) ? selected : [selected]).filter(Boolean).map(String));
  const lines = (Array.isArray(listing?.paidExtras) ? listing.paidExtras : [])
    .filter((extra) => Number(extra?.price) > 0 && (wanted.has(extra?.amenity?.en) || wanted.has(extra?.amenity?.sk)))
    .map((extra) => {
      const priceCents = Math.round(Number(extra.price) * 100);
      const perNight = extra.pricing === "per_night";
      return {
        name: { en: extra.amenity.en, sk: extra.amenity.sk },
        pricing: perNight ? "per_night" : "per_stay",
        priceCents,
        totalCents: perNight ? priceCents * nights : priceCents,
      };
    });
  return { lines, totalCents: lines.reduce((sum, line) => sum + line.totalCents, 0) };
}

/**
 * A reservation's extras as one line for emails: "Hot Tub €30/night · €120, Sauna €50/stay".
 * Empty string when there are none.
 */
export function extrasSummary(extras, lang = "sk") {
  const en = lang === "en";
  const euros = (cents) => `€${((Number(cents) || 0) / 100).toFixed(2).replace(/\.00$/, "")}`;
  return (Array.isArray(extras) ? extras : [])
    .map((extra) => {
      const name = (en ? extra?.name?.en : extra?.name?.sk) || extra?.name?.en || "";
      return extra?.pricing === "per_night"
        ? `${name} ${euros(extra.priceCents)}/${en ? "night" : "noc"} · ${euros(extra.totalCents)}`
        : `${name} ${euros(extra?.totalCents)}/${en ? "stay" : "pobyt"}`;
    })
    .join(", ");
}

/**
 * Price a stay from the listing itself.
 *
 * @param {object} listing  Accommodation document
 * @param {object} stay     { checkInDate, checkOutDate, adults, children, infants, withPet, extras }
 * @returns {{ ok: boolean, error?: string, totalCents: number, breakdown: object }}
 */
export function quoteStay(listing, stay) {
  const nights = nightsBetween(stay.checkInDate, stay.checkOutDate);

  if (!listing) {
    return { ok: false, error: "listing_not_found", totalCents: 0, breakdown: {} };
  }
  if (nights <= 0) {
    return { ok: false, error: "check_out_must_follow_check_in", totalCents: 0, breakdown: {} };
  }

  const basePrice = Number(listing.pricePerNight) || 0;
  const perPersonRate = Number(listing.pricePerPerson) || 0;

  // Infants do not count towards the per-person rate, matching the checkout page.
  const payingGuests = (Number(stay.adults) || 0) + (Number(stay.children) || 0);

  // Weekday rate for the breakdown; each night below is priced on its own
  // (weekend nights may differ).
  const effectiveNightly =
    Number(listing.includedGuests) > 0
      ? basePrice + perPersonRate * extraGuestsFor(listing, payingGuests)
      : perPersonRate > 0 && payingGuests > 0
        ? Math.max(basePrice, perPersonRate * payingGuests)
        : basePrice;

  const resolveFlexible = buildFlexiblePriceResolver(listing, nights, payingGuests);

  // Non-null: nights > 0 already proves both dates parsed.
  const start = dateOnly(stay.checkInDate);
  let accommodationTotal = 0;
  let seasonalNights = 0;
  // Nights priced by an offer whose host turned discounts off.
  let undiscountedTotal = 0;

  for (let i = 0; i < nights; i++) {
    const night = new Date(start.getTime() + i * 86400000);
    const seasonal = resolveFlexible(night);

    if (seasonal) {
      accommodationTotal += seasonal.price;
      seasonalNights++;
      if (!seasonal.applyDiscounts) undiscountedTotal += seasonal.price;
    } else {
      accommodationTotal += regularNightPrice(listing, night, payingGuests);
    }
  }

  // The pet fee applies only when the guest said at checkout they are bringing
  // a pet; a guest without one pays the stay alone.
  const withPet = stay.withPet === true || stay.withPet === "true";
  const petFeePerNight = withPet ? Number(listing.petFeePerNight) || 0 : 0;
  const petFeeTotal = petFeePerNight > 0 ? petFeePerNight * nights : 0;

  // Optional host extras. The cleaning fee is charged once per stay; the local
  // tax per paying guest per night. Neither depends on the number of pets.
  const cleaningFee = Math.max(0, Number(listing.cleaningFee) || 0);
  const localTaxPerPersonNight = Math.max(0, Number(listing.localTaxPerPersonNight) || 0);
  const localTaxTotal = localTaxPerPersonNight * payingGuests * nights;

  // Host discounts come off the nights only, never the fees, and not off
  // nights of an offer that opted out of them.
  const discount = stayDiscount(listing, nights, payingGuests, accommodationTotal - undiscountedTotal);

  // Extras the guest picked; like the fees, never discounted.
  const extras = paidExtrasQuote(listing, stay.extras, nights);

  // Round once, at the end, and only into cents. Every consumer downstream works
  // in integer cents from here on.
  const totalCents =
    Math.round((accommodationTotal - discount.amount + petFeeTotal + cleaningFee + localTaxTotal) * 100) +
    extras.totalCents;

  if (totalCents <= 0) {
    return { ok: false, error: "listing_has_no_price", totalCents: 0, breakdown: { nights } };
  }

  return {
    ok: true,
    totalCents,
    breakdown: {
      nights,
      payingGuests,
      includedGuests: Number(listing.includedGuests) > 0 ? Number(listing.includedGuests) : 0,
      extraGuests: extraGuestsFor(listing, payingGuests),
      weekendPricePerNightCents: Math.round((Number(listing.weekendPricePerNight) || 0) * 100),
      basePriceCents: Math.round(basePrice * 100),
      perPersonRateCents: Math.round(perPersonRate * 100),
      effectiveNightlyCents: Math.round(effectiveNightly * 100),
      seasonalNights,
      withPet,
      accommodationCents: Math.round(accommodationTotal * 100),
      discountPercent: discount.percent,
      lengthDiscountPercent: discount.nightPercent,
      guestDiscountPercent: discount.guestPercent,
      discountCents: Math.round(discount.amount * 100),
      petFeePerNightCents: Math.round(petFeePerNight * 100),
      petFeeCents: Math.round(petFeeTotal * 100),
      cleaningFeeCents: Math.round(cleaningFee * 100),
      localTaxPerPersonNightCents: Math.round(localTaxPerPersonNight * 100),
      localTaxCents: Math.round(localTaxTotal * 100),
      extras: extras.lines,
      extrasCents: extras.totalCents,
      averageNightlyCents: Math.round((accommodationTotal / nights) * 100),
    },
  };
}

/**
 * Compare what the client claimed against what the listing actually costs.
 * A tolerance of one cent absorbs float rounding in the browser; anything
 * larger is a real divergence worth surfacing.
 */
export function priceMismatch(clientCents, serverCents) {
  const claimed = Math.round(Number(clientCents) || 0);
  if (!claimed) return null;

  const delta = claimed - serverCents;
  if (Math.abs(delta) <= 1) return null;

  return {
    claimedCents: claimed,
    serverCents,
    deltaCents: delta,
    // Negative delta is the direction that costs money: the client asked to pay
    // less than the listing charges.
    direction: delta < 0 ? "underpaid" : "overpaid",
  };
}
