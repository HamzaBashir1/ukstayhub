// utils/resultPage.js — the backend's own result pages (pay links, Stripe
// onboarding return, password reset): round icon, title, message, card, buttons.
import { esc } from "./emailLayout.js";

const ICONS = {
  ok: { bg: "#319a81", svg: '<path d="M20 6 9 17l-5-5"/>' },
  fail: { bg: "#dc2626", svg: '<circle cx="12" cy="12" r="9"/><path d="M12 8v5M12 16h.01"/>' },
  warn: { bg: "#d97706", svg: '<path d="M12 8v5M12 16h.01"/><circle cx="12" cy="12" r="9"/>' },
  pay: { bg: "#319a81", svg: '<rect x="3" y="6" width="18" height="12" rx="2"/><path d="M3 10h18"/>' },
  lock: { bg: "#319a81", svg: '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>' },
};
const ICON_ALIASES = { "✅": "ok", "❌": "fail", "⚠️": "warn", "⏱️": "warn", "📅": "warn", "↩️": "warn", "💳": "pay" };

/**
 * Same look as the app's result screens. `body` and `html` are raw HTML;
 * everything else is escaped.
 */
export const payPage = ({ title, body, icon = "ok", rows, primary, secondary, autoOpen, html = "", script = "" }) => {
  const ic = ICONS[ICON_ALIASES[icon] || icon] || ICONS.ok;
  const card = rows?.length
    ? `<div class="card">${rows
        .map(([k, v]) => `<div class="row"><span>${esc(k)}</span><b>${esc(v)}</b></div>`)
        .join("")}</div>`
    : "";
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(title)} · UK Stay Hub</title>
<style>*{box-sizing:border-box}body{font-family:-apple-system,"Segoe UI",Roboto,Inter,sans-serif;background:#f8f5ef;color:#1e3e2b;margin:0;padding:48px 16px}
.w{max-width:560px;margin:0 auto;text-align:center}
.brand{font-weight:800;color:#319a81;font-size:18px;margin-bottom:32px}
.ic{width:80px;height:80px;border-radius:50%;margin:0 auto;display:flex;align-items:center;justify-content:center;background:${ic.bg}}
.ic svg{width:40px;height:40px;stroke:#fff;fill:none;stroke-width:2.5;stroke-linecap:round;stroke-linejoin:round}
h1{font-family:Georgia,"Times New Roman",serif;font-weight:600;font-size:28px;margin:24px 0 16px}
p{color:#64748b;font-size:15px;line-height:1.6;margin:0}
.card{background:#fff;border:1px solid #e5e7eb;border-radius:16px;padding:10px 16px;margin-top:20px;text-align:left}
.row{display:flex;justify-content:space-between;gap:12px;padding:6px 0;font-size:14px}.row span{color:#737373}.row b{text-align:right;word-break:break-all}
.b{display:block;width:100%;margin-top:12px;padding:15px;border-radius:12px;font-weight:700;font-size:15px;text-decoration:none;border:0;cursor:pointer;font-family:inherit}
.p{background:#319a81;color:#fff}.p:disabled{opacity:.6}.s{border:1px solid #e5e5e5;background:#fff;color:#1e3e2b}
label{display:block;font-size:14px;font-weight:500;margin:16px 0 8px}
input{width:100%;padding:13px 14px;border:1px solid #d1d5db;border-radius:12px;font-size:15px;font-family:inherit}
.err{color:#dc2626;font-size:14px;margin-top:12px;min-height:1em}
.acts{margin-top:32px}</style></head>
<body><div class="w"><div class="brand">UK Stay Hub</div>
<div class="ic"><svg viewBox="0 0 24 24">${ic.svg}</svg></div>
<h1>${esc(title)}</h1><p>${body}</p>${card}${html}
<div class="acts">${primary ? `<a class="b p" href="${esc(primary.href)}">${esc(primary.label)}</a>` : ""}
${secondary ? `<a class="b s" href="${esc(secondary.href)}">${esc(secondary.label)}</a>` : ""}</div>
</div>${autoOpen ? `<script>setTimeout(function(){location.href=${JSON.stringify(autoOpen)}},300)</script>` : ""}${script}</body></html>`;
};

/**
 * A page of the website (the Flutter web app, hash routing) from CLIENT_SITE_URL.
 * Accepts the env value with or without a trailing "/" or "/#".
 * siteUrl("/host/payouts") → http://localhost:8080/#/host/payouts
 */
export const siteUrl = (path = "/") => {
  const base = String(process.env.CLIENT_SITE_URL || "").trim().replace(/[/#]+$/, "");
  const safe = typeof path === "string" && path.startsWith("/") && !path.startsWith("//") ? path : "/";
  return `${base}/#${safe}`;
};
