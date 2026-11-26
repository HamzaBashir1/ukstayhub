// utils/payLink.js
//
// The payment link emailed to a guest points at OUR domain, not straight at
// checkout.stripe.com:
//
//   <APP_LINK_BASE_URL>/pay/<reservationId>?reservationToken=<token>
//
// On a phone with the UK Stay Hub app installed, Android App Links / iOS
// Universal Links open that URL in the app, which shows the booking and runs
// the payment in-app. Without the app (desktop, or app not installed) the
// browser hits GET /pay/:id here, which redirects to the Stripe Checkout page.
//
// A Stripe URL can never open the app — only a domain we control and that
// publishes the /.well-known files below can.

/**
 * Origin the pay links are built on. It must be the domain that serves the
 * /.well-known files (this backend), over https in production.
 *
 * APP_LINK_BASE_URL wins; otherwise the origin the current request came in on
 * (`trust proxy` is set, so req.protocol honours X-Forwarded-Proto on Render).
 */
export function payLinkBase(req) {
  const env = (process.env.APP_LINK_BASE_URL || "").trim().replace(/\/+$/, "");
  if (env) return env;
  if (req) return `${req.protocol}://${req.get("host")}`;
  return `http://localhost:${process.env.PORT || 5001}`;
}

export function payLinkUrl(req, reservationId, accessToken) {
  const base = payLinkBase(req);
  const q = accessToken ? `?reservationToken=${encodeURIComponent(accessToken)}` : "";
  return `${base}/pay/${reservationId}${q}`;
}

const list = (v) =>
  String(v || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);

/**
 * GET /.well-known/assetlinks.json — lets Android open /pay/* links in the app.
 * ANDROID_SHA256_CERT_FINGERPRINTS: comma-separated "AA:BB:..." SHA-256 of
 * every signing key (debug, upload, and Play App Signing).
 */
export function assetLinks(req, res) {
  const pkg = process.env.ANDROID_APP_PACKAGE || "uk.co.ukstayhub.app";
  res.json([
    {
      relation: ["delegate_permission/common.handle_all_urls"],
      target: {
        namespace: "android_app",
        package_name: pkg,
        sha256_cert_fingerprints: list(process.env.ANDROID_SHA256_CERT_FINGERPRINTS),
      },
    },
  ]);
}

/**
 * GET /.well-known/apple-app-site-association — lets iOS open /pay/* links in
 * the app. IOS_APP_IDS: comma-separated "<TeamID>.<bundle id>".
 */
export function appleAppSiteAssociation(req, res) {
  const appIDs = list(process.env.IOS_APP_IDS || "29HHN6P2T6.uk.co.ukstayhub.app");
  res.type("application/json").send(
    JSON.stringify({
      applinks: {
        details: [{ appIDs, components: [{ "/": "/pay/*", comment: "Guest payment links" }] }],
      },
    })
  );
}
