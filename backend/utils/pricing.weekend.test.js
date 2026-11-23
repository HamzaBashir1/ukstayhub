// Weekend rates and "price covers N guests + extra beds". Plain objects only.
//
// Figures are Vila Kollár 16 from the host's 2027 price list: Winter
// (10.01.–12.02.2027) Fri–Sat €90, Sun–Thu €75, for 2 people, extra bed €20.
import test from "node:test";
import assert from "node:assert/strict";
import { quoteStay, regularNightPrice, weekendDaysOf } from "./pricing.js";

const winter = {
  name: "Zima",
  start: "2027-01-10",
  end: "2027-02-12",
  tiers: [{ minNights: 2, price: 75, weekendPrice: 90 }],
};
const vk16 = {
  pricePerNight: 75,
  weekendPricePerNight: 90,
  pricePerPerson: 20,
  includedGuests: 2,
  flexiblePrices: [winter],
};

// Thu 14 Jan → Sun 17 Jan 2027: nights Thu, Fri, Sat.
const stay = { checkInDate: "2027-01-14", checkOutDate: "2027-01-17" };

test("offer: weekday and weekend row prices, extra bed on top", () => {
  // 2 guests: 75 + 90 + 90
  assert.equal(quoteStay(vk16, { ...stay, adults: 2 }).totalCents, 25500);
  // 3 guests: + 3 nights × €20 extra bed
  assert.equal(quoteStay(vk16, { ...stay, adults: 3 }).totalCents, 31500);
  // 4 guests (2 + 2 extra beds)
  assert.equal(quoteStay(vk16, { ...stay, adults: 2, children: 2 }).totalCents, 25500 + 2 * 3 * 2000);
});

test("offer's own extra-bed price overrides the listing's", () => {
  const listing = { ...vk16, flexiblePrices: [{ ...winter, extraPerPerson: 25 }] };
  assert.equal(quoteStay(listing, { ...stay, adults: 3 }).totalCents, 25500 + 3 * 2500);
  const free = { ...vk16, flexiblePrices: [{ ...winter, extraPerPerson: 0 }] };
  assert.equal(quoteStay(free, { ...stay, adults: 3 }).totalCents, 25500);
});

test("outside offers: listing weekend price on the host's chosen days", () => {
  const listing = { ...vk16, flexiblePrices: [] };
  assert.equal(quoteStay(listing, { ...stay, adults: 2 }).totalCents, 25500);
  // Host whose weekend is Thursday + Friday nights.
  const thuFri = { ...listing, weekendDays: [4, 5] };
  assert.equal(quoteStay(thuFri, { ...stay, adults: 2 }).totalCents, (90 + 90 + 75) * 100);
  assert.deepEqual(weekendDaysOf({}), [5, 6]);
});

test("listings without the new fields are priced exactly as before", () => {
  const legacy = { pricePerNight: 100, pricePerPerson: 30 };
  // max(100, 30 × guests)
  assert.equal(regularNightPrice(legacy, "2027-01-15", 2), 100);
  assert.equal(regularNightPrice(legacy, "2027-01-15", 4), 120);
  assert.equal(quoteStay(legacy, { ...stay, adults: 4 }).totalCents, 3 * 12000);
  // An offer row without weekendPrice charges its price every night.
  const offer = { pricePerNight: 100, flexiblePrices: [{ ...winter, tiers: [{ minNights: 1, price: 80 }] }] };
  assert.equal(quoteStay(offer, { ...stay, adults: 5 }).totalCents, 3 * 8000);
});

test("discounts still come off the nights including extra beds", () => {
  const listing = { ...vk16, lengthDiscounts: [{ minNights: 3, percent: 5 }] };
  assert.equal(quoteStay(listing, { ...stay, adults: 3 }).totalCents, 31500 - 1575);
});
