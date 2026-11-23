/**
 * Completion and publish rules for a Host workspace listing.
 *
 * This is the authoritative copy. `frontend/src/app/host/hostEditorValidation.js`
 * mirrors it to show inline messages while the host types, but the editor
 * always defers to the `completedSteps` / `missingRequirements` / `canPublish`
 * values returned from here.
 *
 * Requirement ids are part of the API: the review sheet maps each one back to
 * the step and field that satisfies it, so renaming one is a breaking change.
 */

export const EDITOR_STEP_IDS = [
  "basics",
  "location",
  "spaces",
  "amenities",
  "photos",
  "pricing",
  // Optional sub-units (A1, A2, …). Nothing is required here, so the step is
  // always complete and never holds a listing back from publishing.
  "units",
  "availability",
  "calendar",
  "readiness",
];

const nonEmpty = (value) => typeof value === "string" && value.trim().length > 0;

const positive = (value) =>
  typeof value === "number" && Number.isFinite(value) && value > 0;

export const isHttpUrl = (value) => {
  if (typeof value !== "string" || !value.trim()) return false;
  try {
    const url = new URL(value.trim());
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
};

/**
 * Keep the editor's tri-state answer authoritative while remaining compatible
 * with older listings that used external calendar feeds as the only signal
 * that the property was also advertised elsewhere.
 *
 * Only a real boolean is an explicit answer. Null (and an absent value) stays
 * unset unless an existing feed provides the legacy signal. Invalid historical
 * values are dropped rather than leaking a non-boolean value to the editor.
 * This is data compatibility only; it does not affect completion or publishing.
 */
export const preserveLegacyPlatformOffer = (data = {}) => {
  const payload = data && typeof data === "object" && !Array.isArray(data) ? data : {};
  if (typeof payload.offeredOnOtherPlatforms === "boolean") return payload;

  const hasLegacyFeed =
    Array.isArray(payload.calendarFeeds) &&
    payload.calendarFeeds.some((feed) => typeof feed?.url === "string" && feed.url.trim());
  const normalized = { ...payload };

  if (payload.offeredOnOtherPlatforms !== null) {
    delete normalized.offeredOnOtherPlatforms;
  }
  if (hasLegacyFeed) normalized.offeredOnOtherPlatforms = true;

  return normalized;
};

/** Requirement id → the step that owns it, in the order the editor shows them. */
const STEP_REQUIREMENTS = {
  basics: ["name", "propertyType", "description"],
  location: ["street", "city", "country", "phoneNumber"],
  spaces: ["guests", "bedrooms", "beds", "bathrooms"],
  amenities: ["amenities"],
  photos: ["photoUrls"],
  pricing: ["nightlyPrice", "minNights"],
  units: [],
  availability: ["checkIn", "checkOut", "availabilityConfirmed"],
  calendar: ["calendarFeeds"],
  readiness: ["payoutAcknowledged"],
};

/** One predicate per requirement id. A requirement is missing when it fails. */
const SATISFIED = {
  name: (d) => nonEmpty(d.name),
  propertyType: (d) => nonEmpty(d.propertyType),
  description: (d) => nonEmpty(d.description),

  street: (d) => nonEmpty(d.street),
  city: (d) => nonEmpty(d.city),
  country: (d) => nonEmpty(d.country),
  // The Accommodation model requires a phone number, so a listing without one
  // would pass this check and then fail on publish with a validation error.
  phoneNumber: (d) => nonEmpty(d.phoneNumber),

  guests: (d) => positive(d.guests),
  bedrooms: (d) => positive(d.bedrooms),
  beds: (d) => positive(d.beds),
  bathrooms: (d) => positive(d.bathrooms),

  amenities: (d) =>
    Array.isArray(d.amenities) && d.amenities.filter(nonEmpty).length > 0,

  photoUrls: (d) =>
    Array.isArray(d.photoUrls) &&
    d.photoUrls.some((photo) =>
      typeof photo === "string" ? isHttpUrl(photo) : isHttpUrl(photo?.url),
    ),

  nightlyPrice: (d) => positive(d.nightlyPrice),
  minNights: (d) => positive(d.minNights) && Number.isInteger(d.minNights),

  checkIn: (d) => nonEmpty(d.checkIn),
  checkOut: (d) => nonEmpty(d.checkOut),
  availabilityConfirmed: (d) => d.availabilityConfirmed === true,

  // Calendar links are optional: a host with no other platform to import from
  // manages availability in Putko and is not blocked from publishing for it.
  // This used to hang off a manual/connect choice, which had to be answered
  // before the step counted as done — and answering "connect" then demanded a
  // link, so a host part-way through pasting one could not publish at all.
  //
  // What still has to hold is that a link which IS filled in is usable. A
  // half-typed URL would otherwise publish and then fail every fetch, with
  // nothing on the listing to say why.
  calendarFeeds: (d) => {
    const feeds = Array.isArray(d.calendarFeeds) ? d.calendarFeeds : [];
    return feeds.every((feed) => {
      const url = typeof feed?.url === "string" ? feed.url.trim() : "";
      return url === "" || isHttpUrl(url);
    });
  },

  payoutAcknowledged: (d) => d.payoutAcknowledged === true,
};

/**
 * Evaluate a listing payload.
 *
 * @returns {{completedSteps: string[], missingRequirements: string[],
 *            completionPercent: number, canPublish: boolean}}
 */
export const evaluateListing = (data = {}) => {
  const payload = data && typeof data === "object" ? data : {};

  const completedSteps = [];
  const missingRequirements = [];

  for (const stepId of EDITOR_STEP_IDS) {
    const requirements = STEP_REQUIREMENTS[stepId] || [];
    const missingHere = requirements.filter(
      (requirement) => !SATISFIED[requirement](payload),
    );

    if (missingHere.length === 0) completedSteps.push(stepId);
    else missingRequirements.push(...missingHere);
  }

  const completionPercent = Math.round(
    (completedSteps.length / EDITOR_STEP_IDS.length) * 100,
  );

  return {
    completedSteps,
    missingRequirements,
    completionPercent,
    canPublish: missingRequirements.length === 0,
  };
};

/**
 * The wire shape of a listing.
 *
 * The workspace addresses listings by `id`, so mongo's `_id` is renamed here
 * rather than in every handler, and the derived completion fields travel with
 * every response so the editor never has to recompute them to stay in sync.
 */
export const serializeListing = (
  listing,
  { slug = null, payoutStripeAccountId, flexiblePrices } = {},
) => {
  let data = preserveLegacyPlatformOffer(listing.data || {});
  // A draft saved before the editor had a flexible-price section has no
  // `flexiblePrices` key, while its Accommodation may already hold offers.
  // Show those, so the host edits the real list and a save keeps it.
  if (!Array.isArray(data.flexiblePrices) && Array.isArray(flexiblePrices) && flexiblePrices.length) {
    data = { ...data, flexiblePrices };
  }
  // Account assignment is stored on the Accommodation. HostListing.data can
  // lag after a payout-account change made elsewhere, so a linked live listing
  // takes the current value from its Accommodation when the caller has it.
  if (listing.status === "LIVE" && payoutStripeAccountId !== undefined) {
    data = { ...data, payoutStripeAccountId };
  }
  const evaluation = evaluateListing(data);

  return {
    id: listing._id.toString(),
    status: listing.status,
    data,
    ...evaluation,
    // The public URL segment of the accommodation this listing publishes into,
    // so the workspace can link a host straight to the page guests see. Null
    // while the listing is still only a draft and has no public page yet.
    // Lives here rather than in `data` because the slug belongs to the
    // Accommodation and is never edited through the workspace.
    slug,
    // The real Accommodation this draft publishes into, or null while it is
    // still only a draft. The editor needs to know: a calendar exists only on
    // the accommodation, so the calendar link and the per-link Fetch button
    // have nothing to address until this is set. Without it the client could
    // only guess from `status`, which is wrong — a LIVE listing taken back to
    // DRAFT keeps its accommodation.
    accommodationId: listing.accommodationId ? listing.accommodationId.toString() : null,
    publishedAt: listing.publishedAt || null,
    createdAt: listing.createdAt,
    updatedAt: listing.updatedAt,
  };
};