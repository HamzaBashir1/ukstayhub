// scripts/hauziSync/fetch.js
//
// Fetching Hauzi pages (axios → curl → ScraperAPI) and booking details (unit prices, min stay, pet fee).

import "../../config/env.js";
import dns from "node:dns";
import fs from "node:fs";
import https from "node:https";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import axios from "axios";
import { sleep, fold, toNumber } from "./helpers.js";
import { parsePetFeeRow } from "./parse.js";

// ─── Fetching ────────────────────────────────────────────────────────────────

export const execFileAsync = promisify(execFile);

export const BROWSER_HEADERS = {
  "User-Agent":
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
  "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
  "Accept-Language": "sk-SK,sk;q=0.9",
};

export const isChallengePage = (html) =>
  typeof html !== "string" || (/<title>Just a moment/i.test(html) && !/window\.clientData/.test(html));

export const loadHauziHtml = async (source) => {
  if (!/^https?:\/\//i.test(source)) {
    const file = path.resolve(source);
    if (!fs.existsSync(file)) throw new Error(`Hauzi source not found: ${source}`);
    return fs.readFileSync(file, "utf8");
  }
  const failures = [];
  try {
    const res = await axios.get(source, { timeout: 30000, responseType: "text", headers: BROWSER_HEADERS });
    if (!isChallengePage(res.data)) return res.data;
    failures.push("axios: Cloudflare challenge");
  } catch (err) {
    failures.push(`axios: ${err.response ? `HTTP ${err.response.status}` : err.code || err.message}`);
  }

  // Cloudflare answers Node's HTTP client with 403 / a "Just a moment..."
  // challenge (it fingerprints the TLS handshake, so headers alone do not
  // help), while curl with the same headers sometimes gets the real page. curl
  // ships with Windows 10+, macOS and Linux.
  try {
    const { stdout } = await execFileAsync(
      "curl",
      [
        "-s", "-L", "--max-time", "30",
        ...Object.entries(BROWSER_HEADERS).flatMap(([k, v]) => ["-H", `${k}: ${v}`]),
        source,
      ],
      { maxBuffer: 50 * 1024 * 1024, encoding: "utf8" },
    );
    if (!isChallengePage(stdout)) return stdout;
    failures.push("curl: Cloudflare challenge");
  } catch (err) {
    failures.push(`curl: ${err.message}`);
  }

  // Last resort: ScraperAPI (needs SCRAPERAPI_KEY in backend/.env).
  if (SCRAPERAPI_KEY) {
    try {
      return await fetchWithScraperApi(source);
    } catch (err) {
      failures.push(`ScraperAPI: ${err.message}`);
    }
  } else {
    failures.push("ScraperAPI: SCRAPERAPI_KEY not set");
  }
  throw new Error(`Hauzi page blocked (${failures.join("; ")})`);
};

export const SCRAPERAPI_KEY = process.env.SCRAPERAPI_KEY;
export const SCRAPERAPI_RETRYABLE = new Set([408, 429, 500, 502, 503, 504]);

// Some resolvers (home routers, 1.1.1.1) answer SERVFAIL for scraperapi.com,
// which surfaces as EAI_AGAIN. When the system lookup fails, ask public DNS
// servers directly instead.
export const publicResolver = new dns.promises.Resolver({ timeout: 5000, tries: 2 });
publicResolver.setServers(["8.8.8.8", "8.8.4.4", "9.9.9.9"]);

export const lookupWithFallback = (hostname, options, callback) => {
  if (typeof options === "function") [callback, options] = [options, {}];
  const opts = typeof options === "number" ? { family: options } : options || {};
  dns.lookup(hostname, opts, (err, address, family) => {
    if (!err || !["EAI_AGAIN", "ENOTFOUND"].includes(err.code)) {
      return callback(err, address, family);
    }
    publicResolver
      .resolve4(hostname)
      .then((ips) => {
        if (!ips.length) throw err;
        if (opts.all) callback(null, ips.map((ip) => ({ address: ip, family: 4 })));
        else callback(null, ips[0], 4);
      })
      .catch(() => callback(err));
  });
};

export const scraperApiAgent = new https.Agent({ keepAlive: true, lookup: lookupWithFallback });

export const fetchWithScraperApi = async (url, attempts = 3) => {
  let error = "no response";
  for (let attempt = 1; attempt <= attempts; attempt++) {
    let retryable;
    try {
      const res = await axios.get("https://api.scraperapi.com/", {
        params: { api_key: SCRAPERAPI_KEY, url },
        httpsAgent: scraperApiAgent,
        timeout: 90000,
        responseType: "text",
        validateStatus: () => true,
      });
      if (res.status === 200 && !isChallengePage(res.data)) return res.data;
      error = res.status === 200 ? "Cloudflare challenge" : `HTTP ${res.status}`;
      retryable = res.status === 200 || SCRAPERAPI_RETRYABLE.has(res.status);
    } catch (err) {
      error = err.code || err.message;
      retryable = true;
    }
    console.log(`   ScraperAPI attempt ${attempt}/${attempts} failed: ${error}`);
    if (!retryable || attempt === attempts) break;
    await sleep(5000 * attempt);
  }
  throw new Error(error);
};

// ─── Booking details: pet fee and minimum stay ───────────────────────────────

/** Date `days` from today as Hauzi's YYYYMMDD number. */
export const hauziDay = (days) => {
  const d = new Date(Date.now() + days * 864e5);
  return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate();
};

/**
 * The pet fee amount and the minimum stay are not in the page HTML; Hauzi
 * loads them with the booking form (Lead.getVariations), one "variation" per
 * unit. Any dates work — even a unit booked on those dates comes back with its
 * fee table. The reply is JSON chunks separated by "~~CHUNK-SEPARATOR~~".
 */
export const fetchHauziVariations = async (pageUrl, rentalId, nights = 3, startInDays = 30) => {
  const endpoint = `${new URL(pageUrl).origin}/~method/Lead.getVariations`;
  // lastNight is the last night slept: 5.–6. 10. is 2 nights.
  const body = { rentalId, firstNight: hauziDay(startInDays), lastNight: hauziDay(startInDays + nights - 1), guests: [30], pets: 0, cribs: [] };

  const failures = [];
  let text = null;
  try {
    const res = await axios.post(endpoint, body, { timeout: 30000, responseType: "text", headers: BROWSER_HEADERS });
    if (/"variations"/.test(res.data)) text = res.data;
    else failures.push("direct: Cloudflare challenge");
  } catch (err) {
    failures.push(`direct: ${err.response ? `HTTP ${err.response.status}` : err.code || err.message}`);
  }
  if (!text && SCRAPERAPI_KEY) {
    try {
      const res = await axios.post("https://api.scraperapi.com/", body, {
        params: { api_key: SCRAPERAPI_KEY, url: endpoint },
        headers: { "Content-Type": "application/json" },
        httpsAgent: scraperApiAgent,
        timeout: 90000,
        responseType: "text",
        validateStatus: () => true,
      });
      if (res.status === 200 && /"variations"/.test(res.data)) text = res.data;
      else failures.push(`ScraperAPI: HTTP ${res.status}`);
    } catch (err) {
      failures.push(`ScraperAPI: ${err.code || err.message}`);
    }
  }
  if (!text) throw new Error(`booking details not loaded from Hauzi (${failures.join("; ")})`);

  const variations = [];
  for (const chunk of text.split("~~CHUNK-SEPARATOR~~")) {
    try {
      variations.push(...(JSON.parse(chunk.trim())?.variations || []).map((v) => ({ ...v, nights })));
    } catch {
      /* partial chunk */
    }
  }
  return variations;
};

/**
 * A unit's minimum stay: the variation's minStay, or the booking error
 * "Minimálny počet nocí je 3." when the requested stay is shorter.
 */
export const variationMinStay = (v) => {
  const fromError = (v.errors || [])
    .map((e) => fold(e?.text).match(/minimaln\S* pocet noci\D*(\d+)/)?.[1])
    .find(Boolean);
  return toNumber(fromError) ?? toNumber(v.minStay);
};

/**
 * Fills from Hauzi's booking form, on the property and each unit:
 *   nightMin       — the minimum stay (the property gets the shortest of its units)
 *   petFeePerNight — when pets are allowed for a fee; only "… / noc" fees are
 *                    taken, a per-stay fee is reported in the note and Putko's
 *                    value kept.
 */
export const addBookingDetails = async (hauzi, pageUrl) => {
  if (!hauzi.rentalId || !/^https?:\/\//i.test(pageUrl)) return;

  let variations;
  try {
    variations = await fetchHauziVariations(pageUrl, hauzi.rentalId);
  } catch (err) {
    if (hauzi.nightMin === null) hauzi.notes.nightMin = `${err.message}; Putko value kept`;
    if (hauzi.pet === "Allowed with an additional fee") hauzi.notes.petFeePerNight = `Pets allowed for a fee, but ${err.message}; Putko value kept`;
    return;
  }
  const ofUnit = (unit) => variations.filter((v) => v.unitId === unit.unitId);

  // A unit whose minimum stay is longer than the request has no price in the
  // reply; ask again for that many nights.
  const longest = Math.max(0, ...variations.map(variationMinStay).filter((n) => n !== null));
  if (longest > variations[0]?.nights && longest <= 30) {
    try {
      variations.push(...(await fetchHauziVariations(pageUrl, hauzi.rentalId, longest)));
    } catch {
      /* the first reply still gives min stay and pet fee */
    }
  }

  // ── Price per night of each unit ──────────────────────────────────────────
  // Hauzi's "od 180 €" on a unit is the price of its minimum stay (2 nights),
  // not of one night. The booking reply's finalPrice for N nights / N is.
  if (hauzi.units.length > 1) {
    // A unit booked on the dates checked comes back without a price (common for resorts
    // with many units), so ask for later windows until every unit has been priced.
    const priceOf = (unit) => ofUnit(unit).find((v) => v.finalPrice > 0 && !(v.errors || []).length);
    const stay = Math.max(variations[0]?.nights || 3, longest || 0);
    for (const startInDays of [60, 90, 120, 180, 270]) {
      if (hauzi.units.every((u) => u.pricePerNight || priceOf(u))) break;
      try {
        variations.push(...(await fetchHauziVariations(pageUrl, hauzi.rentalId, stay, startInDays)));
      } catch {
        break; // the dates already fetched still give what they can
      }
    }
    for (const unit of hauzi.units) {
      // The unit's own Cenník (parse.js) already gave it a price; the booking form only fills a gap.
      if (unit.pricePerNight) continue;
      const priced = priceOf(unit);
      if (priced) {
        unit.pricePerNight = Math.round((priced.finalPrice / priced.nights) * 100) / 100;
      } else {
        unit.notes = {
          ...unit.notes,
          pricePerNight: "Unit is booked (or has no price) on every date window checked (30–270 days out); Putko price kept",
        };
      }
    }
  }

  // ── Minimum stay ──────────────────────────────────────────────────────────
  const applyMinStay = (view, list) => {
    const stays = list.map(variationMinStay).filter((n) => n !== null);
    if (stays.length) view.nightMin = Math.min(...stays);
  };
  applyMinStay(hauzi, variations);
  for (const unit of hauzi.units) applyMinStay(unit, ofUnit(unit));

  // ── Pet fee ───────────────────────────────────────────────────────────────
  if (hauzi.pet !== "Allowed with an additional fee") return;
  const applyPetFee = (view, list) => {
    const found = list.map((v) => parsePetFeeRow(v.priceDetailsHtml)).filter(Boolean);
    if (!found.length) return;
    const texts = [...new Set(found.map((f) => f.text))];
    const fee = found[0];
    if (texts.length === 1 && fee.perNight && fee.amount !== null) {
      view.petFeePerNight = fee.amount;
    } else {
      view.petFeePerNight = null;
      view.notes = {
        ...view.notes,
        petFeePerNight: texts.length > 1
          ? `Hauzi pet fee differs between units (${texts.join(" | ")}); Putko value kept`
          : `Hauzi pet fee is "${fee.text}", not per night; Putko value kept`,
      };
    }
  };
  applyPetFee(hauzi, variations);
  for (const unit of hauzi.units) applyPetFee(unit, ofUnit(unit));
};
