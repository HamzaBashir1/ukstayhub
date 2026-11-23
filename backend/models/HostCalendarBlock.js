import mongoose from "mongoose";

/**
 * One unavailable range on a listing's calendar.
 *
 * Ranges are inclusive `YYYY-MM-DD` calendar dates with no time component, so
 * the same block reads identically regardless of the host's or the server's
 * timezone.
 *
 * manual      — owned by the host, created and removed by hand.
 * feed        — what the last successful fetch of an iCal feed imported;
 *               replaced wholesale on every fetch of that feed.
 * reservation — the nights of an accepted stay; written and removed together
 *               with the reservation decision, never by hand.
 */
const HostCalendarBlockSchema = new mongoose.Schema(
  {
    listingId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "HostListing",
      required: true,
      index: true,
    },
    startDate: { type: String, required: true },
    endDate: { type: String, required: true },
    source: {
      type: String,
      enum: ["manual", "feed", "reservation"],
      default: "manual",
    },
    // Identifier of the feed entry inside the listing payload's
    // `calendarFeeds` array; null for manual and reservation blocks.
    feedId: { type: String, default: null },
    // The accepted reservation this block belongs to; null unless
    // `source === "reservation"`.
    reservationId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "HostReservation",
      default: null,
    },
    note: { type: String, default: null },
  },
  { timestamps: true },
);

HostCalendarBlockSchema.index({ listingId: 1, startDate: 1 });

export default mongoose.model("HostCalendarBlock", HostCalendarBlockSchema);
