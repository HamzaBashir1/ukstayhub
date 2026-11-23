/**
 * Host workspace — the Today dashboard.
 *
 * Read-only aggregation over the other modules. It returns facts, not task
 * cards: the wording, ordering and deep links are the client's job
 * (`frontend/src/app/host/dashboard/hostDashboardModel.js`), so the same
 * summary can drive the full screen and the compact overview without the
 * server knowing about either.
 */

import Accommodation from "../models/Accommodation.js";
import Host from "../models/Host.js";
import HostCalendarBlock from "../models/HostCalendarBlock.js";
import HostCalendarFeed from "../models/HostCalendarFeed.js";
import HostConversation from "../models/HostConversation.js";
import HostListing from "../models/HostListing.js";
import HostMessage from "../models/HostMessage.js";
import Reservation from "../models/Reservation.js";
import { addDays, rangesOverlap, todayIso } from "../utils/hostWorkspace.js";
import { evaluateListing } from "../utils/hostListingCompletion.js";

const listingRef = (listing) => ({
  id: listing._id.toString(),
  name: listing.data?.name || "",
});

// GET /api/host/host-dashboard
export const getHostDashboard = async (req, res) => {
  try {
    const today = todayIso();

    const listings = await HostListing.find({ ownerId: req.hostId }).lean();
    const listingIds = listings.map((listing) => listing._id);
    const listingById = new Map(listings.map((l) => [l._id.toString(), l]));

    const [requests, blocks, feeds, conversations, host, legacyAccommodationCount] = await Promise.all([
      // Real bookings, from the collection checkout writes to. Scoped by
      // `accommodationProvider` exactly as the Reservations screen is.
      Reservation.find({
        accommodationProvider: req.hostId,
        bookingMode: "request",
        isApproved: "pending",
      })
        .populate("accommodationId", "name")
        .sort({ createdAt: 1 })
        .lean(),
      HostCalendarBlock.find({ listingId: { $in: listingIds } }).select("source feedId").lean(),
      HostCalendarFeed.find({ listingId: { $in: listingIds }, status: "failed" }).lean(),
      HostConversation.find({ listingId: { $in: listingIds } }).lean(),
      Host.findById(req.hostId).select("stripeAccountId").lean(),
      // Needs only the owner's linked accommodation ids, so it runs alongside
      // the rest instead of after them.
      Accommodation.countDocuments({
        userId: req.hostId,
        _id: {
          $nin: listings.filter((listing) => listing.accommodationId).map((listing) => listing.accommodationId),
        },
      }),
    ]);

    /* ---------------------------------------------------------- setup */

    // Properties added straight through the traveller-side Profile form have
    // no HostListing draft, so the loop below never sees them — without this
    // a host with only such properties saw "0 listings" on Today despite
    // having live accommodations (the Listings tab has the same fix).
    const counts = { total: listings.length + legacyAccommodationCount, live: 0, ready: 0, draft: 0 };
    const setupItems = [];

    for (const listing of listings) {
      const evaluation = evaluateListing(listing.data);

      if (listing.status === "LIVE") counts.live += 1;
      else if (evaluation.canPublish) {
        counts.ready += 1;
        setupItems.push({ kind: "ready", listing: listingRef(listing), ...evaluation });
      } else {
        counts.draft += 1;
        setupItems.push({ kind: "incomplete", listing: listingRef(listing), ...evaluation });
      }
    }

    // Always live, never a task: a legacy accommodation is already a complete,
    // saved listing with no workspace draft to send the host to (a setup card
    // here would link to a screen that 404s) — same reasoning as the Listings
    // tab's `serializeLegacyAccommodation`.
    counts.live += legacyAccommodationCount;

    /* ------------------------------------------------------- requests */

    // No conflict cross-check here. Availability blocks are keyed to workspace
    // listings and a reservation to the published `Accommodation`, so matching
    // the two up would produce confident nonsense. Reporting none is honest;
    // the double-booking check below is left for when the calendar reads the
    // same collection.
    const requestItems = requests.map((reservation) => {
      const listing =
        reservation.accommodationId && typeof reservation.accommodationId === "object"
          ? reservation.accommodationId
          : null;

      return {
        id: reservation._id.toString(),
        listing: {
          id: listing ? listing._id.toString() : String(reservation.accommodationId || ""),
          name: listing?.name || "",
        },
        guestName: reservation.name || "",
        checkIn: new Date(reservation.checkInDate).toISOString().slice(0, 10),
        checkOut: new Date(reservation.checkOutDate).toISOString().slice(0, 10),
        createdAt: reservation.createdAt,
        conflicts: [],
      };
    });

    /* ------------------------------------------------------- calendar */

    // Double bookings are not computed for the same reason: the calendar is
    // keyed to workspace listings, the stays to published accommodations.
    const calendarConflicts = [];

    const feedFailures = feeds.map((feed) => {
      const listing = listingById.get(feed.listingId.toString());
      const definition = (listing?.data?.calendarFeeds || []).find(
        (item) => item.id === feed.feedId,
      );
      return {
        listing: listingRef(listing || { _id: feed.listingId, data: {} }),
        feedId: feed.feedId,
        label: definition?.label || "",
        lastError: feed.lastError,
        // Whether the host is still running on what an earlier fetch imported.
        hasImportedDates: blocks.some(
          (block) => block.source === "feed" && block.feedId === feed.feedId,
        ),
      };
    });

    /* ------------------------------------------------------- messages */

    const conversationIds = conversations.map((row) => row._id);
    // One indexed match instead of a $lookup per message: each conversation
    // contributes "guest messages newer than its own read marker" (all of them
    // when it has never been read).
    const unreadRows = conversationIds.length
      ? await HostMessage.aggregate([
          {
            $match: {
              sender: "guest",
              $or: conversations.map((conversation) =>
                conversation.hostLastReadAt
                  ? { conversationId: conversation._id, createdAt: { $gt: conversation.hostLastReadAt } }
                  : { conversationId: conversation._id },
              ),
            },
          },
          { $group: { _id: "$conversationId", count: { $sum: 1 } } },
        ])
      : [];

    const unreadById = new Map(unreadRows.map((row) => [row._id.toString(), row.count]));

    const messageItems = conversations
      .filter((conversation) => unreadById.get(conversation._id.toString()))
      .map((conversation) => ({
        id: conversation._id.toString(),
        listing: listingRef(listingById.get(conversation.listingId.toString()) || { _id: conversation.listingId, data: {} }),
        guestName: conversation.guestName,
        unreadCount: unreadById.get(conversation._id.toString()),
        lastMessageAt: conversation.lastMessageAt,
      }));

    const unreadMessages = messageItems.reduce((sum, item) => sum + item.unreadCount, 0);

    /* -------------------------------------------------------- payouts */

    const connected = Boolean(host?.stripeAccountId);

    res.status(200).json({
      today,
      setup: { counts, items: setupItems },
      requests: { count: requestItems.length, items: requestItems },
      calendar: { conflicts: calendarConflicts, feedFailures },
      messages: { unreadMessages, items: messageItems },
      payouts: {
        connected,
        // Only a blocker once something is actually live and unpayable.
        blocker: !connected && counts.live > 0 ? { liveListings: counts.live } : null,
      },
    });
  } catch (error) {
    console.error("Error in getHostDashboard controller:", error.message);
    res.status(500).json({ message: "Could not load your dashboard." });
  }
};
