import mongoose from "mongoose";

/**
 * A booking request in the Host workspace.
 *
 * Ownership is never stored here: a reservation belongs to whoever owns its
 * listing, and every host endpoint resolves that on the server, so an id in a
 * request can never be used to reach someone else's reservation.
 *
 * `status` is the stored lifecycle (what the host or guest decided). The
 * operational stage a host sees — request / upcoming / active / completed /
 * declined / cancelled — is derived from `status` plus today's date, so it
 * stays correct without a background job.
 *
 * Stays are stored as `YYYY-MM-DD` calendar dates with an exclusive check-out,
 * like every booking system, so the blocked nights are `checkIn .. checkOut-1`.
 * They are strings rather than Dates so a stay reads as the same nights in
 * every timezone.
 */
const HostReservationSchema = new mongoose.Schema(
  {
    listingId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "HostListing",
      required: true,
      index: true,
    },
    // The travelling guest when they have a Putko account; sample requests
    // created by the development fixtures have none.
    guestId: { type: mongoose.Schema.Types.ObjectId, default: null },
    guestName: { type: String, required: true },
    guestEmail: { type: String, default: null },
    guestPhone: { type: String, default: null },
    guestMessage: { type: String, default: null },

    checkIn: { type: String, required: true },
    checkOut: { type: String, required: true },
    guests: { type: Number, default: 1 },

    // Money is stored in minor units at request time so a later price edit on
    // the listing never rewrites what the guest was quoted.
    nightlyPriceCents: { type: Number, required: true },
    totalCents: { type: Number, required: true },
    currency: { type: String, default: "GBP" },

    status: {
      type: String,
      enum: ["requested", "accepted", "declined", "cancelled"],
      default: "requested",
      index: true,
    },
    // "putko" for requests from a booking flow, "fixture" for sample data so
    // it can be told apart and cleaned up.
    source: { type: String, default: "putko" },
    // Who ended an accepted stay: "host" | "guest".
    cancelledBy: { type: String, default: null },
    hostNote: { type: String, default: null },
    respondedAt: { type: Date, default: null },
    cancelledAt: { type: Date, default: null },
  },
  { timestamps: true },
);

HostReservationSchema.index({ listingId: 1, checkIn: 1 });

export default mongoose.model("HostReservation", HostReservationSchema);
