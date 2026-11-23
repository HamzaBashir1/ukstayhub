// utils/calendarHold.js
//
// Dates used to be blocked only once payment settled, which left a window the
// whole length of a Stripe Checkout session during which two guests could pay
// for the same nights. The loser was not refunded or told: `finalizeReservation`
// silently filtered conflicting dates out and booked whatever was left, so
// somebody paid in full for a partial stay.
//
// A hold closes that window. It is taken when checkout starts, expires on its
// own if the guest walks away, and is converted to a real booking when the
// payment confirms.

import { eachDayOfInterval, format } from "date-fns";
import Accommodation from "../models/Accommodation.js";
import Reservation from "../models/Reservation.js";
import { alertAdmin } from "./mailer.js";
import { rowBlocksUnit } from "./listingUnits.js";

/** How long a checkout may hold dates before the hold lapses. */
export const HOLD_MINUTES = Number(process.env.CHECKOUT_HOLD_MINUTES || 30);

const dayKeys = (start, end) =>
  eachDayOfInterval({ start: new Date(start), end: new Date(end) }).map((d) =>
    format(d, "yyyy-MM-dd")
  );

/** The unit fields a booking's calendar row carries; none without a unit. */
const unitStamp = (reservation) =>
  reservation?.unitId ? { unitId: reservation.unitId, unitName: reservation.unitName || "" } : {};

/** True when a calendar row still occupies its dates. */
export function isActive(entry, now = new Date()) {
  if (entry.status !== "held") return true;
  return Boolean(entry.holdExpiresAt) && new Date(entry.holdExpiresAt) > now;
}

/**
 * Days that are already spoken for, ignoring lapsed holds and anything
 * belonging to `exceptReservationId` (so a booking does not conflict with its
 * own hold when it converts). With `unitId`, only rows that take that unit
 * count (see `rowBlocksUnit`).
 */
export function occupiedDays(
  accommodation,
  { exceptReservationId = null, now = new Date(), unitId = null } = {}
) {
  const taken = new Set();

  for (const entry of accommodation?.occupancyCalendar || []) {
    if (!entry.startDate || !entry.endDate) continue;
    if (!isActive(entry, now)) continue;
    // On a listing split into units, another unit's booking leaves this one free.
    if (!rowBlocksUnit(entry, unitId)) continue;
    if (
      exceptReservationId &&
      String(entry.reservationId || "") === String(exceptReservationId)
    ) {
      continue;
    }

    for (const day of dayKeys(entry.startDate, entry.endDate)) taken.add(day);
  }

  return taken;
}

/**
 * Drop holds that this guest's own earlier, unfinished attempt left behind.
 *
 * Checkout mints a NEW reservation on every attempt, so a guest who reaches
 * Stripe, presses Back and tries again arrives with a different reservation id
 * — and `exceptReservationId` therefore does not recognise the hold they took
 * sixty seconds ago as their own. The dates they are actively trying to book
 * appear taken, by them, for the whole HOLD_MINUTES window.
 *
 * A hold is only superseded when it is unmistakably the same guest resuming the
 * same purchase: same listing, same email, and a booking that never got paid.
 * Another guest's hold is never touched — that one is a real race and must still
 * win.
 *
 * Mutates `accommodation.occupancyCalendar`; the caller is responsible for
 * saving.
 *
 * @returns {number} how many stale holds were dropped
 */
async function dropSupersededHolds(accommodation, reservation, now) {
  const email = String(reservation.email || "").trim().toLowerCase();
  if (!email) return 0;

  const staleCandidates = (accommodation.occupancyCalendar || []).filter(
    (entry) =>
      entry.status === "held" &&
      entry.reservationId &&
      String(entry.reservationId) !== String(reservation._id) &&
      isActive(entry, now)
  );
  if (!staleCandidates.length) return 0;

  // Only the guest's own unpaid attempts qualify. A paid booking is a real
  // booking even if its row still says "held".
  const owners = await Reservation.find({
    _id: { $in: staleCandidates.map((entry) => entry.reservationId) },
    paymentStatus: { $ne: "paid" },
  })
    .select("_id email")
    .lean();

  const supersede = new Set(
    owners
      .filter((owner) => String(owner.email || "").trim().toLowerCase() === email)
      .map((owner) => String(owner._id))
  );
  if (!supersede.size) return 0;

  const before = accommodation.occupancyCalendar.length;
  accommodation.occupancyCalendar = accommodation.occupancyCalendar.filter(
    (entry) =>
      !(entry.status === "held" && supersede.has(String(entry.reservationId || "")))
  );

  const dropped = before - accommodation.occupancyCalendar.length;
  if (dropped) {
    console.log(
      `[calendar-hold] superseded ${dropped} stale hold(s) from ${email}'s earlier ` +
        `checkout attempt on listing ${accommodation._id}`
    );
  }
  return dropped;
}

/**
 * Are these dates free, without taking anything?
 *
 * The read-only half of `holdDates`. Approving a request-to-book mails a
 * payment link rather than sending the guest straight to Stripe, so the host
 * does not want those nights to go off the market yet — but they still must
 * not be able to accept a request for dates somebody else has already booked.
 * This answers that question and writes nothing.
 *
 * Unlike `holdDates` this does NOT drop the guest's superseded holds: nothing
 * is being taken, so there is no reason to mutate the calendar to make room.
 *
 * @returns {{ ok: boolean, conflictDays?: string[], reason?: string }}
 */
export async function checkAvailability(reservation) {
  const listingId = reservation.accommodationId?._id || reservation.accommodationId;
  const accommodation = await Accommodation.findById(listingId);
  if (!accommodation) return { ok: false, conflictDays: [], reason: "listing_not_found" };

  const now = new Date();
  const wanted = dayKeys(reservation.checkInDate, reservation.checkOutDate);
  const taken = occupiedDays(accommodation, {
    exceptReservationId: reservation._id,
    now,
    unitId: reservation.unitId,
  });

  const conflictDays = wanted.filter((d) => taken.has(d));
  if (conflictDays.length) return { ok: false, conflictDays, reason: "dates_unavailable" };

  return { ok: true };
}

/**
 * Try to hold a date range for a booking.
 *
 * @returns {{ ok: boolean, conflictDays?: string[], expiresAt?: Date }}
 */
export async function holdDates(reservation) {
  const listingId = reservation.accommodationId?._id || reservation.accommodationId;
  const accommodation = await Accommodation.findById(listingId);
  if (!accommodation) return { ok: false, conflictDays: [], reason: "listing_not_found" };

  const now = new Date();
  const wanted = dayKeys(reservation.checkInDate, reservation.checkOutDate);

  // Clear the guest's own abandoned attempt first — otherwise their previous
  // hold reads as somebody else's booking and refuses them their own dates.
  await dropSupersededHolds(accommodation, reservation, now);

  const taken = occupiedDays(accommodation, {
    exceptReservationId: reservation._id,
    now,
    unitId: reservation.unitId,
  });

  const conflictDays = wanted.filter((d) => taken.has(d));
  if (conflictDays.length) {
    return { ok: false, conflictDays, reason: "dates_unavailable" };
  }

  const expiresAt = new Date(now.getTime() + HOLD_MINUTES * 60000);

  // Drop this booking's own previous hold before writing a fresh one, so a
  // guest who returns to checkout does not accumulate rows.
  accommodation.occupancyCalendar = (accommodation.occupancyCalendar || []).filter(
    (entry) =>
      !(entry.status === "held" && String(entry.reservationId || "") === String(reservation._id))
  );

  accommodation.occupancyCalendar.push({
    startDate: reservation.checkInDate,
    endDate: reservation.checkOutDate,
    guestName: reservation.name || "N/A",
    status: "held",
    holdExpiresAt: expiresAt,
    reservationId: reservation._id,
    // Stamped explicitly: `source` defaults to "manual", so a row written
    // without it reads back as a block the host added by hand.
    source: "reservation",
    ...unitStamp(reservation),
  });

  await accommodation.save();

  return { ok: true, expiresAt };
}

/** Drop a booking's hold — payment failed, or the guest abandoned checkout. */
export async function releaseHold(reservation) {
  const listingId = reservation.accommodationId?._id || reservation.accommodationId;
  const accommodation = await Accommodation.findById(listingId);
  if (!accommodation?.occupancyCalendar?.length) return;

  const before = accommodation.occupancyCalendar.length;

  accommodation.occupancyCalendar = accommodation.occupancyCalendar.filter(
    (entry) =>
      !(entry.status === "held" && String(entry.reservationId || "") === String(reservation._id))
  );

  if (accommodation.occupancyCalendar.length !== before) {
    await accommodation.save();
  }
}

/**
 * Turn this booking's hold into a confirmed booking.
 *
 * Returns the conflicting days if the dates were taken in the meantime — which
 * should now be impossible via the normal flow, but a payment that arrives
 * without a hold (a stale session, a manually created booking) must not
 * silently overwrite someone else's stay.
 */
export async function confirmHold(reservation) {
  const listingId = reservation.accommodationId?._id || reservation.accommodationId;
  const accommodation = await Accommodation.findById(listingId);
  if (!accommodation) return { ok: false, reason: "listing_not_found" };

  const now = new Date();
  const wanted = dayKeys(reservation.checkInDate, reservation.checkOutDate);
  const taken = occupiedDays(accommodation, {
    exceptReservationId: reservation._id,
    now,
    unitId: reservation.unitId,
  });
  const conflictDays = wanted.filter((d) => taken.has(d));

  if (conflictDays.length) {
    // The guest has already paid, so this needs a human: either a refund or a
    // move. Silently booking the non-conflicting nights is what used to happen
    // and is the worse outcome.
    await alertAdmin("Double booking — guest paid for dates already taken", {
      reservationId: String(reservation._id),
      listingId: String(listingId),
      conflictDays,
    });
    return { ok: false, reason: "double_booked", conflictDays };
  }

  // Replace this booking's hold with a confirmed row.
  accommodation.occupancyCalendar = (accommodation.occupancyCalendar || []).filter(
    (entry) => String(entry.reservationId || "") !== String(reservation._id)
  );

  accommodation.occupancyCalendar.push({
    startDate: reservation.checkInDate,
    endDate: reservation.checkOutDate,
    guestName: reservation.name || "N/A",
    status: "booked",
    reservationId: reservation._id,
    // Without this the row defaults to source "manual", and the host calendar
    // offered "Unblock" on a paid stay instead of "Cancel booking".
    source: "reservation",
    ...unitStamp(reservation),
  });

  await accommodation.save();

  return { ok: true };
}

/**
 * Remove lapsed holds across all listings. Holds expire logically the moment
 * `holdExpiresAt` passes — `isActive` already ignores them — so this is
 * housekeeping, not correctness.
 */
export async function sweepExpiredHolds() {
  const result = await Accommodation.updateMany(
    { "occupancyCalendar.status": "held", "occupancyCalendar.holdExpiresAt": { $lt: new Date() } },
    { $pull: { occupancyCalendar: { status: "held", holdExpiresAt: { $lt: new Date() } } } }
  );

  if (result.modifiedCount) {
    console.log(`[calendar-hold] swept expired holds from ${result.modifiedCount} listings`);
  }
  return result.modifiedCount || 0;
}
