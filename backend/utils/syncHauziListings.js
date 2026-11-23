// utils/syncHauziListings.js
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
//   node utils/syncHauziListings.js [input.csv] [options]
//
//   --apply        write the Hauzi values into Putko (default: dry run, report only)
//   --prices       with --apply, also update pricePerNight
//   --images       with --apply, re-upload the Hauzi photos to Cloudinary and
//                  replace the listing's images when the photo count differs
//   --parse-only   no database at all: only extract the Hauzi data into the CSV
//                  (useful for checking the parser against a saved .html file)
//   --output FILE  report path (default: hauzi_sync_report_<timestamp>.csv
//                  next to the input)
//   --delay MS     pause between Hauzi requests (default 1500)
//
// Hauzi pages are fetched with axios, then curl, then ScraperAPI
// (SCRAPERAPI_KEY in backend/.env) when Cloudflare blocks the first two.
//
// The hauziUrl column may also be a path to a saved Hauzi .html page.
//
// Hauzi is treated as the source of truth. For multi-choice amenity groups the
// Hauzi set REPLACES the Putko set (that is how a wrong importer default such as
// wellness = ["Sauna"] gets corrected) — except where Hauzi has no data for the
// group at all, in which case the field is reported NOT_ON_HAUZI and left alone.
//
// Price and min nights are taken only when the page shows them; otherwise the
// report says the property has none on Hauzi and Putko's value is kept. Hauzi
// units that no Putko listing stands for are reported as MISSING_ON_PUTKO.

import { pathToFileURL } from "node:url";
import dns from "node:dns";
import fs from "node:fs";
import https from "node:https";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

import axios from "axios";
import mongoose from "mongoose";
import xlsx from "xlsx";
import "../config/env.js";
import Accommodation from "../models/Accommodation.js";
import Host from "../models/Host.js";
import { uploadAccommodationImages } from "./uploadUrlToCloudinary.js";

// ─── CLI ─────────────────────────────────────────────────────────────────────

const argv = process.argv.slice(2);
const flag = (name) => argv.includes(name);
const option = (name, fallback) => {
  const i = argv.indexOf(name);
  return i !== -1 && argv[i + 1] ? argv[i + 1] : fallback;
};

const APPLY = flag("--apply");
const UPDATE_PRICES = flag("--prices");
const UPDATE_IMAGES = flag("--images");
const PARSE_ONLY = flag("--parse-only");
const DELAY_MS = Number(option("--delay", 1500)) || 0;

const OPTIONS_WITH_VALUE = new Set(["--output", "--delay"]);
const positional = argv.filter(
  (a, i) => !a.startsWith("--") && !OPTIONS_WITH_VALUE.has(argv[i - 1]),
);
const INPUT = positional[0] || "hauzi_sync_input.csv";

// ─── Text helpers ────────────────────────────────────────────────────────────

const ENTITIES = { nbsp: " ", amp: "&", quot: '"', apos: "'", lt: "<", gt: ">" };

const decodeEntities = (s = "") =>
  s.replace(/&(#x?[0-9a-f]+|[a-z]+);/gi, (m, code) => {
    if (code[0] === "#") {
      const n = code[1].toLowerCase() === "x" ? parseInt(code.slice(2), 16) : parseInt(code.slice(1), 10);
      return Number.isFinite(n) ? String.fromCodePoint(n) : m;
    }
    return ENTITIES[code.toLowerCase()] ?? m;
  });

/** HTML fragment → plain text. <br> and </p> become newlines; runs of spaces collapse. */
const htmlToText = (html = "") =>
  decodeEntities(
    html
      // Line breaks in the HTML source are only formatting; the real ones are <br>/<p>.
      .replace(/\s+/g, " ")
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<\/p>/gi, "\n\n")
      .replace(/<[^>]+>/g, " "),
  )
    .split("\n")
    .map((line) => line.replace(/\s+/g, " ").trim())
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

/** Lower-case, accents removed — "Vírivka" and "virivka" compare equal. */
const fold = (s = "") =>
  String(s).normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();

const squash = (s = "") => String(s ?? "").replace(/\s+/g, " ").trim();

const toNumber = (v) => {
  if (v === null || v === undefined || v === "") return null;
  const n = Number(String(v).replace(",", "."));
  return Number.isFinite(n) ? n : null;
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ─── Putko enum translations (must match models/Accommodation.js) ────────────

const SK = {
  // propertyType
  "Apartment": "Apartmán",
  "Cottages": "Chaty",
  "Wooden House": "Drevený dom",
  "Guest Houses": "Penzióny",
  "Hotels": "Hotely",
  "Rooms": "Izby",
  "Entire Homes": "Celé domy",
  // rentalform
  "Entire place": "Celé miesto",
  "Private room": "Súkromná izba",
  // services
  "Wifi": "Wifi",
  "TV": "TV",
  "PC Desk(workspace)": "PC stôl(pracovný priestor)",
  // bathroomAmenities
  "Bathtub": "Vaňa",
  "Shower": "Sprcha",
  "Washing Machine": "Práčka",
  "Dryer": "Sušička",
  "Ironing": "Žehlenie",
  // kitchenDiningAmenities
  "Stovetop": "Varná doska",
  "Oven": "Rúra",
  "Dishwasher": "Umývačka riadu",
  "Refrigerator": "Chladnička",
  "Freezer": "Mraznička",
  "Dining Table": "Jedálenský stôl",
  "Coffee Maker": "Kávovar",
  // heatingCoolingAmenities
  "Indoor Fireplace": "Vnútorný krb",
  "Air Conditioning": "Klimatizácia",
  "Central Heating": "Ústredné kúrenie",
  // safetyAmenities
  "Fire Extinguisher": "Hasiaci prístroj",
  "First Aid Kit": "Lekárnička",
  // wellnessAmenities
  "Sauna": "Sauna",
  "Hot Tub": "Vírivka",
  "Indoor Pool": "Vnútorný bazén",
  "Outdoor Pool": "Vonkajší bazén",
  // outdoorAmenities
  "Firepit": "Ohnisko",
  "Balcony": "Balkón",
  "Terrace": "Terasa",
  "Outdoor dining area": "Vonkajší jedálenský priestor",
  "Grill": "Gril",
  // parkingFacilities
  "Free Parking on-site": "Bezplatné parkovanie na mieste",
  "Paid Parking on-site": "Platené parkovanie",
  "Public Parking": "Verejné parkovanie",
  // meals
  "No Meals": "Bez stravy",
  "Breakfast": "Raňajky",
  "Half Board": "Polpenzia",
  "Full Board": "Plná penzia",
  "All-Inclusive": "All-inclusive",
  // pet
  "Allowed at no extra charge": "Povolené bez príplatku",
  "Allowed with an additional fee": "Povolené za príplatok",
  "Allowed for a fee by arrangement with the owner": "Povolené za poplatok po dohode s majiteľom",
  "Not Allowed": "Nepovolené",
  // smoking
  "Allowed indoors": "Povolené v interiéri",
  "Allowed in designated areas": "Povolené v určených priestoroch",
  "Not allowed": "Nepovolené",
  // partyOrganizing ("Not Allowed" is under pet)
  "Allowed": "Povolené",
  // shared
  "None": "Žiadne",
};

const bilingualList = (en) => ({ en, sk: en.map((v) => SK[v] ?? v) });
const bilingualOne = (en) => ({ en, sk: SK[en] ?? en });

// Hauzi breadcrumb category slug → Putko propertyType.en
const PROPERTY_TYPE_BY_HAUZI_SLUG = {
  "apartmany": "Apartment",
  "chaty-chalupy": "Cottages",
  "chaty": "Cottages",
  "drevenice": "Wooden House",
  "penziony": "Guest Houses",
  "hotely": "Hotels",
};

// ─── Hauzi page parsing ──────────────────────────────────────────────────────

const extractClientData = (html) => {
  const m = html.match(/window\.clientData\s*=\s*([\s\S]*?)\s*<\/script>/);
  if (!m) return null;
  try {
    return JSON.parse(m[1].replace(/;\s*$/, ""));
  } catch {
    return null;
  }
};

const extractJsonLd = (html) => {
  const blocks = [];
  const re = /<script[^>]*type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/gi;
  let m;
  while ((m = re.exec(html))) {
    try {
      blocks.push(JSON.parse(m[1]));
    } catch {
      /* one broken block must not hide the others */
    }
  }
  return blocks;
};

/** Rows of every `table-amenities` table as { label, value } in plain text. */
const extractAmenityTables = (html) => {
  const rows = [];
  const tableRe = /<table[^>]*class="[^"]*table-amenities[^"]*"[^>]*>([\s\S]*?)<\/table>/gi;
  let t;
  while ((t = tableRe.exec(html))) {
    const rowRe = /<tr[^>]*>\s*<td[^>]*>([\s\S]*?)<\/td>\s*<td[^>]*>([\s\S]*?)<\/td>\s*<\/tr>/gi;
    let r;
    while ((r = rowRe.exec(t[1]))) {
      rows.push({
        label: squash(htmlToText(r[1])).replace(/[:?]\s*$/, ""),
        value: squash(htmlToText(r[2]).replace(/zobraziť na mape/i, "")),
      });
    }
  }
  return rows;
};

const innerHtmlById = (html, id) => {
  const m = html.match(new RegExp(`<(span|div|p)[^>]*id="${id}"[^>]*>([\\s\\S]*?)</\\1>`, "i"));
  return m ? m[2] : "";
};

/** "Maše Haľamovej 4004/5, 059 85, Štrba - Štrbské Pleso, Slovensko" under the <h1>. */
const extractAddress = (html) => {
  const m = html.match(/<\/h1>([\s\S]*?)<\/div>/i);
  if (!m) return null;
  const full = squash(htmlToText(m[1])).replace(/\s+,/g, ",");
  const parts = full.split(",").map((p) => p.trim()).filter(Boolean);
  const zipIdx = parts.findIndex((p) => /^\d{3}\s?\d{2}$/.test(p));
  const cityLink = m[1].match(/<a[^>]*>([^<]+)<\/a>/i);
  return {
    full,
    street: zipIdx > 0 ? parts.slice(0, zipIdx).join(", ") : parts.length > 3 ? parts[0] : "",
    zipCode: zipIdx !== -1 ? parts[zipIdx] : "",
    city: cityLink ? squash(decodeEntities(cityLink[1])) : "",
    country: parts.length ? parts[parts.length - 1] : "",
  };
};

/**
 * Rooms from a unit's roomText: "<b>1x kuchyňa</b><br>Vybavenie: …" →
 * { count: 1, name: "kuchyňa", equipment: "…" }.
 *
 * A room can hold rooms of its own ("2x spálňa … Ďalšie miestnosti v tejto
 * izbe: <div><b>1x kúpeľňa s toaletou</b></div>"). Those are returned too, with
 * their count multiplied by the parent's — two bedrooms each with a bathroom
 * are two bathrooms.
 */
export const parseRooms = (roomText = "") => {
  const nested = [];
  const top = decodeEntities(roomText).replace(/<div[^>]*>([\s\S]*?)<\/div>/gi, (_, inner) => {
    nested.push(inner);
    return `<nested ${nested.length - 1}>`;
  });

  const heads = [...top.matchAll(/<b>\s*(\d+)x\s*([^<]+)<\/b>/gi)];
  const rooms = [];
  heads.forEach((h, i) => {
    const segment = top.slice(h.index, i + 1 < heads.length ? heads[i + 1].index : top.length);
    const count = Number(h[1]);
    const equipment = segment.match(/Vybavenie:\s*([^<]*)/i);
    rooms.push({ count, name: squash(h[2]), equipment: equipment ? squash(equipment[1]) : "" });
    for (const m of segment.matchAll(/<nested (\d+)>/g)) {
      for (const inner of parseRooms(nested[m[1]])) rooms.push({ ...inner, count: inner.count * count });
    }
  });
  return rooms;
};

/**
 * Photos in the page's own gallery, in display order. Read from the gallery
 * markup only — the rest of the page also shows photos of nearby attractions,
 * which must never end up on a listing.
 */
const extractGalleryIds = (html) =>
  [...html.matchAll(/<div data-title="[^"]*"\s+class="photo"[\s\S]*?<img src="[^"]*?\/([a-z0-9]+)\.jpg"/gi)].map((m) => m[1]);

const hauziImageUrl = (id) => `https://images.hauzi.com/1800/${id.slice(-2)}/${id}.jpg`;

const parseTime = (text, word) => {
  const m = String(text || "").match(new RegExp(`${word}\\s*(\\d{1,2}):(\\d{2})`, "i"));
  return m ? `${m[1].padStart(2, "0")}:${m[2]}` : null;
};

// Table rows that describe the surroundings or rules rather than equipment —
// kept out of the amenity text so "Kúpanie: Aquacity" never becomes a pool.
const NON_AMENITY_LABELS =
  /gps|region|obchod|restaura|vlak|autobus|mobiln|nastup|odchod|majitel|zviera|oplot|bezbarier|fajcen|stravovan|parkovan|vhodne|akceptuj|preferuj/;

const matchAny = (text, re) => re.test(text);

/** Amenity text (folded) → Putko amenity groups. Pure, so it can be tested alone. */
export const detectAmenities = (corpus, heatingText = "") => {
  const t = fold(corpus);
  const heat = fold(heatingText);

  const services = [];
  if (matchAny(t, /wi-?fi|internet/)) services.push("Wifi");
  if (matchAny(t, /televizor|\btv\b|satelit/)) services.push("TV");
  if (matchAny(t, /pracovn\S* (stol|kut|priestor|miesto)|pisaci stol|kancelar|workspace/)) services.push("PC Desk(workspace)");

  const bathroom = [];
  if (matchAny(t, /\bvan(a|ou|e|u)\b/)) bathroom.push("Bathtub");
  if (matchAny(t, /sprch/)) bathroom.push("Shower");
  if (matchAny(t, /prack/)) bathroom.push("Washing Machine");
  if (matchAny(t, /susick/)) bathroom.push("Dryer");
  if (matchAny(t, /zehli/)) bathroom.push("Ironing");

  const kitchen = [];
  if (matchAny(t, /varna doska|platnick|sporak|varic|indukc/)) kitchen.push("Stovetop");
  // A microwave counts as an oven on Putko.
  if (matchAny(t, /\brur(a|ou|y)\b|mikrovln|trouba/)) kitchen.push("Oven");
  if (matchAny(t, /umyvack/)) kitchen.push("Dishwasher");
  if (matchAny(t, /chladnick/)) kitchen.push("Refrigerator");
  if (matchAny(t, /mrazni|mraziak/)) kitchen.push("Freezer");
  if (matchAny(t, /jedalen|jedalny (stol|kut)|stolovani/)) kitchen.push("Dining Table");
  if (matchAny(t, /kavovar|espress|kapsulov/)) kitchen.push("Coffee Maker");

  const heating = [];
  const indoorText = t.replace(/vonkajs\S* krb/g, "");
  if (matchAny(indoorText + " " + heat, /\bkrb|kachl|kozub/)) heating.push("Indoor Fireplace");
  if (matchAny(t, /klimatiz/)) heating.push("Air Conditioning");
  // Central Heating only when Hauzi's "Kúrenie" row says central or gas
  // ("ústredné", "centrálne", "plynové"). Floor, electric, heat pump etc. alone
  // give no heating option.
  if (matchAny(heat, /ustredn|centraln|plyn/)) heating.push("Central Heating");

  const safety = [];
  if (matchAny(t, /hasiac/)) safety.push("Fire Extinguisher");
  if (matchAny(t, /lekarnick/)) safety.push("First Aid Kit");

  const wellness = [];
  if (matchAny(t, /saun/)) wellness.push("Sauna");
  if (matchAny(t, /virivk|jacuzzi|kupacia kad|hot ?tub/)) wellness.push("Hot Tub");
  let indoorPool = false;
  let outdoorPool = false;
  for (const m of t.matchAll(/(\S+)\s+bazen|^bazen|[^a-z]bazen/g)) {
    const prefix = m[1] || "";
    if (/detsk/.test(prefix)) continue; // a paddling pool is not a pool amenity
    if (/kryt|vnutor|interier/.test(prefix) && !/nekryt/.test(prefix)) indoorPool = true;
    else outdoorPool = true;
  }
  if (indoorPool) wellness.push("Indoor Pool");
  if (outdoorPool) wellness.push("Outdoor Pool");

  const outdoor = [];
  if (matchAny(t, /ohnisk|kotlik|vonkajs\S* krb/)) outdoor.push("Firepit");
  if (matchAny(t, /balkon|loggi|lodzi/)) outdoor.push("Balcony");
  if (matchAny(t, /teras/)) outdoor.push("Terrace");
  if (matchAny(t, /vonkajsie posedenie|altan|zahradne posedenie/)) outdoor.push("Outdoor dining area");
  if (matchAny(t, /gril/)) outdoor.push("Grill");

  return {
    services,
    bathroomAmenities: bathroom,
    kitchenDiningAmenities: kitchen,
    heatingCoolingAmenities: heating,
    safetyAmenities: safety,
    wellnessAmenities: wellness.length ? wellness : ["None"],
    outdoorAmenities: outdoor.length ? outdoor : ["None"],
  };
};

/**
 * Does the free-text description mention the thing `re` matches?
 * Some outdoor amenities are often only mentioned there, not in Hauzi's
 * equipment lists. A mention right after "bez" / "nemá" ("bez balkóna") does
 * not count.
 */
export const descriptionMentions = (description = "", re) => {
  const t = fold(description);
  for (const m of t.matchAll(new RegExp(re.source, "g"))) {
    const before = t.slice(Math.max(0, m.index - 15), m.index);
    if (!/\b(bez|nema\S*|ziadn\S*)\s+(\S+\s+)?$/.test(before)) return true;
  }
  return false;
};

// Outdoor amenities also taken from the description, with the words that mean them.
const DESCRIPTION_OUTDOOR = [
  ["Balcony", /balkon|loggi|lodzi/],
  ["Terrace", /teras/],
  ["Grill", /gril/],
];

export const descriptionMentionsBalcony = (description = "") =>
  descriptionMentions(description, DESCRIPTION_OUTDOOR[0][1]);

// Pets allowed, but no per-night fee on Hauzi ("za poplatok (po dohode s majiteľom)").
const PET_BY_ARRANGEMENT = "Allowed for a fee by arrangement with the owner";

const mapPet = (animal, text) => {
  const a = fold(animal);
  const x = fold(text);
  if (a.startsWith("no") || /nepovolen|^nie/.test(x)) return "Not Allowed";
  if (a.includes("paid") || /za poplatok|poplatok|priplatok/.test(x)) return "Allowed with an additional fee";
  if (a.includes("free") || /bez poplatku|zadarmo|bezplatn/.test(x)) return "Allowed at no extra charge";
  // Allowed, but Hauzi does not say whether it costs anything.
  return PET_BY_ARRANGEMENT;
};

/**
 * Pet fee per night, only when Hauzi states an amount ("za poplatok 10 € / noc").
 * Free pets → 0. Paid pets with no amount shown (usually "po dohode s majiteľom")
 * → null, so the report says the fee is not on Hauzi and Putko's fee is kept.
 */
export const mapPetFee = (pet, text) => {
  if (pet === "Allowed at no extra charge") return 0;
  if (pet !== "Allowed with an additional fee") return null;
  return toNumber(fold(text).match(/(\d+(?:[.,]\d+)?)\s*(€|eur)/)?.[1]);
};

/**
 * The "Domáce zviera: 10 € / osoba / noc" row of a unit's "Doplatky na mieste"
 * table (Hauzi's priceDetailsHtml) → { text, amount, perNight }. Only a fee
 * charged per night fits Putko's petFeePerNight; "20 € / pobyt" is per stay.
 */
export const parsePetFeeRow = (priceDetailsHtml = "") => {
  const m = priceDetailsHtml.match(/zviera:?\s*<\/td>\s*<td[^>]*>([\s\S]*?)<\/td>/i);
  if (!m) return null;
  const text = squash(htmlToText(m[1]));
  return {
    text,
    amount: toNumber(text.match(/(\d+(?:[.,]\d+)?)\s*(€|eur)/i)?.[1]),
    perNight: /\/\s*noc/i.test(text),
  };
};

/** "Neakceptujeme: Hlučné oslavy a párty" → Not Allowed; accepted / suitable for parties → Allowed. */
export const mapParty = (rejected, accepted) => {
  // "Partie mladých ľudí" (groups of young people) is not a party.
  const party = /oslav|party|vecierk|teambuilding/;
  if (party.test(fold(rejected))) return "Not Allowed";
  if (party.test(fold(accepted))) return "Allowed";
  return null;
};

const mapSmoking = (text) => {
  const x = fold(text);
  if (!x) return null;
  // "Fajčenie v interiéri JE povolené iba vo vyhradených priestoroch."
  if (!/nie je|nepovolen|zakazan|^nie/.test(x) && /vyhraden|urcen|iba v|len v|mimo|vonku|exterier|terase/.test(x)) {
    return "Allowed in designated areas";
  }
  // "Fajčenie v interiéri NIE JE povolené."
  if (/nie je|nepovolen|zakazan|^nie/.test(x)) return "Not allowed";
  // "Fajčenie v interiéri JE povolené."
  if (/povolen|^ano/.test(x)) return "Allowed indoors";
  return null;
};

const mapMeals = (text) => {
  const x = fold(text);
  if (!x) return null;
  const out = [];
  if (/bez stravy|bez stravovania|ziadne/.test(x)) out.push("No Meals");
  if (/ranajk/.test(x)) out.push("Breakfast");
  if (/polpenzi/.test(x)) out.push("Half Board");
  if (/plna penzi/.test(x)) out.push("Full Board");
  if (/all.?inclusive/.test(x)) out.push("All-Inclusive");
  return out.length ? out : null;
};

const mapParking = (text) => {
  const x = fold(text);
  if (!x) return null;
  if (/^nie|bez parkovania|nie je mozne/.test(x)) return [];
  const out = [];
  if (/bezplatn|zadarmo|zahrnut/.test(x)) out.push("Free Parking on-site");
  if (/(^|[^z])platen|za poplatok|€|eur/.test(x)) out.push("Paid Parking on-site");
  if (/verejn/.test(x)) out.push("Public Parking");
  return out.length ? out : ["Free Parking on-site"];
};

/**
 * Everything Putko can use from one Hauzi detail page. Values Hauzi does not
 * publish are left `null` so the comparison reports them as NOT_ON_HAUZI
 * instead of overwriting Putko with a guess.
 */
export const parseHauziPage = (html, sourceUrl = "") => {
  const client = extractClientData(html);
  const ld = extractJsonLd(html);
  const rental = client?.rental || null;
  const place = ld.find((b) => b?.geo || b?.amenityFeature || b?.["@type"] === "VacationRental") || {};
  const breadcrumb = ld.find((b) => b?.["@type"] === "BreadcrumbList");
  const faq = ld.find((b) => b?.["@type"] === "FAQPage");

  if (!rental && !place.name) {
    throw new Error("Hauzi page could not be read (blocked by Cloudflare, or the page layout changed)");
  }

  const units = rental?.units || [];
  const tables = extractAmenityTables(html);
  const row = (re) => tables.find((r) => re.test(fold(r.label)))?.value || "";

  // ── Descriptions ──────────────────────────────────────────────────────────
  const autoDescription = htmlToText(innerHtmlById(html, "auto-description-content"));
  const humanDescription = htmlToText(innerHtmlById(html, "human-description-modal-content"));
  const description = [autoDescription, humanDescription].filter(Boolean).join("\n\n") || place.description || "";

  // ── Rooms, beds and amenities for a set of units ──────────────────────────
  // Called once for the whole property and once per unit, so a property with
  // several units (an apartment and a cottage) can be matched to several
  // Putko listings, each against its own unit.
  const amenityRows = tables.filter((r) => !NON_AMENITY_LABELS.test(fold(r.label)) && !/^nie\b/.test(fold(r.value)));
  const heatingText = row(/^kurenie/);

  const statsFor = (someUnits) => {
    const rooms = someUnits.flatMap((u) =>
      parseRooms(u.roomText).map((r) => ({ ...r, count: r.count * (u.count || 1) })),
    );
    const countRooms = (re) => rooms.filter((r) => re.test(fold(r.name))).reduce((s, r) => s + r.count, 0);
    const hasRooms = rooms.length > 0;

    let doublebed = 0;
    let singlebed = 0;
    let bunkbed = 0;
    let beds = 0;
    for (const u of someUnits) {
      const b = u.beds || {};
      const mult = u.count || 1;
      doublebed += (b.couple || 0) * mult;
      singlebed += (b.adult || 0) * mult;
      bunkbed += (b.bunk || 0) * mult; // icon-bed-bunk
      // Putko "beds" holds only the extra beds ("2x prístelka", icon-bed-extra).
      beds += (b.extra || 0) * mult;
    }

    // The property-level equipment rows (parking, garden, grill, …) are shared
    // by every unit, so they are part of each unit's amenity text.
    const corpus = [
      ...someUnits.map((u) => u.amenities || ""),
      ...rooms.map((r) => `${r.name}: ${r.equipment}`),
      ...amenityRows.map((r) => r.value),
    ].join("\n");
    const amenitiesKnown = hasRooms || amenityRows.length > 0;
    const detected = amenitiesKnown ? detectAmenities(corpus, heatingText) : null;

    // Balcony, terrace and grill are also taken from the description. Other
    // amenities are not, because descriptions mention nearby places too
    // ("wellness in the local hotels").
    if (detected) {
      for (const [amenity, re] of DESCRIPTION_OUTDOOR) {
        if (!detected.outdoorAmenities.includes(amenity) && descriptionMentions(description, re)) {
          detected.outdoorAmenities = [...detected.outdoorAmenities.filter((v) => v !== "None"), amenity];
        }
      }
    }

    const has = someUnits.length > 0;
    return {
      person: has ? someUnits.reduce((s, u) => s + (u.capacity?.total || 0) * (u.count || 1), 0) || null : null,
      bedroom: has ? someUnits.reduce((s, u) => s + (u.bedroomsCount || 0) * (u.count || 1), 0) : null,
      bathroom: hasRooms ? countRooms(/kupeln/) : null,
      WCs: hasRooms ? countRooms(/toalet|\bwc\b/) : null,
      kitchen: hasRooms ? countRooms(/kuchyn/) : null,
      LivingRoom: hasRooms ? countRooms(/obyvac/) : null,
      // Every common room on Hauzi ("spoločenská miestnosť", "spoločná
      // miestnosť", "klubovňa") goes to CommonRoom; SocialRoom is not used.
      SocialRoom: 0,
      CommonRoom: hasRooms ? countRooms(/spolocensk|spolocn\S* (miestnost|priestor|izba)|klubovn/) : null,
      // Putko sofa beds are never set from Hauzi.
      Sofa: 0,
      beds: has ? beds : null,
      doublebed: has ? doublebed : null,
      bunkbed: has ? bunkbed : null,
      singlebed: has ? singlebed : null,
      ...(detected || {}),
      amenitiesKnown,
      // Raw text kept for the report so a reviewer can see what was matched.
      rawAmenityText: squash(corpus),
    };
  };

  // ── Photos ────────────────────────────────────────────────────────────────
  // Gallery order first; unit photos the gallery did not show are appended.
  // A gallery photo that belongs to no unit (garden, exterior) is shared by
  // every unit.
  const galleryIds = extractGalleryIds(html);
  const unitPhotoIds = (u) => (u.photos || []).map((p) => p._id).filter(Boolean);
  const allUnitPhotoIds = new Set(units.flatMap(unitPhotoIds));
  const uniq = (ids) => [...new Set(ids.filter(Boolean))];

  const wholeImages = uniq([...galleryIds, rental?.photo?._id, ...allUnitPhotoIds]).map(hauziImageUrl);
  const unitImages = (u) => {
    const own = new Set(unitPhotoIds(u));
    const shared = [...galleryIds, rental?.photo?._id].filter((id) => id && !allUnitPhotoIds.has(id));
    return uniq([...galleryIds.filter((id) => own.has(id) || shared.includes(id)), ...shared, ...own]).map(hauziImageUrl);
  };

  // ── Property type / rental form ───────────────────────────────────────────
  // The unit type ("5 chát", "1 apartmán") is what the owner set for THIS
  // property, so it wins. The breadcrumb is only the Hauzi search category it
  // is filed under — TREE-TOP VILLAGE is 5 chát but sits under "Drevenice" —
  // and is used only when the unit type is not recognised.
  const propertyTypeFromUnit = (typeName) => {
    const t = fold(typeName);
    if (/chat|chalup/.test(t)) return "Cottages";
    if (/apartman|byt/.test(t)) return "Apartment";
    if (/dreveni|zrub/.test(t)) return "Wooden House";
    if (/penzi/.test(t)) return "Guest Houses";
    if (/hotel/.test(t)) return "Hotels";
    if (/izb/.test(t)) return "Rooms";
    return null;
  };
  // Units of different types (an apartment and a cottage) → the unit type says
  // nothing about the whole property, so the Hauzi category is used instead.
  const unitTypes = [...new Set(units.map((u) => propertyTypeFromUnit(u.typeName)).filter(Boolean))];
  let propertyType = unitTypes.length === 1 ? unitTypes[0] : null;
  if (!propertyType) {
    const categorySlug = (breadcrumb?.itemListElement || [])
      .map((el) => String(el?.item?.["@id"] || "").replace(/\/+$/, "").split("/").pop())
      .find((slug) => PROPERTY_TYPE_BY_HAUZI_SLUG[slug]);
    propertyType = categorySlug ? PROPERTY_TYPE_BY_HAUZI_SLUG[categorySlug] : unitTypes[0] || null;
  }

  // Only rooms are "Private room". A house of separately booked apartments is
  // not exclusive on Hauzi, yet every apartment is still an entire place.
  let rentalform = null;
  if (units.length) rentalform = units.every((u) => /izb/.test(fold(u.typeName))) ? "Private room" : "Entire place";
  else if (rental) rentalform = rental.exclusiveAsWhole || rental.exclusive ? "Entire place" : "Private room";

  // ── Price / stay length ───────────────────────────────────────────────────
  // "od 40 € / apartmán / noc" is the lowest price Hauzi has for a coming night.
  // When the page lacks it, the same is taken from the day-by-day price
  // calendar (index 0 = 1 January of this year), counting only future nights.
  // Neither there → null: reported as not on Hauzi, Putko price kept.
  const priceRange = String(place.priceRange || "");
  const priceFromRange = toNumber(priceRange.match(/(\d+(?:[.,]\d+)?)/)?.[1]);
  const todayIndex = Math.floor((Date.now() - new Date(new Date().getFullYear(), 0, 1).getTime()) / 864e5);
  const futurePrices = (rental?.calendarPrices || []).slice(todayIndex).filter((p) => p > 0);
  const lowestPrice = priceFromRange ?? (futurePrices.length ? Math.min(...futurePrices) : null);
  // "/ osoba / noc" is a price per person; anything else is per night.
  const perPerson = /osob/.test(fold(priceRange));
  // "/ apartmán / noc" or "/ chata / noc" on a page with several units is the
  // price of ONE unit, not of the whole property, so a Putko listing for the
  // whole property must not get it.
  const unitTotal = units.reduce((n, u) => n + (u.count || 1), 0);
  const perOneUnit = !perPerson && unitTotal > 1 && !/objekt|cely|cele/.test(fold(priceRange));
  const pricePerNight = perPerson || perOneUnit ? null : lowestPrice;
  const pricePerPerson = perPerson ? lowestPrice : null;

  // Most Hauzi pages say the minimum stay "depends on the date" and publish no
  // number; then it is reported as not on Hauzi and Putko's value is kept.
  let nightMin = toNumber(rental?.model?.minStay);
  if (nightMin === null && faq) {
    const answer = (faq.mainEntity || [])
      .filter((q) => /minim/i.test(q?.name || ""))
      .map((q) => q?.acceptedAnswer?.text || "")
      .join(" ");
    nightMin = toNumber(answer.match(/(\d+)\s*noc/i)?.[1]);
  }

  // ── Location ──────────────────────────────────────────────────────────────
  const address = extractAddress(html);
  let latitude = toNumber(place?.geo?.latitude);
  let longitude = toNumber(place?.geo?.longitude);
  if (latitude === null) {
    const gps = row(/^gps/).match(/(-?\d+\.\d+)\s*,\s*(-?\d+\.\d+)/);
    if (gps) [latitude, longitude] = [Number(gps[1]), Number(gps[2])];
  }

  const arrival = row(/^nastup/);
  const departure = row(/^odchod/);
  const pet = mapPet(rental?.animal, row(/zviera/));

  // Everything that belongs to the property as a whole — the same for every unit.
  const shared = {
    sourceUrl,
    description: description || null,
    arrivalFrom: parseTime(arrival, "od"),
    arrivalTo: parseTime(arrival, "do"),
    departureFrom: parseTime(departure, "od"),
    departureTo: parseTime(departure, "do"),
    pet,
    petFeePerNight: mapPetFee(pet, row(/zviera/)),
    partyOrganizing: mapParty(row(/^neakceptuj/), [row(/^(akceptuj|preferuj)/), row(/vhodne na/)].join(", ")),
    smoking: mapSmoking(row(/fajcen/)),
    meals: mapMeals(row(/stravovan/)),
    parkingFacilities: mapParking(row(/parkovan/)),
    nightMin,
    nightMax: 0, // Hauzi does not publish a maximum stay; Putko uses 0
    // Why a value is missing, shown in the report's note column.
    notes: {
      nightMin: "This property has no minimum stay on Hauzi (it depends on the date); Putko value kept",
      pricePerNight: perPerson
        ? `Hauzi prices this property per person (${priceRange.trim()}); see pricePerPerson`
        : "This property has no price on Hauzi; Putko value kept",
      pricePerPerson: perPerson ? "" : "Hauzi does not price this property per person; Putko value kept",
      petFeePerNight: pet === "Allowed with an additional fee"
        ? "Pets allowed for a fee, but Hauzi does not show the amount; Putko value kept"
        : "No pet fee applies; Putko value kept",
      partyOrganizing: "Hauzi does not say whether parties are allowed; Putko value kept",
    },
    virtualTourUrl: rental?.virtualTour || null,
    rentalId: rental?._id || null,
    latitude,
    longitude,
    address,
  };

  // ── The whole property (one Putko listing for the whole Hauzi page) ───────
  const wholeStats = statsFor(units);
  const whole = {
    ...shared,
    ...wholeStats,
    name: rental?.name || place.name || null,
    unitName: null,
    propertyType,
    rentalform,
    // The page's own totals are preferred where it states them.
    person: toNumber(rental?.maxCapacity) ?? toNumber(place?.occupancy?.maxValue) ?? wholeStats.person,
    bedroom: toNumber(place.numberOfBedrooms) ?? wholeStats.bedroom,
    bathroom: toNumber(place.numberOfBathroomsTotal) ?? wholeStats.bathroom,
    WCs: toNumber(autoDescription.match(/(\d+)\s*x\s*WC/i)?.[1]) ?? wholeStats.WCs,
    pricePerNight,
    pricePerPerson,
    images: wholeImages,
    notes: {
      ...shared.notes,
      ...(perOneUnit
        ? { pricePerNight: `Hauzi price "${priceRange.trim()}" is for one of the ${unitTotal} units, not the whole property; Putko price kept` }
        : {}),
    },
  };

  // ── Each unit on its own (one Putko listing per Hauzi unit) ───────────────
  const multiUnit = units.length > 1;
  const unitViews = units.map((u) => ({
    ...shared,
    ...statsFor([u]),
    // A unit is only called "Apartmán" or "Chata" on Hauzi; the Putko listing
    // keeps its own, fuller name.
    name: null,
    unitId: u._id || null,
    unitName: u.name || u.typeName || "",
    unitTypeName: u.typeName || "",
    propertyType: propertyTypeFromUnit(u.typeName) || propertyType,
    rentalform: /izb/.test(fold(u.typeName)) ? "Private room" : "Entire place",
    // Hauzi publishes one "from" price for the whole property, not per unit.
    pricePerNight: multiUnit ? null : pricePerNight,
    pricePerPerson: multiUnit ? null : pricePerPerson,
    images: unitImages(u),
    // The Hauzi address covers all units ("APARTMÁN č.123 a CHATA č.107"), so
    // a unit's own Putko street address is kept. City and ZIP are shared.
    address: multiUnit && shared.address ? { ...shared.address, full: null, street: "" } : shared.address,
    notes: {
      ...shared.notes,
      ...(multiUnit
        ? {
            address: "Hauzi shows one address for all units; the unit's Putko address kept",
            streetAndNumber: "Hauzi shows one address for all units; the unit's Putko address kept",
          }
        : {}),
      name: `Hauzi unit is only called "${u.name || u.typeName}"; Putko name kept`,
      ...(multiUnit
        ? {
            pricePerNight: `Hauzi shows one price for the whole property (${place.priceRange || "n/a"}); Putko price kept`,
            pricePerPerson: `Hauzi shows one price for the whole property (${place.priceRange || "n/a"}); Putko price kept`,
          }
        : {}),
    },
  }));

  return { ...whole, units: unitViews };
};

/**
 * Which Hauzi unit is each Putko listing? An explicit "#Unit name" on the
 * Putko URL wins; otherwise the unit whose name words ("apartman", "chata")
 * appear in the listing's name or slug. Each unit is used at most once.
 * Returns a Map listing-index → unit-index.
 */
export const matchListingsToUnits = (listings, units, propertyName = "") => {
  const words = (s) => fold(s).split(/[^a-z0-9]+/).filter((w) => w.length >= 3 && !/^\d+$/.test(w));
  const numbers = (s) => fold(s).match(/\d+/g) || [];
  // The unit's numbers, in order, end the listing's: "Apartmán s 1 spálňou č. 8"
  // is [1, 8] and "…-apartman-s-1-spalnou-c-8" ends with [1, 8]; "…-c-9" does not.
  const endsWith = (list, tail) => tail.length <= list.length && tail.every((n, i) => list[list.length - tail.length + i] === n);
  // "Apartmány Agnesa" is in every listing's name and slug, so it says nothing
  // about which unit a listing is.
  const propertyWords = new Set(words(propertyName));
  const pairs = [];
  listings.forEach((l, li) => {
    const text = `${l.name || ""} ${l.slug || ""}`;
    const hay = new Set(words(text).filter((w) => !propertyWords.has(w)));
    // The slug is the reliable source of numbers; the name may add a year etc.
    const listingNumbers = numbers(l.slug || l.name || "");
    units.forEach((u, ui) => {
      if (l.unitHint) {
        if (fold(l.unitHint) === fold(u.unitName)) pairs.push({ li, ui, score: 1000 });
        return;
      }
      // "Apartmán č. 4" ↔ "…-apartman-c-4": a unit number must match when both
      // have one, and a matching number outweighs the words.
      const unitNumbers = numbers(u.unitName);
      const numberMatch = unitNumbers.length > 0 && endsWith(listingNumbers, unitNumbers);
      if (unitNumbers.length && listingNumbers.length && !numberMatch) return;
      const unitWords = new Set([...words(u.unitName), ...words(u.unitTypeName)]);
      const score =
        [...unitWords].filter((w) => [...hay].some((h) => h.startsWith(w) || w.startsWith(h))).length +
        (numberMatch ? 10 : 0);
      if (score > 0) pairs.push({ li, ui, score });
    });
  });

  const result = new Map();
  const usedUnits = new Set();
  for (const p of pairs.sort((a, b) => b.score - a.score)) {
    if (result.has(p.li) || usedUnits.has(p.ui)) continue;
    result.set(p.li, p.ui);
    usedUnits.add(p.ui);
  }
  return result;
};

// ─── Fetching ────────────────────────────────────────────────────────────────

const execFileAsync = promisify(execFile);

const BROWSER_HEADERS = {
  "User-Agent":
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
  "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
  "Accept-Language": "sk-SK,sk;q=0.9",
};

const isChallengePage = (html) =>
  typeof html !== "string" || (/<title>Just a moment/i.test(html) && !/window\.clientData/.test(html));

const loadHauziHtml = async (source) => {
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

const SCRAPERAPI_KEY = process.env.SCRAPERAPI_KEY;
const SCRAPERAPI_RETRYABLE = new Set([408, 429, 500, 502, 503, 504]);

// Some resolvers (home routers, 1.1.1.1) answer SERVFAIL for scraperapi.com,
// which surfaces as EAI_AGAIN. When the system lookup fails, ask public DNS
// servers directly instead.
const publicResolver = new dns.promises.Resolver({ timeout: 5000, tries: 2 });
publicResolver.setServers(["8.8.8.8", "8.8.4.4", "9.9.9.9"]);

const lookupWithFallback = (hostname, options, callback) => {
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

const scraperApiAgent = new https.Agent({ keepAlive: true, lookup: lookupWithFallback });

const fetchWithScraperApi = async (url, attempts = 3) => {
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
const hauziDay = (days) => {
  const d = new Date(Date.now() + days * 864e5);
  return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate();
};

/**
 * The pet fee amount and the minimum stay are not in the page HTML; Hauzi
 * loads them with the booking form (Lead.getVariations), one "variation" per
 * unit. Any dates work — even a unit booked on those dates comes back with its
 * fee table. The reply is JSON chunks separated by "~~CHUNK-SEPARATOR~~".
 */
const fetchHauziVariations = async (pageUrl, rentalId, nights = 3) => {
  const endpoint = `${new URL(pageUrl).origin}/~method/Lead.getVariations`;
  // lastNight is the last night slept: 5.–6. 10. is 2 nights.
  const body = { rentalId, firstNight: hauziDay(30), lastNight: hauziDay(30 + nights - 1), guests: [30], pets: 0, cribs: [] };

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
const addBookingDetails = async (hauzi, pageUrl) => {
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
    for (const unit of hauzi.units) {
      const priced = ofUnit(unit).find((v) => v.finalPrice > 0 && !(v.errors || []).length);
      if (priced) {
        unit.pricePerNight = Math.round((priced.finalPrice / priced.nights) * 100) / 100;
      } else {
        unit.notes = {
          ...unit.notes,
          pricePerNight: "Unit is booked (or has no price) on the dates checked; Putko price kept",
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

// ─── CSV in / out ────────────────────────────────────────────────────────────

const readInput = (file) => {
  const wb = xlsx.readFile(file, { raw: false, codepage: 65001 });
  const rows = xlsx.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { defval: "" });
  // Header names are matched loosely: "Hauzi URL", "hauzi_link", "hauziUrl" all work.
  const pick = (r, re) => {
    const key = Object.keys(r).find((k) => re.test(fold(k).replace(/[^a-z]/g, "")));
    return key ? String(r[key]).trim() : "";
  };
  return rows
    .map((r) => ({
      hauziUrl: pick(r, /^hauzi|^hazui|^hauz/),
      putkoUrl: pick(r, /^putko/),
      hostEmail: pick(r, /email|mail/),
    }))
    .filter((r) => r.hauziUrl || r.putkoUrl || r.hostEmail);
};

const REPORT_COLUMNS = [
  "row", "hostEmail", "hauziUrl", "putkoUrl", "listing",
  "field", "hauziValue", "putkoValue", "status", "note",
];

const csvCell = (v) => {
  const s = v === null || v === undefined ? "" : typeof v === "string" ? v : JSON.stringify(v);
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};

// Written after every listing, so a crash half-way still leaves a usable report.
// The BOM makes Excel open the file as UTF-8 (Slovak characters intact).
const writeReport = (file, rows) => {
  const lines = [REPORT_COLUMNS.join(",")];
  for (const r of rows) lines.push(REPORT_COLUMNS.map((c) => csvCell(r[c])).join(","));
  fs.writeFileSync(file, "\uFEFF" + lines.join("\r\n") + "\r\n", "utf8");
};

// ─── Comparison ──────────────────────────────────────────────────────────────

const sameSet = (a = [], b = []) => {
  const x = [...new Set(a)].sort();
  const y = [...new Set(b)].sort();
  return x.length === y.length && x.every((v, i) => v === y[i]);
};

const sameText = (a, b) => fold(squash(a)) === fold(squash(b));

const sameNumber = (a, b, tolerance = 0) =>
  a !== null && a !== undefined && b !== null && b !== undefined && Math.abs(Number(a) - Number(b)) <= tolerance;

/**
 * Field-by-field plan. Each entry knows how to read the Hauzi value, read the
 * Putko value, compare them and produce the $set to make Putko match.
 */
const FIELDS = [
  { field: "name", hauzi: (h) => h.name, putko: (a) => a.name, same: sameText, set: (v) => ({ name: v }) },
  { field: "description", hauzi: (h) => h.description, putko: (a) => a.description, same: sameText, set: (v) => ({ description: v }) },
  {
    field: "propertyType",
    hauzi: (h) => h.propertyType,
    putko: (a) => a.propertyType?.en,
    same: (x, y) => x === y,
    set: (v) => ({ propertyType: bilingualOne(v) }),
    bilingual: true,
  },
  {
    field: "rentalform",
    hauzi: (h) => h.rentalform,
    putko: (a) => a.rentalform?.en,
    same: (x, y) => x === y,
    set: (v) => ({ rentalform: bilingualOne(v) }),
    bilingual: true,
  },
  ...["person", "bedroom", "bathroom", "WCs", "kitchen", "LivingRoom", "SocialRoom", "CommonRoom", "beds", "doublebed", "singlebed", "bunkbed", "Sofa", "nightMin", "nightMax"].map((key) => ({
    field: key,
    hauzi: (h) => h[key],
    putko: (a) => a[key],
    same: (x, y) => sameNumber(x, y),
    set: (v) => ({ [key]: v }),
  })),
  ...["arrivalFrom", "arrivalTo", "departureFrom", "departureTo"].map((key) => ({
    field: key,
    hauzi: (h) => h[key],
    putko: (a) => a[key],
    same: (x, y) => String(x || "").padStart(5, "0") === String(y || "").padStart(5, "0"),
    set: (v) => ({ [key]: v }),
  })),
  ...["pet", "partyOrganizing", "smoking"].map((key) => ({
    field: key,
    hauzi: (h) => h[key],
    putko: (a) => a[key]?.en,
    same: (x, y) => x === y,
    set: (v) => ({ [key]: bilingualOne(v) }),
    bilingual: true,
  })),
  ...[
    "services", "bathroomAmenities", "kitchenDiningAmenities", "heatingCoolingAmenities",
    "safetyAmenities", "wellnessAmenities", "outdoorAmenities", "parkingFacilities", "meals",
  ].map((key) => ({
    field: key,
    hauzi: (h) => h[key],
    putko: (a) => a[key]?.en || [],
    same: (x, y) => sameSet(x, y),
    set: (v) => ({ [key]: bilingualList(v) }),
    bilingual: true,
    // Hauzi never lists safety equipment, so an empty Hauzi set there means
    // "not published", not "none" — Putko's value is kept.
    unknownWhen: (h) => key === "safetyAmenities" && (!h[key] || h[key].length === 0),
  })),
  {
    field: "latitude",
    hauzi: (h) => h.latitude,
    putko: (a) => a.location?.latitude,
    same: (x, y) => sameNumber(x, y, 0.0005),
    set: (v) => ({ "location.latitude": v }),
  },
  {
    field: "longitude",
    hauzi: (h) => h.longitude,
    putko: (a) => a.location?.longitude,
    same: (x, y) => sameNumber(x, y, 0.0005),
    set: (v) => ({ "location.longitude": v }),
  },
  {
    field: "address",
    hauzi: (h) => h.address?.full || null,
    putko: (a) => a.location?.address,
    same: sameText,
    set: (v) => ({ "location.address": v }),
  },
  {
    field: "streetAndNumber",
    hauzi: (h) => h.address?.street || null,
    putko: (a) => a.locationDetails?.streetAndNumber,
    same: sameText,
    set: (v) => ({ "locationDetails.streetAndNumber": v.toLowerCase() }),
  },
  {
    field: "city",
    hauzi: (h) => h.address?.city || null,
    putko: (a) => a.locationDetails?.city,
    same: sameText,
    set: (v) => ({ "locationDetails.city": v.toLowerCase() }),
  },
  {
    field: "zipCode",
    hauzi: (h) => h.address?.zipCode || null,
    putko: (a) => a.locationDetails?.zipCode,
    same: (x, y) => String(x || "").replace(/\s/g, "") === String(y || "").replace(/\s/g, ""),
    set: (v) => ({ "locationDetails.zipCode": v }),
  },
  {
    field: "virtualTourUrl",
    hauzi: (h) => h.virtualTourUrl,
    putko: (a) => a.virtualTourUrl,
    same: (x, y) => String(x || "") === String(y || ""),
    set: (v) => ({ virtualTourUrl: v }),
  },
  {
    field: "petFeePerNight",
    hauzi: (h) => h.petFeePerNight,
    putko: (a) => a.petFeePerNight,
    same: (x, y) => sameNumber(x, y ?? 0),
    set: (v) => ({ petFeePerNight: v }),
  },
  {
    field: "pricePerNight",
    hauzi: (h) => h.pricePerNight,
    putko: (a) => a.pricePerNight,
    same: (x, y) => sameNumber(x, y),
    set: (v) => ({ pricePerNight: v }),
    gate: () => (UPDATE_PRICES ? null : "not updated without --prices"),
  },
  {
    field: "pricePerPerson",
    hauzi: (h) => h.pricePerPerson,
    putko: (a) => a.pricePerPerson,
    same: (x, y) => sameNumber(x, y),
    set: (v) => ({ pricePerPerson: v }),
    gate: () => (UPDATE_PRICES ? null : "not updated without --prices"),
  },
];

const describe = (v) => (Array.isArray(v) ? v.join(" | ") : v ?? "");

// Enum fields are shown in both languages, e.g. "Cottages (SK: Chaty)".
const show = (spec, v) => {
  if (!spec.bilingual || v === null || v === undefined || v === "") return describe(v);
  const list = Array.isArray(v) ? v : [v];
  if (!list.length) return "";
  return `${list.join(" | ")} (SK: ${list.map((x) => SK[x] ?? x).join(" | ")})`;
};

const slugFromPutkoUrl = (url) => {
  const clean = String(url || "").trim().split(/[?#]/)[0].replace(/\/+$/, "");
  return decodeURIComponent(clean.split("/").pop() || "");
};

const escapeRegex = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/** Compares (and with --apply updates) one input row. Returns report rows. */
const syncOne = async (input, rowNo) => {
  const base = { row: rowNo, hostEmail: input.hostEmail, hauziUrl: input.hauziUrl, putkoUrl: input.putkoUrl };
  const report = [];
  const push = (r) => report.push({ ...base, ...r });

  if (!input.hauziUrl) {
    push({ field: "_listing", status: "ERROR", note: "hauziUrl is empty" });
    return report;
  }

  const hauzi = parseHauziPage(await loadHauziHtml(input.hauziUrl), input.hauziUrl);
  await addBookingDetails(hauzi, input.hauziUrl);
  // Pets for a fee, but no per-night amount on Hauzi → "by arrangement with
  // the owner" (both languages), with no fee on Putko.
  for (const view of [hauzi, ...hauzi.units]) {
    if (view.pet === "Allowed with an additional fee" && (view.petFeePerNight === null || view.petFeePerNight === undefined)) {
      view.pet = PET_BY_ARRANGEMENT;
    }
    if (view.pet === PET_BY_ARRANGEMENT) view.petFeePerNight = 0;
  }
  const multiUnit = hauzi.units.length > 1;

  // ── Parse-only: just show what Hauzi says ────────────────────────────────
  if (PARSE_ONLY) {
    const views = [{ label: hauzi.name, view: hauzi }];
    if (multiUnit) hauzi.units.forEach((u) => views.push({ label: `${hauzi.name} › unit: ${u.unitName}`, view: u }));
    for (const { label, view } of views) {
      for (const spec of FIELDS) {
        const value = spec.hauzi(view);
        const missing = value === null || value === undefined || value === "";
        push({ listing: label, field: spec.field, hauziValue: show(spec, value), status: "PARSED", note: missing ? view.notes?.[spec.field] || "" : "" });
      }
      push({ listing: label, field: "images", hauziValue: view.images.join(" | "), status: "PARSED", note: `${view.images.length} photo(s)` });
      push({ listing: label, field: "_amenityText", hauziValue: view.rawAmenityText, status: "PARSED", note: "text the amenities were detected from" });
    }
    return report;
  }

  // ── Resolve host + listings, and make sure they belong together ──────────
  if (!input.hostEmail) {
    push({ listing: hauzi.name, field: "_listing", status: "ERROR", note: "hostEmail is empty" });
    return report;
  }
  const host = await Host.findOne({ email: new RegExp(`^${escapeRegex(input.hostEmail)}$`, "i") }).select("_id email");
  if (!host) {
    push({ listing: hauzi.name, field: "_listing", status: "ERROR", note: `no host with email ${input.hostEmail}` });
    return report;
  }

  // The putkoUrl cell may hold several links (comma, space, ; or new line),
  // one per Hauzi unit. "…/listings/slug#Chata" pins a link to a unit by name.
  const putkoUrls = String(input.putkoUrl || "").split(/[\s,;]+/).filter(Boolean);
  if (!putkoUrls.length) {
    push({ listing: hauzi.name, field: "_listing", status: "ERROR", note: "putkoUrl is empty" });
    return report;
  }

  const listings = [];
  for (const url of putkoUrls) {
    const key = slugFromPutkoUrl(url);
    const unitHint = decodeURIComponent(url.split("#")[1] || "").trim() || null;
    const acc = /^[a-f0-9]{24}$/i.test(key)
      ? await Accommodation.findById(key)
      : await Accommodation.findOne({ slug: key });
    const rowBase = { putkoUrl: url };
    if (!acc) {
      push({ ...rowBase, listing: hauzi.name, field: "_listing", status: "ERROR", note: `no Putko listing for "${key}"` });
      continue;
    }
    if (String(acc.userId) !== String(host._id)) {
      push({ ...rowBase, listing: acc.name, field: "_listing", status: "ERROR", note: `listing belongs to another host, not ${input.hostEmail} — nothing changed` });
      continue;
    }
    listings.push({ url, acc, unitHint, name: acc.name, slug: acc.slug });
  }

  // One Putko link → compared with the whole Hauzi property. Several links, or
  // one link pinned with "#UnitName", on a multi-unit page → each compared with
  // its own unit.
  const perUnit = multiUnit && (listings.length > 1 || listings.some((l) => l.unitHint));
  const unitOf = perUnit ? matchListingsToUnits(listings, hauzi.units, hauzi.name) : null;

  // Hauzi units no Putko listing stands for. Listed before the comparisons so
  // they are easy to spot in the report.
  const describeUnit = (u) => `${u.unitName} (${u.unitTypeName}, ${u.person ?? "?"} guests, ${u.bedroom ?? "?"} bedrooms)`;
  if (unitOf) {
    const matched = new Set(unitOf.values());
    const missing = hauzi.units.filter((_, ui) => !matched.has(ui));
    if (missing.length) {
      push({
        listing: hauzi.name, field: "_missingUnits", hauziValue: missing.map(describeUnit).join(" | "), status: "MISSING_ON_PUTKO",
        note: `This Hauzi property has ${hauzi.units.length} units; Putko has no listing for: ${missing.map((u) => u.unitName).join(", ")}. Create the listing(s) on Putko, then add the link(s) to the putkoUrl cell`,
      });
    }
  } else if (multiUnit && listings.length === 1) {
    push({
      listing: listings[0].acc.name, field: "_missingUnits", hauziValue: hauzi.units.map(describeUnit).join(" | "), status: "CHECK_UNITS",
      note: `This Hauzi property has ${hauzi.units.length} units but Putko has 1 listing, compared with the whole property. If the Putko listing is only one of the units, add "#UnitName" to its link and create Putko listings for the other units`,
    });
  }

  for (let i = 0; i < listings.length; i++) {
    const { url, acc } = listings[i];
    let view = hauzi;
    if (unitOf) {
      if (!unitOf.has(i)) {
        push({
          putkoUrl: url, listing: acc.name, field: "_listing", status: "ERROR",
          note: `could not tell which Hauzi unit this is (units: ${hauzi.units.map((u) => u.unitName).join(", ")}). Add "#UnitName" to the Putko URL — nothing changed`,
        });
        continue;
      }
      view = hauzi.units[unitOf.get(i)];
      push({ putkoUrl: url, listing: acc.name, field: "_unit", hauziValue: view.unitName, status: "MATCHED", note: `compared with Hauzi unit "${view.unitName}" (${view.unitTypeName})` });
    }
    await compareListing(view, acc, (r) => push({ putkoUrl: url, ...r }));
  }
  return report;
};

/** Compares (and with --apply updates) one Putko listing against one Hauzi view. */
const compareListing = async (hauzi, acc, push) => {
  const $set = {};
  const pending = [];
  const counts = { MATCH: 0, MISMATCH: 0, UPDATED: 0, NOT_ON_HAUZI: 0, SKIPPED: 0 };

  for (const spec of FIELDS) {
    const hv = spec.hauzi(hauzi);
    const pv = spec.putko(acc);
    const entry = { listing: acc.name, field: spec.field, hauziValue: show(spec, hv), putkoValue: show(spec, pv) };

    if (hv === null || hv === undefined || hv === "" || spec.unknownWhen?.(hauzi)) {
      push({ ...entry, status: "NOT_ON_HAUZI", note: hauzi.notes?.[spec.field] || "Putko value kept" });
      counts.NOT_ON_HAUZI++;
      continue;
    }
    if (spec.same(hv, pv)) {
      push({ ...entry, status: "MATCH" });
      counts.MATCH++;
      continue;
    }
    const blocked = spec.gate?.();
    if (blocked) {
      push({ ...entry, status: "SKIPPED", note: blocked });
      counts.SKIPPED++;
      continue;
    }
    Object.assign($set, spec.set(hv));
    const r = { ...entry, status: APPLY ? "UPDATED" : "MISMATCH" };
    pending.push(r);
    push(r);
  }

  // ── Images: Cloudinary copies cannot be compared by content, only by count ──
  const putkoImages = acc.images || [];
  const imageEntry = {
    listing: acc.name,
    field: "images",
    hauziValue: `${hauzi.images.length} photo(s): ${hauzi.images.join(" | ")}`,
    putkoValue: `${putkoImages.length} photo(s)`,
  };
  if (!hauzi.images.length) {
    push({ ...imageEntry, status: "NOT_ON_HAUZI", note: "Putko images kept" });
    counts.NOT_ON_HAUZI++;
  } else if (hauzi.images.length === putkoImages.length) {
    push({ ...imageEntry, status: "MATCH", note: "same photo count (content not compared)" });
    counts.MATCH++;
  } else if (!(APPLY && UPDATE_IMAGES)) {
    push({ ...imageEntry, status: APPLY ? "SKIPPED" : "MISMATCH", note: "photo count differs; run with --apply --images to replace" });
    counts[APPLY ? "SKIPPED" : "MISMATCH"]++;
  } else {
    try {
      $set.images = await uploadAccommodationImages(hauzi.images.join(","), acc.slug);
      const r = { ...imageEntry, status: "UPDATED", note: `${$set.images.length} photo(s) uploaded to Cloudinary` };
      pending.push(r);
      push(r);
    } catch (err) {
      push({ ...imageEntry, status: "ERROR", note: `image upload failed: ${err.message}` });
    }
  }

  // ── Write ────────────────────────────────────────────────────────────────
  if (APPLY && Object.keys($set).length) {
    try {
      await Accommodation.updateOne({ _id: acc._id }, { $set }, { runValidators: true });
    } catch (err) {
      // Nothing was written — the updateOne is all-or-nothing — so every row
      // that claimed UPDATED is corrected to ERROR.
      for (const r of pending) {
        r.status = "ERROR";
        r.note = `update failed: ${err.message}`.slice(0, 300);
      }
    }
  }
  for (const r of pending) counts[r.status] = (counts[r.status] || 0) + 1;

  push({
    listing: acc.name,
    field: "_summary",
    status: "DONE",
    note: Object.entries(counts).filter(([, n]) => n).map(([k, n]) => `${k}: ${n}`).join(", "),
  });
};

// ─── Main ────────────────────────────────────────────────────────────────────

async function run() {
  const inputFile = path.resolve(INPUT);
  if (!fs.existsSync(inputFile)) throw new Error(`Input CSV not found: ${inputFile}`);

  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const outputFile = path.resolve(option("--output", path.join(path.dirname(inputFile), `hauzi_sync_report_${timestamp}.csv`)));

  const inputs = readInput(inputFile);
  console.log(`${inputs.length} listing(s) in ${inputFile}`);
  console.log(`Mode: ${PARSE_ONLY ? "PARSE ONLY (no database)" : APPLY ? "APPLY" : "DRY RUN"}` +
    `${UPDATE_PRICES ? " +prices" : ""}${UPDATE_IMAGES ? " +images" : ""}\n`);

  if (!PARSE_ONLY) await mongoose.connect(process.env.MONGODB_URI, {});

  const report = [];
  for (let i = 0; i < inputs.length; i++) {
    const input = inputs[i];
    const label = `[${i + 1}/${inputs.length}] ${input.hauziUrl}`;
    try {
      const rows = await syncOne(input, i + 1);
      report.push(...rows);
      const outcomes = rows.filter((r) => r.field === "_summary" || r.field === "_missingUnits" || (r.field === "_listing" && r.status === "ERROR"));
      if (!outcomes.length) console.log(`${label} → ${rows[rows.length - 1]?.status || "done"}`);
      for (const r of outcomes) {
        console.log(`${label} → ${r.listing || ""}: ${r.status === "ERROR" || r.field === "_missingUnits" ? `${r.status}: ${r.note}` : r.note}`);
      }
    } catch (err) {
      // One bad page or listing must not end the run.
      report.push({ row: i + 1, ...input, field: "_listing", status: "ERROR", note: err.message.slice(0, 300) });
      console.error(`${label} → ERROR: ${err.message}`);
    }
    writeReport(outputFile, report);
    if (i < inputs.length - 1 && /^https?:/i.test(inputs[i + 1].hauziUrl)) await sleep(DELAY_MS);
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
