// scripts/mergeUnits/index.js
//
// Converts properties stored the OLD way (one Putko listing per unit) into the
// current way: ONE new parent listing, named after the Hauzi property, whose
// `units` are the old listings. See plan.js for the rules.
//
// Input: the same CSV hauzi-sync reads. hauziUrl is the property on Hauzi (its
// name becomes the parent's name and slug); putkoUrl lists the old per-unit
// listings; hostEmail owns them all.
//
//   node scripts/mergeUnits/index.js [input.csv]                      dry run: plan report only
//   node scripts/mergeUnits/index.js [input.csv] --apply              do it (one transaction per property)
//   node scripts/mergeUnits/index.js --rollback BACKUP.json --apply   undo one run
//   --names names.json    { "<slug or id>": "Unit name" } instead of the Hauzi-matched names
//   --no-hauzi-sync       do not run hauzi-sync on the new parent afterwards
//   --prices, --images    passed on to that hauzi-sync (see README)
//   --output FILE         report path
//
// What --apply does per property, atomically:
//   • creates the parent listing (the first old listing's address, host and policies;
//     name, slug, description and flexiblePrices from Hauzi) with the old listings as units;
//     a unit takes its Hauzi Cenník as flexiblePrices when Hauzi has one, else keeps its own
//   • stamps every calendar row and iCal feed with its unit
//   • moves bookings, deleted bookings, reviews and favorites onto the parent
//   • moves host-panel reservations/blocks/messages onto a host-panel copy of the parent
//   • moves each old listing into DeletedAccommodation (kept, restorable)
// A JSON backup of everything touched is written FIRST; --rollback restores it.
// Afterwards hauzi-sync fills the rest from Hauzi: units' guests, beds, amenities, …

import "../../config/env.js";
import fs from "node:fs";
import path from "node:path";
import mongoose from "mongoose";
import Accommodation from "../../models/Accommodation.js";
import DeletedAccommodation from "../../models/DeletedAccommodation.js";
import Reservation from "../../models/Reservation.js";
import DeletedReservation from "../../models/DeletedReservation.js";
import Review from "../../models/Review.js";
import User from "../../models/User.js";
import Host from "../../models/Host.js";
import HostListing from "../../models/HostListing.js";
import HostReservation from "../../models/HostReservation.js";
import HostCalendarBlock from "../../models/HostCalendarBlock.js";
import HostConversation from "../../models/HostConversation.js";
import { mapAccommodationToListing, uniqueSlug } from "../../utils/accommodationMapper.js";
import { bumpPinCacheVersion } from "../../utils/pinCache.js";
import { readInput, SCRIPT_DIR } from "../hauziSync/helpers.js";
import { loadHauziHtml } from "../hauziSync/fetch.js";
import { parseHauziPage } from "../hauziSync/parse.js";
import { hauziUnitList, syncOne, putkoListingUrl } from "../hauziSync/sync.js";
import { planMerge, matchHauziNames } from "./plan.js";

const { EJSON } = mongoose.mongo.BSON;
const argv = process.argv.slice(2);
const APPLY = argv.includes("--apply");
const HAUZI_SYNC = !argv.includes("--no-hauzi-sync");
const val = (name) => (argv.includes(name) ? argv[argv.indexOf(name) + 1] : undefined);
const VALUE_OPTS = new Set(["--names", "--output", "--rollback"]);
const INPUT = argv.find((a, i) => !a.startsWith("--") && !VALUE_OPTS.has(argv[i - 1])) || path.join(SCRIPT_DIR, "hauzi_sync_input.csv");

const WORKSPACE_ROWS = [HostReservation, HostCalendarBlock, HostConversation];
const ids = (docs) => docs.map((d) => d._id);
const stamp = () => new Date().toISOString().replace(/[:.]/g, "-");
const csvCell = (v) => `"${String(v ?? "").replace(/"/g, '""')}"`;
const LISTING_REDIRECTS_FILE = path.resolve(SCRIPT_DIR, "../../../frontend/listing-redirects.json");
const MIDDLEWARE_FILE = path.resolve(SCRIPT_DIR, "../../../frontend/src/middleware.js");

/** Persist old per-unit URLs for Next.js to serve as permanent redirects. */
function saveListingRedirects(olds, parentSlug) {
  const redirects = fs.existsSync(LISTING_REDIRECTS_FILE)
    ? JSON.parse(fs.readFileSync(LISTING_REDIRECTS_FILE, "utf8"))
    : [];
  const bySource = new Map(redirects.map((r) => [r.source, r]));
  for (const old of olds) {
    if (!old.slug || old.slug === parentSlug) continue;
    const source = `/listings/${old.slug}`;
    bySource.set(source, { source, destination: `/listings/${parentSlug}` });
  }
  const next = [...bySource.values()].sort((a, b) => a.source.localeCompare(b.source));
  const tempFile = `${LISTING_REDIRECTS_FILE}.tmp`;
  fs.writeFileSync(tempFile, `${JSON.stringify(next, null, 2)}\n`, "utf8");
  fs.renameSync(tempFile, LISTING_REDIRECTS_FILE);
}

const slugOf = (url) => decodeURIComponent(String(url).trim().split(/[?#]/)[0].replace(/\/+$/, "").split("/").pop() || "");
const lookup = (Model, k) => (/^[a-f0-9]{24}$/i.test(k) ? Model.findById(k) : Model.findOne({ slug: k })).lean();

/** Everything the plan needs, read from the database and the Hauzi page. */
async function load(input, explicitNames) {
  if (!input.hauziUrl) throw new Error("hauziUrl is empty: the parent is named after the Hauzi property");
  if (!input.hostEmail) throw new Error("hostEmail is empty");
  const escaped = input.hostEmail.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const host = await Host.findOne({ email: new RegExp(`^${escaped}$`, "i") }).select("_id").lean();
  if (!host) throw new Error(`no host with email ${input.hostEmail}`);

  const allLinks = String(input.putkoUrl || "").split(/[\s,;]+/).filter(Boolean);
  if (!allLinks.length) throw new Error("putkoUrl is empty");
  // The same link pasted twice is one listing, not two units.
  const links = [...new Map(allLinks.map((l) => [slugOf(l), l])).values()];
  const repeated = allLinks.length - links.length;

  const olds = [];
  for (const link of links) {
    const k = slugOf(link);
    const acc = await lookup(Accommodation, k);
    if (!acc) {
      const gone = await lookup(DeletedAccommodation, k);
      throw new Error(gone
        ? `${link} is already in the deleted listings (since ${new Date(gone.deletedAt).toISOString()}); roll that run back or remove the link`
        : `no Putko listing for ${link}`);
    }
    if (String(acc.userId) !== String(host._id)) throw new Error(`"${acc.name}" belongs to another host, not ${input.hostEmail}`);
    olds.push(acc);
  }

  // The parent is the Hauzi property; its units are named as Hauzi names them.
  const hauzi = parseHauziPage(await loadHauziHtml(input.hauziUrl), input.hauziUrl);
  if (!hauzi.name) throw new Error("the Hauzi page has no property name");
  const hauziUnits = hauziUnitList(hauzi);
  const { names: fromHauzi, unmatched } = matchHauziNames(olds, hauziUnits.map((u) => u.unitName));
  const notes = unmatched.map((a) => `no Hauzi unit matches "${a.name}"; its unit name is derived from the listing name`);
  if (repeated) notes.push(`${repeated} repeated link(s) in putkoUrl ignored`);

  const parent = { _id: new mongoose.Types.ObjectId(), name: hauzi.name, description: hauzi.description, flexiblePrices: hauzi.flexiblePrices, slug: await uniqueSlug(hauzi.name) };
  // The frontend answers 410 for every path in middleware.js's goneUrls, so a reused slug would never show.
  if (fs.existsSync(MIDDLEWARE_FILE) && fs.readFileSync(MIDDLEWARE_FILE, "utf8").includes(`"/listings/${parent.slug}"`)) {
    notes.push(`/listings/${parent.slug} is in goneUrls (frontend/src/middleware.js), so the site answers 410 Gone; remove it there and redeploy the frontend`);
  }
  const oldIds = ids(olds);
  const hostListings = await HostListing.find({ accommodationId: { $in: oldIds } }).lean();
  const reservations = await Reservation.find({ accommodationId: { $in: oldIds } }).lean();
  return { olds, parent, reservations, hostListings, names: { ...fromHauzi, ...explicitNames }, hauziUnits, notes, input };
}

/** Snapshot of every document the merge will change, taken before it does. */
async function snapshot({ olds, parent, hostListings }, parentDraftId) {
  const oldIds = ids(olds);
  const workspace = {};
  for (const M of WORKSPACE_ROWS) workspace[M.modelName] = await M.find({ listingId: { $in: ids(hostListings) } }).select("_id listingId").lean();
  return {
    parent: { _id: parent._id, slug: parent.slug, draftId: hostListings.length ? parentDraftId : null },
    olds, hostListings,
    reservations: await Reservation.find({ accommodationId: { $in: oldIds } }).select("_id accommodationId unitId unitName").lean(),
    deletedReservations: await DeletedReservation.find({ accommodationId: { $in: oldIds } }).select("_id accommodationId").lean(),
    reviews: await Review.find({ accommodation: { $in: oldIds } }).select("_id accommodation").lean(),
    userFavorites: await User.find({ favorites: { $in: oldIds } }).select("_id favorites").lean(),
    hostFavorites: await Host.find({ favorites: { $in: oldIds } }).select("_id favorites").lean(),
    workspace,
  };
}

async function applyMerge(session, plan, ctx, parentDraftId) {
  const { olds, hostListings } = ctx;
  const S = { session };
  const parent = plan.parent;
  const oldIds = ids(olds);

  for (const { old, unit } of plan.oldUnits) {
    await Reservation.updateMany({ accommodationId: old._id }, { $set: { accommodationId: parent._id, unitId: unit._id, unitName: unit.name } }, S);
    await DeletedReservation.updateMany({ accommodationId: old._id }, { $set: { accommodationId: parent._id } }, S);
    await Review.updateMany({ accommodation: old._id }, { $set: { accommodation: parent._id } }, S);
  }
  for (const M of [User, Host]) {
    await M.updateMany({ favorites: { $in: oldIds } }, { $addToSet: { favorites: parent._id } }, S);
    await M.updateMany({ favorites: { $in: oldIds } }, { $pull: { favorites: { $in: oldIds } } }, S);
  }

  // Old listings go first so a slug they held is free, then the parent exists.
  for (const old of olds) {
    await DeletedAccommodation.collection.insertOne({ ...old, deletedAt: new Date() }, S);
    await Accommodation.deleteOne({ _id: old._id }, S);
  }
  await Accommodation.collection.insertOne(parent, S);

  // Host panel: one copy for the parent, carrying everything the old copies had.
  if (hostListings.length) {
    const first = hostListings[0];
    await HostListing.collection.insertOne({
      ...first, _id: parentDraftId, accommodationId: parent._id,
      data: { ...first.data, ...mapAccommodationToListing(parent) },
      createdAt: new Date(), updatedAt: new Date(),
    }, S);
    for (const d of hostListings) {
      for (const M of WORKSPACE_ROWS) await M.updateMany({ listingId: d._id }, { $set: { listingId: parentDraftId } }, S);
      await HostListing.deleteOne({ _id: d._id }, S);
    }
  }
}

async function rollback(file) {
  const b = EJSON.parse(fs.readFileSync(file, "utf8"));
  console.log(`Rollback of ${b.parent.slug}: ${b.olds.length} listing(s) come back, ${b.reservations.length} booking(s) move back`);
  if (!APPLY) return console.log("Dry run — add --apply to restore.");

  await mongoose.connection.transaction(async (session) => {
    const S = { session };
    await Accommodation.collection.deleteOne({ _id: b.parent._id }, S);
    if (b.parent.draftId) await HostListing.collection.deleteOne({ _id: b.parent.draftId }, S);
    for (const old of b.olds) {
      await DeletedAccommodation.collection.deleteOne({ _id: old._id }, S);
      await Accommodation.collection.replaceOne({ _id: old._id }, old, { ...S, upsert: true });
    }
    const back = (r) => ({
      updateOne: {
        filter: { _id: r._id },
        update: r.unitId ? { $set: { accommodationId: r.accommodationId, unitId: r.unitId, unitName: r.unitName } } : { $set: { accommodationId: r.accommodationId }, $unset: { unitId: "", unitName: "" } },
      },
    });
    if (b.reservations.length) await Reservation.collection.bulkWrite(b.reservations.map(back), S);
    if (b.deletedReservations.length) await DeletedReservation.collection.bulkWrite(b.deletedReservations.map(back), S);
    if (b.reviews.length) await Review.collection.bulkWrite(b.reviews.map((r) => ({ updateOne: { filter: { _id: r._id }, update: { $set: { accommodation: r.accommodation } } } })), S);
    for (const [M, rows] of [[User, b.userFavorites], [Host, b.hostFavorites]]) {
      if (rows.length) await M.collection.bulkWrite(rows.map((r) => ({ updateOne: { filter: { _id: r._id }, update: { $set: { favorites: r.favorites } } } })), S);
    }
    for (const h of b.hostListings) await HostListing.collection.replaceOne({ _id: h._id }, h, { ...S, upsert: true });
    for (const M of WORKSPACE_ROWS) {
      const rows = b.workspace[M.modelName] || [];
      if (rows.length) await M.collection.bulkWrite(rows.map((r) => ({ updateOne: { filter: { _id: r._id }, update: { $set: { listingId: r.listingId } } } })), S);
    }
  });
  for (const old of b.olds) await Review.calAverageRatings(old._id);
  bumpPinCacheVersion();
  console.log("Rolled back.");
}

async function run() {
  await mongoose.connect(process.env.MONGODB_URI, {});

  if (val("--rollback")) return rollback(path.resolve(val("--rollback")));

  const inputFile = path.resolve(INPUT);
  if (!fs.existsSync(inputFile)) throw new Error(`Input CSV not found: ${inputFile}`);
  const names = val("--names") ? JSON.parse(fs.readFileSync(path.resolve(val("--names")), "utf8")) : {};
  const out = path.resolve(val("--output") || path.join(path.dirname(inputFile), `merge_units_${APPLY ? "result" : "plan"}_${stamp()}.csv`));

  const rows = [["row", "property", "status", "detail"]];
  const inputs = readInput(inputFile);
  console.log(`${inputs.length} propert${inputs.length === 1 ? "y" : "ies"} — ${APPLY ? "APPLY" : "DRY RUN"}\n`);
  // Same run as machine-readable JSON: which units were added, which listings were removed, what moved.
  const props = [];
  const statusFile = out.replace(/\.csv$/i, "") + ".status.json";
  const save = () => {
    fs.writeFileSync(out, "\uFEFF" + rows.map((r) => r.map(csvCell).join(",")).join("\r\n"), "utf8");
    fs.writeFileSync(statusFile, JSON.stringify({ mode: APPLY ? "apply" : "dry-run", createdAt: new Date().toISOString(), properties: props }, null, 2), "utf8");
  };

  for (let i = 0; i < inputs.length; i++) {
    const add = (property, status, detail) => { rows.push([i + 1, property, status, detail]); console.log(`[${i + 1}] ${status} ${property}: ${detail}`); };
    const entry = { row: i + 1, status: "ERROR", hauziUrl: inputs[i].hauziUrl, putkoUrl: inputs[i].putkoUrl, hostEmail: inputs[i].hostEmail };
    props.push(entry);
    try {
      const ctx = await load(inputs[i], names);
      const plan = planMerge({ ...ctx, newId: () => new mongoose.Types.ObjectId() });
      const label = ctx.parent.name;
      const warnings = [...ctx.notes, ...(plan.warnings || [])];
      warnings.forEach((w) => add(label, "WARNING", w));
      Object.assign(entry, {
        warnings,
        parent: { id: String(ctx.parent._id), name: ctx.parent.name, slug: ctx.parent.slug, url: putkoListingUrl(ctx.parent.slug) },
      });
      if (!plan.ok) { Object.assign(entry, { status: "BLOCKED", blockers: plan.blockers }); plan.blockers.forEach((b) => add(label, "BLOCKED", b)); save(); continue; }

      const snap = await snapshot(ctx, null);
      Object.assign(entry, {
        // Units the parent will have, and the old listing each one came from.
        unitsAdded: plan.oldUnits.map(({ old, unit }) => ({ unit: unit.name, unitId: String(unit._id), fromListing: { id: String(old._id), slug: old.slug, name: old.name } })),
        // Old listings taken out of the live catalogue (kept in DeletedAccommodation).
        listingsRemoved: ctx.olds.map((o) => ({ id: String(o._id), slug: o.slug, name: o.name, movedTo: "DeletedAccommodation", redirectTo: ctx.parent.slug })),
        moved: {
          bookings: snap.reservations.length, deletedBookings: snap.deletedReservations.length, reviews: snap.reviews.length,
          favoritesUsers: snap.userFavorites.length + snap.hostFavorites.length,
          calendarRows: plan.parent.occupancyCalendar.length, calendarFeeds: plan.parent.calendarSync.length,
          hostPanelRows: Object.values(snap.workspace).reduce((n, r) => n + r.length, 0),
        },
        expiredHoldsDropped: plan.droppedHolds,
      });

      entry.flexiblePrices = { parent: plan.parent.flexiblePrices?.length || 0, units: Object.fromEntries(plan.units.map((u) => [u.name, u.flexiblePrices?.length || 0])) };
      const unitList = plan.units.map((u) => `${u.name} (${u.flexiblePrices?.length || 0} price period(s))`).join(" | ");
      const redirects = ctx.olds.map((o) => `${o.slug} -> ${ctx.parent.slug}`).join("; ");
      const summary = `new listing "${ctx.parent.name}" (/listings/${ctx.parent.slug}), ${entry.flexiblePrices.parent} price period(s); units: ${unitList}; ${ctx.reservations.length} booking(s) move; ${plan.droppedHolds} expired hold(s) dropped; old links need redirects: ${redirects}`;
      if (!APPLY) { entry.status = "WOULD_MERGE"; add(label, "WOULD_MERGE", summary); save(); continue; }

      const parentDraftId = new mongoose.Types.ObjectId();
      const backupFile = path.join(path.dirname(out), `merge_units_backup_${ctx.parent.slug}_${stamp()}.json`);
      fs.writeFileSync(backupFile, EJSON.stringify(await snapshot(ctx, parentDraftId), null, 2), "utf8");
      entry.backupFile = backupFile;
      await mongoose.connection.transaction((session) => applyMerge(session, plan, ctx, parentDraftId));
      saveListingRedirects(ctx.olds, ctx.parent.slug);
      await Review.calAverageRatings(plan.parent._id);
      bumpPinCacheVersion();
      entry.status = "MERGED";
      add(label, "MERGED", `${summary}; backup: ${backupFile}`);

      // The rest "according to Hauzi": the parent's fields and each unit's guests, beds, amenities, …
      if (HAUZI_SYNC) {
        try {
          const syncRows = await syncOne({ hauziUrl: ctx.input.hauziUrl, putkoUrl: putkoListingUrl(ctx.parent.slug), hostEmail: ctx.input.hostEmail }, i + 1);
          const counts = syncRows.reduce((c, r) => ({ ...c, [r.status]: (c[r.status] || 0) + 1 }), {});
          entry.hauziSync = {
            counts,
            // Units hauzi-sync added or matched afterwards (e.g. a Hauzi unit Putko did not have).
            units: syncRows.filter((r) => r.field === "_unit").map((r) => ({ unit: r.hauziValue, status: r.status })),
            errors: syncRows.filter((r) => r.status === "ERROR").map((r) => ({ field: r.field, note: r.note })),
          };
          add(label, counts.ERROR ? "HAUZI_SYNC_ERRORS" : "HAUZI_SYNCED", Object.entries(counts).map(([k, v]) => `${v} ${k}`).join(", "));
        } catch (err) {
          entry.hauziSync = { error: err.message.slice(0, 200) };
          add(label, "HAUZI_SYNC_ERRORS", `${err.message.slice(0, 200)}; the merge itself is complete — run hauzi-sync on /listings/${ctx.parent.slug}`);
        }
      }
    } catch (err) {
      entry.error = err.message.slice(0, 300);
      add(inputs[i].putkoUrl || inputs[i].hostEmail, "ERROR", err.message.slice(0, 300));
    }
    save();
  }
  save();
  console.log(`\nReport: ${out}`);
  console.log(`Status: ${statusFile}`);
}

run()
  .then(() => process.exit(0))
  .catch(async (err) => {
    console.error("❌", err.message);
    await mongoose.disconnect().catch(() => {});
    process.exit(1);
  });
