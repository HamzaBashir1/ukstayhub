import mongoose from "mongoose";

/**
 * What the server last did with one iCal feed.
 *
 * The feed definition (label + URL) lives in the listing payload so the editor
 * and the calendar screen share one source of truth; this document only
 * records the fetch outcome. `url` is the URL that was actually fetched: when
 * it no longer matches the payload the status is stale and is discarded on the
 * next read rather than shown as if it described the current URL.
 */
const HostCalendarFeedSchema = new mongoose.Schema(
  {
    listingId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "HostListing",
      required: true,
      index: true,
    },
    feedId: { type: String, required: true },
    url: { type: String, required: true },
    status: {
      type: String,
      enum: ["never", "ok", "failed"],
      default: "never",
    },
    lastAttemptAt: { type: Date, default: null },
    lastFetchedAt: { type: Date, default: null },
    lastError: { type: String, default: null },
    importedCount: { type: Number, default: 0 },
  },
  { timestamps: true },
);

HostCalendarFeedSchema.index({ listingId: 1, feedId: 1 }, { unique: true });

export default mongoose.model("HostCalendarFeed", HostCalendarFeedSchema);
