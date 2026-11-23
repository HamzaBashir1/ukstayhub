/**
 * Host workspace — per-property availability.
 *
 * Works on the real `Accommodation`, which already carries a calendar:
 *
 * - `occupancyCalendar[]` — dated rows with a status (booked / blocked / held /
 *   available) and a `source` of manual | ics | reservation. Checkout writes
 *   `held` and `booked` rows here, so a host blocking a date and a guest
 *   booking one meet in the same place.
 * - `calendarSync[]` — the connected iCal feeds and what the last fetch did.
 *
 * It used to keep its own `HostCalendarBlock` / `HostCalendarFeed` collections
 * from the Putko port, which meant the host's calendar and the site's real
 * availability were two unrelated sets of dates.
 *
 * The wire format is unchanged, so the screen needs no rework: inclusive
 * `YYYY-MM-DD` ranges, and every mutation answers with the whole snapshot
 * because the screen replaces its state wholesale.
 */

import { randomUUID } from "node:crypto";
import ical from "ical";
import mongoose from "mongoose";

import Accommodation from "../models/Accommodation.js";
import HostListing from "../models/HostListing.js";
import Reservation from "../models/Reservation.js";
import { addDays, isIsoDate, isObjectId, todayIso, validateRange } from "../utils/hostWorkspace.js";
import { isHttpUrl } from "../utils/hostListingCompletion.js";
import { feedUnitStamp, findUnit, listingUnits, rowBlocksUnit } from "../utils/listingUnits.js";

const NOT_FOUND = { message: "Property not found." };

const RANGE_ERRORS = {
  rangeRequired: "A date range is required.",
  rangeInvalid: "Dates must be calendar dates in YYYY-MM-DD form.",
  rangeReversed: "The range ends before it starts.",
};

const FEED_TIMEOUT_MS = 15_000;
const MAX_FEED_EVENTS = 2_000;

/* ------------------------------------------------------------------ dates */

/** Stored rows are Dates; the API speaks `YYYY-MM-DD`. */
const toIso = (value) => {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString().slice(0, 10);
};

/** UTC midnight, so a stored row means the same day in every timezone. */
const toDate = (iso) => new Date(`${iso}T00:00:00.000Z`);

/* --------------------------------------------------------------- snapshot */

/** Rows that actually make a date unavailable. `available` rows do not. */
const BLOCKING = new Set(["booked", "blocked", "held"]);

/**
 * What a calendar row actually IS, for the screen.
 *
 * Not simply `row.source`: that field defaults to "manual" in the schema and
 * `confirmHold` never sets it, so every paid booking on the calendar claimed to
 * be a block the host had added by hand. The host calendar then offered
 * "Unblock" on a real stay — which would have freed a paid guest's dates with
 * no refund, no email and no cancellation record.
 *
 * The reservation link is the reliable signal, so it wins over `source`.
 * Nothing is migrated: the rule reads correctly against rows already written.
 */
const sourceOut = (row) => {
  if (row.source === "ics") return "feed";
  if (row.reservationId) return "reservation";
  return row.source || "manual";
};

/** A feed's unit for the screen: its id and name, or nulls for the whole listing. */
const feedUnitOut = (accommodation, feed) => {
  const stamp = feedUnitStamp(accommodation, feed);
  return { unitId: stamp.unitId ? stamp.unitId.toString() : null, unitName: stamp.unitName || null };
};

const buildSnapshot = (accommodation) => {
  const feeds = (accommodation.calendarSync || []).map((feed) => ({
    id: feed._id.toString(),
    label: feed.label || "",
    url: feed.url,
    // The model records 'ok' | 'error' | 'never'; the screen expects
    // 'ok' | 'failed' | 'never'.
    status: feed.lastSyncStatus === "error" ? "failed" : feed.lastSyncStatus || "never",
    lastAttemptAt: feed.lastSyncAt || null,
    lastFetchedAt: feed.lastSyncStatus === "ok" ? feed.lastSyncAt || null : null,
    lastError: feed.lastSyncError || null,
    importedCount: feed.lastImportedCount || 0,
    // The unit this calendar blocks, on a listing split into units. Null means
    // the whole listing — every feed without a unit, and one whose unit has
    // since been removed (its dates then block every unit).
    ...feedUnitOut(accommodation, feed),
  }));

  const blocks = (accommodation.occupancyCalendar || [])
    .filter((row) => BLOCKING.has(row.status))
    .map((row) => ({
      id: row._id.toString(),
      startDate: toIso(row.startDate),
      endDate: toIso(row.endDate),
      source: sourceOut(row),
      feedId: row.calendarSyncId ? row.calendarSyncId.toString() : null,
      reservationId: row.reservationId ? row.reservationId.toString() : null,
      // A checkout that is under way but unpaid. The dates are unavailable, so
      // the row still blocks, but there is no booking to cancel yet and the
      // hold lapses on its own — so the screen offers no action on it.
      pending: row.status === "held",
      // A booked row carries the guest's name; a manual one the host's note.
      note: row.guestName && row.guestName !== "N/A" ? row.guestName : null,
      // The unit this row takes, on a listing split into units. Null means
      // the whole listing (every unit).
      unitId: row.unitId ? row.unitId.toString() : null,
      unitName: row.unitId ? row.unitName || null : null,
    }))
    .filter((block) => block.startDate && block.endDate)
    .sort((a, b) => a.startDate.localeCompare(b.startDate));

  return {
    listing: {
      id: accommodation._id.toString(),
      name: accommodation.name || "",
      status: accommodation.status || "DRAFT",
    },
    // Derived rather than stored: a property with feeds connected is on
    // "connect", one without manages availability by hand.
    calendarChoice: (accommodation.calendarSync || []).length > 0 ? "connect" : "none",
    // The listing's units, so the screen can show and block one at a time.
    // Empty on a listing without units, which keeps the screen as it was.
    units: listingUnits(accommodation).map((unit) => ({ id: unit._id.toString(), name: unit.name })),
    today: todayIso(),
    blocks,
    feeds,
  };
};

/** The property, but only when this host owns it. */
const loadOwned = async (req, res) => {
  if (!isObjectId(req.params.id)) {
    res.status(404).json(NOT_FOUND);
    return null;
  }

  let accommodation = await Accommodation.findOne({
    _id: req.params.id,
    userId: req.hostId,
  });

  // The id may be a workspace draft's rather than an accommodation's.
  //
  // A listing created in the host editor is a `HostListing`; publishing it
  // creates a SEPARATE `Accommodation` and records its id on the draft. The
  // draft keeps its own id, and that is the id every host screen passes
  // around — the listings grid, the editor, the calendar link out of it. So
  // every calendar request for a workspace-created listing arrived with an id
  // this collection has never held, and the host was told "This listing no
  // longer exists" about a property that was live on the site.
  //
  // Only the draft's own accommodation is accepted, and still only when this
  // host owns it, so this widens which id opens a calendar, never whose.
  if (!accommodation) {
    const listing = await HostListing.findOne({
      _id: req.params.id,
      ownerId: req.hostId,
    }).select("accommodationId");

    if (listing?.accommodationId) {
      accommodation = await Accommodation.findOne({
        _id: listing.accommodationId,
        userId: req.hostId,
      });
    }
  }

  if (!accommodation) {
    res.status(404).json(NOT_FOUND);
    return null;
  }
  return accommodation;
};

const respond = (res, accommodation, status = 200) =>
  res.status(status).json(buildSnapshot(accommodation));

/* ------------------------------------------------------------- read */

// GET /api/host/host-accommodations/:id/calendar
export const getHostCalendar = async (req, res) => {
  try {
    const accommodation = await loadOwned(req, res);
    if (!accommodation) return;

    respond(res, accommodation);
  } catch (error) {
    console.error("Error in getHostCalendar controller:", error.message);
    res.status(500).json({ message: "Could not load the calendar." });
  }
};

/* ----------------------------------------------------------- manual blocks */

// POST /api/host/host-accommodations/:id/calendar/blocks
export const blockHostCalendarRange = async (req, res) => {
  try {
    const accommodation = await loadOwned(req, res);
    if (!accommodation) return;

    const { startDate, endDate, note, unitId } = req.body || {};
    const problem = validateRange({ startDate, endDate });
    if (problem) {
      return res.status(400).json({ message: RANGE_ERRORS[problem], code: problem });
    }

    // Optional: block one unit of a listing split into units. Without it the
    // block closes the whole listing, every unit, as it always has.
    const unit = unitId ? findUnit(accommodation, unitId) : null;
    if (unitId && !unit) {
      return res.status(400).json({ message: "That unit does not exist on this listing.", code: "unitNotFound" });
    }

    // A date a guest has already booked or is holding cannot be blocked: the
    // block would not free it, it would just hide a commitment from the host.
    // Blocking one unit only clashes with bookings that take that unit.
    const clash = (accommodation.occupancyCalendar || []).find(
      (row) =>
        (row.status === "booked" || row.status === "held") &&
        toIso(row.startDate) <= endDate &&
        toIso(row.endDate) >= startDate &&
        (!unit || rowBlocksUnit(row, unit._id)),
    );
    if (clash) {
      return res.status(409).json({
        message: "Those dates include a booking, so they cannot be blocked.",
        code: "datesBooked",
        conflicts: [
          {
            id: clash._id.toString(),
            startDate: toIso(clash.startDate),
            endDate: toIso(clash.endDate),
            source: sourceOut(clash.source),
          },
        ],
      });
    }

    accommodation.occupancyCalendar.push({
      startDate: toDate(startDate),
      endDate: toDate(endDate),
      status: "blocked",
      source: "manual",
      guestName: typeof note === "string" && note.trim() ? note.trim() : "N/A",
      ...(unit ? { unitId: unit._id, unitName: unit.name } : {}),
    });
    await accommodation.save();

    respond(res, accommodation, 201);
  } catch (error) {
    console.error("Error in blockHostCalendarRange controller:", error.message);
    res.status(500).json({ message: "Could not block those dates." });
  }
};

// POST /api/host/host-accommodations/:id/calendar/unblock
export const unblockHostCalendarRange = async (req, res) => {
  try {
    const accommodation = await loadOwned(req, res);
    if (!accommodation) return;

    const { startDate, endDate, unitId, blockId } = req.body || {};
    const problem = validateRange({ startDate, endDate });
    if (problem) {
      return res.status(400).json({ message: RANGE_ERRORS[problem], code: problem });
    }

    // Optional: open the dates for one unit only. Without it every manual
    // block in the range goes, whole-listing and per-unit alike.
    const unit = unitId ? findUnit(accommodation, unitId) : null;
    if (unitId && !unit) {
      return res.status(400).json({ message: "That unit does not exist on this listing.", code: "unitNotFound" });
    }
    const otherUnits = unit
      ? listingUnits(accommodation).filter((other) => String(other._id) !== String(unit._id))
      : [];

    // Only the host's own blocks are theirs to clear. A feed row returns on
    // the next fetch and a reservation row is someone's booking, so removing
    // either here would be undone or would double-book the property.
    const kept = [];
    for (const row of accommodation.occupancyCalendar || []) {
      if (row.source !== "manual" || row.status !== "blocked") {
        kept.push(row);
        continue;
      }

      // `blockId` (the day sheet's Unblock) clears exactly that one block.
      if (blockId && String(row._id) !== String(blockId)) {
        kept.push(row);
        continue;
      }

      // Another unit's block is not this unit's to clear.
      if (unit && row.unitId && String(row.unitId) !== String(unit._id)) {
        kept.push(row);
        continue;
      }

      const from = toIso(row.startDate);
      const to = toIso(row.endDate);
      if (!from || !to || to < startDate || from > endDate) {
        kept.push(row);
        continue;
      }

      // Clearing part of a block can leave nothing, one remainder, or two.
      if (from < startDate) {
        kept.push({ ...row.toObject(), _id: new mongoose.Types.ObjectId(), endDate: toDate(addDays(startDate, -1)) });
      }
      if (to > endDate) {
        kept.push({ ...row.toObject(), _id: new mongoose.Types.ObjectId(), startDate: toDate(addDays(endDate, 1)) });
      }

      // Opening one unit inside a whole-listing block: the other units stay
      // closed for the cleared part, so each gets a block of its own.
      if (unit && !row.unitId) {
        const overlapFrom = from > startDate ? from : startDate;
        const overlapTo = to < endDate ? to : endDate;
        for (const other of otherUnits) {
          kept.push({
            ...row.toObject(),
            _id: new mongoose.Types.ObjectId(),
            startDate: toDate(overlapFrom),
            endDate: toDate(overlapTo),
            unitId: other._id,
            unitName: other.name,
          });
        }
      }
    }

    accommodation.occupancyCalendar = kept;
    await accommodation.save();

    respond(res, accommodation);
  } catch (error) {
    console.error("Error in unblockHostCalendarRange controller:", error.message);
    res.status(500).json({ message: "Could not free those dates." });
  }
};

/* --------------------------------------------------------------- iCal feeds */

/** Rows a given feed imported. */
const isFeedRow = (row, feedId) =>
  row.source === "ics" && String(row.calendarSyncId || "") === String(feedId);

/**
 * The unit a feed request names, on a listing split into units.
 *
 * `undefined` (the field not sent) leaves the feed as it is; `null` or "" means
 * the whole listing; anything else must be one of this listing's units.
 *
 * @returns {{unit: object|null|undefined, problem?: true}}
 */
const feedUnitFrom = (accommodation, unitId) => {
  if (unitId === undefined) return { unit: undefined };
  if (unitId === null || unitId === "") return { unit: null };
  const unit = findUnit(accommodation, unitId);
  return unit ? { unit } : { unit: undefined, problem: true };
};

const UNIT_NOT_FOUND = { message: "That unit does not exist on this listing.", code: "unitNotFound" };

// POST /api/host/host-accommodations/:id/calendar/mode
export const setHostCalendarMode = async (req, res) => {
  try {
    const accommodation = await loadOwned(req, res);
    if (!accommodation) return;

    const { calendarChoice } = req.body || {};
    if (calendarChoice !== "none" && calendarChoice !== "connect") {
      return res.status(400).json({
        message: 'calendarChoice must be "none" or "connect".',
        code: "calendarChoiceInvalid",
      });
    }

    // "Manual only" means the connected calendars go, along with the dates
    // they imported — the screen confirms this before calling, listing them.
    if (calendarChoice === "none") {
      accommodation.occupancyCalendar = (accommodation.occupancyCalendar || []).filter(
        (row) => row.source !== "ics",
      );
      accommodation.calendarSync = [];
      await accommodation.save();
    }

    respond(res, accommodation);
  } catch (error) {
    console.error("Error in setHostCalendarMode controller:", error.message);
    res.status(500).json({ message: "Could not change the calendar mode." });
  }
};

// POST /api/host/host-accommodations/:id/calendar/feeds
export const addHostCalendarFeed = async (req, res) => {
  try {
    const accommodation = await loadOwned(req, res);
    if (!accommodation) return;

    const { url, label, unitId } = req.body || {};
    if (!isHttpUrl(url)) {
      return res.status(400).json({
        message: "Enter a valid http(s) calendar link.",
        code: "feedUrlInvalid",
      });
    }

    // Optional: the unit this calendar belongs to. Without it the calendar
    // blocks the whole listing, as every calendar always has.
    const { unit, problem } = feedUnitFrom(accommodation, unitId);
    if (problem) return res.status(400).json(UNIT_NOT_FOUND);

    const trimmed = url.trim();
    if ((accommodation.calendarSync || []).some((feed) => feed.url === trimmed)) {
      return res.status(409).json({
        message: "That calendar link is already connected.",
        code: "feedDuplicate",
      });
    }

    accommodation.calendarSync.push({
      url: trimmed,
      label: typeof label === "string" ? label.trim() : "",
      lastSyncStatus: "never",
      ...(unit ? { unitId: unit._id } : {}),
    });
    await accommodation.save();

    respond(res, accommodation, 201);
  } catch (error) {
    console.error("Error in addHostCalendarFeed controller:", error.message);
    res.status(500).json({ message: "Could not connect that calendar." });
  }
};

// PATCH /api/host/host-accommodations/:id/calendar/feeds/:feedId
export const updateHostCalendarFeed = async (req, res) => {
  try {
    const accommodation = await loadOwned(req, res);
    if (!accommodation) return;

    const feed = accommodation.calendarSync?.id(req.params.feedId);
    if (!feed) return res.status(404).json({ message: "Calendar link not found." });

    const { url, label, unitId } = req.body || {};
    const previousUrl = feed.url;

    const { unit, problem } = feedUnitFrom(accommodation, unitId);
    if (problem) return res.status(400).json(UNIT_NOT_FOUND);

    if (url !== undefined) {
      if (!isHttpUrl(url)) {
        return res.status(400).json({
          message: "Enter a valid http(s) calendar link.",
          code: "feedUrlInvalid",
        });
      }
      feed.url = url.trim();
    }
    if (label !== undefined) feed.label = String(label).trim();

    // A new unit moves the dates already imported with it, so the calendar is
    // right at once rather than after the next fetch.
    if (unit !== undefined) {
      feed.unitId = unit ? unit._id : undefined;
      const stamp = feedUnitStamp(accommodation, feed);
      for (const row of accommodation.occupancyCalendar || []) {
        if (!isFeedRow(row, feed._id)) continue;
        row.unitId = stamp.unitId;
        row.unitName = stamp.unitName;
      }
    }

    // A changed URL invalidates what the old one imported: those dates are not
    // this feed's any more and must not linger until the next fetch.
    if (feed.url !== previousUrl) {
      accommodation.occupancyCalendar = (accommodation.occupancyCalendar || []).filter(
        (row) => !isFeedRow(row, feed._id),
      );
      feed.lastSyncStatus = "never";
      feed.lastSyncAt = undefined;
      feed.lastSyncError = undefined;
      feed.lastImportedCount = 0;
    }

    await accommodation.save();
    respond(res, accommodation);
  } catch (error) {
    console.error("Error in updateHostCalendarFeed controller:", error.message);
    res.status(500).json({ message: "Could not update that calendar link." });
  }
};

// DELETE /api/host/host-accommodations/:id/calendar/feeds
//
// Disconnects every feed at once, same as the traveller-side Synchronization
// page's "Remove sync" button: `removeImported` also drops every date those
// feeds imported, otherwise the dates stay blocked but nothing will refresh
// them again.
export const removeAllHostCalendarFeeds = async (req, res) => {
  try {
    const accommodation = await loadOwned(req, res);
    if (!accommodation) return;

    const removeImported = req.body?.removeImported === true;
    const hadFeeds = (accommodation.calendarSync || []).length > 0;

    accommodation.calendarSync = [];

    let removedCount = 0;
    if (removeImported) {
      const before = accommodation.occupancyCalendar.length;
      accommodation.occupancyCalendar = (accommodation.occupancyCalendar || []).filter(
        (row) => row.source !== "ics",
      );
      removedCount = before - accommodation.occupancyCalendar.length;
    }

    await accommodation.save();

    res.status(200).json({ ...buildSnapshot(accommodation), hadFeeds, removedCount });
  } catch (error) {
    console.error("Error in removeAllHostCalendarFeeds controller:", error.message);
    res.status(500).json({ message: "Could not disconnect your calendars." });
  }
};

// DELETE /api/host/host-accommodations/:id/calendar/feeds/:feedId
export const removeHostCalendarFeed = async (req, res) => {
  try {
    const accommodation = await loadOwned(req, res);
    if (!accommodation) return;

    const feed = accommodation.calendarSync?.id(req.params.feedId);
    if (!feed) return res.status(404).json({ message: "Calendar link not found." });

    accommodation.occupancyCalendar = (accommodation.occupancyCalendar || []).filter(
      (row) => !isFeedRow(row, feed._id),
    );
    accommodation.calendarSync.pull({ _id: feed._id });
    await accommodation.save();

    respond(res, accommodation);
  } catch (error) {
    console.error("Error in removeHostCalendarFeed controller:", error.message);
    res.status(500).json({ message: "Could not remove that calendar link." });
  }
};

/**
 * `ical`'s VALUE=DATE parsing builds each Date from the bare `YYYY-MM-DD` in
 * the feed using the SERVER's local clock ("No TZ info - assume same
 * timezone as this computer", ical.js `dateParam`), not UTC. Reading it back
 * with `.toISOString()` re-interprets those local-midnight components as UTC,
 * so on any server timezone ahead of UTC (e.g. Europe/Bratislava) every
 * imported date lands one calendar day earlier than the feed actually says.
 * Reading the same local components back out undoes exactly that shift,
 * whatever the server's zone.
 */
const isoOfLocalDate = (date) =>
  `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;

/**
 * Turn an iCal document into inclusive blocked ranges.
 *
 * iCal DTEND is exclusive for all-day events, matching a booking check-out, so
 * the last blocked night is the day before it.
 */
const parseFeedRanges = (body) => {
  const parsed = ical.parseICS(body);
  const ranges = [];

  for (const event of Object.values(parsed)) {
    if (!event || event.type !== "VEVENT" || !event.start) continue;

    const start = new Date(event.start);
    const rawEnd = event.end ? new Date(event.end) : new Date(event.start);
    if (Number.isNaN(start.getTime()) || Number.isNaN(rawEnd.getTime())) continue;

    const startIso = isoOfLocalDate(start);
    const endIso = isoOfLocalDate(rawEnd);
    const inclusiveEnd = endIso > startIso ? addDays(endIso, -1) : startIso;

    if (!isIsoDate(startIso) || !isIsoDate(inclusiveEnd)) continue;

    ranges.push({
      startDate: startIso,
      endDate: inclusiveEnd,
      note: typeof event.summary === "string" ? event.summary.slice(0, 200) : null,
    });

    if (ranges.length >= MAX_FEED_EVENTS) break;
  }

  return ranges;
};

/**
 * Pull one feed's ICS document and fold it into the accommodation's
 * occupancy calendar. Mutates `accommodation` and `feed` in place; the caller
 * saves. Shared by the fetch-now route and by publish/save, which pull a
 * newly-added link immediately instead of leaving it on "never" until
 * something else asks it to fetch.
 */
export const pullCalendarFeed = async (accommodation, feed) => {
  const attemptedAt = new Date();
  let ranges = null;
  let failure = null;

  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), FEED_TIMEOUT_MS);
    try {
      const response = await fetch(feed.url, { signal: controller.signal });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      ranges = parseFeedRanges(await response.text());
    } finally {
      clearTimeout(timer);
    }
  } catch (error) {
    // A feed being unreachable is an expected outcome, not a server fault:
    // it is recorded on the feed and reported as a normal snapshot.
    failure = error.name === "AbortError" ? "timeout" : error.message;
  }

  if (failure) {
    feed.lastSyncStatus = "error";
    feed.lastSyncAt = attemptedAt;
    feed.lastSyncError = String(failure).slice(0, 300);
  } else {
    // Replace wholesale: an event removed upstream must stop blocking here.
    accommodation.occupancyCalendar = (accommodation.occupancyCalendar || []).filter(
      (row) => !isFeedRow(row, feed._id),
    );

    // A feed assigned to a unit blocks only that unit; otherwise every unit.
    const unitStamp = feedUnitStamp(accommodation, feed);
    for (const range of ranges) {
      accommodation.occupancyCalendar.push({
        startDate: toDate(range.startDate),
        endDate: toDate(range.endDate),
        status: "blocked",
        source: "ics",
        calendarSyncId: feed._id,
        guestName: range.note || "N/A",
        ...unitStamp,
      });
    }

    feed.lastSyncStatus = "ok";
    feed.lastSyncAt = attemptedAt;
    feed.lastSyncError = undefined;
    feed.lastImportedCount = ranges.length;
  }
};

// POST /api/host/host-accommodations/:id/calendar/feeds/:feedId/fetch
export const fetchHostCalendarFeed = async (req, res) => {
  try {
    const accommodation = await loadOwned(req, res);
    if (!accommodation) return;

    const feed = accommodation.calendarSync?.id(req.params.feedId);
    if (!feed) return res.status(404).json({ message: "Calendar link not found." });

    await pullCalendarFeed(accommodation, feed);

    await accommodation.save();
    respond(res, accommodation);
  } catch (error) {
    console.error("Error in fetchHostCalendarFeed controller:", error.message);
    res.status(500).json({ message: "Could not fetch that calendar." });
  }
};

export { buildSnapshot };
