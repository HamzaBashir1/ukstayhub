import Accommodation from "../models/Accommodation.js";
import { searchKey } from "./searchText.js";

const TTL_MS = 60_000;
let cache = { at: 0, rows: null, loading: null };

const titleOf = (row) => [row.name, row.name?.en, row.accommodationName].find((v) => typeof v === "string" && v.trim()) || "";

// shortcut: whole name list held in memory for 60s, so a new listing shows up
// in suggestions after at most a minute; swap for a text index if listings reach the hundreds of thousands.
const load = async () => {
  const fresh = cache.rows && Date.now() - cache.at < TTL_MS;
  if (fresh) return cache.rows;
  // Stale list: answer now, refresh in the background so no keystroke waits for the full scan.
  const stale = cache.rows;
  cache.loading ||= Accommodation.find({}).select("_id name accommodationName").lean()
    .then((docs) => {
      const rows = docs.map((d) => ({ _id: d._id, name: titleOf(d) })).filter((r) => r.name)
        .map((r) => ({ ...r, key: searchKey(r.name) }));
      cache = { at: Date.now(), rows, loading: null };
      return rows;
    })
    .catch((error) => { cache.loading = null; if (!stale) throw error; });
  return stale || cache.loading;
};

/** Pure ranking: exact, then prefix, then word-prefix, then anywhere; ties alphabetical. */
export const rankNames = (rows, text, limit = 8) => {
  const q = searchKey(text);
  if (!q) return [];
  const score = (key) => key === q ? 0 : key.startsWith(q) ? 1 : key.includes(` ${q}`) ? 2 : key.includes(q) ? 3 : -1;
  return rows
    .map((r) => ({ r, s: score(r.key) }))
    .filter((x) => x.s >= 0)
    .sort((a, b) => a.s - b.s || a.r.name.localeCompare(b.r.name, "sk"))
    .slice(0, limit)
    .map(({ r }) => ({ _id: r._id, name: r.name }));
};

export const suggestNames = async (text, limit = 8) => rankNames(await load(), text, limit);
