/**
 * Host workspace — reservations.
 *
 * Reads the real `Reservation` collection, the one checkout writes to. It used
 * to read a `HostReservation` collection carried over from the Putko
 * workspace, which meant the Reservations screen was empty however many real
 * bookings a host had.
 *
 * Ownership is `accommodationProvider`, taken from the verified token exactly
 * as `loadRequestForHost` does in ReservationController, so an id in a request
 * can never reach another host's booking.
 *
 * This module is read-only. Accepting and declining a request are money
 * operations — they issue payment links and, for a cancellation, refunds — and
 * they already exist, tested, on `/api/reservation/:id/approve|decline` and the
 * cancellation routes. The workspace calls those rather than this file growing
 * a second implementation of them.
 */

import mongoose from "mongoose";

import Accommodation from "../models/Accommodation.js";
import Reservation from "../models/Reservation.js";
import { dayNumber, isObjectId, todayIso } from "../utils/hostWorkspace.js";

const NOT_FOUND = { message: "Reservation not found." };

/** `YYYY-MM-DD` for a stored Date, so stage maths is calendar-based. */
const isoDay = (value) => {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString().slice(0, 10);
};

/**
 * The operational stage the workspace shows, derived from the stored state and
 * today's date so it is always current without a background job.
 *
 * `isApproved` is the model's lifecycle: pending | approved | cancelled. A
 * request the host let lapse is cancelled with `requestExpiredAt` set, which
 * reads as "declined" to a host rather than "cancelled by someone".
 */
export const reservationStage = (reservation, today = todayIso()) => {
  if (reservation.isApproved === "cancelled") {
    if (reservation.requestDeclinedAt || reservation.requestExpiredAt) return "declined";
    return "cancelled";
  }
  if (reservation.isApproved !== "approved") return "request";

  const checkIn = isoDay(reservation.checkInDate);
  const checkOut = isoDay(reservation.checkOutDate);
  if (!checkIn || !checkOut) return "upcoming";

  if (dayNumber(today) < dayNumber(checkIn)) return "upcoming";
  if (dayNumber(today) >= dayNumber(checkOut)) return "completed";
  return "active";
};

export const RESERVATION_STAGES = [
  "request",
  "upcoming",
  "active",
  "completed",
  "declined",
  "cancelled",
];

/**
 * What the host may do from the workspace right now.
 *
 * Only a request-to-book that is still open can be answered: an instant
 * booking was paid at checkout and needs no decision. Cancelling an accepted
 * stay is deliberately absent — it goes through the cancellation flow, which
 * computes the refund tier, so offering a button here that did not would be
 * worse than offering none.
 */
export const allowedActions = (reservation) => {
  if (reservation.bookingMode !== "request") return [];
  if (reservation.isApproved !== "pending") return [];
  if (reservation.paymentStatus === "paid") return [];
  if (reservation.requestExpiresAt && new Date(reservation.requestExpiresAt) < new Date()) {
    return [];
  }
  return ["accept", "decline"];
};

const nightsBetween = (from, to) => {
  const a = isoDay(from);
  const b = isoDay(to);
  if (!a || !b) return 0;
  return Math.max(0, dayNumber(b) - dayNumber(a));
};

/** Money is stored as euros on `totalPrice` and minor units on `totalPriceCents`. */
const totalCents = (reservation) =>
  Number(reservation.totalPriceCents) ||
  Math.round((Number(reservation.totalPrice) || 0) * 100);

const serialize = (reservation, today = todayIso()) => {
  // `accommodationId` is populated where possible, so it may be the listing
  // itself or a bare id for a listing that has since been removed.
  const listing =
    reservation.accommodationId && typeof reservation.accommodationId === "object"
      ? reservation.accommodationId
      : null;

  const nights = nightsBetween(reservation.checkInDate, reservation.checkOutDate);
  const total = totalCents(reservation);

  return {
    id: reservation._id.toString(),
    accommodationId: listing
      ? listing._id.toString()
      : reservation.accommodationId
        ? reservation.accommodationId.toString()
        : null,
    // On a listing split into units the booked unit is named with it
    // ("Apartments A · A1"), so every screen showing the listing shows which.
    listing: listing
      ? {
          id: listing._id.toString(),
          name: [listing.name || "", reservation.unitName].filter(Boolean).join(" · "),
        }
      : null,
    unitName: reservation.unitName || null,
    guest: {
      name: reservation.name || "",
      email: reservation.email || null,
      phone: reservation.phone || null,
      message: reservation.message || reservation.note || null,
    },
    checkIn: isoDay(reservation.checkInDate),
    checkOut: isoDay(reservation.checkOutDate),
    nights,
    guests: reservation.numberOfPersons ?? 1,
    // The guest's pet ("dog" | "cat" | "other"), or null when they bring none.
    pet: reservation.withPet ? reservation.petType || "other" : null,
    // How many pets they bring (0 without one). Older bookings predate the
    // count, so a pet with no count reads as one.
    pets: reservation.withPet ? Math.max(1, Number(reservation.numberOfPets) || 1) : 0,
    // Paid extras the guest picked, as priced at booking ([] without any).
    extras: (reservation.extras || []).map((extra) => ({
      name: extra.name || {},
      pricing: extra.pricing,
      priceCents: extra.priceCents,
      totalCents: extra.totalCents,
    })),
    // Per-night figure is derived: the model stores the stay total, and a
    // zero-night stay must not divide by zero.
    nightlyPriceCents: nights > 0 ? Math.round(total / nights) : total,
    totalCents: total,
    currency: (reservation.currency || "eur").toUpperCase(),
    status: reservation.isApproved,
    stage: reservationStage(reservation, today),
    actions: allowedActions(reservation),
    // Which flow this booking came through, so the screen can explain why a
    // request is waiting on the host but an instant booking is not.
    bookingMode: reservation.bookingMode,
    paymentStatus: reservation.paymentStatus,
    requestExpiresAt: reservation.requestExpiresAt || null,
    source: reservation.bookingMode === "request" ? "request" : "putko",
    cancelledBy: reservation.cancelledBy || null,
    hostNote: null,
    respondedAt: reservation.requestApprovedAt || reservation.requestDeclinedAt || null,
    cancelledAt: reservation.cancelledAt || null,
    createdAt: reservation.createdAt,
    updatedAt: reservation.updatedAt,
  };
};

// GET /api/host/host-reservations
export const listHostReservations = async (req, res) => {
  try {
    const query = { accommodationProvider: req.hostId };

    // A property filter must be one of this host's own listings, so it is
    // checked against ownership rather than trusted.
    const { property, stage } = req.query;
    if (property) {
      if (!isObjectId(property)) {
        return res.status(400).json({ message: "Unknown property filter." });
      }
      const owned = await Accommodation.exists({ _id: property, userId: req.hostId });
      if (!owned) return res.status(404).json({ message: "Listing not found." });
      query.accommodationId = new mongoose.Types.ObjectId(property);
    }

    const reservations = await Reservation.find(query)
      .populate("accommodationId", "name slug images locationDetails")
      .sort({ checkInDate: -1 });

    const today = todayIso();
    let result = reservations.map((reservation) => serialize(reservation, today));

    // Stage is derived rather than stored, so it can only be filtered after
    // serializing.
    if (stage) {
      if (!RESERVATION_STAGES.includes(stage)) {
        return res.status(400).json({ message: "Unknown reservation stage." });
      }
      result = result.filter((item) => item.stage === stage);
    }

    res.status(200).json({ reservations: result, today });
  } catch (error) {
    console.error("Error in listHostReservations controller:", error.message);
    res.status(500).json({ message: "Could not load your reservations." });
  }
};

// GET /api/host/host-reservations/:id
export const getHostReservation = async (req, res) => {
  try {
    if (!isObjectId(req.params.id)) return res.status(404).json(NOT_FOUND);

    const reservation = await Reservation.findOne({
      _id: req.params.id,
      accommodationProvider: req.hostId,
    }).populate("accommodationId", "name slug images locationDetails");

    // "Not yours" and "does not exist" answer the same, so the response cannot
    // be used to discover which reservation ids are real.
    if (!reservation) return res.status(404).json(NOT_FOUND);

    res.status(200).json({ reservation: serialize(reservation), today: todayIso() });
  } catch (error) {
    console.error("Error in getHostReservation controller:", error.message);
    res.status(500).json({ message: "Could not load the reservation." });
  }
};

export { serialize as serializeReservation };
