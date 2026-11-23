// utils/pinCache.js
//
// Two-tier cache for the map-pin payload
// (`/accommodations/searching?...&mapOnly=true`).
//
// Why this exists: the pin query has to read every matching accommodation
// document to project ~600 bytes out of each one. An accommodation document is
// ~51 KB, and ~86 % of that is the embedded `occupancyCalendar` array, so
// answering the default map view means reading roughly 72 MB to return 830 KB.
// Measured, that is ~10.5 s — which the guest sees as an empty map. The pin set
// changes only when a listing changes, so it is a near-perfect caching target.
//
// Two tiers, because Redis alone was not fast enough. Upstash is a remote,
// TLS-terminated Redis; a measured round trip for this payload is ~1.1 s. Good
// against 10.5 s, poor against what an in-process map can do:
//
//   L1  process memory   ~0 ms    lost on restart, per-instance
//   L2  Redis (Upstash)  ~1.1 s   survives restarts, shared across instances
//   L3  MongoDB          ~10.5 s  the source of truth
//
// So a warm process answers instantly, a freshly restarted one pays ~1.1 s
// instead of ~10.5 s, and Mongo is touched only when the data actually changed.
//
// Invalidation is by VERSION COUNTER, not by key deletion. Keys embed the
// current version (`pins:v7:<hash>`), so bumping the counter orphans every
// entry at once — no SCAN over the keyspace, no chance of missing a key.
// Orphans age out via the TTL.
//
// Every operation is best-effort: if Redis is down, slow, or the value is
// corrupt, the caller falls back to querying Mongo. A cache must never be able
// to take the endpoint down.

import zlib from "node:zlib";
import crypto from "node:crypto";
import { promisify } from "node:util";
import redisClient from "./redis.js";

const gzip = promisify(zlib.gzip);
const gunzip = promisify(zlib.gunzip);

const VERSION_KEY = "pins:ver";

// Part of every key. Change it whenever the payload shape changes: Redis is
// shared between deployments, and an older server must never read a newer
// server's payload (or the reverse).
const PAYLOAD_FORMAT = "slim2";

// 5 minutes. The version bump handles listing edits, so this TTL only bounds
// staleness for things no write hook can see — chiefly a checkout hold expiring
// on its own. That direction is safe: it can briefly show a listing as taken
// when it has just become free, never the reverse.
const TTL_SECONDS = Number(process.env.PIN_CACHE_TTL_SECONDS || 300);

// How long the version counter is trusted without re-reading it from Redis.
// Without this, every cache hit still paid a network round trip just to learn it
// was allowed to use the local copy — measured at ~0.4 s against Upstash, which
// would have been most of the remaining latency.
//
// A write made by THIS process clears the memo synchronously (see
// bumpPinCacheVersion), so this window only delays noticing a write made by a
// DIFFERENT instance — at worst, a listing edited on another node takes this
// long to change the map.
const VERSION_MEMO_MS = Number(process.env.PIN_CACHE_VERSION_MEMO_MS || 10000);

// Distinct filter sets held in process memory. The default map view dominates
// real traffic; this only needs to be deep enough to cover it plus a few common
// filters. Each entry is the raw JSON payload (~830 KB), so this caps L1 at a
// few MB.
const L1_MAX_ENTRIES = Number(process.env.PIN_CACHE_L1_ENTRIES || 6);

const ENABLED =
  String(process.env.PIN_CACHE_ENABLED ?? "true").toLowerCase() !== "false";

// Query params that do not change WHICH pins come back. `mapOnly` is constant
// for this endpoint, and paging/sorting are ignored by the pin branch entirely —
// folding them into the key would shard the cache for no reason.
const IGNORED_PARAMS = new Set(["mapOnly", "page", "limit", "sortOption"]);

const redisUsable = () => ENABLED && redisClient?.isOpen;

/* ----------------------------- L1 ----------------------------- */

/** @type {Map<string, string>} versioned key -> raw JSON payload */
const l1 = new Map();

let memoVersion = null;
let memoVersionAt = 0;

const l1Set = (key, value) => {
  // Re-inserting moves the key to the end, so the eviction below is LRU-ish
  // rather than strictly insertion-ordered.
  if (l1.has(key)) l1.delete(key);
  l1.set(key, value);
  while (l1.size > L1_MAX_ENTRIES) {
    l1.delete(l1.keys().next().value);
  }
};

const l1Get = (key) => {
  const hit = l1.get(key);
  if (hit === undefined) return null;
  l1.delete(key);
  l1.set(key, hit);
  return hit;
};

/* --------------------------- helpers -------------------------- */

/**
 * Deterministic key for a filter set. Sorted so that two requests with the same
 * filters in a different query-string order share one entry.
 */
const hashQuery = (query = {}) => {
  const pairs = Object.keys(query)
    .filter((k) => !IGNORED_PARAMS.has(k))
    .filter((k) => query[k] !== undefined && query[k] !== null && query[k] !== "")
    .sort()
    .map((k) => `${k}=${String(query[k])}`);
  return crypto.createHash("sha1").update(pairs.join("&")).digest("hex");
};

const readVersion = async () => {
  const now = Date.now();
  if (memoVersion !== null && now - memoVersionAt < VERSION_MEMO_MS) {
    return memoVersion;
  }
  if (!redisUsable()) {
    // No Redis: L1 still works, keyed off a stable local version.
    memoVersion = memoVersion ?? "0";
    memoVersionAt = now;
    return memoVersion;
  }
  try {
    const v = (await redisClient.get(VERSION_KEY)) || "0";
    // Another process (production, a sync script) invalidated the cache.
    if (memoVersion !== null && v !== memoVersion) scheduleWarm();
    memoVersion = v;
    memoVersionAt = now;
    return v;
  } catch {
    return memoVersion ?? "0";
  }
};

/* ---------------------------- API ----------------------------- */

/**
 * Cached pin payload for these filters, as a raw JSON STRING.
 *
 * Deliberately a string: the caller sends it straight to the client, so a hit
 * skips JSON.parse and re-serialisation entirely.
 *
 * @returns {Promise<{payload: string, tier: 'L1'|'L2'}|null>} null on miss
 */
export const readPinCache = async (query) => {
  if (!ENABLED) return null;
  try {
    const version = await readVersion();
    const key = `pins:${PAYLOAD_FORMAT}:v${version}:${hashQuery(query)}`;

    const local = l1Get(key);
    if (local) return { payload: local, tier: "L1" };

    if (!redisUsable()) return null;

    const stored = await redisClient.get(key);
    if (!stored) return null;

    const payload = (await gunzip(Buffer.from(stored, "base64"))).toString("utf8");
    l1Set(key, payload);
    return { payload, tier: "L2" };
  } catch (err) {
    console.warn("[pin-cache] read failed, falling back to Mongo:", err.message);
    return null;
  }
};

/**
 * Store a pin payload in both tiers.
 *
 * Gzipped for L2: the real payload measures ~830 KB of JSON and 112 KB gzipped
 * (7.4x), which keeps it clear of Upstash's per-value size ceiling and leaves
 * headroom as the listing count grows.
 */
export const writePinCache = async (query, jsonString) => {
  if (!ENABLED) return;
  try {
    const version = await readVersion();
    const key = `pins:${PAYLOAD_FORMAT}:v${version}:${hashQuery(query)}`;

    l1Set(key, jsonString);

    if (!redisUsable()) return;
    const packed = (await gzip(Buffer.from(jsonString, "utf8"))).toString("base64");
    await redisClient.set(key, packed, { EX: TTL_SECONDS });
  } catch (err) {
    console.warn("[pin-cache] write failed:", err.message);
  }
};

// The default map view is rebuilt in the background after every invalidation
// and at startup, so a guest rarely pays the cold Mongo read. Debounced because
// a bulk import bumps the version once per saved listing.
let warmer = null;
let warmTimer = null;
const WARM_DELAY_MS = 3000;

const scheduleWarm = () => {
  if (!warmer) return;
  clearTimeout(warmTimer);
  warmTimer = setTimeout(() => {
    Promise.resolve(warmer()).catch((err) =>
      console.warn("[pin-cache] warm-up failed:", err.message)
    );
  }, WARM_DELAY_MS);
  warmTimer.unref?.();
};

/** Register the function that rebuilds the default pins, and run it once now. */
export const setPinCacheWarmer = (fn) => {
  warmer = fn;
  scheduleWarm();
  // Notice invalidations made by other processes even when no guest is asking.
  setInterval(() => readVersion().catch(() => {}), VERSION_MEMO_MS * 3).unref?.();
};

/**
 * Invalidate every cached pin payload.
 *
 * L1 and the memoised version are cleared SYNCHRONOUSLY, so a write made by
 * this process is visible to the very next request it serves. The Redis INCR is
 * fire-and-forget: it runs from Mongoose post-hooks on the write path, and a
 * slow or unreachable Redis must not delay — or fail — the write that triggered
 * it.
 */
export const bumpPinCacheVersion = () => {
  l1.clear();
  memoVersion = null;
  memoVersionAt = 0;
  scheduleWarm();

  if (!redisUsable()) return;
  redisClient
    .incr(VERSION_KEY)
    .catch((err) => console.warn("[pin-cache] invalidation failed:", err.message));
};

export const PIN_CACHE_TTL_SECONDS = TTL_SECONDS;
export const PIN_CACHE_ENABLED = ENABLED;
