// utils/payoutAccountRemoval.js
//
// Removing (disconnecting) a Stripe payout account — and, as a separate,
// optional step, deleting it in Stripe. The host does all of it themselves; no
// admin is needed.
//
//   1. REMOVE. The account's `stripeAccounts` entry is ARCHIVED with
//      `status: "disconnected"` — never hard-deleted — and disappears from the
//      active list and every dropdown. Stripe is not touched: money already
//      transferred still reaches the host's bank. Refused while (a) listings
//      still use it, (b) bookings or payouts are pending on it, or (c) it is the
//      default account. See accountRemovalBlockers.
//
//   2. DELETE IN STRIPE (optional, only after step 1). The Express-account
//      equivalent of deauthorizing it. Irreversible; Stripe only allows it once
//      the balance is zero. Refused while money is on the account, a bank payout
//      is still on its way, or Putko transferred to it recently enough that a
//      dispute might still need it.
//
// A disconnected account can be RECONNECTED, as long as it was not deleted in
// Stripe.
//
// Every dependency can be swapped (createPayoutAccountRemoval), so the tests
// run against in-memory fakes — never the real database or Stripe.

import HostModel from "../models/Host.js";
import AccommodationModel from "../models/Accommodation.js";
import ReservationModel from "../models/Reservation.js";
import { getStripe as realGetStripe, logStripeCall } from "./stripeHelpers.js";
import { alertAdmin as realAlertAdmin } from "./mailer.js";
import { syncListingStatusForHost, syncHostFromStripeAccount } from "./hostStripeSync.js";
import {
  ACCOUNT_STATUS,
  accountRemovalBlockers,
  disconnectedAccountEntry,
  listPayoutAccounts,
  listRemovedAccounts,
} from "./payoutAccounts.js";

/**
 * How long after the last transfer an account must not be deleted in Stripe.
 * Card disputes can arrive up to ~120 days after the payment (longer for some
 * networks); if Putko ever needs to reverse a transfer to cover one, the
 * account has to still exist.
 */
export const STRIPE_DELETE_TRANSFER_WINDOW_DAYS = Number(
  process.env.STRIPE_DELETE_TRANSFER_WINDOW_DAYS || 180
);

const DAY_MS = 24 * 3600 * 1000;

/** Stripe says the account does not exist, or this key cannot reach it. */
const isGoneError = (err) =>
  err?.code === "resource_missing" ||
  err?.code === "account_invalid" ||
  err?.type === "StripePermissionError" ||
  (err?.type === "StripeInvalidRequestError" && err?.statusCode === 403);

const actorOf = (actor) => ({
  kind: actor?.kind || "unknown",
  id: actor?.id ? String(actor.id) : undefined,
});

/**
 * Updates target exactly one `stripeAccounts` entry: the one the query's
 * `$elemMatch` matched, written through the positional `$` operator. Not
 * `arrayFilters` — Mongoose casts those against the schema itself and throws
 * "Could not find path \"stripeAccounts.0.status\" in schema" whenever it cannot
 * resolve the path, which turned a plain Remove click into a 500.
 */
const entryMatch = (accountId, status) => ({ $elemMatch: { accountId, status } });

export function createPayoutAccountRemoval(deps = {}) {
  const {
    Host = HostModel,
    Accommodation = AccommodationModel,
    Reservation = ReservationModel,
    getStripe = realGetStripe,
    log = logStripeCall,
    alertAdmin = realAlertAdmin,
    syncListingStatus = syncListingStatusForHost,
    syncFromStripe = syncHostFromStripeAccount,
    now = () => new Date(),
  } = deps;

  /** Everything the removal rules need to know about this host. */
  async function loadContext(host) {
    const listings = await Accommodation.find({ userId: host._id })
      .select("_id name payoutStripeAccountId")
      .lean();

    const listingIds = listings.map((l) => l._id);
    if (!listingIds.length) return { listings, unpaidPayouts: [], pendingReservations: [] };

    const [unpaidPayouts, pendingReservations] = await Promise.all([
      // (b) Paid, not yet transferred — the same test the payout sweep uses to
      // pick what it will still pay (utils/payoutJob.js).
      Reservation.find({
        accommodationId: { $in: listingIds },
        paymentStatus: "paid",
        payoutStatus: { $ne: "released" },
        transferId: null,
        isApproved: { $ne: "cancelled" },
        refundAmountCents: { $not: { $gt: 0 } },
      })
        .select("_id accommodationId checkInDate hostAmountCents currency")
        .lean(),
      // (b) Upcoming bookings not paid yet: awaiting the host's answer, or
      // accepted and waiting for the guest to pay. Once paid they pay out to
      // whatever the listing points at, so they must not be left hanging.
      Reservation.find({
        accommodationId: { $in: listingIds },
        paymentStatus: "unpaid",
        isApproved: { $in: ["pending", "approved"] },
        checkOutDate: { $gte: now() },
        requestDeclinedAt: null,
        requestExpiredAt: null,
      })
        .select("_id accommodationId checkInDate isApproved")
        .lean(),
    ]);

    return { listings, unpaidPayouts, pendingReservations };
  }

  /**
   * Can this account be removed right now? Read-only — the host's dialog calls
   * this to show what is in the way before they confirm.
   */
  async function checkRemoval({ hostId, accountId }) {
    const host = await Host.findById(hostId);
    if (!host) return { ok: false, status: 404, code: "host_not_found" };

    const context = await loadContext(host);
    const result = accountRemovalBlockers({ host, accountId, ...context });

    return { ok: true, host, ...result };
  }

  /**
   * Remove (disconnect) the account.
   *
   * @param {object} args
   * @param {string} args.hostId
   * @param {string} args.accountId
   * @param {{kind: string, id: string}} args.actor who is asking
   */
  async function removeAccount({ hostId, accountId, actor }) {
    // Always decided again here — never trust what the dialog was shown.
    const check = await checkRemoval({ hostId, accountId });
    if (!check.ok) return check;
    if (!check.canRemove) {
      const listingsBlocker = check.blockers.find((b) => b.code === "listings_assigned");
      return {
        ok: false,
        status: check.blockers.some((b) => b.code === "unknown_account") ? 404 : 409,
        code: "removal_blocked",
        blockers: check.blockers,
        // (a) The listings to reassign, at the top level for easy use.
        listings: listingsBlocker?.listings || [],
      };
    }

    const { host } = check;
    const at = now();

    // One atomic write, conditional on nothing having changed since the check:
    // the entry is still active, and it has not become the default meanwhile
    // (another tab pressing "Make default" at the wrong moment).
    const updated = await Host.findOneAndUpdate(
      {
        _id: host._id,
        stripeAccountId: { $ne: accountId },
        stripeAccounts: {
          // Entries written before `status` existed have none; `$ne` covers them.
          $elemMatch: { accountId, status: { $ne: ACCOUNT_STATUS.DISCONNECTED } },
        },
      },
      {
        $set: {
          "stripeAccounts.$.status": ACCOUNT_STATUS.DISCONNECTED,
          "stripeAccounts.$.disconnectedAt": at,
          "stripeAccounts.$.disconnectedBy": actorOf(actor),
        },
      },
      { new: true }
    );
    if (!updated) {
      return {
        ok: false,
        status: 409,
        code: "changed_meanwhile",
        error: "The payout accounts changed while this was being removed. Reload and try again.",
      };
    }

    // The old per-listing field some listings still carry. Nothing decides a
    // payout from it any more, but it must not keep naming a removed account.
    await Accommodation.updateMany(
      { userId: host._id, stripeAccountId: accountId },
      { $unset: { stripeAccountId: "" } }
    );

    const statusResult = await syncListingStatus(updated);

    // The check and the write are not one transaction with the listings and
    // bookings: the host could point a listing at this account, or a booking
    // could be made, in the moment between. Look again and tell a human if so —
    // rare, and recoverable, but it must not go unnoticed.
    const after = await loadContext(updated);
    const racedListings = after.listings.filter((l) => l.payoutStripeAccountId === accountId);
    if (racedListings.length) {
      await alertAdmin("Payout account removed while a listing still named it", {
        hostId: String(host._id),
        accountId,
        listings: racedListings.map((l) => String(l._id)),
        nowPayingInto: updated.stripeAccountId || null,
      });
    }

    log("account.disconnected", {
      hostId: String(host._id),
      accountId,
      removedBy: actorOf(actor).kind,
      listingsUpdated: statusResult?.updated || 0,
    });

    return {
      ok: true,
      accounts: listPayoutAccounts(updated),
      removedAccounts: listRemovedAccounts(updated),
      defaultAccountId: updated.stripeAccountId || null,
    };
  }

  /**
   * Reconnect a disconnected account. Refused once it has been deleted in
   * Stripe — there is nothing left to reconnect.
   */
  async function restoreAccount({ hostId, accountId, actor }) {
    const host = await Host.findById(hostId);
    if (!host) return { ok: false, status: 404, code: "host_not_found" };

    if (listPayoutAccounts(host).some((a) => a.accountId === accountId)) {
      return { ok: false, status: 409, code: "already_connected" };
    }
    const entry = disconnectedAccountEntry(host, accountId);
    if (!entry) return { ok: false, status: 404, code: "not_removed" };
    if (entry.stripeDeletedAt) return { ok: false, status: 409, code: "deleted_in_stripe" };

    // Make sure it still exists and is still ours before offering it again.
    let stripeAccount;
    try {
      stripeAccount = await getStripe().accounts.retrieve(accountId);
    } catch (err) {
      log("accounts.retrieve", { hostId: String(host._id), accountId, reason: "restore" }, "error", err);
      if (isGoneError(err)) return { ok: false, status: 409, code: "unreachable_in_stripe" };
      return { ok: false, status: 502, code: "stripe_error", error: err.message };
    }

    const at = now();
    const updated = await Host.findOneAndUpdate(
      {
        _id: host._id,
        stripeAccounts: {
          $elemMatch: { accountId, status: ACCOUNT_STATUS.DISCONNECTED, stripeDeletedAt: null },
        },
      },
      {
        $set: {
          "stripeAccounts.$.status": ACCOUNT_STATUS.ACTIVE,
          "stripeAccounts.$.connectedAt": at,
        },
        $unset: {
          "stripeAccounts.$.disconnectedAt": "",
          "stripeAccounts.$.disconnectedBy": "",
        },
      },
      { new: true }
    );
    if (!updated) return { ok: false, status: 409, code: "changed_meanwhile" };

    // Fill in its current Stripe status. It comes back as an ordinary extra
    // account — it becomes the default only if the host has none.
    let synced = updated;
    try {
      synced =
        (await syncFromStripe({
          ...stripeAccount,
          metadata: { ...(stripeAccount.metadata || {}), host_id: String(host._id) },
        })) || updated;
    } catch (err) {
      console.error("[payout-accounts] reconnected, but the status sync failed:", err.message);
    }

    log("account.reconnected", {
      hostId: String(host._id),
      accountId,
      reconnectedBy: actorOf(actor).kind,
    });

    return {
      ok: true,
      accounts: listPayoutAccounts(synced),
      removedAccounts: listRemovedAccounts(synced),
      defaultAccountId: synced.stripeAccountId || null,
    };
  }

  /**
   * Can this disconnected account be deleted in Stripe? Read-only. Asks Stripe
   * directly — Putko's own records do not know the account's balance.
   */
  async function checkStripeDeletion({ hostId, accountId }) {
    const host = await Host.findById(hostId);
    if (!host) return { ok: false, status: 404, code: "host_not_found" };

    if (listPayoutAccounts(host).some((a) => a.accountId === accountId)) {
      // Step 1 first. Deleting an account listings may still pay into would
      // make every one of those payouts fail.
      return { ok: true, host, canDelete: false, blockers: [{ code: "not_removed_yet" }] };
    }
    const entry = disconnectedAccountEntry(host, accountId);
    if (!entry) return { ok: false, status: 404, code: "not_removed" };
    if (entry.stripeDeletedAt) {
      return { ok: true, host, canDelete: false, blockers: [{ code: "already_deleted" }] };
    }

    const stripe = getStripe();
    const opts = { stripeAccount: accountId };
    const blockers = [];

    // Balance must be zero — Stripe refuses otherwise, and money on it is the
    // host's. Negative balances (money owed) count too.
    try {
      const balance = await stripe.balance.retrieve({}, opts);
      const nonZero = [...(balance.available || []), ...(balance.pending || [])].filter(
        (b) => b.amount !== 0
      );
      if (nonZero.length) {
        blockers.push({
          code: "balance_not_zero",
          amounts: nonZero.map((b) => ({ amountCents: b.amount, currency: b.currency })),
        });
      }
    } catch (err) {
      log("balance.retrieve", { hostId: String(host._id), accountId }, "error", err);
      if (isGoneError(err)) {
        // Already gone in Stripe. Nothing left to protect; recording it is all
        // that remains.
        return { ok: true, host, canDelete: true, alreadyGone: true, blockers: [] };
      }
      return { ok: true, host, canDelete: false, blockers: [{ code: "stripe_error", error: err.message }] };
    }

    // No bank payout still on its way.
    try {
      const payouts = await stripe.payouts.list({ limit: 100 }, opts);
      const inFlight = (payouts.data || []).filter((p) =>
        ["pending", "in_transit"].includes(p.status)
      );
      if (inFlight.length) {
        blockers.push({
          code: "payouts_in_flight",
          payouts: inFlight.map((p) => ({
            id: p.id,
            amountCents: p.amount,
            currency: p.currency,
            arrivalDate: p.arrival_date ? new Date(p.arrival_date * 1000) : null,
          })),
        });
      }
    } catch (err) {
      log("payouts.list", { hostId: String(host._id), accountId }, "error", err);
      blockers.push({ code: "stripe_error", error: err.message });
    }

    // No recent transfer from Putko — a late dispute might need it reversed.
    try {
      const since = Math.floor((now().getTime() - STRIPE_DELETE_TRANSFER_WINDOW_DAYS * DAY_MS) / 1000);
      const transfers = await stripe.transfers.list({
        destination: accountId,
        created: { gte: since },
        limit: 1,
      });
      const latest = transfers.data?.[0];
      if (latest) {
        const lastAt = new Date(latest.created * 1000);
        blockers.push({
          code: "recent_transfers",
          lastTransferAt: lastAt,
          deletableFrom: new Date(lastAt.getTime() + STRIPE_DELETE_TRANSFER_WINDOW_DAYS * DAY_MS),
        });
      }
    } catch (err) {
      log("transfers.list", { hostId: String(host._id), accountId }, "error", err);
      blockers.push({ code: "stripe_error", error: err.message });
    }

    return { ok: true, host, canDelete: blockers.length === 0, blockers };
  }

  /** Delete a disconnected account in Stripe. Irreversible. */
  async function deleteInStripe({ hostId, accountId, actor }) {
    const check = await checkStripeDeletion({ hostId, accountId });
    if (!check.ok) return check;
    if (!check.canDelete) {
      return { ok: false, status: 409, code: "deletion_blocked", blockers: check.blockers };
    }

    let alreadyGone = Boolean(check.alreadyGone);
    if (!alreadyGone) {
      try {
        const result = await getStripe().accounts.del(accountId);
        if (!result?.deleted) {
          return { ok: false, status: 502, code: "stripe_did_not_delete" };
        }
      } catch (err) {
        log("accounts.del", { hostId: String(hostId), accountId }, "error", err);
        if (isGoneError(err)) {
          alreadyGone = true;
        } else {
          // Stripe's own reason (e.g. a balance that appeared since the check).
          return { ok: false, status: 400, code: "stripe_refused", error: err.message };
        }
      }
    }

    const updated = await Host.findOneAndUpdate(
      { _id: check.host._id, stripeAccounts: entryMatch(accountId, ACCOUNT_STATUS.DISCONNECTED) },
      {
        $set: {
          "stripeAccounts.$.stripeDeletedAt": now(),
          "stripeAccounts.$.stripeDeletedBy": actorOf(actor),
        },
      },
      { new: true }
    );

    log("accounts.del", {
      hostId: String(hostId),
      accountId,
      deletedBy: actorOf(actor).kind,
      alreadyGone,
    });

    return {
      ok: true,
      alreadyGone,
      removedAccounts: listRemovedAccounts(updated || check.host),
    };
  }

  return { checkRemoval, removeAccount, restoreAccount, checkStripeDeletion, deleteInStripe };
}

export const payoutAccountRemoval = createPayoutAccountRemoval();
