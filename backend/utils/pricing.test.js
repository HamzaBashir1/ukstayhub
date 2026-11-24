// Paid extras in the authoritative price. Plain objects only — no database.
import test from "node:test";
import assert from "node:assert/strict";
import { quoteStay, paidExtrasQuote, extrasSummary } from "./pricing.js";

const listing = {
  pricePerNight: 100,
  paidExtras: [
    { field: "wellnessAmenities", amenity: { en: "Hot Tub", sk: "Vírivka" }, pricing: "per_night", price: 30 },
    { field: "wellnessAmenities", amenity: { en: "Sauna", sk: "Sauna" }, pricing: "per_stay", price: 50 },
  ],
  lengthDiscounts: [{ minNights: 2, percent: 10 }],
};
const stay = { checkInDate: "2026-12-23", checkOutDate: "2026-12-27", adults: 2 };

test("extras are charged only when picked: per night × nights, or once per stay; never discounted", () => {
  // 4 nights × €100 = 400, −10 % = 360.
  assert.equal(quoteStay(listing, stay).totalCents, 36000);
  const q = quoteStay(listing, { ...stay, extras: ["Hot Tub", "Sauna"] });
  assert.equal(q.totalCents, 36000 + 4 * 3000 + 5000);
  assert.equal(q.breakdown.extrasCents, 17000);
  assert.deepEqual(q.breakdown.extras.map((e) => [e.name.en, e.totalCents]), [["Hot Tub", 12000], ["Sauna", 5000]]);
});

test("an extra the listing does not offer, or a Slovak name, is handled from the listing alone", () => {
  assert.equal(paidExtrasQuote(listing, ["Pool", "Vírivka"], 2).totalCents, 6000);
  assert.equal(paidExtrasQuote({}, ["Hot Tub"], 2).totalCents, 0);
});

test("email line", () => {
  const { lines } = paidExtrasQuote(listing, ["Hot Tub", "Sauna"], 4);
  assert.equal(extrasSummary(lines, "gbp"), "Hot Tub £30/night · £120, Sauna £50/stay");
  assert.equal(extrasSummary(lines, "eur"), "Hot Tub €30/night · €120, Sauna €50/stay");
  assert.equal(extrasSummary(undefined), "");
});
