/**
 * Shared helpers for the Host workspace routes.
 *
 * The one rule every endpoint in this module follows: a listing, reservation,
 * calendar block or conversation is reachable only through the host who owns
 * the listing it hangs off. Ids arriving in a request are treated as untrusted
 * and are always re-resolved against `req.hostId`.
 */

import mongoose from "mongoose";

import Host from "../models/Host.js";
import HostListing from "../models/HostListing.js";

const DAY_MS = 86_400_000;

/* ------------------------------------------------------------------ dates */

const pad = (value) => String(value).padStart(2, "0");

/** `YYYY-MM-DD` strings only — a stay must read as the same nights anywhere. */
export const isIsoDate = (value) => {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return (
    date.getUTCFullYear() === year &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day
  );
};

export const dayNumber = (iso) => {
  const [year, month, day] = iso.split("-").map(Number);
  return Math.round(Date.UTC(year, month - 1, day) / DAY_MS);
};

export const fromDayNumber = (value) =>
  new Date(value * DAY_MS).toISOString().slice(0, 10);

export const addDays = (iso, days) => fromDayNumber(dayNumber(iso) + days);

export const todayIso = (now = new Date()) =>
  `${now.getUTCFullYear()}-${pad(now.getUTCMonth() + 1)}-${pad(now.getUTCDate())}`;

/** Nights of a stay: check-out is exclusive, so the last night is checkOut-1. */
export const stayNights = (checkIn, checkOut) =>
  Math.max(0, dayNumber(checkOut) - dayNumber(checkIn));

/** Inclusive ranges overlap when neither ends before the other begins. */
export const rangesOverlap = (a, b) =>
  dayNumber(a.startDate) <= dayNumber(b.endDate) &&
  dayNumber(b.startDate) <= dayNumber(a.endDate);

/* ------------------------------------------------------------- validation */

export const isObjectId = (value) => mongoose.Types.ObjectId.isValid(value);

/**
 * Validate an inclusive `{ startDate, endDate }` range.
 * Returns an error code the route layer localizes, or null when the range is
 * usable.
 */
export const validateRange = (range) => {
  if (!range || typeof range !== "object") return "rangeRequired";
  const { startDate, endDate } = range;
  if (!isIsoDate(startDate) || !isIsoDate(endDate)) return "rangeInvalid";
  if (dayNumber(endDate) < dayNumber(startDate)) return "rangeReversed";
  return null;
};

/* ------------------------------------------------------- auth & ownership */

/**
 * Require a signed-in host.
 *
 * Runs after `authenticate`, which puts the verified JWT's `id` and `role` on
 * the request. The role claim alone is not enough — the account must still
 * exist — so the Host document is loaded once here and reused by the handlers.
 */
export const requireHost = async (req, res, next) => {
  try {
    if (req.role !== "host") {
      return res
        .status(403)
        .json({ message: "This area is available to hosts only." });
    }

    const host = await Host.findById(req.userId).select("_id name lastName email photo");
    if (!host) {
      return res.status(401).json({ message: "Host account not found." });
    }

    // Not `req.host`: that is a read-only getter for the Host header on
    // Node's IncomingMessage and assigning to it throws.
    req.hostAccount = host;
    req.hostId = host._id;
    next();
  } catch (error) {
    console.error("Error in requireHost middleware:", error.message);
    res.status(500).json({ message: "Something went wrong. Please try again." });
  }
};

/**
 * The listing with this id **if this host owns it**.
 *
 * Returns null for "does not exist" and for "belongs to someone else" alike:
 * telling the two apart would leak which listing ids are real.
 */
export const findOwnedListing = async (listingId, hostId) => {
  if (!isObjectId(listingId)) return null;
  return HostListing.findOne({ _id: listingId, ownerId: hostId });
};

/** Ids of every listing this host owns — the scope for all cross-listing reads. */
export const ownedListingIds = async (hostId) => {
  const rows = await HostListing.find({ ownerId: hostId }).select("_id").lean();
  return rows.map((row) => row._id);
};

/* ------------------------------------------------------------- reservation */

/**
 * The operational stage a host sees, derived from the stored status and
 * today's date so it is always current without a background job.
 */
export const reservationStage = (reservation, today = todayIso()) => {
  if (reservation.status === "requested") return "request";
  if (reservation.status === "declined") return "declined";
  if (reservation.status === "cancelled") return "cancelled";

  // accepted
  if (dayNumber(today) < dayNumber(reservation.checkIn)) return "upcoming";
  if (dayNumber(today) >= dayNumber(reservation.checkOut)) return "completed";
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
 * Which actions a reservation allows right now.
 *
 * Expressed as an allowed-transition map rather than as checks scattered
 * through the handlers, so an action the map does not list simply cannot
 * happen.
 */
export const allowedActions = (reservation, today = todayIso()) => {
  if (reservation.status === "requested") return ["accept", "decline"];
  if (reservation.status !== "accepted") return [];
  // An accepted stay can still be called off until the guest checks out.
  return dayNumber(today) < dayNumber(reservation.checkOut) ? ["cancel"] : [];
};
