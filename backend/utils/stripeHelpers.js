// utils/stripeHelpers.js
import Stripe from "stripe";
import { logExternalCall } from "./auditLog.js";

let cachedClient = null;

/** Shared Stripe client — avoids re-instantiating on every request. */
export function getStripe() {
  if (!cachedClient) {
    cachedClient = new Stripe(process.env.STRIPE_SECRET_KEY);
  }
  return cachedClient;
}

/**
 * Structured audit log for every Stripe call.
 * Thin wrapper over the shared logger in `utils/auditLog.js`, so Stripe and
 * SuperFaktúra calls land in one greppable stream and in the same shape.
 */
export function logStripeCall(operation, context = {}, outcome = "ok", error = null) {
  return logExternalCall("stripe", operation, context, outcome, error);
}

/**
 * Resolve the charge behind a PaymentIntent and its Stripe processing fee.
 *
 * Older code expanded `charges.data[0]`, which no longer exists on recent Stripe
 * API versions — the PaymentIntent exposes `latest_charge` instead. That silently
 * yielded a fee of 0 and therefore a wrong host payout. This handles both shapes.
 *
 * @returns {{ charge: object|null, stripeFeeCents: number }}
 */
export async function resolveChargeAndFee(stripe, paymentIntentOrId) {
  let paymentIntent = paymentIntentOrId;

  if (typeof paymentIntentOrId === "string") {
    paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentOrId, {
      expand: ["latest_charge.balance_transaction"],
    });
  }

  let charge = null;

  // Current API shape.
  if (paymentIntent?.latest_charge) {
    charge =
      typeof paymentIntent.latest_charge === "string"
        ? await stripe.charges.retrieve(paymentIntent.latest_charge, {
            expand: ["balance_transaction"],
          })
        : paymentIntent.latest_charge;
  }

  // Legacy API shape, kept so older expanded objects still work.
  if (!charge && paymentIntent?.charges?.data?.length) {
    charge = paymentIntent.charges.data[0];
  }

  if (!charge) return { charge: null, stripeFeeCents: 0 };

  let stripeFeeCents = 0;
  const bt = charge.balance_transaction;

  if (bt && typeof bt === "object" && bt.fee != null) {
    stripeFeeCents = Math.round(bt.fee);
  } else if (typeof bt === "string") {
    const fetched = await stripe.balanceTransactions.retrieve(bt);
    stripeFeeCents = Math.round(fetched?.fee || 0);
  }

  return { charge, stripeFeeCents };
}

/** Gross amount actually captured for a PaymentIntent, in cents. */
export function capturedAmountCents(paymentIntent) {
  return Math.round(
    paymentIntent?.amount_received || paymentIntent?.amount || 0
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Connected account shape
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Merchant category for short-term accommodation. Sent at account creation so
 * Stripe does not put `business_profile.mcc` on the host's to-do list.
 */
export const CONNECT_MCC = process.env.STRIPE_CONNECT_MCC || "7011";

/**
 * `CLIENT_SITE_URL`, but only when Stripe would actually accept it.
 *
 * `business_profile.url` must be a reachable public https URL. In development
 * CLIENT_SITE_URL is http://localhost:3000, which Stripe rejects outright — and
 * a rejected create call is a host who cannot onboard at all. Omitting the field
 * is harmless: Stripe then asks for it during onboarding, exactly as it did
 * before this was set at all.
 */
function publicSiteUrl() {
  const raw = (process.env.CLIENT_SITE_URL || "").trim();
  if (!/^https:\/\//i.test(raw)) return null;

  try {
    const { hostname } = new URL(raw);
    if (
      hostname === "localhost" ||
      hostname.endsWith(".local") ||
      /^\d{1,3}(\.\d{1,3}){3}$/.test(hostname)
    ) {
      return null;
    }
    return raw;
  } catch {
    return null;
  }
}

/**
 * The payload for `accounts.create`, shared by every path that connects a host.
 *
 * Two decisions here are the whole reason accounts kept coming back RESTRICTED,
 * and both are about asking Stripe for less than we used to.
 *
 * 1. ONLY the `transfers` capability is requested.
 *
 *    Putko takes the guest's money on the PLATFORM account — the Checkout
 *    Session in `createCheckoutSession` carries no `transfer_data`, no
 *    `on_behalf_of` and no connected-account header — and moves the host's share
 *    afterwards with `transfers.create({ destination })`. That is "separate
 *    charges and transfers", and in it the connected account never processes a
 *    card payment.
 *
 *    Requesting `card_payments` anyway told Stripe to treat every host as a
 *    card-accepting merchant, which pulls in the full merchant verification set
 *    — company registration, ownership declaration, directors, card-acceptance
 *    terms. Those land in `requirements.currently_due`, and an account with
 *    outstanding requirements is exactly what the Stripe dashboard labels
 *    "Restricted". Hosts were being asked to prove things about a payment method
 *    they were never going to accept, and the ones who could not simply stopped.
 *
 *    Dropping it leaves identity and bank details, which is all a transfer
 *    destination actually needs.
 *
 * 2. `business_type` is NOT guessed.
 *
 *    It used to be guessed as `host.companyName ? "company" : "individual"`.
 *    `companyName` is free-text profile data that plenty of sole traders fill
 *    in, and guessing "company" makes Stripe demand company registration
 *    documents and a directors list that an individual cannot produce — a dead
 *    end with no way back, because the type cannot be changed from inside the
 *    Express form. Leaving it unset makes the first question of onboarding "are
 *    you an individual or a business?", answered by the one party who knows.
 *
 *    The one exception is a host who explicitly declared themselves a private
 *    individual (`billingSubjectType: "individual"`) — see onboardingPrefill.
 *
 * `business_profile` is prefilled for the opposite reason: those fields are
 * required, we already know them, and anything supplied here is one less item on
 * the host's list. With `prefillIdentity`, the host's billing identity (name,
 * address, phone, IČO…) is prefilled too, so the Stripe form opens already
 * filled in with what they gave Putko. `personalIdentity: false` limits that to
 * the company details (see onboardingPrefill).
 *
 * @param {object} host the Host document being connected
 * @param {{country?: string, email?: string, prefillIdentity?: boolean, personalIdentity?: boolean}} options
 */
export function connectedAccountCreateParams(
  host,
  { country, email, prefillIdentity = false, personalIdentity = true } = {}
) {
  // Stripe rules on the country, not us: `host.countryCode` is free-text profile
  // data ("PAKISTAN", "PA") and driving creation from it produced errors the
  // host had no way to get past. An explicit request wins; otherwise Putko's own
  // jurisdiction.
  const requested = (country || "").trim().toUpperCase() || "GB";

  const businessProfile = {
    mcc: CONNECT_MCC,
    product_description:
      "Short-term accommodation rental booked through the Putko marketplace.",
  };

  const url = publicSiteUrl();
  if (url) businessProfile.url = url;

  const params = {
    type: "express",
    country: requested,
    email: email || host?.email,
    capabilities: { transfers: { requested: true } },
    business_profile: businessProfile,
    // Lets account.updated find the host without a DB lookup by account id.
    metadata: { host_id: String(host?._id || "") },
  };

  if (prefillIdentity) {
    const { business_profile: extraProfile, ...identity } = onboardingPrefill(host, requested, params.email, {
      personalIdentity,
    });
    Object.assign(params.business_profile, extraProfile);
    Object.assign(params, identity);
  }

  return params;
}

/**
 * The host's billing identity, reshaped into the fields Stripe's onboarding
 * form asks for, so the host confirms their details rather than retyping them.
 *
 * Every value is optional and is only sent when it is well-formed: a malformed
 * phone or IČO makes Stripe reject `accounts.create` outright, and a host who
 * cannot open onboarding is far worse off than one with an empty field. Anything
 * left out here is simply asked for by Stripe, as before.
 *
 * - `billingSubjectType: "individual"` is the host's own explicit declaration
 *   (the schema default is "business"), so it is the one case where
 *   `business_type` is set: to "individual", with their personal details.
 * - "business" covers both a sole trader (živnostník) and an s.r.o., which
 *   Stripe treats as different business types, and Stripe refuses `company`
 *   unless `business_type` is sent with it. So company details — and
 *   `business_type: "company"` — are only sent when the company name carries a
 *   legal form (see hasCompanyLegalForm). Otherwise the type stays unset for
 *   the host to choose, and no company data is sent.
 * - The address is only sent when the host's country matches the account's:
 *   it is prefilled as the account's own address, and a foreign one there would
 *   be wrong rather than helpful.
 *
 * - `personalIdentity: false` drops the individual branch (and with it any
 *   `business_type`). Used for a host's additional accounts, which may be
 *   someone else's — a spouse's, a co-owner's. Company details stay: they
 *   lock nothing, only apply if the host picks "Company", and remain editable.
 *
 * For SK, Stripe maps `company.tax_id` to the IČO (`sk_ico` in API v2).
 *
 * @param {object} host
 * @param {string} accountCountry ISO code the account is being created in
 * @param {string} [email] the email the account is created with
 * @param {{personalIdentity?: boolean}} [options]
 */
export function onboardingPrefill(host, accountCountry, email, { personalIdentity = true } = {}) {
  if (!host) return {};

  const hostCountry = (host.countryCode || "GB").trim().toUpperCase();
  const phone = toE164(host.phoneNumber || host.phone, hostCountry);
  const address = hostCountry === accountCountry ? stripeAddress(host, accountCountry) : null;

  const out = { business_profile: {} };
  if (phone) out.business_profile.support_phone = phone;

  if (host.billingSubjectType === "individual") {
    if (!personalIdentity) return out;
    const individual = compact({
      first_name: trimmed(host.name),
      last_name: trimmed(host.lastName),
      email: trimmed(email),
      phone,
      dob: stripeDob(host.dateOfBirth),
      address,
    });
    // Without a first name there is no person to prefill; leave the type
    // undecided rather than lock it in with nothing to show for it.
    if (individual.first_name) {
      out.business_type = "individual";
      out.individual = individual;
    }
    return out;
  }

  const companyName = trimmed(host.companyName);
  if (companyName) out.business_profile.name = companyName;

  // Without a legal form in the name this may be a živnostník, and guessing
  // "company" for them is the unrecoverable dead end described above.
  if (!hasCompanyLegalForm(companyName)) return out;

  const company = compact({
    name: companyName,
    phone,
    address,
    tax_id: accountCountry === "SK" ? slovakIco(host.ico || host.idNumber) : undefined,
    vat_id: host.isVatPayer ? euVatId(host.icDph) : undefined,
  });
  if (Object.keys(company).length) {
    out.business_type = "company";
    out.company = company;
  }

  return out;
}

/**
 * True when a Slovak/Czech company name carries a company legal form.
 *
 * The Commercial Code requires a company's business name to include its legal
 * form (s. r. o., a. s., v. o. s., k. s., j. s. a., družstvo), while a
 * živnostník trades under their own name. So the suffix — unlike the mere
 * presence of a `companyName`, which sole traders fill in too — reliably says
 * "company". Short forms must keep their dots so names like "Tomas" or
 * "Vos" never match.
 */
export function hasCompanyLegalForm(name) {
  const n = String(name ?? "").toLowerCase();
  return [
    /(^|[\s,])(spol\.\s*s\s*r\.\s*o\.?|s\.\s*r\.\s*o\.?|sro)(?=[\s,]|$)/,
    /(^|[\s,])a\.\s*s\.?(?=[\s,]|$)/,
    /(^|[\s,])v\.\s*o\.\s*s\.?(?=[\s,]|$)/,
    /(^|[\s,])k\.\s*s\.?(?=[\s,]|$)/,
    /(^|[\s,])j\.\s*s\.\s*a\.?(?=[\s,]|$)/,
    /(^|[\s,])dru(ž|z)stvo(?=[\s,]|$)/,
  ].some((re) => re.test(n));
}

/**
 * Create a connected account with the host's details prefilled, falling back to
 * creating it without them if Stripe rejects one of the prefilled values.
 *
 * The fallback exists because Stripe's per-country validation (phone ranges,
 * postal codes, tax ID formats) is stricter than anything checked locally, and
 * prefill is a convenience: it must never be the reason a host cannot connect.
 *
 * @param {import("stripe").Stripe} stripe
 * @param {object} host
 * @param {{country?: string, email?: string, prefillIdentity?: boolean, personalIdentity?: boolean}} options
 */
export async function createConnectedAccount(stripe, host, options = {}) {
  const params = connectedAccountCreateParams(host, options);
  if (!options.prefillIdentity) return stripe.accounts.create(params);

  const account = await sendDroppingRejectedFields(
    (p) => stripe.accounts.create(p),
    params,
    // Only a prefilled field may be dropped; anything else (an unsupported
    // country, say) is a real error that retrying without it would hide.
    (path) =>
      ["business_type", "individual", "company"].includes(path[0]) ||
      (path[0] === "business_profile" && ["name", "support_phone"].includes(path[1])),
    (param, err) =>
      logStripeCall(
        "accounts.create.prefill_rejected",
        { hostId: String(host?._id || ""), param },
        "error",
        err
      )
  );

  // What Stripe actually kept, read back from the created account. Flags
  // only, never the values: this line is for confirming the prefill landed.
  const company = account?.company || {};
  const person = account?.individual || {};
  const address = company.address?.line1 ? company.address : person.address || {};
  logStripeCall("accounts.create.prefilled", {
    hostId: String(host?._id || ""),
    accountId: account?.id,
    businessType: account?.business_type || null,
    name: Boolean(company.name || person.first_name),
    taxId: Boolean(company.tax_id_provided),
    street: Boolean(address.line1),
    city: Boolean(address.city),
    postalCode: Boolean(address.postal_code),
    phone: Boolean(company.phone || person.phone),
  });

  return account;
}

/**
 * Send `params`, and when Stripe rejects one field, drop exactly that field and
 * try again with the rest.
 *
 * Stripe validates harder than we can locally (it knows which phone ranges and
 * postcodes actually exist), and it rejects the WHOLE request over one bad
 * field. Before this, a single invalid phone number meant nothing was
 * prefilled at all: not the company name or the IČO, which were fine.
 *
 * @param {(params: object) => Promise<any>} send
 * @param {object} params
 * @param {(path: string[]) => boolean} droppable which fields may be dropped
 * @param {(param: string, err: Error) => void} onDrop
 */
async function sendDroppingRejectedFields(send, params, droppable, onDrop) {
  let current = params;
  // One retry per distinct bad field is plenty; the cap only guards a loop.
  for (let attempt = 0; ; attempt++) {
    try {
      return await send(current);
    } catch (err) {
      const param = String(err?.param || "");
      const path = param.split(/[[\].]+/).filter(Boolean);
      const next =
        err?.type === "StripeInvalidRequestError" && path.length && droppable(path) && attempt < 8
          ? withoutPath(current, path)
          : null;
      if (!next) throw err;
      onDrop(param, err);
      current = next;
    }
  }
}

/**
 * A deep copy of `obj` without the field at `path`, pruning objects left empty.
 * Returns null when there is nothing at `path` to remove, so a rejection we
 * cannot act on is surfaced instead of retried forever.
 */
function withoutPath(obj, path) {
  const copy = structuredClone(obj);
  const parents = [];
  let node = copy;
  for (const key of path.slice(0, -1)) {
    if (!node || typeof node[key] !== "object") break;
    parents.push([node, key]);
    node = node[key];
  }
  // Stripe sometimes names a leaf inside a value we sent whole (e.g. a part of
  // `dob`); dropping the deepest thing we did send is the useful equivalent.
  const leaf = path[parents.length];
  if (!node || !(leaf in node)) return null;
  delete node[leaf];
  for (let i = parents.length - 1; i >= 0; i--) {
    const [parent, key] = parents[i];
    if (Object.keys(parent[key]).length) break;
    delete parent[key];
  }
  return copy;
}

/**
 * The part of the host's prefill an EXISTING account is still missing.
 *
 * Only empty fields are filled: the host may have typed their details into
 * Stripe already, and those win over profile data. `business_type` is never
 * set here — on an account that already exists the host may have chosen it in
 * Stripe, or the account may belong to a different entity than the billing
 * profile describes, and a wrong type cannot be undone in the Express form. So
 * personal details are only added once the account already says "individual",
 * and company details only while it says "company" or nothing yet.
 *
 * @param {object} account a Stripe Account object
 * @param {object} host
 * @param {{personalIdentity?: boolean}} [options] see onboardingPrefill
 * @returns {object} params for `accounts.update`, empty when nothing is missing
 */
export function missingPrefillFor(account, host, { personalIdentity = true } = {}) {
  const full = onboardingPrefill(host, account.country, account.email, { personalIdentity });
  const update = {};

  const currentProfile = account.business_profile || {};
  const profile = compact({
    name:
      currentProfile.name || !sameName(account.company?.name, full.business_profile?.name)
        ? undefined
        : full.business_profile?.name,
    support_phone: currentProfile.support_phone ? undefined : full.business_profile?.support_phone,
  });
  if (Object.keys(profile).length) update.business_profile = profile;

  const type = account.business_type || null;

  if (full.individual && type === "individual" && sameName(account.individual?.first_name, full.individual.first_name)) {
    const cur = account.individual || {};
    const individual = compact({
      first_name: cur.first_name ? undefined : full.individual.first_name,
      last_name: cur.last_name ? undefined : full.individual.last_name,
      email: cur.email ? undefined : full.individual.email,
      phone: cur.phone ? undefined : full.individual.phone,
      dob: cur.dob?.year ? undefined : full.individual.dob,
      address: cur.address?.line1 ? undefined : full.individual.address,
    });
    if (Object.keys(individual).length) update.individual = individual;
  }

  if (full.company && (type === null || type === "company") && sameName(account.company?.name, full.company.name)) {
    const cur = account.company || {};
    const company = compact({
      name: cur.name ? undefined : full.company.name,
      phone: cur.phone ? undefined : full.company.phone,
      address: cur.address?.line1 ? undefined : full.company.address,
      tax_id: cur.tax_id_provided ? undefined : full.company.tax_id,
      vat_id: cur.vat_id_provided ? undefined : full.company.vat_id,
    });
    if (Object.keys(company).length) {
      update.company = company;
      // Stripe refuses `company` on an account with no business type. Setting
      // it here is the same call as at creation: full.company only exists when
      // the name carries a company legal form.
      if (type === null) update.business_type = "company";
    }
  }

  return update;
}

/**
 * True when the account either has no name yet or already names the same
 * person/company the billing profile does. A different name means the account
 * belongs to someone else, and topping up its other fields with this host's
 * phone or address would stitch two identities together.
 */
function sameName(onAccount, fromProfile) {
  const norm = (v) => String(v ?? "").trim().toLowerCase();
  return !norm(onAccount) || norm(onAccount) === norm(fromProfile);
}

/**
 * Fill in what an unfinished Express account is missing from the host's
 * billing profile, before the host is sent back into onboarding.
 *
 * Best effort by design: any failure is logged and swallowed, because the host
 * getting to the form matters more than the form being prefilled.
 *
 * @param {import("stripe").Stripe} stripe
 * @param {object} host
 * @param {object|string} accountOrId a Stripe Account object, or its id
 * @param {{personalIdentity?: boolean}} [options] see onboardingPrefill
 */
export async function prefillExistingAccount(stripe, host, accountOrId, options = {}) {
  const accountId = typeof accountOrId === "string" ? accountOrId : accountOrId?.id;
  try {
    const account =
      typeof accountOrId === "string" ? await stripe.accounts.retrieve(accountOrId) : accountOrId;
    // Standard accounts cannot be updated by the platform, and a submitted
    // account's details are the host's own — only unfinished Express ones.
    const skipped = (reason) =>
      logStripeCall("accounts.update.prefill_skipped", {
        hostId: String(host?._id || ""),
        accountId,
        reason,
        accountType: account?.type,
        businessType: account?.business_type,
        detailsSubmitted: account?.details_submitted,
        billingSubjectType: host?.billingSubjectType,
      });
    if (!account) return skipped("no_account");
    if (account.type !== "express") return skipped("not_express");
    if (account.details_submitted) return skipped("details_submitted");

    const update = missingPrefillFor(account, host, options);
    if (!Object.keys(update).length) return skipped("nothing_missing");

    // Everything in `update` is prefill, so any field Stripe rejects can go.
    await sendDroppingRejectedFields(
      (p) => stripe.accounts.update(account.id, p),
      update,
      () => true,
      (param, err) =>
        logStripeCall(
          "accounts.update.prefill_rejected",
          { hostId: String(host?._id || ""), accountId: account.id, param },
          "error",
          err
        )
    );
    logStripeCall("accounts.update.prefill", {
      hostId: String(host?._id || ""),
      accountId: account.id,
      fields: Object.keys(update),
    });
  } catch (err) {
    logStripeCall(
      "accounts.update.prefill",
      { hostId: String(host?._id || ""), accountId, param: err?.param },
      "error",
      err
    );
  }
}

function trimmed(value) {
  const s = String(value ?? "").trim();
  return s || undefined;
}

/** Drops undefined/empty entries, so Stripe never receives a blank field. */
function compact(obj) {
  return Object.fromEntries(
    Object.entries(obj).filter(([, v]) => v !== undefined && v !== null && v !== "")
  );
}

const DIAL_CODES = { GB: "44", SK: "421", CZ: "420", AT: "43", HU: "36", PL: "48", DE: "49" };

/**
 * A phone number in the E.164 form Stripe requires, or undefined.
 * Accepts "+421 901 234 567", "00421901234567" and, when the host's country
 * dialing code is known, a national "0901 234 567".
 */
export function toE164(raw, country) {
  let s = String(raw ?? "").replace(/[\s\-().\/]/g, "");
  if (!s) return undefined;
  if (s.startsWith("00")) s = `+${s.slice(2)}`;
  if (!s.startsWith("+") && s.startsWith("0") && DIAL_CODES[country]) {
    s = `+${DIAL_CODES[country]}${s.slice(1)}`;
  }
  if (!/^\+[1-9]\d{7,14}$/.test(s)) return undefined;
  // "+421 000 000 000" is the phone field's placeholder, typed in as a value.
  // No real number is all zeros after the country code.
  if (/^\+\d{1,3}0{6,}$/.test(s)) return undefined;
  return s;
}

function stripeAddress(host, country) {
  const address = compact({
    line1: trimmed(host.streetNumber),
    city: trimmed(host.city),
    postal_code: trimmed(host.zipcode),
  });
  // A lone city or postcode is not an address anyone can confirm.
  if (!address.line1 || !address.city) return null;
  return { ...address, country };
}

/** Date of birth as Stripe's {day, month, year}, only for a plausible adult. */
function stripeDob(value) {
  if (!value) return undefined;
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return undefined;
  // Stored from a date-only input, i.e. UTC midnight — read it back in UTC so
  // the day does not shift by the server's timezone.
  const year = d.getUTCFullYear();
  const age = new Date().getUTCFullYear() - year;
  if (age < 18 || age > 120) return undefined;
  return { day: d.getUTCDate(), month: d.getUTCMonth() + 1, year };
}

/** Slovak IČO: exactly 8 digits (older 6-digit ones are zero-padded). */
function slovakIco(raw) {
  const digits = String(raw ?? "").replace(/\s/g, "");
  if (!/^\d{6,8}$/.test(digits)) return undefined;
  return digits.padStart(8, "0");
}

/** EU VAT ID such as SK2020123456 — same shape HostAccountController accepts. */
function euVatId(raw) {
  const s = String(raw ?? "").replace(/\s/g, "").toUpperCase();
  return /^[A-Z]{2}\d{8,12}$/.test(s) ? s : undefined;
}

/**
 * Stripe's `requirements.disabled_reason` values that mean "we are looking at
 * it", as opposed to "the host must do something".
 *
 * The distinction matters because the two need opposite messages: one says sit
 * tight, the other says go back into onboarding. Showing "action needed" to a
 * host who is merely waiting on Stripe's review sends them round the form again
 * to change nothing.
 */
const REVIEW_DISABLED_REASONS = new Set([
  "requirements.pending_verification",
  "under_review",
]);

/**
 * The full state of a connected account, as Putko needs to store and show it.
 *
 * Everything here comes off one `Account` object. Previously only
 * `charges_enabled`, `payouts_enabled` and `currently_due` were read, which is
 * why a restricted account showed up in the UI as an ordinary "Verifying" with
 * an empty list of requirements — the fields that say WHY (`disabled_reason`,
 * `past_due`, `errors`) were never looked at, so the host was told nothing and
 * had nothing to act on.
 *
 * @param {object} account a Stripe Account object
 */
export function describeAccountState(account) {
  const requirements = account?.requirements || {};
  const future = account?.future_requirements || {};

  const transfersActive = account?.capabilities?.transfers === "active";
  const payoutsEnabled = Boolean(account?.payouts_enabled);
  const chargesEnabled = Boolean(account?.charges_enabled);

  const currentlyDue = requirements.currently_due || [];
  const pastDue = requirements.past_due || [];
  const pendingVerification = requirements.pending_verification || [];
  const eventuallyDue = requirements.eventually_due || [];
  const disabledReason = requirements.disabled_reason || null;

  // Stripe names the offending field AND why it was rejected ("the document is
  // expired", "the name does not match"). Without this the host re-uploads the
  // same unusable document and waits again.
  const errors = (requirements.errors || []).map((e) => ({
    requirement: e.requirement,
    code: e.code,
    reason: e.reason,
  }));

  const underReview = REVIEW_DISABLED_REASONS.has(disabledReason);

  let state;
  if (payoutsEnabled && transfersActive) {
    state = "active";
  } else if ((disabledReason && !underReview) || pastDue.length) {
    state = "restricted";
  } else if (currentlyDue.length) {
    state = "pending";
  } else if (pendingVerification.length || underReview) {
    state = "verifying";
  } else {
    state = "pending";
  }

  return {
    state,
    transfersActive,
    payoutsEnabled,
    chargesEnabled,
    currentlyDue,
    pastDue,
    pendingVerification,
    eventuallyDue,
    disabledReason,
    errors,
    currentDeadline: requirements.current_deadline
      ? new Date(requirements.current_deadline * 1000)
      : null,
    // Requirements that only bite after a future date. Surfaced so a host can
    // clear them before the deadline turns them into a restriction, which is the
    // single most common way an already-working account goes bad.
    futureDue: future.currently_due || [],
    futureDeadline: future.current_deadline
      ? new Date(future.current_deadline * 1000)
      : null,
    // Whether returning to the Stripe form would actually achieve anything.
    actionRequired: Boolean(currentlyDue.length || pastDue.length || errors.length),
  };
}
