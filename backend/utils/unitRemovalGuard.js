// utils/unitRemovalGuard.js
//
// A unit (A1, A2, …) cannot be removed from a listing while it still has a
// booking to honour. Removing it would leave that booking pointing at a unit
// that no longer exists: the host calendar could no longer show or filter it,
// and nothing would stop the host re-letting those nights.
//
// Only removals are checked. Renaming a unit, changing its price, adding one,
// or saving a listing without units is never refused here.

import Reservation from "../models/Reservation.js";
import { listingUnits } from "./listingUnits.js";

/** UTC midnight today, the way calendar rows store their days. */
const startOfTodayUtc = (now) => new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));

/**
 * The units the editor payload drops that still have a booking from today on.
 *
 * @param {object} accommodation  the stored listing (its current units and calendar)
 * @param {Array|undefined} nextUnits  the editor's `units`; undefined leaves units untouched
 * @returns {Promise<Array<{unitId: string, unitName: string, bookings: number}>>}
 */
export async function removedUnitsWithBookings(accommodation, nextUnits, now = new Date()) {
  // The mapper leaves `units` alone when the payload has no such key.
  if (!accommodation || !Array.isArray(nextUnits)) return [];

  // Same rule as the mapper: a unit without a name is not kept.
  const kept = new Set(
    nextUnits
      .filter((unit) => typeof unit?.name === "string" && unit.name.trim())
      .map((unit) => String(unit.id)),
  );
  const removed = listingUnits(accommodation).filter((unit) => !kept.has(String(unit._id)));
  if (!removed.length) return [];

  const today = startOfTodayUtc(now);
  const counts = new Map(removed.map((unit) => [String(unit._id), 0]));

  // Paid bookings, and checkouts under way whose hold has not lapsed.
  for (const row of accommodation.occupancyCalendar || []) {
    const key = row.unitId ? String(row.unitId) : null;
    if (!key || !counts.has(key)) continue;
    if (!row.endDate || new Date(row.endDate) < today) continue;
    const live = row.status === "booked" || (row.status === "held" && row.holdExpiresAt && new Date(row.holdExpiresAt) > now);
    if (live) counts.set(key, counts.get(key) + 1);
  }

  // Requests to book the host has not answered yet: accepting one later would
  // book a unit that is gone.
  const openRequests = await Reservation.find({
    accommodationId: accommodation._id,
    unitId: { $in: removed.map((unit) => unit._id) },
    bookingMode: "request",
    isApproved: "pending",
    paymentStatus: "unpaid",
    checkOutDate: { $gte: today },
    requestExpiresAt: { $gt: now },
  })
    .select("unitId")
    .lean();
  for (const request of openRequests) {
    const key = String(request.unitId);
    if (counts.has(key)) counts.set(key, counts.get(key) + 1);
  }

  return removed
    .filter((unit) => counts.get(String(unit._id)) > 0)
    .map((unit) => ({ unitId: String(unit._id), unitName: unit.name, bookings: counts.get(String(unit._id)) }));
}

/** The 409 body the editor turns into "A1 still has bookings". */
export const unitHasBookingsResponse = (blocked) => ({
  message: `These units still have upcoming bookings and cannot be removed: ${blocked.map((unit) => unit.unitName).join(", ")}.`,
  code: "unitHasBookings",
  units: blocked,
});
