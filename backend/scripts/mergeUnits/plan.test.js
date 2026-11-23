// Fake in-memory documents only — nothing here touches a database.
import test from "node:test";
import assert from "node:assert/strict";
import { planMerge, deriveUnitName, unitFromListing, matchHauziNames } from "./plan.js";

const now = new Date("2026-06-01T12:00:00Z");
let n = 0;
const newId = () => `new${++n}`;
const acc = (id, name, extra = {}) => ({
  _id: id, slug: id, name, userId: "host1", person: 4, bedroom: 2, doublebed: 1, singlebed: 2, beds: 0,
  pricePerNight: 100, nightMin: 2, description: `desc ${id}`, images: [`${id}.jpg`], occupancyCalendar: [], calendarSync: [], ...extra,
});
const identity = { _id: "p", name: "Apartmány Lubika", slug: "apartmany-lubika-2", description: "Hauzi text" };
const run = (over = {}) => planMerge({ olds: [acc("a", "Apartmány Lubika - Apartmán A"), acc("b", "Apartmány Lubika - Apartmán B")], parent: identity, newId, now, ...over });

test("unit name drops the parent's name", () => {
  assert.equal(deriveUnitName("Apartmány Ľubika", "Apartmány Ľubika - Apartmán B"), "Apartmán B");
  assert.equal(deriveUnitName("Chata", "Iná chata"), "Iná chata");
  assert.equal(deriveUnitName("Chata", "Chata"), "Chata");
});

test("parent gets the Hauzi name, slug and description; every old listing becomes a unit without its own description", () => {
  const p = run();
  assert.ok(p.ok);
  assert.deepEqual([p.parent.name, p.parent.slug, p.parent.description], ["Apartmány Lubika", "apartmany-lubika-2", "Hauzi text"]);
  assert.deepEqual(p.parent.units.map((u) => u.name), ["Apartmán A", "Apartmán B"]);
  assert.ok(p.parent.units.every((u) => u.description === undefined));
  assert.equal(p.parent.userId, "host1");
  assert.deepEqual(p.parent.images, ["a.jpg", "b.jpg"]);
});

test("parent does not inherit the old listing's identity or counters", () => {
  const p = run({ olds: [acc("a", "Apartmány Lubika - A", { views: 9, averageRating: 4.5, translations: { en: { name: "x" } }, icalExportUrl: "u" }), acc("b", "Apartmány Lubika - B")] });
  for (const k of ["views", "averageRating", "translations", "icalExportUrl"]) assert.equal(p.parent[k], undefined, k);
});

test("every calendar row and feed lands on its unit; row links are kept", () => {
  const a = acc("a", "Apartmány Lubika - Apartmán A", { occupancyCalendar: [{ _id: "r1", status: "booked", reservationId: "res" }], calendarSync: [{ _id: "f1", url: "u1" }] });
  const b = acc("b", "Apartmány Lubika - Apartmán B", { occupancyCalendar: [{ _id: "r2", status: "blocked" }], calendarSync: [{ _id: "f2", url: "u2" }] });
  const p = run({ olds: [a, b] });
  const [ua, ub] = p.units;
  assert.deepEqual(p.parent.occupancyCalendar.map((r) => [r._id, r.unitId, r.unitName]), [["r1", ua._id, "Apartmán A"], ["r2", ub._id, "Apartmán B"]]);
  assert.equal(p.parent.occupancyCalendar[0].reservationId, "res");
  assert.deepEqual(p.parent.calendarSync.map((f) => [f._id, f.unitId]), [["f1", ua._id], ["f2", ub._id]]);
});

test("parent totals: most guests, lowest price", () => {
  const p = run({ olds: [acc("a", "Apartmány Lubika - A", { person: 2, pricePerNight: 90 }), acc("b", "Apartmány Lubika - B", { person: 6, pricePerNight: 150 })] });
  assert.deepEqual([p.parent.person, p.parent.pricePerNight], [6, 90]);
});

test("beds counts every bed, amenities copied as a whole set", () => {
  const u = unitFromListing(acc("x", "X", { services: { en: ["WiFi"], sk: ["WiFi"] } }), "X", "id");
  assert.equal(u.beds, 3);
  assert.deepEqual(u.services, { en: ["WiFi"], sk: ["WiFi"] });
  assert.deepEqual(u.safetyAmenities, { en: [], sk: [] });
});

test("blocked: other host, duplicate names, same listing twice, no Hauzi name", () => {
  assert.ok(run({ olds: [acc("a", "Apartmány Lubika - A"), acc("b", "Apartmány Lubika - B", { userId: "host2" })] }).blockers.some((b) => /different hosts/.test(b)));
  assert.ok(run({ olds: [acc("a", "Apartmány Lubika - Apartmán"), acc("b", "Apartmány Lubika - apartman")] }).blockers.some((b) => /named/.test(b)));
  assert.ok(run({ olds: [acc("a", "x"), acc("a", "y")] }).blockers.some((b) => /twice/.test(b)));
  assert.equal(run({ parent: { _id: "p" } }).ok, false);
});

test("blocked: active checkout hold on an old listing; expired hold dropped", () => {
  const live = { _id: "h", status: "held", holdExpiresAt: new Date("2026-06-01T12:10:00Z") };
  const dead = { _id: "d", status: "held", holdExpiresAt: new Date("2026-06-01T11:00:00Z") };
  assert.ok(run({ olds: [acc("a", "Apartmány Lubika - A", { occupancyCalendar: [live] }), acc("b", "Apartmány Lubika - B")] }).blockers.some((b) => /hold/.test(b)));
  const p = run({ olds: [acc("a", "Apartmány Lubika - A", { occupancyCalendar: [dead] }), acc("b", "Apartmány Lubika - B")] });
  assert.ok(p.ok);
  assert.equal(p.droppedHolds, 1);
  assert.equal(p.parent.occupancyCalendar.length, 0);
});

test("blocked: open booking request; a lapsed one is fine", () => {
  const open = { _id: "q", bookingMode: "request", isApproved: "pending", requestExpiresAt: new Date("2026-06-02T00:00:00Z") };
  assert.ok(run({ reservations: [open] }).blockers.some((b) => /request/.test(b)));
  assert.ok(run({ reservations: [{ ...open, requestExpiresAt: new Date("2026-05-01T00:00:00Z") }] }).ok);
});

test("blocked: different Stripe account; warned: differing cancellation policy", () => {
  assert.ok(run({ olds: [acc("a", "Apartmány Lubika - A", { stripeAccountId: "s1" }), acc("b", "Apartmány Lubika - B", { stripeAccountId: "s2" })] }).blockers.some((b) => /Stripe/.test(b)));
  const p = run({ olds: [acc("a", "Apartmány Lubika - A"), acc("b", "Apartmány Lubika - B", { cancellationPolicyType: "strict" })] });
  assert.ok(p.ok && p.warnings.some((w) => /cancellationPolicyType/.test(w)));
});

test("flexible prices: Hauzi's win for the parent and matched units; old listing's kept otherwise", () => {
  const offer = (price) => [{ name: "Leto", start: new Date("2026-07-01"), end: new Date("2026-08-31"), tiers: [{ minNights: 1, price }] }];
  const olds = [acc("a", "Apartmány Lubika - Apartmán A", { flexiblePrices: offer(110) }), acc("b", "Apartmány Lubika - Apartmán B", { flexiblePrices: offer(120) })];
  const p = run({
    olds,
    parent: { ...identity, flexiblePrices: offer(90) },
    hauziUnits: [{ unitName: "apartman a", flexiblePrices: offer(95) }, { unitName: "Apartmán B", flexiblePrices: [] }],
  });
  assert.deepEqual([p.parent.flexiblePrices, p.units[0].flexiblePrices, p.units[1].flexiblePrices].map((f) => f[0].tiers[0].price), [90, 95, 120]);
  // No Hauzi offers at all: the parent keeps the first listing's.
  assert.equal(run({ olds }).parent.flexiblePrices[0].tiers[0].price, 110);
});

test("flexible prices: a unit with none of its own gets the property's Hauzi periods", () => {
  const offer = [{ name: "Vianoce", start: new Date("2026-12-23"), end: new Date("2027-01-02"), tiers: [{ minNights: 1, price: 130 }] }];
  const p = run({ parent: { ...identity, flexiblePrices: offer } });
  assert.deepEqual(p.units.map((u) => u.flexiblePrices?.[0].tiers[0].price), [130, 130]);
});

test("warned: unit offers without its own nightly price", () => {
  const p = run({ olds: [acc("a", "Apartmány Lubika - A", { pricePerNight: undefined }), acc("b", "Apartmány Lubika - B")], hauziUnits: [{ unitName: "A", flexiblePrices: [{ tiers: [] }] }] });
  assert.ok(p.warnings.some((w) => /no nightly price/.test(w)));
});

test("explicit names override", () => {
  assert.equal(run({ names: { a: "Chata Alfa" } }).units[0].name, "Chata Alfa");
});

test("Hauzi unit names are matched to listings by whole words, each used once", () => {
  const ls = [acc("a", "Apartmány Lubika - Apartmán A"), acc("b", "Apartmány Lubika - Apartmán B"), acc("z", "Chata Zed")];
  const { names, unmatched } = matchHauziNames(ls, ["Apartmán A", "Apartmán B"]);
  assert.deepEqual(names, { a: "Apartmán A", b: "Apartmán B" });
  assert.deepEqual(unmatched.map((u) => u.slug), ["z"]);
  assert.deepEqual(matchHauziNames([acc("q", "Apartmány Ab")], ["Apartmán A"]).names, {});
});

test("same listing names: matched by slug; a type name takes the first free numbered copy", () => {
  const ls = [acc("apartmany-luna-hrebienok-apartman-deluxe", "Apartmán Luna"), acc("apartmany-luna-hrebienok-apartman-luxe", "Apartmán Luna")];
  const { names, unmatched } = matchHauziNames(ls, ["Apartmán Deluxe 1", "Apartmán Deluxe 2", "Apartmán luxe"]);
  assert.deepEqual(names, { "apartmany-luna-hrebienok-apartman-deluxe": "Apartmán Deluxe 1", "apartmany-luna-hrebienok-apartman-luxe": "Apartmán luxe" });
  assert.equal(unmatched.length, 0);
});

test("Hauzi's English 'Apartment' matches Putko's Slovak 'Apartmán'", () => {
  const ls = [acc("b5", "TATRYSTAY Apartments Tatranska - Apartmán Tatranska B5")];
  assert.deepEqual(matchHauziNames(ls, ["Apartment Tatranska B12", "Apartment Tatranska B5"]).names, { b5: "Apartment Tatranska B5" });
});

// The two shapes from the brief: Hauzi {A,B}; Putko {A,B} or {A,B,C} under different slugs.
const scenario = (hauziUnits, putkoNames) => {
  const olds = putkoNames.map((nm, i) => acc(`slug-${i}`, `Apartmány Lubika - ${nm}`));
  const { names } = matchHauziNames(olds, hauziUnits);
  const p = planMerge({ olds, parent: identity, names, newId, now });
  return { p, unitNames: p.units.map((u) => u.name) };
};

test("Hauzi A,B and Putko A,B: one parent, units A and B", () => {
  const { p, unitNames } = scenario(["Apartmán A", "Apartmán B"], ["Apartmán A", "Apartmán B"]);
  assert.ok(p.ok);
  assert.deepEqual(unitNames, ["Apartmán A", "Apartmán B"]);
  assert.equal(p.parent.name, "Apartmány Lubika");
  assert.equal(p.oldUnits.length, 2);
});

test("Hauzi A,B and Putko A,B,C: the extra Putko listing is kept as unit C", () => {
  const { p, unitNames } = scenario(["Apartmán A", "Apartmán B"], ["Apartmán A", "Apartmán B", "Apartmán C"]);
  assert.ok(p.ok);
  assert.deepEqual(unitNames, ["Apartmán A", "Apartmán B", "Apartmán C"]);
});

test("Hauzi A,B,D and Putko A,B: only Putko's units are merged (hauzi-sync adds D afterwards)", () => {
  const { unitNames } = scenario(["Apartmán A", "Apartmán B", "Apartmán D"], ["Apartmán A", "Apartmán B"]);
  assert.deepEqual(unitNames, ["Apartmán A", "Apartmán B"]);
});
