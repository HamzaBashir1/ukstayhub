// utils/payoutAccounts.js
//
// Which connected account does a given listing pay out to?
//
// A host may hold several. One account across every property is the common
// case; a separate account per property is the reason this exists — an owner
// with an apartment in their own name and a chalet under a company needs both,
// and the money has to land in the right one.
//
// Every caller that moves money, or decides whether money CAN be moved, resolves
// through here. Duplicating the fallback rule is how a booking ends up paying
// the wrong account.

import { DEFAULT_CURRENCY } from "../config/payments.js";

/**
 * The host's accounts as a list, including the legacy single account.
 *
 * A host onboarded before `stripeAccounts` existed has only `stripeAccountId`
 * and the top-level capability fields. Presenting that as a one-entry list means
 * nothing downstream needs to know which era a host belongs to.
 *
 * @param {object|null} host
 * @returns {Array<{accountId, label, chargesEnabled, payoutsEnabled, requirementsDue, isDefault}>}
 */
export function listPayoutAccounts(host) {
  if (!host) return [];

  // Disconnected accounts are archived on the host but are not accounts the
  // host "holds" any more: nothing lists them, offers them or pays into them.
  const accounts = (host.stripeAccounts || [])
    .filter((a) => a?.accountId && !isDisconnected(a))
    .map((a) => ({
      accountId: a.accountId,
      label: a.label || "",
      chargesEnabled: Boolean(a.chargesEnabled),
      payoutsEnabled: Boolean(a.payoutsEnabled),
      // Undefined rather than false when never synced — `isAccountPayoutReady`
      // distinguishes the two, and coercing here would erase that.
      transfersActive: a.transfersActive,
      requirementsDue: a.requirementsDue || [],
      pastDue: a.pastDue || [],
      pendingVerification: a.pendingVerification || [],
      eventuallyDue: a.eventuallyDue || [],
      disabledReason: a.disabledReason || null,
      requirementErrors: a.requirementErrors || [],
      currentDeadline: a.currentDeadline || null,
      futureDue: a.futureDue || [],
      futureDeadline: a.futureDeadline || null,
      payoutState: a.payoutState || null,
      statusUpdatedAt: a.statusUpdatedAt || null,
      payoutIban: a.payoutIban || null,
      connectedAt: a.connectedAt || null,
      status: ACCOUNT_STATUS.ACTIVE,
      isDefault: host.stripeAccountId === a.accountId,
    }));

  // The default account may predate the list. Fold it in from the top-level
  // fields rather than showing a host an empty dropdown next to a working
  // account.
  //
  // Never for a disconnected account: removal refuses the default, but a
  // default that somehow names an archived entry must not be revived from the
  // top-level fields.
  if (
    host.stripeAccountId &&
    !accounts.some((a) => a.accountId === host.stripeAccountId) &&
    !(host.stripeAccounts || []).some(
      (a) => a?.accountId === host.stripeAccountId && isDisconnected(a)
    )
  ) {
    accounts.unshift({
      accountId: host.stripeAccountId,
      label: "",
      chargesEnabled: Boolean(host.chargesEnabled),
      payoutsEnabled: Boolean(host.payoutsEnabled),
      transfersActive: host.stripeTransfersActive,
      requirementsDue: host.stripeRequirementsDue || [],
      pastDue: host.stripePastDue || [],
      pendingVerification: [],
      eventuallyDue: [],
      disabledReason: host.stripeDisabledReason || null,
      requirementErrors: [],
      currentDeadline: null,
      futureDue: [],
      futureDeadline: null,
      payoutState: host.stripePayoutState || null,
      statusUpdatedAt: host.stripeStatusUpdatedAt || null,
      payoutIban: host.payoutIban || null,
      connectedAt: null,
      status: ACCOUNT_STATUS.ACTIVE,
      isDefault: true,
    });
  }

  // Most recently connected first — the spec asks for the newest to be
  // pre-selected in the add form, and a host who has just connected an account
  // is almost always connecting it FOR the listing they are creating.
  return accounts.sort((a, b) => {
    if (a.isDefault !== b.isDefault && !a.connectedAt && !b.connectedAt) {
      return a.isDefault ? -1 : 1;
    }
    return new Date(b.connectedAt || 0) - new Date(a.connectedAt || 0);
  });
}

/**
 * The account a listing actually pays out to.
 *
 * Falls back to the host's default when the listing names none — and ALSO when
 * it names one the host no longer holds. The second case matters: an account id
 * left on a listing after the host disconnected it would otherwise send money
 * to an account this platform may not even control.
 *
 * @param {object|null} accommodation
 * @param {object|null} host
 * @returns {object|null} the resolved account, or null when there is none
 */
export function resolvePayoutAccount(accommodation, host) {
  const accounts = listPayoutAccounts(host);
  if (!accounts.length) return null;

  const named = accommodation?.payoutStripeAccountId;
  if (named) {
    const match = accounts.find((a) => a.accountId === named);
    if (match) return match;
    console.warn(
      `[payout-accounts] listing ${accommodation?._id} names account ${named}, ` +
        `which host ${host?._id} does not hold — falling back to the default`
    );
  }

  return accounts.find((a) => a.isDefault) || accounts[0];
}

/** Just the id, for the many callers that only need a transfer destination. */
export function resolvePayoutAccountId(accommodation, host) {
  return resolvePayoutAccount(accommodation, host)?.accountId || null;
}

/**
 * Is this specific account ready to receive money?
 *
 * Deliberately per-account. With several accounts a host-level "payouts
 * enabled" is meaningless — one account can be verified while another is still
 * waiting on an ID document.
 *
 * The rule is `payoutsEnabled && transfersActive`, NOT the former
 * `chargesEnabled && payoutsEnabled`.
 *
 * Putko charges the guest on the platform account and moves the host's share
 * with `transfers.create`, so `transfers` is the only capability a host account
 * needs — and since the platform stopped requesting `card_payments` (which was
 * what dragged hosts into Stripe's "Restricted" state for a payment method they
 * never accept), `charges_enabled` is permanently false on newly connected
 * accounts. Gating on it would refuse every host onboarded from now on.
 *
 * `transfersActive` is undefined on accounts that have not been synced since
 * that change, so those fall back to the old rule rather than being locked out
 * of a payout they had already qualified for. The next `account.updated` — or
 * the next staleness refresh — fills it in and the fallback stops applying.
 */
export function isAccountPayoutReady(account) {
  if (!account?.payoutsEnabled) return false;

  if (account.transfersActive === undefined || account.transfersActive === null) {
    return Boolean(account.chargesEnabled);
  }

  return Boolean(account.transfersActive);
}

/**
 * What is standing between this account and a payout, as a short state name.
 *
 * `payoutState` is written by the Stripe sync (utils/stripeHelpers.js ->
 * describeAccountState). This derives the same answer for an account that
 * predates the field, so callers never have to special-case its absence.
 *
 * @returns {'active'|'pending'|'verifying'|'restricted'}
 */
export function payoutStateOf(account) {
  if (!account) return "pending";
  if (isAccountPayoutReady(account)) return "active";
  if (account.payoutState) return account.payoutState;
  if (account.disabledReason || account.pastDue?.length) return "restricted";
  if (account.requirementsDue?.length) return "pending";
  if (account.pendingVerification?.length) return "verifying";
  return "pending";
}

// ---------------------------------------------------------------------------
// Removing an account
//
// Removing ARCHIVES the account on the host: its `stripeAccounts` entry stays,
// with `status: "disconnected"`, and `listPayoutAccounts` above stops returning
// it. It is never hard-deleted, and removal does not touch Stripe — money
// already transferred still reaches the host's bank. Deleting it in Stripe is a
// separate, optional step (utils/payoutAccountRemoval.js).
//
// Removal is refused while anything still depends on the account. The danger
// is `resolvePayoutAccount`: a listing naming an account the host no longer
// holds falls back to the default, so removing one that listings or unpaid
// bookings rely on would quietly send that money somewhere else.
// ---------------------------------------------------------------------------

export const ACCOUNT_STATUS = Object.freeze({
  ACTIVE: "active",
  DISCONNECTED: "disconnected",
});

/** Is this `stripeAccounts` entry archived? A missing status means active. */
export function isDisconnected(entry) {
  return entry?.status === ACCOUNT_STATUS.DISCONNECTED;
}

/** The archived entry for this account, or null. */
export function disconnectedAccountEntry(host, accountId) {
  if (!host || !accountId) return null;
  return (
    (host.stripeAccounts || []).find(
      (a) => a?.accountId === accountId && isDisconnected(a)
    ) || null
  );
}

/** Was this account removed from Putko (and not reconnected since)? */
export function isAccountRemoved(host, accountId) {
  return Boolean(disconnectedAccountEntry(host, accountId));
}

/** Every disconnected account, most recently removed first. */
export function listRemovedAccounts(host) {
  return (host?.stripeAccounts || [])
    .filter((a) => a?.accountId && isDisconnected(a))
    .map((a) => ({
      accountId: a.accountId,
      label: a.label || "",
      payoutIban: a.payoutIban || null,
      status: ACCOUNT_STATUS.DISCONNECTED,
      disconnectedAt: a.disconnectedAt || null,
      disconnectedBy: a.disconnectedBy?.kind || null,
      stripeDeletedAt: a.stripeDeletedAt || null,
    }))
    .sort((a, b) => new Date(b.disconnectedAt || 0) - new Date(a.disconnectedAt || 0));
}

/**
 * The host's top-level Stripe fields as they must read when `account` is the
 * default. Those fields mirror the DEFAULT account only, so they move whenever
 * the default does — leaving them behind would report one account's readiness
 * under another account's id, the one combination that can wave a transfer
 * through to an account Stripe has not enabled.
 *
 * @param {object} account an entry from listPayoutAccounts
 * @param {object} [options]
 * @param {string} [options.fallbackIban] kept when the account has no IBAN yet
 */
export function defaultMirrorFields(account, { fallbackIban } = {}) {
  return {
    stripeAccountId: account.accountId,
    chargesEnabled: Boolean(account.chargesEnabled),
    payoutsEnabled: Boolean(account.payoutsEnabled),
    stripeTransfersActive: account.transfersActive,
    onboardingComplete: isAccountPayoutReady(account),
    stripeRequirementsDue: account.requirementsDue || [],
    stripePastDue: account.pastDue || [],
    stripeDisabledReason: account.disabledReason || undefined,
    stripePayoutState: payoutStateOf(account),
    payoutIban: account.payoutIban || fallbackIban,
    stripeStatusUpdatedAt: new Date(),
  };
}

/**
 * Everything standing between this account and its removal. Pure: the caller
 * loads the listings and bookings, this only decides.
 *
 * Blocker codes, in the order a host would fix them:
 *   unknown_account      not one of the host's active accounts
 *   only_account         the host would be left with none
 *   is_default           (c) set another account as default first
 *   listings_assigned    (a) listings still use it — `listings` names them
 *   pending_payouts      (b) paid bookings whose payout has not been sent
 *   pending_reservations (b) upcoming bookings not paid yet
 *
 * @param {object} args
 * @param {object} args.host
 * @param {string} args.accountId
 * @param {Array}  args.listings            ALL the host's listings: {_id, name, payoutStripeAccountId}
 * @param {Array}  args.unpaidPayouts       paid bookings not yet transferred
 * @param {Array}  args.pendingReservations upcoming, not cancelled, not yet paid
 */
export function accountRemovalBlockers({
  host,
  accountId,
  listings = [],
  unpaidPayouts = [],
  pendingReservations = [],
}) {
  const accounts = listPayoutAccounts(host);
  const account = accounts.find((a) => a.accountId === accountId);

  if (!account) {
    return {
      canRemove: false,
      blockers: [{ code: "unknown_account" }],
      isDefault: false,
      otherAccounts: [],
      affectedListings: [],
    };
  }

  const blockers = [];
  const others = accounts.filter((a) => a.accountId !== accountId);
  const summarise = (l) => ({ _id: String(l._id), name: l.name || "" });

  // A host always keeps one account — with none, every listing drops to DRAFT.
  if (!others.length) {
    blockers.push({ code: "only_account" });
  } else if (account.isDefault) {
    // (c) Listings that name no account pay into the default, so it can only
    // go once the host has deliberately chosen another one.
    blockers.push({ code: "is_default" });
  }

  // Every listing paying into this account today: those naming it, plus — for
  // the default — those naming nothing or an account the host lacks.
  const affected = listings.filter(
    (l) => resolvePayoutAccount(l, host)?.accountId === accountId
  );
  const affectedIds = new Set(affected.map((l) => String(l._id)));
  const onAffected = (r) =>
    affectedIds.has(String(r.accommodationId?._id || r.accommodationId));

  // (a) Listings still using it, named so the host knows what to reassign.
  if (affected.length) {
    blockers.push({ code: "listings_assigned", listings: affected.map(summarise) });
  }

  // (b) Money taken but not yet sent. The destination is resolved when the
  // transfer is made, so these would be paid wherever the listing points later.
  const stuck = unpaidPayouts.filter(onAffected);
  if (stuck.length) {
    blockers.push({
      code: "pending_payouts",
      reservations: stuck.map((r) => ({
        _id: String(r._id),
        accommodationId: String(r.accommodationId?._id || r.accommodationId),
        checkInDate: r.checkInDate || null,
        amountCents: r.hostAmountCents || 0,
        currency: r.currency || DEFAULT_CURRENCY,
      })),
    });
  }

  // (b) Bookings on their way in: accepted or awaiting the host, not paid yet.
  const upcoming = pendingReservations.filter(onAffected);
  if (upcoming.length) {
    blockers.push({
      code: "pending_reservations",
      reservations: upcoming.map((r) => ({
        _id: String(r._id),
        accommodationId: String(r.accommodationId?._id || r.accommodationId),
        checkInDate: r.checkInDate || null,
        status: r.isApproved || "pending",
      })),
    });
  }

  return {
    canRemove: blockers.length === 0,
    blockers,
    isDefault: account.isDefault,
    // For the "set another account as default first" hint.
    otherAccounts: others.map((a) => ({
      accountId: a.accountId,
      label: a.label,
      payoutIban: a.payoutIban,
      ready: isAccountPayoutReady(a),
    })),
    affectedListings: affected.map(summarise),
  };
}
