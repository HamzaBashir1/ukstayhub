import { test } from "node:test";
import assert from "node:assert/strict";
import { computeMarketStats } from "./marketStats.js";

const now = new Date("2026-10-06T00:00:00Z");

test("median price, pet share, wellness shares and rating", () => {
  const stats = computeMarketStats(
    [
      { pricePerNight: 60, pet: { en: "Allowed at no extra charge" }, wellnessAmenities: { en: ["Sauna"] }, averageRating: 5 },
      { pricePerNight: 80, pet: { en: "Not Allowed" }, wellnessAmenities: { en: ["Hot Tub", "Sauna"] }, averageRating: 4.6 },
      { pricePerNight: 100, pet: { en: "Allowed with an additional fee" }, wellnessAmenities: { en: ["None"] }, averageRating: 0 },
      { pricePerNight: 0, wellnessAmenities: { en: ["Outdoor Pool"] } },
    ],
    now
  );

  assert.equal(stats.listings, 4);
  assert.equal(stats.priceMedian, 80); // 0 is "no price", not a free stay
  assert.equal(stats.petPolicyKnown, 3);
  assert.equal(stats.petFriendlyShare, 67); // 2 of the 3 with a pet policy
  assert.equal(stats.saunaShare, 50);
  assert.equal(stats.hotTubShare, 25);
  assert.equal(stats.wellnessShare, 75); // sauna, hot tub or a pool
  assert.equal(stats.averageRating, 4.8); // unrated listings are left out
  assert.equal(stats.ratedListings, 2);
  assert.equal(stats.updatedAt, "2026-10-06T00:00:00.000Z");
});

test("even number of prices uses the middle two", () => {
  assert.equal(computeMarketStats([{ pricePerNight: 50 }, { pricePerNight: 71 }]).priceMedian, 61);
});

test("no listings gives zeros, which the frontend leaves out", () => {
  const stats = computeMarketStats([]);
  assert.equal(stats.listings, 0);
  assert.equal(stats.priceMedian, 0);
  assert.equal(stats.averageRating, 0);
});
