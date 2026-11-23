import mongoose from "mongoose";

/**
 * A listing as the Host workspace editor owns it.
 *
 * The editor payload lives in `data` as a free-form document rather than as
 * columns: the editor's steps change shape often, and the workspace is the
 * only reader. `status` is the part the rest of the system needs, so it is a
 * real field and not buried in the payload.
 *
 * DRAFT — being written, never shown to travellers.
 * READY — passed the publish review and may go live.
 * LIVE  — published.
 */
const HostListingSchema = new mongoose.Schema(
  {
    ownerId: {
      type: mongoose.Schema.Types.ObjectId,
      required: true,
      index: true,
    },
    data: {
      type: mongoose.Schema.Types.Mixed,
      default: () => ({}),
    },
    status: {
      type: String,
      enum: ["DRAFT", "READY", "LIVE"],
      default: "DRAFT",
      index: true,
    },
    publishedAt: { type: Date },
    // The real `Accommodation` this listing publishes into, set the first time
    // it goes LIVE. Kept so a republish updates that document instead of
    // creating a second copy of the same place.
    accommodationId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "Accommodation",
      default: null,
      index: true,
    },
  },
  { timestamps: true },
);

export default mongoose.model("HostListing", HostListingSchema);
