// scripts/hauziSync/index.js
//
// Compares Putko listings against their Hauzi.sk originals, field by field, and
// (optionally) updates Putko so the two match.
//
// Input: a CSV with one listing per row and three columns
//
//   hauziUrl, putkoUrl, hostEmail
//
// Output: a report CSV with one row per compared field, so every difference is
// visible and reviewable before anything is written.
//
// Usage (from backend/):
//
//   node scripts/hauziSync/index.js [input.csv] [options]
//   npm run hauzi-sync -- [input.csv] [options]
//   npm run hauzi-sync:samples     parse the saved pages in samples/ (no network, no database)
//
// input.csv defaults to scripts/hauziSync/hauzi_sync_input.csv.
//
//   --apply        write the Hauzi values into Putko (default: dry run, report only).
//                  A Hauzi page with several units is ONE Putko listing: the listing is
//                  compared with the whole property and each Hauzi unit is synced into
//                  the listing's `units` (matched by name; a missing unit is added, a
//                  Putko unit Hauzi does not list is kept). Only the first link of the
//                  putkoUrl cell is used then; further links (old one-listing-per-unit
//                  listings) are reported SKIPPED. No listing is ever created.
//
// Run without --apply first: the PLAN report (hauzi_sync_plan_*.csv) shows every
// change and every new listing with all its values. Then run with --apply: the
// RESULT report (hauzi_sync_result_*.csv) shows what was done — old value, new
// value, match / mismatch / updated / created, and why.
//   --prices       with --apply, also update pricePerNight
//   --images       with --apply, re-upload the Hauzi photos to Cloudinary and
//                  replace the listing's and each unit's images when the photo count differs
//   --parse-only   no database at all: only extract the Hauzi data into the CSV
//                  (useful for checking the parser against a saved .html file)
//   --output FILE  report path (default: hauzi_sync_plan_/result_/parsed_<timestamp>.csv
//                  next to the input)
//   --delay MS     pause between Hauzi requests (default 1500)
//
// Hauzi pages are fetched with axios, then curl, then ScraperAPI
// (SCRAPERAPI_KEY in backend/.env) when Cloudflare blocks the first two.
//
// The hauziUrl column may also be a path to a saved Hauzi .html page
// (relative to the CSV, or to the working directory).
//
// Files:
//
//   index.js     run the script (this file)
//   helpers.js   command-line options, text helpers, Putko translations, CSV in/out
//   parse.js     read a Hauzi page: rooms, amenities, house rules, area
//   fetch.js     download Hauzi pages and booking details (prices, min stay, pet fee)
//   sync.js      compare with Putko field by field, update with --apply
//   samples/     saved Hauzi pages + sample_input.csv for --parse-only
//
// Hauzi is treated as the source of truth. For multi-choice amenity groups the
// Hauzi set REPLACES the Putko set (that is how a wrong importer default such as
// wellness = ["Sauna"] gets corrected) — except where Hauzi has no data for the
// group at all, in which case the field is reported NOT_ON_HAUZI and left alone.
//
// Price and min nights are taken only when the page shows them; otherwise the
// report says the property has none on Hauzi and Putko's value is kept.

import "../../config/env.js";
import { pathToFileURL } from "node:url";
import fs from "node:fs";
import path from "node:path";
import mongoose from "mongoose";
import { option, APPLY, UPDATE_PRICES, UPDATE_IMAGES, FLEXIBLE_PRICES_ONLY, PARSE_ONLY, DELAY_MS, INPUT, readInput, writeReport, sleep } from "./helpers.js";
import { syncOne } from "./sync.js";

// ─── Main ────────────────────────────────────────────────────────────────────

// First row of the report: how to read it.
const REPORT_ABOUT = {
  parsed: "PARSE ONLY: what was read from each Hauzi page. Nothing was compared or changed.",
  plan:
    "PLAN (dry run): nothing was changed. MATCH = same on both. MISMATCH = --apply will replace putkoOldValue with putkoNewValue (Hauzi value). " +
    "NOT_ON_HAUZI / SKIPPED = Putko value kept. WOULD_ADD = --apply will add this Hauzi unit to the listing's units; its rows show every value it will get. " +
    "Putko units Hauzi does not list are kept (NOT_ON_HAUZI).",
  result:
    "RESULT (--apply): UPDATED = putkoOldValue was replaced with putkoNewValue. MATCH = already the same. NOT_ON_HAUZI / SKIPPED = Putko value kept. " +
    "ADDED = unit added to the listing. ERROR = nothing written for that row.",
};

// Headings of the final report (the _final rows at the end of the CSV, the
// console and the .summary.json), per kind of outcome.
const FINAL_HEADINGS = {
  created: () => (APPLY ? "NEW ACCOMMODATIONS CREATED" : "NEW ACCOMMODATIONS TO BE CREATED (dry run)"),
  updated: () => (APPLY ? "UPDATED (existing accommodations)" : "EXISTING ACCOMMODATIONS (dry run: compared, --apply updates them)"),
  skipped: () => "SKIPPED",
  failed: () => "FAILED",
};
const FINAL_STATUS = { created: APPLY ? "CREATED" : "WOULD_CREATE", updated: APPLY ? "UPDATED" : "EXISTING", skipped: "SKIPPED", failed: "ERROR" };

/** The final report: one _final row per listing, created first, and the console list. */
const finalReport = (outcomes) => {
  const rows = [];
  const lines = ["", "════ FINAL REPORT ════"];
  for (const kind of ["created", "updated", "skipped", "failed"]) {
    const list = outcomes[kind];
    lines.push("", `${FINAL_HEADINGS[kind]()}: ${list.length}`);
    list.forEach((o, n) => {
      lines.push(`  ${n + 1}. ${o.url || "(no link)"}  —  ${o.name || "?"}${o.id ? ` (id ${o.id})` : ""}${o.note ? `  [${o.note}]` : ""}`);
      rows.push({
        row: o.row, hauziUrl: o.hauziUrl, putkoUrl: o.url || "", listing: o.name || "", field: "_final", status: FINAL_STATUS[kind],
        hauziValue: o.unit || "", note: [o.id ? `id ${o.id}` : "", o.note || ""].filter(Boolean).join("; "),
      });
    });
  }
  return { rows, text: lines.join("\n") };
};

async function run() {
  const inputFile = path.resolve(INPUT);
  if (!fs.existsSync(inputFile)) throw new Error(`Input CSV not found: ${inputFile}`);

  // Dry run → the PLAN report (what --apply will do); --apply → the RESULT
  // report (what was done). Both list every field with old and new value.
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const kind = PARSE_ONLY ? "parsed" : APPLY ? "result" : "plan";
  const outputFile = path.resolve(option("--output", path.join(path.dirname(inputFile), `hauzi_sync_${kind}_${timestamp}.csv`)));

  const inputs = readInput(inputFile);
  console.log(`${inputs.length} listing(s) in ${inputFile}`);
  console.log(`Mode: ${PARSE_ONLY ? "PARSE ONLY (no database)" : APPLY ? "APPLY" : "DRY RUN"}` +
    `${UPDATE_PRICES ? " +prices" : ""}${UPDATE_IMAGES ? " +images" : ""}${FLEXIBLE_PRICES_ONLY ? " +flexible-prices-only" : ""}\n`);

  if (!PARSE_ONLY) await mongoose.connect(process.env.MONGODB_URI, {});

  const report = [{ field: "_about", status: kind.toUpperCase(), note: REPORT_ABOUT[kind] }];
  // Every listing once: created, updated (existing), skipped or failed.
  const outcomes = { created: [], updated: [], skipped: [], failed: [] };
  for (let i = 0; i < inputs.length; i++) {
    const input = inputs[i];
    const label = `[${i + 1}/${inputs.length}] ${input.hauziUrl}`;
    try {
      const rows = await syncOne(input, i + 1, outcomes);
      report.push(...rows);
      const highlights = rows.filter((r) => r.field === "_summary" || r.field === "_unitsSummary" || (r.field === "_listing" && r.status === "ERROR"));
      if (!highlights.length) console.log(`${label} → ${rows[rows.length - 1]?.status || "done"}`);
      for (const r of highlights) {
        console.log(`${label} → ${r.listing || ""}: ${r.status === "ERROR" ? `${r.status}: ${r.note}` : r.note}`);
      }
    } catch (err) {
      // One bad page or listing must not end the run.
      report.push({ row: i + 1, ...input, field: "_listing", status: "ERROR", note: err.message.slice(0, 300) });
      outcomes.failed.push({ row: i + 1, hauziUrl: input.hauziUrl, name: null, id: null, url: input.putkoUrl || null, note: err.message.slice(0, 300) });
      console.error(`${label} → ERROR: ${err.message}`);
    }
    writeReport(outputFile, report);
    if (i < inputs.length - 1 && /^https?:/i.test(inputs[i + 1].hauziUrl)) await sleep(DELAY_MS);
  }

  if (!PARSE_ONLY) {
    const final = finalReport(outcomes);
    writeReport(outputFile, [...report, ...final.rows]);
    const summaryFile = outputFile.replace(/\.csv$/i, "") + ".summary.json";
    fs.writeFileSync(summaryFile, JSON.stringify({ mode: kind, ...outcomes }, null, 2), "utf8");
    console.log(final.text);
    console.log(`\nSummary: ${summaryFile}`);
  }
  console.log(`\nReport: ${outputFile}`);
  if (!PARSE_ONLY) await mongoose.disconnect();
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;

if (isMain) {
  run()
    .then(() => process.exit(0))
    .catch(async (err) => {
      console.error("❌", err.message);
      await mongoose.disconnect().catch(() => {});
      process.exit(1);
    });
}
