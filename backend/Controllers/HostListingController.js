/**
 * Host workspace — listings.
 *
 * Every handler resolves the listing through `findOwnedListing`, so an id in a
 * request can only ever reach a listing this host owns. "Not yours" and "does
 * not exist" both answer 404 on purpose: distinguishing them would leak which
 * listing ids are real.
 */

import Accommodation from "../models/Accommodation.js";
import DeletedAccommodation from "../models/DeletedAccommodation.js";
import HostListing from "../models/HostListing.js";
import HostCalendarBlock from "../models/HostCalendarBlock.js";
import HostCalendarFeed from "../models/HostCalendarFeed.js";
import HostConversation from "../models/HostConversation.js";
import HostMessage from "../models/HostMessage.js";
import Reservation from "../models/Reservation.js";
import { findOwnedListing, isObjectId } from "../utils/hostWorkspace.js";
import {
  evaluateListing,
  preserveLegacyPlatformOffer,
  serializeListing,
} from "../utils/hostListingCompletion.js";
import {
  flexiblePricesOf,
  mapLegacyAccommodationData,
  mapAccommodationToListing,
  mapListingToAccommodation,
  uniqueSlug,
} from "../utils/accommodationMapper.js";
import { syncListingFeeds } from "../utils/syncListingFeeds.js";
import { removedUnitsWithBookings, unitHasBookingsResponse } from "../utils/unitRemovalGuard.js";
import { clearAccommodationCache } from "./AccommodationController.js";
import { pullCalendarFeed } from "./HostCalendarController.js";

const NOT_FOUND = { message: "Listing not found." };

/**
 * Pull every link `syncListingFeeds` just connected, so a feed pasted in the
 * editor imports on save/publish the way the step's own copy promises,
 * instead of sitting on "never" until something else fetches it.
 * Best-effort per feed: one dead link must not stop the others, and a feed
 * that fails here still saves — it shows "Failed" instead of "Connecting".
 */
const pullNewFeeds = async (accommodation, addedFeeds) => {
  for (const feed of addedFeeds) {
    try {
      await pullCalendarFeed(accommodation, feed);
    } catch (error) {
      console.error("[host-listing] could not pull newly connected calendar:", error.message);
    }
  }
};

/**
 * A property added through the traveller-side Profile form, shaped like a
 * workspace listing so it can sit in the same list. It has no `HostListing`
 * draft behind it — `legacy: true` tells the client to adopt it before doing
 * anything that addresses a draft, since the wizard and the delete endpoint
 * both take a `HostListing` id and this row carries an Accommodation one.
 *
 * Always "LIVE": Profile's create form only ever saves a complete
 * accommodation (an in-progress form lives in the browser's own draft
 * storage, never as a partial document here), and the site's actual search
 * query has no status filter at all — every accommodation is visible to
 * guests regardless of any status field. `accommodation.listingStatus`
 * ("Nepripojené"/"Overuje sa"/"Aktívne" on Profile's own badge) answers a
 * completely different question — whether a *payout account* is connected —
 * and is explicitly documented as "a LABEL, not a gate" for whether the
 * listing is live (see ListingStatusBadge.js). Reusing it for the workspace's
 * DRAFT/READY/LIVE — which means "wizard completion" everywhere else in Host —
 * made a fully live, bookable listing read as "unfinished".
 */
const serializeLegacyAccommodation = (accommodation) => {
  return {
    id: accommodation._id.toString(),
    status: "LIVE",
    slug: accommodation.slug || null,
    data: mapLegacyAccommodationData(accommodation),
    completedSteps: [],
    missingRequirements: [],
    completionPercent: 100,
    canPublish: false,
    publishedAt: accommodation.createdAt || null,
    createdAt: accommodation.createdAt,
    updatedAt: accommodation.updatedAt,
    accommodationId: accommodation._id.toString(),
    legacy: true,
  };
};

/**
 * `serializeListing`, with the public slug of the accommodation behind it.
 *
 * The slug lives on the Accommodation, not on the draft, so it has to be
 * fetched. Used by the single-listing handlers; `listHostAccommodations` reads
 * every accommodation it needs in one query already and passes the slug from
 * there instead of calling this per row.
 */
const serializeWithSlug = async (listing) => {
  if (!listing.accommodationId) return serializeListing(listing);

  const accommodation = await Accommodation.findById(listing.accommodationId)
    .select("slug payoutStripeAccountId flexiblePrices")
    .lean();

  return serializeListing(listing, {
    slug: accommodation?.slug || null,
    flexiblePrices: accommodation ? flexiblePricesOf(accommodation.flexiblePrices) : undefined,
    payoutStripeAccountId:
      listing.status === "LIVE" && accommodation
        ? accommodation.payoutStripeAccountId || null
        : undefined,
  });
};

/**
 * Give a listing that has no workspace draft one, so it can be edited.
 *
 * POST /api/host/host-accommodations/:id/adopt  — `:id` is an ACCOMMODATION id.
 *
 * Everything added through the traveller-side Profile form, and everything
 * predating the workspace editor, appears in Listings as a read-only "legacy"
 * row (see `serializeLegacyAccommodation`). The wizard only knows how to open a
 * real `HostListing`, so those rows could offer nothing but a link to their
 * calendar — a host could not change the price, the photos or the description
 * of their own live listing from the workspace at all. This builds the missing
 * draft from the listing itself, after which it is an ordinary workspace
 * listing and every existing screen works on it unchanged.
 *
 * Idempotent: adopting twice returns the draft that already exists rather than
 * creating a second one. That matters because the client calls this every time
 * Manage is pressed, and because `listHostAccommodations` decides what is
 * "legacy" by which accommodations no surviving draft points at — two drafts
 * for one accommodation would make the listing vanish from that list.
 */
export const adoptLegacyAccommodation = async (req, res) => {
  try {
    if (!isObjectId(req.params.id)) return res.status(404).json(NOT_FOUND);

    const accommodation = await Accommodation.findOne({
      _id: req.params.id,
      userId: req.hostId,
    });
    if (!accommodation) return res.status(404).json(NOT_FOUND);

    const existing = await HostListing.findOne({
      ownerId: req.hostId,
      accommodationId: accommodation._id,
    });
    if (existing) return res.status(200).json(await serializeWithSlug(existing));

    const data = mapAccommodationToListing(accommodation.toObject());
    const { canPublish } = evaluateListing(data);

    // LIVE only when the adopted payload would still pass the publish review.
    //
    // Not cosmetic. `updateHostAccommodation` unpublishes the Accommodation
    // when a listing whose status is NOT already DRAFT stops qualifying — so
    // marking an incomplete adoption LIVE would take a live, bookable listing
    // off the site the first time its host pressed Save. Starting it at DRAFT
    // in that case also keeps the mirror quiet: that code only writes back to
    // the Accommodation while `canPublish` holds, so a partial payload can
    // never overwrite good data with blanks.
    const listing = await HostListing.create({
      ownerId: req.hostId,
      data,
      status: canPublish ? "LIVE" : "DRAFT",
      publishedAt: accommodation.createdAt || new Date(),
      accommodationId: accommodation._id,
    });

    res.status(201).json(await serializeWithSlug(listing));
  } catch (error) {
    console.error("Error in adoptLegacyAccommodation controller:", error.message);
    res.status(500).json({ message: "Could not open that listing for editing." });
  }
};

// GET /api/host/host-accommodations
export const listHostAccommodations = async (req, res) => {
  try {
    const listings = await HostListing.find({ ownerId: req.hostId }).sort({
      updatedAt: -1,
    });

    // A listing that already published carries the id of the Accommodation it
    // publishes into — that one has a draft here already and must not be
    // listed twice.
    const linkedAccommodationIds = new Set(
      listings.filter((listing) => listing.accommodationId).map((listing) => listing.accommodationId.toString()),
    );

    // Everything else this host owns in the real collection: listings created
    // before the workspace editor existed, or added straight through Profile.
    // The calendar and reservations screens already read this collection —
    // without this, a host with only such properties saw an empty Listings
    // tab despite having live accommodations.
    const accommodations = await Accommodation.find({ userId: req.hostId })
      .select("name images locationDetails pricePerNight slug calendarSync payoutStripeAccountId createdAt updatedAt")
      .lean();

    const legacyListings = accommodations
      .filter((accommodation) => !linkedAccommodationIds.has(accommodation._id.toString()))
      .map(serializeLegacyAccommodation);

    // Every accommodation this host owns is already in hand, so the published
    // listings get their public slug from the same read rather than one lookup
    // per card.
    const slugByAccommodationId = new Map(
      accommodations.map((accommodation) => [
        accommodation._id.toString(),
        accommodation.slug || null,
      ]),
    );
    const payoutAccountByAccommodationId = new Map(
      accommodations.map((accommodation) => [
        accommodation._id.toString(),
        accommodation.payoutStripeAccountId || null,
      ]),
    );

    const combined = [
      ...listings.map((listing) =>
        serializeListing(listing, {
          slug: listing.accommodationId
            ? slugByAccommodationId.get(listing.accommodationId.toString()) || null
            : null,
          payoutStripeAccountId:
            listing.status === "LIVE" && listing.accommodationId
              ? payoutAccountByAccommodationId.get(listing.accommodationId.toString())
              : undefined,
        }),
      ),
      ...legacyListings,
    ].sort(
      (a, b) => new Date(b.updatedAt) - new Date(a.updatedAt),
    );

    res.status(200).json({ accommodations: combined });
  } catch (error) {
    console.error("Error in listHostAccommodations controller:", error.message);
    res.status(500).json({ message: "Could not load your listings." });
  }
};

// POST /api/host/host-accommodations
export const createHostAccommodation = async (req, res) => {
  try {
    // A new listing starts empty; the editor fills it step by step and saves
    // as it goes, so there is nothing to accept in the request body.
    const listing = await HostListing.create({
      ownerId: req.hostId,
      data: {},
      status: "DRAFT",
    });

    res.status(201).json(await serializeWithSlug(listing));
  } catch (error) {
    console.error("Error in createHostAccommodation controller:", error.message);
    res.status(500).json({ message: "Could not create the listing." });
  }
};

// GET /api/host/host-accommodations/:id
export const getHostAccommodation = async (req, res) => {
  try {
    const listing = await findOwnedListing(req.params.id, req.hostId);
    if (!listing) return res.status(404).json(NOT_FOUND);

    res.status(200).json(await serializeWithSlug(listing));
  } catch (error) {
    console.error("Error in getHostAccommodation controller:", error.message);
    res.status(500).json({ message: "Could not load the listing." });
  }
};

// PATCH /api/host/host-accommodations/:id
export const updateHostAccommodation = async (req, res) => {
  try {
    const listing = await findOwnedListing(req.params.id, req.hostId);
    if (!listing) return res.status(404).json(NOT_FOUND);

    const submittedData = req.body.data;
    if (!submittedData || typeof submittedData !== "object" || Array.isArray(submittedData)) {
      return res.status(400).json({ message: "A listing payload is required." });
    }
    const data = preserveLegacyPlatformOffer(submittedData);

    // A unit that still has a booking cannot be removed. Checked before the
    // draft is written, so a refused save leaves draft and listing as they
    // were. Nothing to check on a listing that was never published.
    if (listing.accommodationId) {
      const published = await Accommodation.findOne({ _id: listing.accommodationId, userId: req.hostId })
        .select("units occupancyCalendar");
      const blocked = await removedUnitsWithBookings(published, data.units);
      if (blocked.length) return res.status(409).json(unitHasBookingsResponse(blocked));
    }

    // The editor sends the whole payload it is holding, so this replaces
    // rather than merges: a field the host cleared must actually disappear.
    listing.data = data;

    // A published listing that no longer meets every requirement must not stay
    // live, and one that was READY only stays READY while it still qualifies.
    const { canPublish } = evaluateListing(data);
    const wasLive = listing.status === "LIVE";
    if (!canPublish && listing.status !== "DRAFT") {
      listing.status = "DRAFT";
      listing.publishedAt = null;

      // It was published, so the traveller site is showing it. Take it out of
      // circulation rather than leaving a live listing whose details the host
      // has just emptied. The document is kept — it may carry reservations and
      // reviews — so republishing restores it.
      if (wasLive && listing.accommodationId) {
        await Accommodation.updateOne(
          { _id: listing.accommodationId, userId: req.hostId },
          { $set: { status: "DRAFT" } },
        );
      }
    }

    listing.markModified("data");
    await listing.save();

    // Carry the edit onto the published listing.
    //
    // Saving used to write the draft and nothing else, so for a listing that
    // was already live NOTHING a host changed here reached the site or the
    // booking rules — minimum and maximum stay, price, capacity, amenities, all
    // of it sat in the draft while the Accommodation kept its old values. The
    // editor showed the new number back to the host, the database still held
    // the old one, and the only way to reconcile them was to press Publish
    // again, which nothing told the host to do.
    //
    // `mapListingToAccommodation` returns only the fields the workspace owns —
    // no slug, no status — so reviews, reservations, payout state and the
    // listing's published/draft standing all survive untouched. The slug is
    // deliberately left alone: it is part of the public URL, and a rename
    // should not silently break links until the host republishes.
    //
    // Only when the draft is still complete. An incomplete one has already been
    // taken out of circulation above, and pushing a half-emptied payload onto
    // the live document would overwrite good data with blanks.
    //
    // Best-effort: the listing has already saved, and a host must not be told
    // their edit failed because the mirror did. The draft is the source of
    // truth, so the next save or publish tries again.
    if (listing.accommodationId) {
      try {
        const accommodation = await Accommodation.findOne({
          _id: listing.accommodationId,
          userId: req.hostId,
        });

        if (accommodation) {
          let dirty = false;

          if (canPublish) {
            Object.assign(
              accommodation,
              mapListingToAccommodation(data, { ownerId: req.hostId }),
            );
            dirty = true;
          }

          // The editor's calendar links, so a link pasted here shows up in the
          // calendar section and can actually be fetched.
          const changes = syncListingFeeds(accommodation, data);
          if (changes.added || changes.updated || changes.removed) dirty = true;
          if (changes.addedFeeds.length) await pullNewFeeds(accommodation, changes.addedFeeds);

          if (dirty) {
            await accommodation.save();
            await clearAccommodationCache();
          }
        }
      } catch (err) {
        console.error("[host-listing] edit not mirrored onto the listing:", err.message);
      }
    }

    res.status(200).json(await serializeWithSlug(listing));
  } catch (error) {
    console.error("Error in updateHostAccommodation controller:", error.message);
    res.status(500).json({ message: "Could not save the listing." });
  }
};

// POST /api/host/host-accommodations/:id/publish
export const publishHostAccommodation = async (req, res) => {
  try {
    const listing = await findOwnedListing(req.params.id, req.hostId);
    if (!listing) return res.status(404).json(NOT_FOUND);

    const evaluation = evaluateListing(listing.data);
    if (!evaluation.canPublish) {
      // The editor renders the missing ids as a checklist, so they are more
      // useful here than a sentence.
      return res.status(409).json({
        message: "This listing is not ready to publish yet.",
        code: "incomplete",
        missingRequirements: evaluation.missingRequirements,
      });
    }

    // Publishing is where a workspace draft becomes a real listing: the
    // payload is mapped onto the Accommodation schema and written to the
    // collection the traveller site actually reads.
    const fields = mapListingToAccommodation(listing.data, { ownerId: req.hostId });

    let accommodation = listing.accommodationId
      ? await Accommodation.findOne({ _id: listing.accommodationId, userId: req.hostId })
      : null;

    if (accommodation) {
      // Same guard as saving: a unit with a booking stays.
      const blocked = await removedUnitsWithBookings(accommodation, listing.data?.units);
      if (blocked.length) return res.status(409).json(unitHasBookingsResponse(blocked));

      // A republish updates the same document. `mapListingToAccommodation`
      // returns only the fields the workspace owns, so reviews, ratings,
      // reservations and payout state survive untouched.
      Object.assign(accommodation, fields);
      // The slug is permanent once published — it's the public URL
      // (/listings/<slug>), already indexed by Google and possibly linked to
      // elsewhere. Renaming the listing must not change it; only mint one
      // here if this document somehow doesn't have one yet.
      if (!accommodation.slug) {
        accommodation.slug = await uniqueSlug(fields.name, accommodation._id);
      }
      accommodation.status = "PUBLISHED";
      // `fields` carries no calendar link — the mapper maps none — so the
      // editor's links are mirrored separately, here, where the accommodation
      // exists to hold them.
      const feedChanges = syncListingFeeds(accommodation, listing.data);
      if (feedChanges.addedFeeds.length) await pullNewFeeds(accommodation, feedChanges.addedFeeds);
      await accommodation.save();
    } else {
      accommodation = await Accommodation.create({
        ...fields,
        slug: await uniqueSlug(fields.name),
        status: "PUBLISHED",
      });
      listing.accommodationId = accommodation._id;

      // Same on a first publish, once the document exists and has an _id for
      // the feed rows to hang off.
      // A link the host pasted while the listing was still a draft lands here:
      // this is the first moment there is an accommodation to carry it onto,
      // which is what the editor promises when it says the dates import on
      // publish.
      const changes = syncListingFeeds(accommodation, listing.data);
      if (changes.addedFeeds.length) await pullNewFeeds(accommodation, changes.addedFeeds);
      if (changes.added || changes.updated || changes.removed) {
        await accommodation.save();
      }
    }

    listing.status = "LIVE";
    listing.publishedAt = new Date();
    await listing.save();

    console.log(
      `[putko-audit] listing.published listing=${listing._id} accommodation=${accommodation._id} host=${req.hostId} at=${new Date().toISOString()}`,
    );

    res.status(200).json(await serializeWithSlug(listing));
  } catch (error) {
    console.error("Error in publishHostAccommodation controller:", error.message);
    // A schema validation failure here means the mapping produced something
    // the Accommodation model rejects, which the host can do nothing about —
    // so say what failed rather than a bare "could not publish".
    if (error?.name === "ValidationError") {
      return res.status(422).json({
        message: "This listing could not be published in its current form.",
        code: "accommodationInvalid",
        details: Object.keys(error.errors || {}),
      });
    }
    res.status(500).json({ message: "Could not publish the listing." });
  }
};

// DELETE /api/host/host-accommodations/:id
export const deleteHostAccommodation = async (req, res) => {
  try {
    const listing = await findOwnedListing(req.params.id, req.hostId);
    if (!listing) return res.status(404).json(NOT_FOUND);

    // A stay that is already approved and has not finished is a commitment to
    // a traveller; withdrawing the listing under it would strand them. Checked
    // against the real reservations, keyed to the published accommodation —
    // the workspace's own collection is not where bookings live.
    const liveStay = listing.accommodationId
      ? await Reservation.findOne({
          accommodationId: listing.accommodationId,
          isApproved: "approved",
          checkOutDate: { $gt: new Date() },
        }).select("_id")
      : null;

    if (liveStay) {
      return res.status(409).json({
        message:
          "This listing still has an accepted booking. Cancel it before deleting the listing.",
        code: "hasActiveReservation",
      });
    }

    // Mongo has no cascading delete, so the workspace's own rows are removed
    // here. Real reservations are deliberately not among them: they belong to
    // the accommodation, which is unpublished rather than destroyed below.
    const conversations = await HostConversation.find({
      listingId: listing._id,
    }).select("_id");

    await Promise.all([
      HostMessage.deleteMany({
        conversationId: { $in: conversations.map((row) => row._id) },
      }),
      HostConversation.deleteMany({ listingId: listing._id }),
      HostCalendarBlock.deleteMany({ listingId: listing._id }),
      HostCalendarFeed.deleteMany({ listingId: listing._id }),
    ]);

    // The published Accommodation is ARCHIVED, not merely unpublished.
    //
    // This used to set `status: "DRAFT"` and leave the document in place, on
    // the reasoning that it may carry reservations, reviews and payout history
    // that deleting a workspace draft has no business destroying. True — but
    // the result was a listing the host could not get rid of. `/host-accommodations`
    // builds its "legacy" entries from every accommodation this host owns that
    // NO surviving draft points at, and deleting the draft is precisely what
    // stops anything pointing at it. So the listing came straight back on the
    // next load, now as a legacy row: labelled LIVE, offering "View calendar",
    // and — because legacy rows are not editable or deletable from that screen
    // — with no delete button at all. The host deleted a listing and got an
    // undeletable copy of it.
    //
    // Moving it to `DeletedAccommodation` is the same soft delete the
    // traveller-side flow already performs: the document is kept in full, with
    // a `deletedAt`, so nothing is destroyed and the existing restore path can
    // bring it back. It is simply no longer in the collection that every
    // listing, search and calendar query reads.
    if (listing.accommodationId) {
      const accommodation = await Accommodation.findOne({
        _id: listing.accommodationId,
        userId: req.hostId,
      });

      if (accommodation) {
        // Upserted on its own _id rather than created: the archive keeps the
        // document's id and its slug is uniquely indexed, so a listing that was
        // deleted, restored and deleted again would otherwise fail on a
        // duplicate key — 500ing the request and leaving the host with the
        // undeletable listing this is meant to remove.
        const { _id, ...fields } = accommodation.toObject();
        await DeletedAccommodation.findOneAndUpdate(
          { _id },
          { $set: { ...fields, deletedAt: new Date() } },
          { upsert: true, setDefaultsOnInsert: true },
        );

        await accommodation.deleteOne();
        await clearAccommodationCache();
      }
    }

    await listing.deleteOne();

    res.status(200).json({
      id: req.params.id,
      deleted: true,
      // So the client can say the public listing was withdrawn rather than
      // erased, if it wants to. It is recoverable from DeletedAccommodation.
      accommodationUnpublished: Boolean(listing.accommodationId),
    });
  } catch (error) {
    console.error("Error in deleteHostAccommodation controller:", error.message);
    res.status(500).json({ message: "Could not delete the listing." });
  }
};