// scripts/hauziSync/helpers.js
//
// Command-line options, text helpers, Putko translations, CSV in/out.

import path from "node:path";
import { fileURLToPath } from "node:url";
import fs from "node:fs";
import xlsx from "xlsx";

/** This script's folder — the default input CSV and the samples live here. */
export const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));

// ─── CLI ─────────────────────────────────────────────────────────────────────

export const argv = process.argv.slice(2);
export const flag = (name) => argv.includes(name);
export const option = (name, fallback) => {
  const i = argv.indexOf(name);
  return i !== -1 && argv[i + 1] ? argv[i + 1] : fallback;
};

export const APPLY = flag("--apply");
export const UPDATE_PRICES = flag("--prices");
export const FLEXIBLE_PRICES_ONLY = flag("--flexible-prices-only");
export const UPDATE_IMAGES = flag("--images");
export const PARSE_ONLY = flag("--parse-only");
export const DELAY_MS = Number(option("--delay", 1500)) || 0;

export const OPTIONS_WITH_VALUE = new Set(["--output", "--delay"]);
export const positional = argv.filter(
  (a, i) => !a.startsWith("--") && !OPTIONS_WITH_VALUE.has(argv[i - 1]),
);
export const INPUT = positional[0] || path.join(SCRIPT_DIR, "hauzi_sync_input.csv");

// ─── Text helpers ────────────────────────────────────────────────────────────

export const ENTITIES = { nbsp: " ", amp: "&", quot: '"', apos: "'", lt: "<", gt: ">" };

export const decodeEntities = (s = "") =>
  s.replace(/&(#x?[0-9a-f]+|[a-z]+);/gi, (m, code) => {
    if (code[0] === "#") {
      const n = code[1].toLowerCase() === "x" ? parseInt(code.slice(2), 16) : parseInt(code.slice(1), 10);
      return Number.isFinite(n) ? String.fromCodePoint(n) : m;
    }
    return ENTITIES[code.toLowerCase()] ?? m;
  });

/** HTML fragment → plain text. <br> and </p> become newlines; runs of spaces collapse. */
export const htmlToText = (html = "") =>
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
export const fold = (s = "") =>
  String(s).normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();

export const squash = (s = "") => String(s ?? "").replace(/\s+/g, " ").trim();

export const toNumber = (v) => {
  if (v === null || v === undefined || v === "") return null;
  const n = Number(String(v).replace(",", "."));
  return Number.isFinite(n) ? n : null;
};

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ─── Putko enum translations (must match models/Accommodation.js) ────────────

export const SK = {
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

export const bilingualList = (en) => ({ en, sk: en.map((v) => SK[v] ?? v) });
export const bilingualOne = (en) => ({ en, sk: SK[en] ?? en });

// Hauzi breadcrumb category slug → Putko propertyType.en
export const PROPERTY_TYPE_BY_HAUZI_SLUG = {
  "apartmany": "Apartment",
  "chaty-chalupy": "Cottages",
  "chaty": "Cottages",
  "drevenice": "Wooden House",
  "penziony": "Guest Houses",
  "hotely": "Hotels",
};

// ─── CSV in / out ────────────────────────────────────────────────────────────

export const readInput = (file) => {
  const wb = xlsx.readFile(file, { raw: false, codepage: 65001 });
  const rows = xlsx.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { defval: "" });
  // Header names are matched loosely: "Hauzi URL", "hauzi_link", "hauziUrl" all work.
  const pick = (r, re) => {
    const key = Object.keys(r).find((k) => re.test(fold(k).replace(/[^a-z]/g, "")));
    return key ? String(r[key]).trim() : "";
  };
  // A saved .html path is taken relative to the CSV when it exists there, so
  // samples/sample_input.csv works from any working directory.
  const resolveSource = (v) => {
    if (!v || /^https?:\/\//i.test(v)) return v;
    const nextToCsv = path.resolve(path.dirname(file), v);
    return fs.existsSync(nextToCsv) ? nextToCsv : v;
  };
  // Several Putko links typed as "link1, link2" without quotes spill into the
  // next columns (the email column, then unnamed ones), and a line break in
  // the cell puts the rest on a line of its own. So the Putko links and the
  // email are taken from every cell of the row, and a line with no Hauzi URL
  // continues the row above.
  const EMAIL = /^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+$/;
  const PUTKO_LINK = /https?:\/\/(?:www\.)?putko\.sk\/\S+/gi;
  const parsed = rows
    .map((r) => {
      const cells = Object.values(r).map((v) => String(v).trim()).filter(Boolean);
      const hostEmail = pick(r, /email|mail/);
      const putkoCell = pick(r, /^putko/);
      return {
        hauziUrl: resolveSource(pick(r, /^hauzi|^hazui|^hauz/)),
        putkoUrl:
          cells.flatMap((c) => c.match(PUTKO_LINK) || []).map((u) => u.replace(/[,;]+$/, "")).join(" ") ||
          (EMAIL.test(putkoCell) ? "" : putkoCell),
        hostEmail: EMAIL.test(hostEmail) ? hostEmail : cells.find((c) => EMAIL.test(c)) || hostEmail,
      };
    })
    .filter((r) => r.hauziUrl || r.putkoUrl || r.hostEmail);
  const merged = [];
  for (const r of parsed) {
    const prev = merged.at(-1);
    if (!r.hauziUrl && prev) {
      if (r.putkoUrl) prev.putkoUrl = [prev.putkoUrl, r.putkoUrl].filter(Boolean).join(" ");
      if (r.hostEmail && !EMAIL.test(prev.hostEmail)) prev.hostEmail = r.hostEmail;
      continue;
    }
    merged.push(r);
  }
  return merged;
};

// Report header → row key. putkoOldValue is Putko before the run,
// putkoNewValue what Putko holds after --apply; "why" explains the status.
export const REPORT_COLUMNS = [
  ["row", "row"], ["hostEmail", "hostEmail"], ["hauziUrl", "hauziUrl"], ["putkoUrl", "putkoUrl"],
  ["listing", "listing"], ["field", "field"], ["status", "status"], ["hauziValue", "hauziValue"],
  ["putkoOldValue", "putkoValue"], ["putkoNewValue", "putkoNewValue"], ["why", "note"],
];

export const csvCell = (v) => {
  const s = v === null || v === undefined ? "" : typeof v === "string" ? v : JSON.stringify(v);
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};

// Written after every listing, so a crash half-way still leaves a usable report.
// The BOM makes Excel open the file as UTF-8 (Slovak characters intact).
export const writeReport = (file, rows) => {
  const lines = [REPORT_COLUMNS.map(([header]) => header).join(",")];
  for (const r of rows) lines.push(REPORT_COLUMNS.map(([, key]) => csvCell(r[key])).join(","));
  fs.writeFileSync(file, "\uFEFF" + lines.join("\r\n") + "\r\n", "utf8");
};
