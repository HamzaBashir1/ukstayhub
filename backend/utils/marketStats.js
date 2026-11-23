// utils/marketStats.js
//
// Putko's own numbers for a set of listings, shown as "Putko v číslach" on the
// landing pages (/ubytovanie, region, town, type and amenity pages): median
// nightly price, share of pet-friendly stays, share with a sauna / hot tub /
// pool, and the average guest rating. Published facts like these are what AI
// search engines quote, and nobody else has them.
//
// The response shape is what frontend/src/app/utils/landingPages.js
// (buildMarketFacts) reads.

const WELLNESS = ["Sauna", "Hot Tub", "Indoor Pool", "Outdoor Pool"];

/** Fields `computeMarketStats` needs; select only these. */
export const MARKET_STATS_FIELDS = "pricePerNight pet wellnessAmenities averageRating";

const percent = (part, whole) => (whole > 0 ? Math.round((part / whole) * 100) : 0);

const median = (values) => {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
};

/**
 * @param {Array<{pricePerNight?, pet?, wellnessAmenities?, averageRating?}>} listings
 * @param {Date} now
 */
export function computeMarketStats(listings, now = new Date()) {
  const prices = [];
  let petPolicyKnown = 0;
  let petFriendly = 0;
  let sauna = 0;
  let hotTub = 0;
  let wellness = 0;
  let ratingSum = 0;
  let rated = 0;

  for (const listing of listings) {
    const price = Number(listing.pricePerNight);
    if (price > 0) prices.push(price);

    const petPolicy = listing.pet?.en;
    if (petPolicy) {
      petPolicyKnown += 1;
      if (petPolicy.startsWith("Allowed")) petFriendly += 1;
    }

    const amenities = Array.isArray(listing.wellnessAmenities?.en) ? listing.wellnessAmenities.en : [];
    if (amenities.includes("Sauna")) sauna += 1;
    if (amenities.includes("Hot Tub")) hotTub += 1;
    if (amenities.some((item) => WELLNESS.includes(item))) wellness += 1;

    // An unrated listing stores 0; counting it would drag the average down
    // (that is how the home page once showed 3.4 instead of 4.8).
    const rating = Number(listing.averageRating);
    if (rating > 0) {
      ratingSum += rating;
      rated += 1;
    }
  }

  return {
    listings: listings.length,
    priceMedian: Math.round(median(prices)),
    petPolicyKnown,
    petFriendlyShare: percent(petFriendly, petPolicyKnown),
    saunaShare: percent(sauna, listings.length),
    hotTubShare: percent(hotTub, listings.length),
    wellnessShare: percent(wellness, listings.length),
    averageRating: rated ? Math.round((ratingSum / rated) * 10) / 10 : 0,
    ratedListings: rated,
    updatedAt: now.toISOString(),
  };
}
