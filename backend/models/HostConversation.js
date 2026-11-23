import mongoose from "mongoose";

/**
 * A host ↔ guest message thread.
 *
 * A conversation is always about one listing and optionally about one
 * reservation of that listing. Its two participants are the host — whoever
 * owns the listing, never stored here, resolved on the server exactly like
 * reservations — and the guest (`guestId` when the traveller has an account;
 * fixture threads carry only a name). Nobody else can read or write a thread.
 *
 * Read state is per participant and lives here rather than per message: a
 * message is unread for a participant when the other side sent it after that
 * participant's `lastReadAt`. That keeps "mark as read" one update and an
 * unread count one query.
 */
const HostConversationSchema = new mongoose.Schema(
  {
    listingId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "HostListing",
      required: true,
      index: true,
    },
    // At most one thread per reservation; listing-only threads have none.
    reservationId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "HostReservation",
      default: null,
    },
    guestId: { type: mongoose.Schema.Types.ObjectId, default: null },
    guestName: { type: String, required: true },
    guestEmail: { type: String, default: null },
    source: { type: String, default: "putko" },

    lastMessageAt: { type: Date, default: Date.now },
    hostLastReadAt: { type: Date, default: null },
    guestLastReadAt: { type: Date, default: null },
  },
  { timestamps: true },
);

HostConversationSchema.index({ listingId: 1, lastMessageAt: -1 });
// One thread per reservation, but many threads may have no reservation at all,
// so the uniqueness must skip nulls.
HostConversationSchema.index(
  { reservationId: 1 },
  { unique: true, partialFilterExpression: { reservationId: { $type: "objectId" } } },
);

export default mongoose.model("HostConversation", HostConversationSchema);
