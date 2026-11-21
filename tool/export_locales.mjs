// Re-export the website's translations and option lists for the app.
// Run from the repo root:  node mobile/tool/export_locales.mjs
// (Node 18+). Writes mobile/assets/l10n/{sk,en}.json and mobile/assets/data/*.json.
import fs from "fs";
import os from "os";
import path from "path";
import { pathToFileURL } from "url";

const root = process.cwd();
const app = path.join(root, "frontend", "src", "app");
const out = path.join(root, "mobile", "assets");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "putko-export-"));

// Copy as .mjs so plain Node can import the Next.js modules.
const copy = (from, to) => {
  fs.mkdirSync(path.dirname(path.join(tmp, to)), { recursive: true });
  let src = fs.readFileSync(path.join(app, from), "utf8");
  src = src.replace(/from "\.\.\/utlis\/cancellationPolicyOptions"/, 'from "./utlis/cancellationPolicyOptions.mjs"');
  src = src.replace(/from "\.\/searchNormalization\.js"/, 'from "./searchNormalization.mjs"');
  fs.writeFileSync(path.join(tmp, to), src);
};
copy("locales/en.js", "en.mjs");
copy("locales/sk.js", "sk.mjs");
copy("utils/searchNormalization.js", "searchNormalization.mjs");
copy("utils/tourismRegions.js", "tourismRegions.mjs");
copy("utlis/cancellationPolicyOptions.js", "utlis/cancellationPolicyOptions.mjs");
copy("host/accommodationOptions.js", "accommodationOptions.mjs");
copy("prirucka-hostitela/guideContent.js", "guide.mjs");
copy("utils/regionContent.js", "regionContent.mjs");

const load = async (f) => import(pathToFileURL(path.join(tmp, f)).href);
const strings = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => typeof v === "string"));

const en = (await load("en.mjs")).default;
const sk = (await load("sk.mjs")).default;
const tr = await load("tourismRegions.mjs");
const o = await load("accommodationOptions.mjs");
const guide = (await load("guide.mjs")).default;
const rc = await load("regionContent.mjs");

fs.writeFileSync(path.join(out, "l10n", "en.json"), JSON.stringify(strings(en)));
fs.writeFileSync(path.join(out, "l10n", "sk.json"), JSON.stringify(strings(sk)));
fs.writeFileSync(path.join(out, "data", "regions.json"), JSON.stringify(tr.TOURISM_REGIONS));
fs.writeFileSync(path.join(out, "data", "guide.json"), JSON.stringify(guide));
fs.writeFileSync(path.join(out, "data", "region_content.json"), JSON.stringify(rc.REGION_CONTENT));
fs.writeFileSync(
  path.join(out, "data", "options.json"),
  JSON.stringify({
    PROPERTY_TYPES: o.PROPERTY_TYPES,
    RENTAL_FORMS: o.RENTAL_FORMS,
    CANCELLATION_POLICIES: o.CANCELLATION_POLICIES,
    AMENITY_GROUPS: o.AMENITY_GROUPS,
    CHECK_IN_METHODS: o.CHECK_IN_METHODS,
    MEALS: o.MEALS,
    PET_OPTIONS: o.PET_OPTIONS,
    PARTY_OPTIONS: o.PARTY_OPTIONS,
    SMOKING_OPTIONS: o.SMOKING_OPTIONS,
    SPACE_FIELDS: o.SPACE_FIELDS,
    EXTRA_SPACE_FIELDS: o.EXTRA_SPACE_FIELDS,
  }),
);
console.log("Exported translations, regions, options and guide to", out);
