// Paid extras through the editor <-> listing mapper, against the real schema enums.
import test from "node:test";
import assert from "node:assert/strict";
import { mapListingToAccommodation, mapAccommodationToListing } from "./accommodationMapper.js";

test("paid extras round-trip; rows for unticked amenities or without a price are dropped", () => {
  const data = {
    wellnessAmenities: ["Hot Tub", "Sauna"],
    paidExtras: [
      { field: "wellnessAmenities", amenity: "Hot Tub", pricing: "per_night", price: 30 },
      { field: "wellnessAmenities", amenity: "Vnútorný bazén", pricing: "per_stay", price: 20 }, // not ticked
      { field: "wellnessAmenities", amenity: "Sauna", pricing: "per_stay", price: 0 }, // no price
    ],
  };
  const stored = mapListingToAccommodation(data).paidExtras;
  assert.deepEqual(stored, [{ field: "wellnessAmenities", amenity: { en: "Hot Tub", sk: "Vírivka" }, pricing: "per_night", price: 30 }]);
  assert.deepEqual(mapAccommodationToListing({ paidExtras: stored }).paidExtras, [
    { field: "wellnessAmenities", amenity: "Hot Tub", pricing: "per_night", price: 30 },
  ]);
  // A draft without the list leaves the listing's extras alone.
  assert.equal("paidExtras" in mapListingToAccommodation({}), false);
});
