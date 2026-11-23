import { test } from "node:test";
import assert from "node:assert/strict";
import {
  mapAccommodationToListing,
  mapLegacyAccommodationData,
} from "./accommodationMapper.js";
import {
  evaluateListing,
  preserveLegacyPlatformOffer,
  serializeListing,
} from "./hostListingCompletion.js";

const feed = { label: "Booking.com", url: "https://example.test/calendar.ics" };

const listing = (data, status = "DRAFT") => ({
  _id: "listing-1",
  status,
  data,
  accommodationId: null,
  createdAt: new Date("2025-01-01T00:00:00.000Z"),
  updatedAt: new Date("2025-01-02T00:00:00.000Z"),
});

test("legacy calendar feeds imply an external-platform offer when the answer is unset", () => {
  const oldData = { calendarFeeds: [feed] };
  const serialized = serializeListing(listing(oldData));

  assert.deepEqual(serialized.data, {
    calendarFeeds: [feed],
    offeredOnOtherPlatforms: true,
  });
  assert.equal(Object.hasOwn(oldData, "offeredOnOtherPlatforms"), false);
});

test("an explicit false remains false and does not remove legacy feeds", () => {
  const serialized = serializeListing(listing({
    offeredOnOtherPlatforms: false,
    calendarFeeds: [feed],
  }));

  assert.equal(serialized.data.offeredOnOtherPlatforms, false);
  assert.deepEqual(serialized.data.calendarFeeds, [feed]);
  assert.deepEqual(preserveLegacyPlatformOffer(serialized.data), serialized.data);
});

test("null remains the unanswered tri-state when there are no legacy feeds", () => {
  const serialized = serializeListing(listing({ offeredOnOtherPlatforms: null }));
  assert.equal(serialized.data.offeredOnOtherPlatforms, null);
});

test("a legacy feed infers true when the stored tri-state is null", () => {
  const serialized = serializeListing(listing({
    offeredOnOtherPlatforms: null,
    calendarFeeds: [feed],
  }));
  assert.equal(serialized.data.offeredOnOtherPlatforms, true);
  assert.deepEqual(serialized.data.calendarFeeds, [feed]);
});

test("the absent state stays absent when there are no legacy feeds", () => {
  const serialized = serializeListing(listing({ name: "Draft" }));
  assert.equal(Object.hasOwn(serialized.data, "offeredOnOtherPlatforms"), false);
});

test("a live listing serializes the Accommodation's current payout account", () => {
  const serialized = serializeListing(
    listing({ payoutStripeAccountId: "acct_old" }, "LIVE"),
    { payoutStripeAccountId: "acct_current" },
  );

  assert.equal(serialized.data.payoutStripeAccountId, "acct_current");
});

test("a live Accommodation with no explicit payout account clears a stale draft value", () => {
  const serialized = serializeListing(
    listing({ payoutStripeAccountId: "acct_old" }, "LIVE"),
    { payoutStripeAccountId: null },
  );

  assert.equal(serialized.data.payoutStripeAccountId, null);
});

test("non-live listings do not apply the Accommodation payout override", () => {
  const serialized = serializeListing(
    listing({ payoutStripeAccountId: "acct_draft" }, "DRAFT"),
    { payoutStripeAccountId: "acct_current" },
  );

  assert.equal(serialized.data.payoutStripeAccountId, "acct_draft");
});

test("adopting an accommodation exposes its calendar feeds and payout selection", () => {
  const data = mapAccommodationToListing({
    calendarSync: [feed],
    payoutStripeAccountId: "acct_property",
  });

  assert.deepEqual(data.calendarFeeds, [feed]);
  assert.equal(data.payoutStripeAccountId, "acct_property");
  assert.equal(data.offeredOnOtherPlatforms, true);
});

test("legacy listing list data exposes calendar feeds and payout account selection", () => {
  const data = mapLegacyAccommodationData({
    name: "Cabin",
    calendarSync: [feed],
    payoutStripeAccountId: "acct_property",
  });

  assert.equal(data.name, "Cabin");
  assert.deepEqual(data.calendarFeeds, [feed]);
  assert.equal(data.payoutStripeAccountId, "acct_property");
  assert.equal(data.offeredOnOtherPlatforms, true);
});

test("an explicit false on an adopted accommodation is preserved alongside its feeds", () => {
  const data = mapAccommodationToListing({
    calendarSync: [feed],
    offeredOnOtherPlatforms: false,
  });

  assert.equal(data.offeredOnOtherPlatforms, false);
  assert.deepEqual(data.calendarFeeds, [feed]);
});

test("an explicit false on a legacy listing is preserved without losing its feeds", () => {
  const data = mapLegacyAccommodationData({
    calendarSync: [feed],
    payoutStripeAccountId: "acct_property",
    offeredOnOtherPlatforms: false,
  });

  assert.equal(data.offeredOnOtherPlatforms, false);
  assert.equal(data.payoutStripeAccountId, "acct_property");
  assert.deepEqual(data.calendarFeeds, [feed]);
});

test("external-platform compatibility data does not change completion or publish rules", () => {
  const payload = { calendarFeeds: [feed] };
  const before = evaluateListing(payload);
  const after = evaluateListing(preserveLegacyPlatformOffer(payload));

  assert.deepEqual(after, before);
});