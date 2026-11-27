import express from "express";
import { autocomplete } from "../utils/geoapify.js";

const router = express.Router();

// Public: the guest search bar uses it too. A per-IP limit keeps one client
// from draining the Geoapify quota (cached answers don't count against it).
const WINDOW_MS = 60 * 1000;
const MAX_PER_WINDOW = 90;
const hits = new Map();
setInterval(() => {
  const now = Date.now();
  for (const [ip, h] of hits) if (h.reset <= now) hits.delete(ip);
}, WINDOW_MS).unref();

function rateLimited(ip) {
  const now = Date.now();
  let h = hits.get(ip);
  if (!h || h.reset <= now) hits.set(ip, (h = { count: 0, reset: now + WINDOW_MS }));
  return ++h.count > MAX_PER_WINDOW;
}

// GET /api/geo/autocomplete?text=melrose avenue&country=gb
// `district=1` (search bar) adds a whole-district row for "E1", "NW2", …
router.get("/geo/autocomplete", async (req, res) => {
  const text = String(req.query.text || "").trim();
  if (text.length < 2) return res.json({ results: [] });
  if (rateLimited(req.ip)) return res.status(429).json({ error: "Too many requests" });
  const country = /^[a-z]{2}$/i.test(req.query.country || "") ? req.query.country.toLowerCase() : "gb";
  try {
    res.set("Cache-Control", "public, max-age=600");
    res.json({ results: await autocomplete(text.slice(0, 200), { country, district: req.query.district === "1" }) });
  } catch (err) {
    console.error("❌ Geo autocomplete:", err.message);
    res.status(502).json({ error: "Address suggestions are unavailable" });
  }
});

export default router;
