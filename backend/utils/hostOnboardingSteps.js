// utils/hostOnboardingSteps.js
//
// What a host still has to do before Putko can pay them — as a list a person
// can act on, rather than the machine-readable blocker codes the gates return.
//
// This exists because of one thing the request-to-book flow does: it emails a
// host a REAL booking for a REAL amount while they are still un-onboarded. That
// email is the strongest nudge the product has, and it was spending it on a
// single sentence ("you need to connect a payout account"). A host who reads
// that still has to work out what "connect" means, what Stripe will ask for,
// and why their listing is not taking payments.
//
// So the steps are spelled out, and they are spelled out for EVERY listing
// status, not only for a listing with no account attached:
//
//   DRAFT      no account yet — the whole sequence is ahead of them
//   PENDING    account created, Stripe still verifying — name the documents it
//              is waiting for, because that is what stalls at this stage
//   PUBLISHED  Stripe is finished, yet the host can STILL be unable to take a
//              booking: billing details are the third gate, and paying out to a
//              host who cannot be invoiced is the failure the monthly run
//              records as `missing_host_billing_details`
//
// The third case is the one worth being careful about. "PUBLISHED" reads like
// "done", so a naive email would tell such a host nothing at all — they would
// see a request they cannot accept and no explanation anywhere.
//
// Nothing here talks to Stripe. It reads the capabilities the `account.updated`
// webhook already cached, so it is safe to call while rendering an email.

import { LISTING_STATUS, listingStatusFor, pendingRequirementsOf } from "./listingStatus.js";
import { hostBookingBlockers } from "./listingGating.js";
import { missingBillingFieldsOf } from "./hostBilling.js";
import { resolvePayoutAccount } from "./payoutAccounts.js";

/** Host-facing names for the invoicing fields the gate can report. */
const BILLING_FIELD_LABELS = {
  billing_name: "Billing name",
  ico: "Company registration number (IČO)",
  dic: "Tax ID (DIČ)",
  billing_address_street: "Street and number",
  billing_address_city: "City",
  billing_address_zip: "Postcode",
  billing_address_country: "Country",
};

/**
 * Names for the Stripe requirement codes seen most often on an Express
 * account. Anything unrecognised falls back to the raw code with its dots and
 * underscores opened up — the same treatment the Payments screen gives it — so
 * a code Stripe adds later still renders as words rather than vanishing.
 */
const STRIPE_REQUIREMENT_LABELS = {
  "individual.verification.document": "Photo ID (passport or national ID card)",
  "individual.verification.additional_document": "Proof of address",
  "individual.id_number": "Personal ID number",
  "individual.address.line1": "Home address",
  "individual.dob.day": "Date of birth",
  "individual.dob.month": "Date of birth",
  "individual.dob.year": "Date of birth",
  "individual.first_name": "First name",
  "individual.last_name": "Last name",
  "individual.email": "Email",
  "individual.phone": "Phone number",
  "company.verification.document": "Company registration document",
  "company.tax_id": "VAT / tax number",
  "company.address.line1": "Registered company address",
  external_account: "Bank account for payouts",
  "business_profile.url": "Website or business description",
  "business_profile.mcc": "Business category",
  "tos_acceptance.date": "Acceptance of Stripe's terms",
  "tos_acceptance.ip": "Acceptance of Stripe's terms",
};

export const billingFieldLabel = (key) => BILLING_FIELD_LABELS[key] || String(key);

export const stripeRequirementLabel = (code) =>
  STRIPE_REQUIREMENT_LABELS[code] || String(code).replace(/[._]/g, " ");

/** Unique, order preserving — Stripe repeats dob.day/month/year, which share one label. */
const uniq = (values) => [...new Set(values)];

/**
 * Everything a host-facing message needs to explain the situation, in one object.
 *
 * `accommodation` is optional and only matters once a host holds several payout
 * accounts: the steps must describe the account THIS listing pays out to, not
 * the host's aggregate state, or a host with one finished account and one new
 * one is told the wrong thing.
 *
 * @param {object|null} host
 * @param {object|null} accommodation
 * @returns {{
 *   status: 'DRAFT'|'PENDING'|'PUBLISHED',
 *   needsOnboarding: boolean,
 *   blockers: string[],
 *   steps: Array<{ key: string, title: string, detail: string, done: boolean }>,
 *   requirements: string[],
 *   missingBilling: string[],
 *   headline: string,
 *   ctaLabel: string
 * }}
 */
export function hostOnboardingGuidance(host, accommodation = null) {
  const status = listingStatusFor(accommodation, host);
  const account = resolvePayoutAccount(accommodation, host);
  const blockers = hostBookingBlockers(host);
  const needsOnboarding = blockers.length > 0;

  const hasAccount = Boolean(account?.accountId || host?.stripeAccountId);
  const stripeVerified =
    hasAccount &&
    !blockers.includes("stripe_charges_disabled") &&
    !blockers.includes("stripe_payouts_disabled");
  const billingDone = !blockers.includes("billing_details_incomplete");
  const missingBilling = missingBillingFieldsOf(host).filter((f) => f !== "host_not_found");

  // Requirements only mean anything while Stripe is still verifying. On a
  // finished account the cached list is empty anyway, but gating on
  // `stripeVerified` keeps a stale value from being read back to a host who is
  // already done.
  const requirements = stripeVerified ? [] : uniq(pendingRequirementsOf(host, accommodation));

  const steps = [
    {
      key: "connect",
      title: "Connect a payout account",
      detail: hasAccount
        ? "Your account is connected."
        : "In your profile, go to <strong>Payments</strong> and click <strong>Connect account</strong>. " +
          "We'll take you to Stripe, our payment partner — signing up is free and " +
          "takes about 5 minutes.",
      done: hasAccount,
    },
    {
      key: "verify",
      title: "Finish verification with Stripe",
      detail: stripeVerified
        ? "Verification is complete — Stripe has enabled payments and payouts."
        : requirements.length
          ? "Stripe still needs: " +
            uniq(requirements.map(stripeRequirementLabel))
              .map((label) => `<strong>${label}</strong>`)
              .join(", ") +
            ". You can add this directly with Stripe using the button below."
          : "Stripe will ask for photo ID, your date of birth, your address and the bank " +
            "account your payouts should go to. Verification usually takes a few " +
            "minutes, occasionally up to one working day.",
      done: stripeVerified,
    },
    {
      key: "billing",
      title: "Complete your billing details",
      detail: billingDone
        ? "Your billing details are complete."
        : "We need them to invoice you for the UK Stay Hub service fee. " +
          (missingBilling.length
            ? "Missing: " +
              missingBilling.map((f) => `<strong>${billingFieldLabel(f)}</strong>`).join(", ") +
              "."
            : "Add them in your profile under <strong>Payments</strong>."),
      done: billingDone,
    },
  ];

  return {
    status,
    needsOnboarding,
    blockers,
    steps,
    requirements,
    missingBilling,
    headline: headlineFor(status, { hasAccount, stripeVerified, billingDone }),
    ctaLabel: hasAccount ? "Finish payout setup" : "Connect a payout account",
  };
}

/**
 * One sentence naming where the host actually stands, per listing status.
 *
 * Written so the PUBLISHED-but-blocked case does not read as a contradiction:
 * the listing IS live, and what is missing is invoicing data, which has nothing
 * to do with Stripe.
 */
function headlineFor(status, { hasAccount, stripeVerified, billingDone }) {
  if (stripeVerified && billingDone) {
    return "Your payouts are set up — you can accept the request right away.";
  }

  if (stripeVerified && !billingDone) {
    return (
      "Your payments are set up — only your billing details are missing. Without them " +
      "we can't invoice the service fee, so you can't accept the request yet."
    );
  }

  if (status === LISTING_STATUS.PENDING || hasAccount) {
    return (
      "Your payout account is connected, but Stripe hasn't finished verifying it. " +
      "Until it does, we have nowhere to send the money for this booking."
    );
  }

  return (
    "Your listing doesn't have a payout account connected yet, so this booking " +
    "can't be paid. Setting it up takes about 5 minutes."
  );
}

/**
 * The steps as email HTML — a numbered list with the finished ones ticked off,
 * so a host part-way through sees what they have already done rather than the
 * whole sequence again.
 *
 * Table-based on purpose: Outlook drops the margins on `<ol>` and the list
 * collapses into the paragraph above it.
 */
export function onboardingStepsHtml(
  steps,
  { ink = "#2A2A2A", muted = "#6B7280", teal = "#238869", hairline = "#E4E9E5" } = {}
) {
  const rows = (steps || [])
    .map((step, index) => {
      const marker = step.done ? "&#10003;" : String(index + 1);
      const markerBg = step.done ? teal : hairline;
      const markerColor = step.done ? "#ffffff" : ink;
      const titleColor = step.done ? muted : ink;

      return `
        <tr>
          <td valign="top" width="36" style="padding:0 12px 14px 0;">
            <table role="presentation" cellpadding="0" cellspacing="0" border="0">
              <tr>
                <td align="center" width="24" height="24" bgcolor="${markerBg}"
                    style="border-radius:12px;font-family:Arial,Helvetica,sans-serif;
                           font-size:13px;font-weight:bold;color:${markerColor};
                           line-height:24px;">${marker}</td>
              </tr>
            </table>
          </td>
          <td valign="top" style="padding:0 0 14px 0;font-family:Arial,Helvetica,sans-serif;
                     font-size:14px;line-height:1.6;color:${ink};">
            <strong style="color:${titleColor};">${step.title}</strong><br />
            <span style="color:${muted};">${step.detail}</span>
          </td>
        </tr>`;
    })
    .join("");

  return `
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%"
           style="margin:6px 0 2px 0;">
      ${rows}
    </table>`;
}
