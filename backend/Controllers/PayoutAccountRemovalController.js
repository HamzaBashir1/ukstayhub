// Controllers/PayoutAccountRemovalController.js
//
// HTTP layer over utils/payoutAccountRemoval.js. All the rules live there; this
// only reads the request, names the caller, and turns results into responses.

import mongoose from "mongoose";
import { payoutAccountRemoval } from "../utils/payoutAccountRemoval.js";

const actorOf = (req) => ({ kind: req.auth?.kind || "unknown", id: req.auth?.id });

const isAccountId = (value) => typeof value === "string" && /^acct_[A-Za-z0-9]+$/.test(value);

/**
 * hostId / accountId from the path, or — for DELETE /host/stripe-account — from
 * the body, the way the other host payout routes take them.
 */
const idsOf = (req) => ({
  hostId: req.params.hostId || req.body?.hostId,
  accountId: req.params.accountId || req.body?.accountId,
});

/** Shared validation. Returns an error response, or null when fine. */
function badRequest(req, res) {
  const { hostId, accountId } = idsOf(req);
  if (!mongoose.Types.ObjectId.isValid(hostId)) {
    return res.status(400).json({ error: "Invalid hostId", code: "invalid_host" });
  }
  if (!isAccountId(accountId)) {
    return res.status(400).json({ error: "Invalid payout account id", code: "invalid_account" });
  }
  return null;
}

/** Service result → response. The `host` document is never sent back. */
function send(res, result) {
  // eslint-disable-next-line no-unused-vars
  const { ok, status, host, ...body } = result;
  if (ok) return res.json(body);
  return res.status(status || 500).json(body);
}

const handle = (fn) => async (req, res) => {
  if (badRequest(req, res)) return;
  try {
    send(res, await fn(req));
  } catch (err) {
    console.error(`[payout-accounts] ${fn.name || "handler"} failed:`, err);
    res.status(500).json({ error: err.message, code: "server_error" });
  }
};

/** GET /api/payments/host/:hostId/stripe-accounts/:accountId/removal-check */
export const checkPayoutAccountRemoval = handle(function checkRemoval(req) {
  return payoutAccountRemoval.checkRemoval(idsOf(req));
});

/**
 * DELETE /api/payments/host/stripe-account          body: { hostId, accountId }
 * DELETE /api/payments/host/:hostId/stripe-accounts/:accountId
 *
 * 200 → { accounts, removedAccounts, defaultAccountId }
 * 409 → { code: "removal_blocked", blockers, listings } — `listings` are the
 *       ones still using the account, to reassign first.
 */
export const removePayoutAccount = handle(function removeAccount(req) {
  return payoutAccountRemoval.removeAccount({ ...idsOf(req), actor: actorOf(req) });
});

/** POST /api/payments/host/:hostId/stripe-accounts/:accountId/restore */
export const restorePayoutAccount = handle(function restoreAccount(req) {
  return payoutAccountRemoval.restoreAccount({
    ...idsOf(req),
    actor: actorOf(req),
  });
});

/** GET /api/payments/host/:hostId/stripe-accounts/:accountId/stripe-deletion-check */
export const checkStripeAccountDeletion = handle(function checkStripeDeletion(req) {
  return payoutAccountRemoval.checkStripeDeletion(idsOf(req));
});

/** DELETE /api/payments/host/:hostId/stripe-accounts/:accountId/stripe */
export const deleteStripeAccount = handle(function deleteInStripe(req) {
  return payoutAccountRemoval.deleteInStripe({
    ...idsOf(req),
    actor: actorOf(req),
  });
});
