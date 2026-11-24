import { DEFAULT_CURRENCY } from "../config/payments.js";

/**
 * Money as text for emails and receipts, in British English: "£120", "£98.50".
 *
 * The currency comes from the booking when it has one, so an older booking
 * that was charged in another currency still shows what was actually paid.
 */
export function formatMoney(amount, currency = DEFAULT_CURRENCY) {
  const value = Number(amount) || 0;
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: (currency || DEFAULT_CURRENCY).toUpperCase(),
    minimumFractionDigits: Number.isInteger(value) ? 0 : 2,
    maximumFractionDigits: 2,
  }).format(value);
}

/** Same, from an amount in minor units (pence). */
export const formatCents = (cents, currency = DEFAULT_CURRENCY) =>
  formatMoney((Number(cents) || 0) / 100, currency);
