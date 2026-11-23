// scripts/hauziSync/parse.js
//
// Reading a Hauzi page: rooms, amenities, house rules, area, and the full page → Putko values.

import { decodeEntities, htmlToText, squash, fold, toNumber, PROPERTY_TYPE_BY_HAUZI_SLUG } from "./helpers.js";

// ─── Hauzi page parsing ──────────────────────────────────────────────────────

export const extractClientData = (html) => {
  const m = html.match(/window\.clientData\s*=\s*([\s\S]*?)\s*<\/script>/);
  if (!m) return null;
  try {
    return JSON.parse(m[1].replace(/;\s*$/, ""));
  } catch {
    return null;
  }
};

export const extractJsonLd = (html) => {
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
export const extractAmenityTables = (html) => {
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

export const innerHtmlById = (html, id) => {
  const m = html.match(new RegExp(`<(span|div|p)[^>]*id="${id}"[^>]*>([\\s\\S]*?)</\\1>`, "i"));
  return m ? m[2] : "";
};

/** "Maše Haľamovej 4004/5, 059 85, Štrba - Štrbské Pleso, Slovensko" under the <h1>. */
export const extractAddress = (html) => {
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
export const extractGalleryPhotos = (html) =>
  [...html.matchAll(/<div data-title="([^"]*)"\s+class="photo"[\s\S]*?<img src="[^"]*?\/([a-z0-9]+)\.jpg"/gi)].map((m) => ({
    id: m[2],
    // "Apartmán č. 3 - Apartmány Agnesa" → "Apartmán č. 3"; "Krb - Apartmány Agnesa" → "Krb".
    title: squash(m[1].replace(/&nbsp;/g, " ")).split(/\s+-\s+/)[0] || "",
  }));

export const extractGalleryIds = (html) => extractGalleryPhotos(html).map((p) => p.id);

// A unit needs at least this many photos; fewer are topped up from the property gallery.
export const MIN_UNIT_IMAGES = 5;

export const hauziImageUrl =(id) => `https://images.hauzi.com/1800/${id.slice(-2)}/${id}.jpg`;

export const parseTime = (text, word) => {
  const m = String(text || "").match(new RegExp(`${word}\\s*(\\d{1,2}):(\\d{2})`, "i"));
  return m ? `${m[1].padStart(2, "0")}:${m[2]}` : null;
};

// Table rows that describe the surroundings or rules rather than equipment —
// kept out of the amenity text so "Kúpanie: Aquacity" never becomes a pool.
export const NON_AMENITY_LABELS =
  /gps|region|obchod|restaura|vlak|autobus|mobiln|nastup|odchod|majitel|zviera|oplot|bezbarier|fajcen|stravovan|parkovan|vhodne|akceptuj|preferuj/;

export const matchAny = (text, re) => re.test(text);

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
export const DESCRIPTION_OUTDOOR = [
  ["Balcony", /balkon|loggi|lodzi/],
  ["Terrace", /teras/],
  ["Grill", /gril/],
];

export const descriptionMentionsBalcony = (description = "") =>
  descriptionMentions(description, DESCRIPTION_OUTDOOR[0][1]);

// Pets allowed, but no per-night fee on Hauzi ("za poplatok (po dohode s majiteľom)").
export const PET_BY_ARRANGEMENT = "Allowed for a fee by arrangement with the owner";

export const mapPet = (animal, text) => {
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

// Hauzi's Cenník table (or its day-by-day calendar) into Putko's native
// flexiblePrices shape. A tier is one price for the stated minimum stay and
// guest count; the optional fields intentionally remain open ended.
const flexibleDate = (value, year = new Date().getFullYear()) => {
  const text = fold(String(value || ""));
  const m = text.match(/(\d{1,2})\s*[.\/]\s*(\d{1,2})(?:\s*[.\/]\s*(\d{4}))?/)
    || text.match(/(\d{1,2})\s*\.?\s*(jan|feb|mar|apr|maj|jun|jul|aug|sep|okt|nov|dec)[a-z]*/);
  if (!m) return null;
  const monthNames = { jan: 1, feb: 2, mar: 3, apr: 4, maj: 5, jun: 6, jul: 7, aug: 8, sep: 9, okt: 10, nov: 11, dec: 12 };
  const month = Number(m[2]) || monthNames[m[2]];
  return new Date(Date.UTC(Number(m[3] || year), month - 1, Number(m[1])));
};

const dateRange = (value) => {
  const parts = String(value || "").split(/\s*[-–]\s*/);
  if (parts.length !== 2) return null;
  const start = flexibleDate(parts[0]);
  let end = flexibleDate(parts[1], start?.getUTCFullYear());
  if (!start || !end) return null;
  if (end < start && !/\d{4}/.test(parts[1])) end = flexibleDate(parts[1], start.getUTCFullYear() + 1);
  return { start, end };
};

const removeUnitPriceModals = (html) => {
  const modalStart = /<div\b(?=[^>]*\bid=["']unit-modal-[^"']+["'])[^>]*>/gi;
  let output = "";
  let cursor = 0;
  let modal;
  while ((modal = modalStart.exec(html))) {
    let depth = 1;
    const tags = /<\/?div\b[^>]*>/gi;
    tags.lastIndex = modalStart.lastIndex;
    let tag;
    let end = html.length;
    let closed = false;
    while ((tag = tags.exec(html))) {
      if (/^<\//.test(tag[0])) depth--;
      else if (!/\/\s*>$/.test(tag[0])) depth++;
      if (depth === 0) {
        end = tags.lastIndex;
        closed = true;
        break;
      }
    }
    if (!closed) return html;
    output += html.slice(cursor, modal.index);
    cursor = end;
    modalStart.lastIndex = end;
  }
  return output + html.slice(cursor);
};

/** The html of the unit's modal (`<div id="unit-modal-ID">…</div>`), or "". */
const unitModalHtml = (html, unitId) => {
  if (!unitId) return "";
  const open = new RegExp(`<div\\b(?=[^>]*\\bid=["']unit-modal-${String(unitId).replace(/[^\w-]/g, "")}["'])[^>]*>`, "i").exec(html);
  if (!open) return "";
  const tags = /<\/?div\b[^>]*>/gi;
  tags.lastIndex = open.index + open[0].length;
  let depth = 1;
  let tag;
  while ((tag = tags.exec(html))) {
    if (/^<\//.test(tag[0])) depth--;
    else if (!/\/\s*>$/.test(tag[0])) depth++;
    if (depth === 0) return html.slice(open.index, tags.lastIndex);
  }
  return "";
};

/** The periods of the first Cenník table (`div.table-prices`) in `scopeHtml`. */
const flexiblePeriodsFromTable = (scopeHtml) => {
  const listingHtml = scopeHtml;
  const marker = listingHtml.match(/<div[^>]*class=["'][^"']*\btable-prices\b[^"']*["'][^>]*>/i);
  if (!marker) return [];
  const afterMarker = listingHtml.slice(marker.index + marker[0].length);
  const tableStart = afterMarker.search(/<table\b/i);
  if (tableStart < 0) return [];
  const tableHtml = afterMarker.slice(tableStart).match(/^[\s\S]*?<\/table>/i)?.[0] || "";
  const periods = [];
  for (const row of tableHtml.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)) {
    const cells = [...row[1].matchAll(/<td\b[^>]*>([\s\S]*?)<\/td>/gi)].map((m) => squash(htmlToText(m[1])));
    if (cells.length < 6) continue;
    const range = dateRange(cells[1]);
    const price = toNumber(cells[5].match(/\d+(?:[.,]\d+)?/)?.[0]);
    if (!range || !price || price <= 0) continue;
    const minGuests = toNumber(cells[2].match(/\d+/)?.[0]);
    const minNights = toNumber(cells[3].match(/\d+/)?.[0]) || 1;
    const name = cells[0].replace(/\s*\d+.*$/, "").trim() || cells[0];
    const period = periods.find((p) => p.name === name && p.start.getTime() === range.start.getTime() && p.end.getTime() === range.end.getTime());
    const tier = { minNights, maxNights: null, minGuests, maxGuests: null, price };
    if (period) period.tiers.push(tier);
    else periods.push({ name, ...range, note: cells[4] || "", applyDiscounts: true, tiers: [tier] });
  }
  return periods;
};

const flexiblePeriodsFromCalendar = (html) => {
  // The Colab scraper reads these fields directly from the raw HTML. They are
  // not always present in the parsed clientData object (some pages embed the
  // calendar separately or make the larger clientData blob non-JSON).
  const pricesMatch = html.match(/"calendarPrices"\s*:\s*\[([^\]]*)\]/);
  const prices = pricesMatch ? [...pricesMatch[1].matchAll(/-?\d+/g)].map((m) => Number(m[0])) : [];
  if (!prices.length) return [];
  const updated = html.match(/"calendarUpdatedAt"\s*:\s*"\d{1,2}\/\d{1,2}\/(\d{4})"/);
  const year = Number(updated?.[1] || new Date().getFullYear());
  const first = new Date(Date.UTC(year, 0, 1));
  const minStay = Number(html.match(/"minStay"\s*:\s*(\d+)/)?.[1]) || 1;
  const now = new Date();
  const today = new Date(Date.UTC(now.getFullYear(), now.getMonth(), now.getDate()));
  const periods = [];
  let runStart = null;
  const closeRun = (endIndex) => {
    if (runStart === null) return;
    const price = Number(prices[runStart]);
    const start = new Date(first); start.setUTCDate(start.getUTCDate() + runStart);
    const end = new Date(first); end.setUTCDate(end.getUTCDate() + endIndex - 1);
    periods.push({ name: `Calendar ${start.toISOString().slice(0, 10)} - ${end.toISOString().slice(0, 10)}`, start, end, applyDiscounts: true,
      tiers: [{ minNights: minStay, maxNights: null, minGuests: null, maxGuests: null, price }] });
    runStart = null;
  };
  prices.forEach((raw, index) => {
    const price = Number(raw);
    const day = new Date(first); day.setUTCDate(day.getUTCDate() + index);
    if (runStart !== null && (price !== Number(prices[runStart]) || price <= 0 || day < today)) closeRun(index);
    if (price > 0 && day >= today && runStart === null) runStart = index;
  });
  closeRun(prices.length);
  return periods;
};

export const parseFlexiblePrices = (html) => {
  // Hauzi also renders a price table in each unit modal. Remove those whole
  // nested divs before selecting the property-level table, as the Colab
  // scraper does when it reads the page's first `div.table-prices`.
  const tablePeriods = flexiblePeriodsFromTable(removeUnitPriceModals(html));
  return tablePeriods.length ? tablePeriods : flexiblePeriodsFromCalendar(html);
};

/**
 * A unit's own Cenník (the table inside its modal), as flexiblePrices. A unit
 * has no calendar of its own on the page, so no table means no periods.
 */
export const parseUnitFlexiblePrices = (html, unitId) => flexiblePeriodsFromTable(unitModalHtml(html, unitId));

/** The nightly price of the period containing `today` (the cheapest of overlapping ones), else null. */
export const flexiblePriceToday = (periods, now = new Date()) => {
  const today = Date.UTC(now.getFullYear(), now.getMonth(), now.getDate());
  const prices = [];
  for (const p of periods || []) {
    const start = new Date(p.start); const end = new Date(p.end);
    // A period that wraps New Year ends next year, so early January is also inside last year's copy.
    const covers = (a, b) => a.getTime() <= today && today <= b.getTime();
    const back = (d) => new Date(Date.UTC(d.getUTCFullYear() - 1, d.getUTCMonth(), d.getUTCDate()));
    if (covers(start, end) || covers(back(start), back(end))) prices.push(...p.tiers.map((t) => t.price));
  }
  return prices.length ? Math.min(...prices) : null;
};

/** "Neakceptujeme: Hlučné oslavy a párty" → Not Allowed; accepted / suitable for parties → Allowed. */
export const mapParty = (rejected, accepted) => {
  // "Partie mladých ľudí" (groups of young people) is not a party.
  const party = /oslav|party|vecierk|teambuilding/;
  if (party.test(fold(rejected))) return "Not Allowed";
  if (party.test(fold(accepted))) return "Allowed";
  return null;
};

export const mapSmoking = (text) => {
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

export const mapMeals = (text) => {
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

export const mapParking = (text) => {
  const x = fold(text);
  if (!x) return null;
  if (/^nie|bez parkovania|nie je mozne/.test(x)) return [];
  const out = [];
  if (/bezplatn|zadarmo|zahrnut/.test(x)) out.push("Free Parking on-site");
  if (/(^|[^z])platen|za poplatok|€|eur/.test(x)) out.push("Paid Parking on-site");
  if (/verejn/.test(x)) out.push("Public Parking");
  return out.length ? out : ["Free Parking on-site"];
};

// ─── Area (m²) → Putko acreage ───────────────────────────────────────────────

// "24 m2", "24 m²", "24,5 m<sup>2</sup>", "24m 2" — the number before the unit.
export const AREA_RE = /(\d+(?:[.,]\d+)?)\s*m\s*(?:2|²|&sup2;|&#178;|<sup>\s*2\s*<\/sup>)(?![\d])/i;

export const parseAreaText = (text = "") => toNumber(String(text).match(AREA_RE)?.[1]);

/** A unit's area from its own data: an area/size field, else "24 m²" in its room text. */
export const unitArea = (u = {}) => {
  for (const key of ["area", "size", "floorArea", "floorSize", "surface"]) {
    const v = u[key];
    const n = typeof v === "object" && v !== null ? toNumber(v.value) : toNumber(v) ?? parseAreaText(v);
    if (n) return n;
  }
  return parseAreaText(decodeEntities(u.roomText || ""));
};

/**
 * The property's area: JSON-LD floorSize, a "Rozloha / Plocha / Výmera" table
 * row, or that word followed by "… m²" in the description. null when Hauzi
 * shows none.
 */
export const parsePropertyArea = ({ place = {}, tables = [], description = "" }) => {
  const floor = place.floorSize;
  const fromLd = toNumber(typeof floor === "object" && floor !== null ? floor.value : floor);
  if (fromLd) return fromLd;
  const row = tables.find((r) => /rozloh|plocha|vymer|velkost|area/.test(fold(r.label)));
  const fromRow = row ? parseAreaText(row.value) ?? toNumber(row.value.match(/\d+(?:[.,]\d+)?/)?.[0]) : null;
  if (fromRow) return fromRow;
  const m = fold(description).match(/(rozloh|ploch|vymer)\S*[^.\n\d]{0,30}(\d+(?:[.,]\d+)?)\s*m\s*(2|²)/);
  return m ? toNumber(m[2]) : null;
};

export const formatArea = (n) => (n === null || n === undefined ? "" : `${String(n).replace(".", ",")} m²`);

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
    // Summed only when every unit states its area; a partial sum would be wrong.
    const unitAreas = someUnits.map((u) => (unitArea(u) ?? NaN) * (u.count || 1));
    const area = has && unitAreas.every(Number.isFinite) ? unitAreas.reduce((s, n) => s + n, 0) : null;
    return {
      area,
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
  // A unit gets its own photos first — its unit card's, in that order
  // ("Apartmán na poschodí" starts with liwyejg1), then gallery photos titled
  // with its name ("Apartmán č. 3 - …") — followed by every shared property
  // photo (exterior, fireplace, gazebo, garden, …: gallery photos no unit owns
  // and whose title is not a unit's name). Photos of another unit are never
  // used, except to top a unit up to MIN_UNIT_IMAGES as a last resort.
  const gallery = extractGalleryPhotos(html);
  const galleryIds = gallery.map((p) => p.id);
  const unitPhotoIds = (u) => (u.photos || []).map((p) => p._id).filter(Boolean);
  const unitTitle = (u) => fold(squash(u.name || u.typeName || ""));
  const unitTitles = new Set(units.map(unitTitle).filter(Boolean));
  const titledIds = (u) => gallery.filter((p) => unitTitle(u) && fold(p.title) === unitTitle(u)).map((p) => p.id);
  const allUnitPhotoIds = new Set(units.flatMap((u) => [...unitPhotoIds(u), ...titledIds(u)]));
  const uniq = (ids) => [...new Set(ids.filter(Boolean))];

  const wholeIds = uniq([...galleryIds, rental?.photo?._id, ...units.flatMap(unitPhotoIds)]);
  const wholeImages = wholeIds.map(hauziImageUrl);
  const sharedIds = uniq([
    ...gallery.filter((p) => !allUnitPhotoIds.has(p.id) && !unitTitles.has(fold(p.title))).map((p) => p.id),
    allUnitPhotoIds.has(rental?.photo?._id) ? null : rental?.photo?._id,
  ]);
  const unitImages = (u) => {
    const ids = uniq([...unitPhotoIds(u), ...titledIds(u), ...sharedIds]);
    const topUp = wholeIds.filter((id) => !ids.includes(id)).slice(0, Math.max(0, MIN_UNIT_IMAGES - ids.length));
    return [...ids, ...topUp].map(hauziImageUrl);
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
  // Hauzi's listing level seasonal table/calendar describes the property.
  // With multiple separately bookable units, the property-wide price cannot
  // safely be assigned to any one unit listing.
  const flexiblePrices = parseFlexiblePrices(html);

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
      flexiblePrices: flexiblePrices.length
        ? ""
        : "No valid Cenník table rows or future calendar prices found in the fetched Hauzi HTML",
      petFeePerNight: pet === "Allowed with an additional fee"
        ? "Pets allowed for a fee, but Hauzi does not show the amount; Putko value kept"
        : "No pet fee applies; Putko value kept",
      partyOrganizing: "Hauzi does not say whether parties are allowed; Putko value kept",
      acreage: "Hauzi does not show the area of this property; Putko value kept",
    },
    virtualTourUrl: rental?.virtualTour || null,
    rentalId: rental?._id || null,
    latitude,
    longitude,
    address,
  };

  // ── The whole property (one Putko listing for the whole Hauzi page) ───────
  const wholeStats = statsFor(units);
  const propertyArea = parsePropertyArea({ place, tables, description });
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
    area: propertyArea ?? wholeStats.area,
    pricePerNight,
    pricePerPerson,
    flexiblePrices,
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
  const unitPricing = (u) => {
    const periods = parseUnitFlexiblePrices(html, u._id);
    const all = periods.flatMap((p) => p.tiers.map((t) => t.price));
    return {
      flexiblePrices: periods,
      pricePerNight: flexiblePriceToday(periods) ?? (all.length ? Math.min(...all) : null),
    };
  };
  const unitViews = units.map((u) => ({
    ...shared,
    // "2x Dvojlôžková izba" = two identical rooms. A unit's Putko listing is
    // ONE of them, so its guests, bedrooms, beds, bathrooms and area are those
    // of a single room (the whole property above still counts both).
    ...statsFor([{ ...u, count: 1 }]),
    unitCount: u.count || 1,
    // With one unit, the property's area is that unit's area.
    ...(!multiUnit && unitArea(u) === null ? { area: propertyArea ?? null } : {}),
    // A unit is only called "Apartmán" or "Chata" on Hauzi; the Putko listing
    // keeps its own, fuller name.
    name: null,
    unitId: u._id || null,
    unitName: u.name || u.typeName || "",
    unitTypeName: u.typeName || "",
    propertyType: propertyTypeFromUnit(u.typeName) || propertyType,
    rentalform: /izb/.test(fold(u.typeName)) ? "Private room" : "Entire place",
    // Hauzi publishes one "from" price for the whole property, not per unit.
    // A unit quotes its own Cenník in its modal; its price is the period that
    // covers today, else the lowest of its periods (so the offers apply at all).
    ...(multiUnit ? unitPricing(u) : {}),
    pricePerPerson: multiUnit ? null : pricePerPerson,
    ...(multiUnit ? {} : { pricePerNight, flexiblePrices }),
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
