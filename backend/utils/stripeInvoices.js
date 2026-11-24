// utils/stripeInvoices.js
//
// Putko's monthly platform-fee invoice to a host, issued as a Stripe Invoice.
// The fee was already deducted from each booking
// payout, so the invoice is created, finalized and marked paid out-of-band: it
// is a tax document, never a payment request.
import axios from "axios";
import {
  INVOICE_EMAIL_ENABLED,
  INVOICE_TEST_EMAIL_OVERRIDE,
  VAT_RATE_PERCENT,
} from "../config/payments.js";
import { logExternalCall } from "./auditLog.js";
import { getStripe } from "./stripeHelpers.js";
import { getTransporter, MAIL_FROM } from "./mailer.js";
import { DEFAULT_CURRENCY } from "../config/payments.js";

/** `2026-08` from an invoice document. */
export const yearMonthOf = (invoiceDocument) =>
  `${invoiceDocument.invoiceYear}-${String(invoiceDocument.invoiceMonth).padStart(2, "0")}`;

const COUNTRY_CODES = { "united kingdom": "GB", uk: "GB", slovensko: "SK", slovakia: "SK", "česko": "CZ", "czech republic": "CZ" };

/** Stripe wants ISO-3166 alpha-2; the host form stores free text. */
const toCountryCode = (country) => {
  const c = String(country || "").trim();
  if (/^[A-Za-z]{2}$/.test(c)) return c.toUpperCase();
  return COUNTRY_CODES[c.toLowerCase()] || undefined;
};

/** Buyer block — the host, from the snapshot taken when the invoice was built. */
export const buildCustomerParams = (host, invoiceDocument) => {
  const s = invoiceDocument?.hostSnapshot || {};
  const name =
    s.companyName || host.companyName || `${host.name || ""} ${host.lastName || ""}`.trim() || "Host";
  return {
    name,
    email: s.email || host.email || undefined,
    address: {
      line1: s.streetNumber || host.streetNumber || undefined,
      city: s.city || host.city || undefined,
      postal_code: s.zipcode || host.zipcode || undefined,
      country: toCountryCode(s.country || host.country || host.countryCode),
    },
    metadata: { hostId: String(host._id || host.id || "") },
  };
};

/** One reusable exclusive VAT rate, found or created. */
let cachedTaxRateId;
async function getVatTaxRateId(stripe) {
  if (cachedTaxRateId) return cachedTaxRateId;
  const { data } = await stripe.taxRates.list({ active: true, limit: 100 });
  const found = data.find((r) => !r.inclusive && Number(r.percentage) === Number(VAT_RATE_PERCENT) && r.metadata?.putko === "platform-fee");
  const rate =
    found ||
    (await stripe.taxRates.create({
      display_name: "VAT",
      percentage: VAT_RATE_PERCENT,
      inclusive: false,
      metadata: { putko: "platform-fee" },
    }));
  cachedTaxRateId = rate.id;
  return rate.id;
}

/** The host's billing Customer: reused once created, else created and remembered. */
async function ensureCustomer(stripe, host, invoiceDocument) {
  const params = buildCustomerParams(host, invoiceDocument);
  if (host.stripeBillingCustomerId) {
    try {
      return await stripe.customers.update(host.stripeBillingCustomerId, params);
    } catch (err) {
      if (err?.code !== "resource_missing") throw err;
    }
  }
  const customer = await stripe.customers.create(params);
  if (typeof host.save === "function") {
    host.stripeBillingCustomerId = customer.id;
    await host.save();
  }
  return customer;
}

/** The identifiers the invoice job stores for a created invoice. */
export function extractInvoiceMeta(invoice) {
  return {
    id: invoice.id,
    number: invoice.number,
    pdfUrl: invoice.invoice_pdf || invoice.hosted_invoice_url,
    hostedUrl: invoice.hosted_invoice_url,
  };
}

/**
 * Create, finalize and mark paid one monthly fee invoice.
 * @returns {{ response: object, emailRequested: boolean, meta: object, recipient: string }}
 */
export async function createStripeInvoice({ host, invoiceDocument }) {
  const stripe = getStripe();
  const yearMonth = yearMonthOf(invoiceDocument);
  const bookingCount = invoiceDocument.billedBookings || 0;
  const currency = (invoiceDocument.currency || DEFAULT_CURRENCY).toLowerCase();
  const recipient = INVOICE_TEST_EMAIL_OVERRIDE || invoiceDocument.hostSnapshot?.email || host.email || "";
  const emailRequested = Boolean(INVOICE_EMAIL_ENABLED && recipient);

  const auditContext = {
    hostId: String(host._id || host.id || ""),
    invoiceId: String(invoiceDocument._id || ""),
    period: yearMonth,
    grossAmountCents: invoiceDocument.grossAmountCents,
    netAmountCents: invoiceDocument.netAmountCents,
    vatAmountCents: invoiceDocument.vatAmountCents,
    emailRequested,
  };

  // Idempotency key: a retry after a crash reuses the same Stripe objects
  // instead of issuing a second invoice for the month.
  const key = `putko-invoice-${invoiceDocument._id}`;
  try {
    const customer = await ensureCustomer(stripe, host, invoiceDocument);
    const taxRate = await getVatTaxRateId(stripe);

    const draft = await stripe.invoices.create(
      {
        customer: customer.id,
        collection_method: "send_invoice",
        days_until_due: 1,
        auto_advance: false,
        currency,
        description: invoiceDocument.description || `Platform fee — ${yearMonth}`,
        metadata: { putkoInvoiceId: String(invoiceDocument._id || ""), hostId: auditContext.hostId, period: yearMonth },
      },
      { idempotencyKey: `${key}-inv` }
    );

    // Priced NET; the exclusive tax rate rebuilds the gross deducted from the host.
    await stripe.invoiceItems.create(
      {
        customer: customer.id,
        invoice: draft.id,
        currency,
        amount: invoiceDocument.netAmountCents,
        tax_rates: [taxRate],
        description: `Platform fees for ${bookingCount} bookings in ${yearMonth}`,
      },
      { idempotencyKey: `${key}-item` }
    );

    const finalized = await stripe.invoices.finalizeInvoice(draft.id, { auto_advance: false });
    // The fee was deducted at each booking; nothing is owed.
    const paid = await stripe.invoices.pay(finalized.id, { paid_out_of_band: true });

    const meta = extractInvoiceMeta(paid);
    logExternalCall("stripe", "invoices.create", { ...auditContext, externalInvoiceId: meta.id, invoiceNumber: meta.number });
    return { response: paid, emailRequested, meta, recipient };
  } catch (err) {
    logExternalCall("stripe", "invoices.create", auditContext, "error", err);
    throw err;
  }
}

/**
 * Email the issued invoice to the host over Putko's SMTP, PDF attached.
 * Stripe does not email an invoice that is already paid out-of-band, so this is
 * the only delivery route.
 * @returns {{ delivered: boolean, via: 'putko'|null, to: string, error?: string }}
 */
export async function deliverInvoice({ host, invoiceDocument, meta }) {
  const hostEmail = invoiceDocument.hostSnapshot?.email || host.email || "";
  const to = INVOICE_TEST_EMAIL_OVERRIDE || hostEmail;
  const yearMonth = yearMonthOf(invoiceDocument);
  const redirected = Boolean(INVOICE_TEST_EMAIL_OVERRIDE);
  if (!to) return { delivered: false, via: null, to: "", error: "no recipient address" };

  const subject = redirected
    ? `[TEST] Invoice from UK Stay Hub — ${yearMonth} (host: ${hostEmail || "no email"})`
    : `Invoice from UK Stay Hub — ${yearMonth}`;
  const bodyText = redirected
    ? `TEST — redirected by INVOICE_TEST_EMAIL_OVERRIDE. Normally sent to ${hostEmail || "the host"}.\n\nPeriod: ${yearMonth}\nInvoice no.: ${meta.number || "—"}`
    : `Hello,\n\nattached is the invoice for UK Stay Hub's intermediary fees for ${yearMonth}. ` +
      "It is already settled — the fee was deducted from each booking.\n\nKind regards,\nUK Stay Hub";

  const audit = { invoiceId: String(invoiceDocument._id || ""), externalInvoiceId: meta.id, to, emailRedirected: redirected || undefined };
  try {
    const attachments = [];
    if (meta.pdfUrl) {
      const pdf = await axios.get(meta.pdfUrl, { responseType: "arraybuffer", timeout: 20000 });
      attachments.push({ filename: `Invoice-${meta.number || meta.id}.pdf`, content: Buffer.from(pdf.data), contentType: "application/pdf" });
    }
    await getTransporter().sendMail({
      from: MAIL_FROM,
      to,
      subject,
      text: bodyText,
      html: `<div style="font-family:Arial,sans-serif;color:#333;line-height:1.6;"><p>${bodyText.replace(/\n/g, "<br/>")}</p>${
        meta.hostedUrl ? `<p><a href="${meta.hostedUrl}">View invoice</a></p>` : ""
      }</div>`,
      attachments,
    });
    logExternalCall("putko-mail", "invoice.send", { ...audit, via: "putko", attached: attachments.length > 0 });
    return { delivered: true, via: "putko", to };
  } catch (err) {
    logExternalCall("putko-mail", "invoice.send", audit, "error", err);
    return { delivered: false, via: null, to, error: err.message };
  }
}
