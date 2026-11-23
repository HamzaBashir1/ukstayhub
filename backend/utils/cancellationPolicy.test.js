import test from "node:test";
import assert from "node:assert/strict";
import {
  getPolicyNameSnapshot,
  getTiersSnapshot,
  isNewYearSpecialDate,
} from "./cancellationPolicy.js";

const specialListing = { cancellationPolicyType: "new_year_special" };

test("New Year special dates are inclusive and recur across calendar years", () => {
  for (const date of ["2026-12-28", "2026-12-31", "2027-01-02"]) {
    assert.equal(isNewYearSpecialDate(new Date(`${date}T00:00:00.000Z`)), true);
  }
  for (const date of ["2026-12-27", "2027-01-03", "2027-06-01"]) {
    assert.equal(isNewYearSpecialDate(new Date(`${date}T00:00:00.000Z`)), false);
  }
});

test("New Year arrivals snapshot as non-refundable while other arrivals get 30 days", () => {
  assert.deepEqual(
    getTiersSnapshot(specialListing, new Date("2026-12-31T00:00:00.000Z")),
    [{ hoursBefore: 0, refundPercent: 0 }],
  );
  assert.deepEqual(
    getTiersSnapshot(specialListing, new Date("2027-06-01T00:00:00.000Z")),
    [
      { hoursBefore: 720, refundPercent: 100 },
      { hoursBefore: 0, refundPercent: 0 },
    ],
  );
  assert.equal(getPolicyNameSnapshot(specialListing), "new_year_special");
});
