import { pathToFileURL } from "node:url";

import mongoose from "mongoose";
import "../config/env.js";
import Accommodation from "../models/Accommodation.js";
import Reservation from "../models/Reservation.js";

const APPLY = process.argv.includes("--apply");

/**
 * Which of a property's rows are orphans, given the ids that still exist.
 *
 * Exported and free of any database access so the selection rule can be tested
 * on its own — this decides what gets deleted, and it is the part worth being
 * sure about.
 */
export const orphanRowsOf = (rows, aliveIds) => {
  const orphans = [];
  let heldSkipped = 0;

  for (const row of rows || []) {
    // Manual blocks and iCal imports carry no reservation link; never touched.
    if (!row.reservationId) continue;
    if (aliveIds.has(String(row.reservationId))) continue;
    // Checkout holds lapse on their own and belong to `calendarHold`.
    if (row.status === "held") {
      heldSkipped++;
      continue;
    }
    orphans.push(row);
  }

  return { orphans, heldSkipped };
};

const iso = (value) => {
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? "??" : d.toISOString().slice(0, 10);
};

async function run() {
  await mongoose.connect(process.env.MONGODB_URI, {});
  console.log(`Connected. Mode: ${APPLY ? "APPLY" : "DRY RUN"}\n`);

  const accommodations = await Accommodation.find({
    "occupancyCalendar.reservationId": { $ne: null },
  }).select("_id name occupancyCalendar");

  console.log(`${accommodations.length} propert${accommodations.length === 1 ? "y" : "ies"} carry linked rows.\n`);

  // Every reservation id referenced anywhere, resolved in ONE query rather than
  // one per row — a property with years of history would otherwise issue
  // hundreds of round-trips.
  const referenced = new Set();
  for (const acc of accommodations) {
    for (const row of acc.occupancyCalendar || []) {
      if (row.reservationId) referenced.add(String(row.reservationId));
    }
  }

  const alive = new Set(
    (
      await Reservation.find({ _id: { $in: [...referenced] } }).select("_id")
    ).map((r) => String(r._id))
  );

  console.log(`${referenced.size} reservation ids referenced, ${alive.size} still exist.\n`);

  let propertiesTouched = 0;
  let rowsRemoved = 0;
  let heldSkipped = 0;

  for (const acc of accommodations) {
    const rows = acc.occupancyCalendar || [];

    const { orphans, heldSkipped: held } = orphanRowsOf(rows, alive);
    heldSkipped += held;

    if (!orphans.length) continue;

    propertiesTouched++;
    console.log(`${acc.name || "(unnamed)"}  [${acc._id}]`);
    for (const row of orphans) {
      console.log(
        `   ${iso(row.startDate)} → ${iso(row.endDate)}  ` +
          `status=${row.status}  guest=${row.guestName || "N/A"}  ` +
          `reservationId=${row.reservationId} (missing)`
      );
    }
    rowsRemoved += orphans.length;

    if (APPLY) {
      const doomed = new Set(orphans.map((row) => String(row._id)));
      acc.occupancyCalendar = rows.filter((row) => !doomed.has(String(row._id)));
      await acc.save();
      console.log(`   removed ${orphans.length}\n`);
    } else {
      console.log(`   would remove ${orphans.length}\n`);
    }
  }

  console.log("─".repeat(60));
  console.log(
    `${APPLY ? "Removed" : "Would remove"} ${rowsRemoved} orphaned row(s) ` +
      `across ${propertiesTouched} propert${propertiesTouched === 1 ? "y" : "ies"}.`
  );
  if (heldSkipped) {
    console.log(`${heldSkipped} live 'held' row(s) left alone — checkout holds lapse on their own.`);
  }
  if (!APPLY && rowsRemoved) {
    console.log("\nRe-run with --apply to remove them.");
  }

  await mongoose.disconnect();
}

// Only when run as a script. Importing this module (to test `orphanRowsOf`)
// must not open a database connection or delete anything.
const executedDirectly =
  process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;

if (executedDirectly) {
  run().catch(async (error) => {
    console.error("sweepOrphanOccupancy failed:", error);
    await mongoose.disconnect().catch(() => {});
    process.exit(1);
  });
}
