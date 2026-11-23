import { pathToFileURL } from "node:url";

import mongoose from "mongoose";
import "../config/env.js";
import Accommodation from "../models/Accommodation.js";
import Review, { reviewScoreExpression } from "../models/Review.js";

const APPLY = process.argv.includes("--apply");

/**
 * Recompute every listing's stored `averageRating`.
 *
 * `Review.calAverageRatings` only fires when a review is saved or deleted, so
 * changing how a rating is derived leaves every existing listing on the old
 * figure until someone happens to review it again. This walks them all once.
 *
 * The rating used to average `overallRating` — a star row on the review form
 * captured separately from the eight category rows and unrelated to them — so a
 * listing card could advertise 5.0 while every category bar on its own page
 * read 4.x. It is now the mean of the category stars guests actually awarded,
 * per models/Review.js.
 *
 * Dry run by default; pass --apply to write.
 */

/** Which listings actually need writing, and what to. Pure, so it is testable. */
export const changedRatings = (scored, listings, epsilon = 0.0005) => {
  const next = new Map(scored.map((row) => [String(row._id), row.avgRating]));
  const changes = [];

  for (const listing of listings) {
    // No usable reviews means no rating, not a rating of zero-point-something.
    const to = next.get(String(listing._id)) ?? 0;
    const from = typeof listing.averageRating === "number" ? listing.averageRating : 0;
    if (Math.abs(to - from) > epsilon) changes.push({ listing, from, to });
  }

  return changes;
};

async function run() {
  await mongoose.connect(process.env.MONGODB_URI, {});
  console.log(`Connected. Mode: ${APPLY ? "APPLY" : "DRY RUN"}\n`);

  // One pass over every review, scored exactly as the live hook scores them.
  const scored = await Review.aggregate([
    { $project: { accommodation: 1, score: reviewScoreExpression } },
    { $match: { score: { $ne: null } } },
    {
      $group: {
        _id: "$accommodation",
        numOfRatings: { $sum: 1 },
        avgRating: { $avg: "$score" },
      },
    },
  ]);

  const listings = await Accommodation.find({}).select("_id name averageRating");

  console.log(
    `${listings.length} listing(s); ${scored.length} have at least one usable review.\n`
  );

  const changes = changedRatings(scored, listings);

  for (const { listing, from, to } of changes) {
    const name = listing.name || "(unnamed)";
    console.log(
      `${name}  [${listing._id}]\n` +
        `   ${from.toFixed(2)} → ${to.toFixed(2)}${to === 0 ? "  (no usable reviews)" : ""}`
    );
  }

  if (APPLY && changes.length) {
    await Accommodation.bulkWrite(
      changes.map(({ listing, to }) => ({
        updateOne: { filter: { _id: listing._id }, update: { $set: { averageRating: to } } },
      }))
    );
  }

  console.log("\n" + "─".repeat(60));
  console.log(
    `${APPLY ? "Updated" : "Would update"} ${changes.length} listing(s); ` +
      `${listings.length - changes.length} already correct.`
  );
  if (!APPLY && changes.length) console.log("\nRe-run with --apply to write them.");

  await mongoose.disconnect();
}

// Only when run as a script. Importing this module (to test `changedRatings`)
// must not open a database connection or write anything.
const executedDirectly =
  process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;

if (executedDirectly) {
  run().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
