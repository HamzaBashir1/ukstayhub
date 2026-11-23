// Read-only: writes a CSV of listings that have no usable public slug, with the
// status of the HostListing draft behind each. Changes nothing in the database.
//
// Two kinds of row (column `problem`):
//   no_slug            an Accommodation whose slug is missing/null/blank
//   accommodation_gone a HostListing whose accommodationId points at an
//                      Accommodation that no longer exists (e.g. deleted from Admin)
//
// `draftStatus` is the linked HostListing's status (DRAFT / LIVE / ...), or
// "none" when the Accommodation has no draft. `draftIsLive` flags drafts that
// still claim LIVE although the public listing is broken.
//
//   node scripts/listMissingSlugs.js [output.csv]
import "../config/env.js";
import fs from "fs";
import mongoose from "mongoose";

const out = process.argv[2] || `accommodations_missing_slug_${new Date().toISOString().slice(0, 10)}.csv`;

const cell = (v) => {
  const s = v instanceof Date ? v.toISOString() : v == null ? "" : String(v);
  // Quote anything that could break a row; also neutralise spreadsheet formulas.
  const safe = /^[=+\-@]/.test(s) ? `'${s}` : s;
  return /[",\r\n]/.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe;
};

try {
  await mongoose.connect(process.env.MONGODB_URI);
  const db = mongoose.connection.db;
  const accommodations = db.collection("accommodations");
  const drafts = db.collection("hostlistings");

  const noSlug = await accommodations
    .find(
      { $or: [{ slug: { $exists: false } }, { slug: null }, { slug: { $regex: /^\s*$/ } }] },
      { projection: { name: 1, slug: 1, userId: 1, status: 1, listingStatus: 1, "locationDetails.city": 1, createdAt: 1, updatedAt: 1 } },
    )
    .sort({ createdAt: -1 })
    .toArray();

  // Drafts that point at an Accommodation: find the ones whose target is missing.
  const linked = await drafts
    .find({ accommodationId: { $ne: null } }, { projection: { ownerId: 1, status: 1, accommodationId: 1, "data.name": 1, createdAt: 1, updatedAt: 1 } })
    .toArray();
  const existing = new Set(
    (await accommodations.find({ _id: { $in: linked.map((d) => d.accommodationId) } }, { projection: { _id: 1 } }).toArray()).map((a) =>
      String(a._id),
    ),
  );
  const gone = linked.filter((d) => !existing.has(String(d.accommodationId)));

  // Accommodation.userId and HostListing.ownerId both reference the Host collection.
  const ownerIds = [...new Set([...noSlug.map((a) => a.userId), ...gone.map((d) => d.ownerId)].filter(Boolean).map(String))].map((id) => new mongoose.Types.ObjectId(id));
  const emailByOwner = new Map(
    (await db.collection("hosts").find({ _id: { $in: ownerIds } }, { projection: { email: 1 } }).toArray()).map((h) => [String(h._id), h.email]),
  );

  const draftByAccommodation = new Map(linked.map((d) => [String(d.accommodationId), d]));

  const header = ["problem", "accommodationId", "name", "slug", "userId", "hostEmail", "status", "listingStatus", "city", "draftId", "draftStatus", "draftIsLive", "createdAt", "updatedAt"];
  const rows = [
    ...noSlug.map((a) => {
      const d = draftByAccommodation.get(String(a._id));
      return ["no_slug", a._id, a.name, a.slug, a.userId, emailByOwner.get(String(a.userId)), a.status, a.listingStatus, a.locationDetails?.city, d?._id, d?.status || "none", d?.status === "LIVE", a.createdAt, a.updatedAt];
    }),
    ...gone.map((d) => ["accommodation_gone", d.accommodationId, d.data?.name, "", d.ownerId, emailByOwner.get(String(d.ownerId)), "", "", "", d._id, d.status, d.status === "LIVE", d.createdAt, d.updatedAt]),
  ];

  const lines = [header.join(",")].concat(rows.map((r) => r.map(cell).join(",")));
  fs.writeFileSync(out, "﻿" + lines.join("\r\n") + "\r\n", "utf8"); // BOM so Excel reads UTF-8
  console.log(`${noSlug.length} accommodation(s) without a slug, ${gone.length} draft(s) pointing at a missing accommodation -> ${out}`);
} catch (err) {
  console.error("Failed:", err.message);
  process.exitCode = 1;
} finally {
  await mongoose.disconnect();
}
