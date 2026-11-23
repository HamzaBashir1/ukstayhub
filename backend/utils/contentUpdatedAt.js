// utils/contentUpdatedAt.js
//
// The sitemap used `updatedAt` as lastmod, and Mongoose bumps `updatedAt` on
// every write: an iCal calendar sync, a view counter, a new rating, a Stripe
// status refresh. Almost every listing therefore claimed to have changed in
// the last day, and Google stops trusting a lastmod that is always "now".
//
// `contentUpdatedAt` moves only when something a visitor sees on the page
// changes value (text, photos, prices, amenities, …). Writing the same value
// again does not count, and documents created before this field existed keep
// no value, so the sitemap falls back to their creation date until their first
// real edit.

/** Listing fields that are rendered on the public listing page. */
export const LISTING_CONTENT_FIELDS = [
  "name", "slug", "description", "specialNote", "translations",
  "cancellationPolicy", "cancellationPolicyType", "customPolicyTiers",
  "virtualTourUrl", "propertyType", "rentalform",
  "specialPrice", "flexiblePrices", "units", "discount", "lengthDiscounts", "guestDiscounts", "pricePerNight", "pricePerPerson",
  "cleaningFee", "localTaxPerPersonNight", "petFeePerNight", "paidExtras",
  "location", "locationDetails", "acreage", "tags", "nightMin", "nightMax",
  "beds", "singlebed", "doublebed", "bunkbed", "kitchen", "WCs", "SocialRoom",
  "CommonRoom", "LivingRoom", "Sofa", "bedroom", "bathroom", "person",
  "phoneNumber", "arrivalFrom", "arrivalTo", "departureFrom", "departureTo", "checkIn",
  "services", "bathroomAmenities", "kitchenDiningAmenities", "heatingCoolingAmenities",
  "safetyAmenities", "wellnessAmenities", "outdoorAmenities", "parkingFacilities",
  "meals", "pet", "partyOrganizing", "smoking", "images",
];

/** Blog fields that are rendered on the public blog post page. */
export const BLOG_CONTENT_FIELDS = [
  "title", "slug", "content", "summary", "image", "categories", "tags",
  "author", "authorName", "authorImg",
];

const UPDATE_OPERATORS_WITH_PATHS = [
  "$set", "$unset", "$inc", "$mul", "$min", "$max", "$rename", "$push", "$pull",
  "$pullAll", "$addToSet", "$pop", "$setOnInsert", "$currentDate",
];

/**
 * Top-level paths an update touches, e.g. `{ $set: { "locationDetails.city": x } }`
 * → `["locationDetails"]`. Returns null for an aggregation-pipeline update,
 * whose effect cannot be read from its keys.
 */
export function touchedPaths(update) {
  if (!update) return [];
  if (Array.isArray(update)) return null;

  const paths = new Set();
  const add = (key) => paths.add(String(key).split(".")[0]);

  for (const [key, value] of Object.entries(update)) {
    if (!key.startsWith("$")) {
      add(key);
    } else if (UPDATE_OPERATORS_WITH_PATHS.includes(key) && value && typeof value === "object") {
      for (const [path, target] of Object.entries(value)) {
        add(path);
        if (key === "$rename") add(target);
      }
    }
  }
  return [...paths];
}

/** True when the update could change any of `fields`. */
export function touchesContent(update, fields) {
  const paths = touchedPaths(update);
  return paths === null || paths.some((path) => fields.includes(path));
}

// Key-order-independent JSON, so `{a, b}` and `{b, a}` compare equal.
function stable(value) {
  if (value === undefined) return "null";
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (value instanceof Date) return JSON.stringify(value.toISOString());
  if (typeof value.toHexString === "function") return JSON.stringify(value.toHexString());
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  const keys = Object.keys(value).filter((k) => value[k] !== undefined && k !== "_id").sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${stable(value[k])}`).join(",")}}`;
}

/** Comparable fingerprint of the content fields of a plain object. */
export function contentSnapshot(obj, fields) {
  return stable(Object.fromEntries(fields.map((field) => [field, obj?.[field]])));
}

// Only the content fields, as plain values (subdocuments and Mongoose arrays
// carry internal keys that would make every comparison differ).
const plain = (doc, fields) =>
  Object.fromEntries(
    fields.map((field) => {
      const value = doc.get(field);
      return [field, typeof value?.toObject === "function" ? value.toObject({ depopulate: true }) : value];
    })
  );

/**
 * Mongoose plugin: adds `contentUpdatedAt` and keeps it in step with `fields`.
 *
 *   schema.plugin(contentUpdatedAtPlugin, { fields: LISTING_CONTENT_FIELDS });
 */
export function contentUpdatedAtPlugin(schema, { fields }) {
  // No default on purpose: a default would be applied when old documents are
  // read and make every one of them look edited today.
  schema.add({ contentUpdatedAt: { type: Date, index: true } });

  // ── document.save() ────────────────────────────────────────────────────────
  schema.post("init", function rememberContent() {
    this.$locals.contentSnapshot = contentSnapshot(plain(this, fields), fields);
  });

  schema.pre("save", function stampOnSave(next) {
    if (this.isNew) {
      if (!this.contentUpdatedAt) this.contentUpdatedAt = new Date();
    } else if (
      this.$locals.contentSnapshot !== undefined &&
      this.$locals.contentSnapshot !== contentSnapshot(plain(this, fields), fields)
    ) {
      this.contentUpdatedAt = new Date();
    }
    next();
  });

  schema.post("save", function refreshSnapshot() {
    this.$locals.contentSnapshot = contentSnapshot(plain(this, fields), fields);
  });

  // ── Model.insertMany() ─────────────────────────────────────────────────────
  schema.pre("insertMany", function stampOnInsert(next, docs) {
    const now = new Date();
    for (const doc of Array.isArray(docs) ? docs : [docs]) {
      if (doc && !doc.contentUpdatedAt) doc.contentUpdatedAt = now;
    }
    next();
  });

  // ── Query updates (findOneAndUpdate, findByIdAndUpdate, updateOne, …) ──────
  // Compare the content before and after the write; the stamp is written with
  // the native driver so it neither re-enters these hooks nor counts as an edit.
  const single = new Set(["findOneAndUpdate", "updateOne", "replaceOne"]);
  const select = [...fields, "_id"].join(" ");

  schema.pre(["findOneAndUpdate", "updateOne", "updateMany", "replaceOne"], async function readBefore() {
    const update = this.getUpdate();
    const isReplace = this.op === "replaceOne";
    if (!isReplace && !touchesContent(update, fields)) return;

    let query = this.model.find(this.getFilter()).select(select).lean();
    if (single.has(this.op)) query = query.limit(1);
    const before = await query;

    this.$locals = this.$locals || {};
    this.$locals.contentBefore = new Map(
      before.map((doc) => [String(doc._id), contentSnapshot(doc, fields)])
    );
  });

  schema.post(["findOneAndUpdate", "updateOne", "updateMany", "replaceOne"], async function stampAfter(result) {
    const before = this.$locals?.contentBefore;
    if (!before) return;

    const ids = [...before.keys()];
    // An upsert that created a new document is new content too.
    const created = result?.upsertedId ?? (result?._id && !before.has(String(result._id)) ? result._id : null);

    const after = ids.length
      ? await this.model.find({ _id: { $in: ids } }).select(select).lean()
      : [];
    const changed = after
      .filter((doc) => before.get(String(doc._id)) !== contentSnapshot(doc, fields))
      .map((doc) => doc._id);
    if (created) changed.push(created);
    if (!changed.length) return;

    await this.model.collection.updateMany(
      { _id: { $in: changed } },
      { $set: { contentUpdatedAt: new Date() } }
    );
  });
}
