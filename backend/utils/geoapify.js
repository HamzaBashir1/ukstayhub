// utils/geoapify.js
// Geoapify geocoding (https://apidocs.geoapify.com/docs/geocoding/).
// The key stays on the server (GEOAPIFY_API_KEY); clients go through /api/geo/*.

const BASE = "https://api.geoapify.com/v1/geocode";

function apiKey() {
  const key = process.env.GEOAPIFY_API_KEY;
  if (!key) throw new Error("GEOAPIFY_API_KEY is not set");
  return key;
}

async function call(path, params) {
  const qs = new URLSearchParams({ ...params, format: "json", apiKey: apiKey() });
  const res = await fetch(`${BASE}/${path}?${qs}`, { signal: AbortSignal.timeout(8000) });
  if (!res.ok) throw new Error(`Geoapify ${path} failed: ${res.status}`);
  const data = await res.json();
  return Array.isArray(data?.results) ? data.results : [];
}

/** Flatten a Geoapify result into the fields the listing editor fills in. */
export function toAddress(r) {
  // Boroughs ("City of Westminster") are London too; Geoapify marks them with
  // state_district/county "Greater London" or ", London" in the address.
  const isLondon =
    [r.city, r.county, r.state_district].some((v) => String(v || "").includes("London")) ||
    /(^|, )London(,|$)/.test(r.formatted || "");
  const isPostcode = r.result_type === "postcode";
  // A postcode match has no street; its address_line1 is the area (e.g. "Brent").
  const street = isPostcode
    ? r.street || ""
    : [r.street, r.housenumber].filter(Boolean).join(" ") || r.address_line1 || r.name || "";
  return {
    type: r.result_type || "",
    label: r.formatted || [r.address_line1, r.address_line2].filter(Boolean).join(", "),
    street,
    city: isLondon ? "London" : r.city || r.town || r.village || r.municipality || "",
    postcode: r.postcode || "",
    country: r.country || "",
    state: r.state || "",
    latitude: typeof r.lat === "number" ? r.lat : null,
    longitude: typeof r.lon === "number" ? r.lon : null,
  };
}

// Central London (lon,lat). Results near here rank first.
const LONDON = "-0.1276,51.5072";

// Typing the same prefix again (or another host typing it) is answered from memory.
const CACHE_TTL_MS = 60 * 60 * 1000;
const CACHE_MAX = 5000;
const cache = new Map();

// UK postcode typed so far: "E1", "NW2", "SW19 8", "EC1A 1B", "SW1A1AA".
const UK_POSTCODE_PREFIX = /^[a-z]{1,2}\d[a-z\d]?(?: ?\d[a-z]{0,2})?$/i;
const UK_OUTCODE = /^[a-z]{1,2}\d[a-z\d]?$/i;

/** "sw1a1aa" → "SW1A 1AA"; partial input is upper-cased only. */
export function normalisePostcode(text) {
  const t = text.replace(/\s+/g, "").toUpperCase();
  const full = t.match(/^([A-Z]{1,2}\d[A-Z\d]?)(\d[A-Z]{2})$/);
  if (full) return `${full[1]} ${full[2]}`;
  return text.trim().replace(/\s+/g, " ").toUpperCase();
}

export const looksLikeUkPostcode = (text) => UK_POSTCODE_PREFIX.test(text.trim().replace(/\s+/g, " "));

/**
 * Address suggestions while typing: UK only, London first, English names.
 * Input that looks like a postcode is searched as postcodes only. With
 * `district`, an outward code ("E1", "NW2") also gets one row for the whole
 * district, centred on the postcodes found in it.
 */
export async function autocomplete(text, { country = "gb", limit = 5, lang = "en", district = false } = {}) {
  let q = text.trim().replace(/\s+/g, " ").toLowerCase();
  const postcode = country === "gb" && looksLikeUkPostcode(q);
  if (postcode) q = normalisePostcode(q);
  const key = `${country}|${lang}|${limit}|${district ? 1 : 0}|${q}`;
  const hit = cache.get(key);
  if (hit && hit.expires > Date.now()) return hit.results;

  const base = { limit: String(postcode ? 10 : limit), lang, bias: `proximity:${LONDON}` };
  if (country) base.filter = `countrycode:${country}`;
  // Geoapify quirks, worked around with a second query in parallel:
  //  * an outward code alone ("E14") is read as "E1 4" unless a town follows;
  //  * a bare street name ("baker street") can miss London's own street unless
  //    asked for streets only.
  const queries = postcode
    ? [{ ...base, text: q, type: "postcode" }, ...(UK_OUTCODE.test(q) ? [{ ...base, text: `${q}, London`, type: "postcode" }] : [])]
    : [{ ...base, text: q }, ...(country === "gb" ? [{ ...base, text: q, type: "street" }] : [])];
  const settled = await Promise.allSettled(queries.map((p) => call("autocomplete", p)));
  if (settled.every((r) => r.status === "rejected")) throw settled[0].reason;
  const seenLabel = new Set();
  let results = settled
    .flatMap((r) => (r.status === "fulfilled" ? r.value : []))
    .map(toAddress)
    .filter((r) => r.label && !seenLabel.has(r.label) && seenLabel.add(r.label));
  // London first, Geoapify's own order otherwise (sort is stable).
  results.sort((a, b) => (b.city === "London") - (a.city === "London"));
  if (!postcode) results = results.slice(0, limit);

  if (postcode) {
    // Keep postcodes that really continue what was typed: "W1" offers W1D and
    // W1A but not W10; "NW2 4" stays inside NW2.
    const [typedOut, typedIn = null] = q.split(" ");
    results = results.filter((r) => {
      const [out, inward = ""] = r.postcode.toUpperCase().split(" ");
      if (typedIn !== null) return out === typedOut && inward.startsWith(typedIn);
      if (!out.startsWith(typedOut)) return false;
      return !(/\d$/.test(typedOut) && /\d/.test(out.charAt(typedOut.length)));
    });
    const seen = new Set();
    results = results.filter((r) => !seen.has(r.postcode) && seen.add(r.postcode));

    // Only for a real district: every match sits in exactly that outward code.
    if (district && UK_OUTCODE.test(q) && results.length && results.every((r) => r.postcode.split(" ")[0] === q)) {
      const pts = results.filter((r) => r.latitude != null && r.longitude != null);
      const mean = (k) => pts.reduce((a, r) => a + r[k], 0) / pts.length;
      const city = results.find((r) => r.city)?.city || "";
      results.unshift({
        type: "postcode",
        label: [q, city, "United Kingdom"].filter(Boolean).join(", "),
        street: "",
        city,
        postcode: q,
        country: results[0].country,
        state: results[0].state,
        latitude: mean("latitude"),
        longitude: mean("longitude"),
      });
    }
    results = results.slice(0, district ? limit + 1 : limit);
  }

  cache.delete(key);
  cache.set(key, { results, expires: Date.now() + CACHE_TTL_MS });
  if (cache.size > CACHE_MAX) cache.delete(cache.keys().next().value);
  return results;
}

/** Best single match for a free-text address, or null. */
export async function geocode(text, { country } = {}) {
  const params = { text, limit: "1", lang: "en", bias: `proximity:${LONDON}` };
  if (country) params.filter = `countrycode:${country}`;
  const [first] = await call("search", params);
  return first ? toAddress(first) : null;
}
