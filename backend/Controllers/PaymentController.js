// Controllers/paymentController.js
import Reservation from "../models/Reservation.js";
import Accommodation from "../models/Accommodation.js";
import Host from "../models/Host.js";
import ProcessedWebhookEvent from "../models/ProcessedWebhookEvent.js";
import mongoose from "mongoose";
import { format, eachDayOfInterval } from 'date-fns';
import {
  calculateFees,
  buildFeeBreakdown,
  DEFAULT_CURRENCY,
  PAYOUT_DELAY_HOURS,
} from "../config/payments.js";
import {
  getStripe,
  logStripeCall,
  resolveChargeAndFee,
  capturedAmountCents,
  createConnectedAccount,
  prefillExistingAccount,
  describeAccountState,
} from "../utils/stripeHelpers.js";
import { getTransporter, MAIL_FROM, alertAdmin } from "../utils/mailer.js";
import {
  brandShell,
  button,
  callout,
  detailTable,
  esc,
  section,
  heroImage,
  logoAttachments,
} from "../utils/emailLayout.js";
import { hoursSinceCheckIn, toCalendarDateString } from "../utils/timezone.js";
import { getTiersSnapshot, getPolicyNameSnapshot } from "../utils/cancellationPolicy.js";
import { recordReservationForDac7 } from "../utils/dac7.js";
import { holdDates, releaseHold, confirmHold, checkAvailability } from "../utils/calendarHold.js";
import { isHostBookingReady } from "../utils/listingGating.js";
import {
  listPayoutAccounts,
  resolvePayoutAccount,
  isAccountPayoutReady,
  payoutStateOf,
} from "../utils/payoutAccounts.js";
import { missingBillingFieldsOf } from "../utils/hostBilling.js";
import { extrasSummary } from "../utils/pricing.js";
import {
  syncHostFromStripeAccount,
  refreshAllHostStripeAccounts,
  syncListingStatusForHost,
} from "../utils/hostStripeSync.js";
import { formatMoney, formatCents } from "../utils/money.js";
import { payLinkUrl, payLinkBase } from "../utils/payLink.js";
import { payPage, siteUrl } from "../utils/resultPage.js";
import { sendGuestRequestClosedEmail } from "../utils/requestToBookEmails.js";

// Moved to utils/hostStripeSync.js so the booking gate can call it without
// closing an import cycle (listingGating -> PaymentController -> listingGating).
// Re-exported here because this was its public home.
export { syncHostFromStripeAccount };

/**
 * Ensure a reservation carries its cancellation-policy snapshot and cents
 * amount before it can be paid for. Reservations created through older paths
 * (or before this feature existed) get backfilled here — from the listing as it
 * is right now, which is still before the guest has paid anything.
 */
export const ensureBookingSnapshot = async (reservation) => {
  let dirty = false;

  if (!reservation.totalPriceCents) {
    reservation.totalPriceCents = Math.round((Number(reservation.totalPrice) || 0) * 100);
    dirty = true;
  }
  if (!reservation.currency) {
    reservation.currency = DEFAULT_CURRENCY;
    dirty = true;
  }

  if (!reservation.cancellationTiersSnapshot?.length) {
    const listing = await Accommodation.findById(reservation.accommodationId).select(
      "cancellationPolicyType customPolicyTiers"
    );
    reservation.cancellationPolicySnapshot = getPolicyNameSnapshot(listing);
    reservation.cancellationTiersSnapshot = getTiersSnapshot(listing, reservation.checkInDate);
    dirty = true;
  }

  // Expected fees, known before payment so the host can be shown what they get.
  if (reservation.platformFeeCents == null) {
    const { platformFeeCents, hostPayoutCents } = calculateFees(reservation.totalPriceCents);
    reservation.platformFeeCents = platformFeeCents;
    reservation.hostAmountCents = hostPayoutCents;
    dirty = true;
  }

  if (dirty) await reservation.save();
  return reservation;
};

/**
 * Build a Checkout Session for a reservation.
 *
 * THE single place a checkout is created. A second, hand-rolled copy used to
 * live in ReservationController's host-approval flow and had drifted badly: it
 * pinned `payment_method_types: ["card"]` (killing Apple Pay and Google Pay),
 * omitted `payment_intent_data.metadata` (so charge-level webhooks could not
 * identify the booking), skipped the locale mapping, skipped the snapshot
 * backfill, and emitted no audit line at all. Everything now routes here.
 *
 * @param {object} reservation  a Reservation document (mutated and saved)
 * @param {object} context      { language, expiresInHours, reserveDates }
 * @param {boolean} context.reserveDates
 *   Whether to take the dates off the calendar now. True (the default) for a
 *   guest who is about to pay in this browser session. False when a host
 *   accepts a request-to-book: that only MAILS a payment link, and the nights
 *   must stay on the market until the guest actually pays. Availability is
 *   still checked either way — accepting dates somebody else has already
 *   booked is refused.
 * @returns {{ session: object, amountCents: number }}
 */
export const buildCheckoutSession = async (reservation, context = {}) => {
  const stripe = getStripe();

  await ensureBookingSnapshot(reservation);

  const amountCents =
    reservation.totalPriceCents || Math.round((reservation.totalPrice || 0) * 100);
  if (!amountCents || amountCents <= 0) {
    const err = new Error("Invalid amount");
    err.code = "invalid_amount";
    throw err;
  }

  // A disabled Reserve button is cosmetic: it stops a guest clicking, not a
  // direct POST to this endpoint, a stale tab, or a payment link mailed before
  // the host's account lapsed. Refuse here too, so the rule holds wherever the
  // checkout is started from.
  //
  // Unconditional since the ENFORCE_* flags were removed. Taking the money is
  // the irreversible half of this transaction, so the refusal happens BEFORE
  // the calendar hold below, leaving the dates on the market.
  //
  // This is not a duplicate of the listing status check: a listing can be
  // PUBLISHED when the session is created and its host's account restricted by
  // the time the guest pays, and a payment link mailed days ago outlives any
  // check made when it was issued.
  // A host accepting a request may do so before connecting Stripe
  // (`skipPayoutGate`); the guest's money stays on the platform and the payout
  // step refuses with `not_onboarded` until the host connects.
  if (!context.skipPayoutGate) {
    const { host, conflict } = await resolveHostForReservation(reservation);
    if (conflict || !isHostBookingReady(host)) {
      const err = new Error(
        "This property cannot take bookings at the moment — the host has not finished setting up payments."
      );
      err.code = "host_not_payout_ready";
      throw err;
    }
  }

  const language = "en";
  const locale = "en-GB";

  const listingId = String(
    reservation.accommodationId?._id || reservation.accommodationId || ""
  );
  const hostId = reservation.accommodationProvider?.toString() || "";

  // Take the dates before sending the guest to Stripe. Without this the
  // calendar was only written once payment settled, so two guests could be
  // paying for the same nights at the same time.
  //
  // A host accepting a request-to-book opts out (`reserveDates: false`). That
  // path does not send anyone to Stripe — it mails a link the guest may open
  // hours later, or never — so holding the nights would strand them off the
  // market on the strength of an intention. Those dates are written to the
  // calendar by `confirmHold` when the payment actually settles.
  //
  // Availability is still checked in both cases, so a request for nights that
  // are already booked is refused rather than accepted into a conflict.
  const reserveDates = context.reserveDates !== false;
  const hold = reserveDates
    ? await holdDates(reservation)
    : await checkAvailability(reservation);

  if (!hold.ok) {
    const err = new Error(
      hold.reason === "dates_unavailable"
        ? "Those dates have just been taken"
        : "Could not reserve those dates"
    );
    err.code = hold.reason;
    err.conflictDays = hold.conflictDays;
    throw err;
  }

  // A session started from the browser uses Stripe's default lifetime. One that
  // is EMAILED — the payment link a host's approval sends — has to outlive the
  // tab, so the caller can widen the window.
  //
  // Stripe's window is "at least 30 minutes, LESS THAN 24 hours from creation".
  // Both ends are exclusive-ish and measured against when Stripe RECEIVES the
  // request, not when we computed Date.now(), so asking for exactly 24 hours is
  // rejected outright ("The `expires_at` timestamp must be less than 24 hours
  // from Checkout Session creation") — which is what a 24-hour
  // REQUEST_PAYMENT_LINK_HOURS did on every host approval. Clamp to a ceiling
  // that leaves room for request latency and a little clock skew between this
  // server and Stripe's.
  const expiresInHours = Number(context.expiresInHours) || 0;
  const MIN_EXPIRY_SECONDS = 31 * 60; // Stripe's floor is 30 min; sit just above it.
  const MAX_EXPIRY_SECONDS = 24 * 3600 - 5 * 60; // just under Stripe's 24h ceiling.
  const expiresAt = expiresInHours
    ? Math.floor(Date.now() / 1000) +
      Math.min(Math.max(Math.round(expiresInHours * 3600), MIN_EXPIRY_SECONDS), MAX_EXPIRY_SECONDS)
    : undefined;

  const session = await stripe.checkout.sessions.create({
    ...(expiresAt ? { expires_at: expiresAt } : {}),
    // payment_method_types is deliberately omitted. Pinning it to ["card"]
    // disables Apple Pay and Google Pay. Omitting it makes Checkout use whatever
    // is enabled in the Stripe Dashboard, which includes the wallets.
    // (automatic_payment_methods is a PaymentIntent-only param — sending it here
    // would be rejected.)
    mode: "payment",
    locale,
    customer_email: reservation.email,
    line_items: [
      {
        price_data: {
          currency: reservation.currency || DEFAULT_CURRENCY,
          product_data: {
            name: `Reservation #${reservation._id} - ${reservation.name}${reservation.unitName ? ` (${reservation.unitName})` : ""}`,
          },
          unit_amount: amountCents,
        },
        quantity: 1,
      },
    ],
    metadata: {
      reservationId: reservation._id.toString(),
      hostId,
      listingId,
      language,
    },
    // The Checkout Session's metadata does not propagate to the charge, so
    // refund/dispute webhooks (which carry a charge, not a session) could not
    // identify the reservation. Copying it onto the PaymentIntent fixes that.
    payment_intent_data: {
      metadata: {
        reservationId: reservation._id.toString(),
        hostId,
        listingId,
      },
    },
    // An EMAILED link (context.returnBase) comes back to this backend's
    // /pay/:id pages, not the website: those work without the site running,
    // offer "Open in the app" on a phone, and the in-app WebView catches them.
    ...returnUrls(reservation, context.returnBase),
  });

  logStripeCall("checkout.sessions.create", {
    reservationId: reservation._id.toString(),
    amountCents,
    sessionId: session.id,
  });

  reservation.checkoutSessionId = session.id;
  reservation.paymentStatus = "unpaid";
  await reservation.save();

  return { session, amountCents };
};

/** Stripe's return URLs: the website by default, our /pay/:id pages for emailed links. */
const returnUrls = (reservation, returnBase) =>
  returnBase
    ? {
        success_url: `${returnBase}/pay/${reservation._id}/success?session_id={CHECKOUT_SESSION_ID}`,
        cancel_url: `${returnBase}/pay/${reservation._id}/cancelled`,
      }
    : {
        success_url: `${process.env.CLIENT_SITE_URL}/payment-success?session_id={CHECKOUT_SESSION_ID}`,
        cancel_url: `${process.env.CLIENT_SITE_URL}/payment-cancel`,
      };

// Create Stripe Checkout Session (guest pays)
export const createCheckoutSession = async (req, res) => {
  try {
    const { reservationId, language } = req.body;
    if (!reservationId) return res.status(400).json({ error: "reservationId required" });

    // Loaded and access-checked by requireReservationAccess where available.
    const reservation = req.reservation || (await Reservation.findById(reservationId));
    if (!reservation) return res.status(404).json({ error: "Reservation not found" });

    const { session } = await buildCheckoutSession(reservation, { language });

    res.status(200).json({ url: session.url, sessionId: session.id });
  } catch (err) {
    if (err.code === "invalid_amount") {
      return res.status(400).json({ error: "Invalid amount" });
    }
    if (err.code === "dates_unavailable") {
      // 409, not 500: the request was well formed, someone else simply got
      // there first. The client should offer different dates.
      return res.status(409).json({
        error: err.message,
        code: err.code,
        conflictDays: err.conflictDays || [],
      });
    }
    if (err.code === "listing_not_found") {
      return res.status(404).json({ error: "Accommodation not found" });
    }
    // 409, not 400: the request is well formed and the guest did nothing wrong —
    // the listing is simply not in a state where it can be paid for.
    if (err.code === "host_not_payout_ready") {
      return res.status(409).json({ error: err.message, code: err.code });
    }
    console.error("createCheckoutSession error:", err);
    logStripeCall("checkout.sessions.create", { reservationId: req.body?.reservationId }, "error", err);
    res.status(500).json({ error: err.message || "Failed to create session" });
  }
};

// Webhook handler (must run with raw body)
export const handleStripeWebhook = async (req, res) => {
  const sig = req.headers["stripe-signature"];
  let event;
  const stripe = getStripe();

  try {
    // req.body must be raw Buffer (see route setup)
    event = stripe.webhooks.constructEvent(req.body, sig, process.env.STRIPE_WEBHOOK_SECRET);
  } catch (err) {
    console.error("Webhook signature verification failed:", err.message);
    return res.status(400).send(`Webhook Error: ${err.message}`);
  }

  // --- Idempotency ---
  // Claim the event first. The unique index on stripeEventId makes this atomic,
  // so a duplicate delivery (Stripe retries anything that is not 2xx) loses the
  // race and returns early instead of re-running the handler.
  let claim;
  try {
    claim = await ProcessedWebhookEvent.create({
      stripeEventId: event.id,
      eventType: event.type,
      status: "processing",
    });
  } catch (err) {
    if (err?.code === 11000) {
      return res.json({ received: true, duplicate: true });
    }
    console.error("Webhook idempotency claim failed:", err);
    return res.status(500).send();
  }

  try {
    await handleStripeEvent(stripe, event);

    claim.status = "completed";
    claim.processedAt = new Date();
    await claim.save();

    res.json({ received: true });
  } catch (err) {
    console.error("Error processing webhook event:", err);
    logStripeCall("webhook.handle", { eventId: event.id, eventType: event.type }, "error", err);

    // Release the claim so Stripe's retry can genuinely reprocess the event
    // rather than being swallowed as a duplicate.
    try {
      await ProcessedWebhookEvent.deleteOne({ _id: claim._id });
    } catch (cleanupErr) {
      console.error("Failed to release webhook claim:", cleanupErr.message);
    }

    res.status(500).send();
  }
};

/** Event dispatch, split out so the idempotency wrapper stays readable. */
async function handleStripeEvent(stripe, event) {
  switch (event.type) {
    case "checkout.session.completed": {
      const session = event.data.object;
      const reservationId = session.metadata?.reservationId;

      if (!reservationId || !mongoose.Types.ObjectId.isValid(reservationId)) {
        console.warn("checkout.session.completed: reservationId missing or invalid in metadata");
        break;
      }

      await applyPaidCheckoutSession(stripe, session, { source: "webhook" });
      break;
    }

    // Payment never completed: free the dates so the listing is bookable again.
    case "payment_intent.payment_failed": {
      const paymentIntent = event.data.object;
      const reservationId = paymentIntent.metadata?.reservationId;
      if (!reservationId || !mongoose.Types.ObjectId.isValid(reservationId)) break;

      const reservation = await Reservation.findById(reservationId);
      // Never downgrade a booking that has already been paid for.
      if (!reservation || reservation.paymentStatus === "paid") break;

      reservation.paymentStatus = "unpaid";
      reservation.isApproved = "pending";
      await reservation.save();

      await releaseCalendarForReservation(reservation);
      logStripeCall("payment.failed", {
        reservationId,
        reason: paymentIntent.last_payment_error?.message,
      });
      break;
    }

    // The only reliable signal for host onboarding progress.
    case "account.updated": {
      const account = event.data.object;
      await syncHostFromStripeAccount(account);
      break;
    }

    case "charge.refunded": {
      const charge = event.data.object;
      const reservationId =
        charge.metadata?.reservationId ||
        (charge.payment_intent
          ? (await Reservation.findOne({ paymentIntentId: charge.payment_intent }).select("_id"))?._id?.toString()
          : null);

      if (!reservationId) break;

      const refundedCents = Math.round(charge.amount_refunded || 0);
      const totalCents = Math.round(charge.amount || 0);

      await Reservation.findByIdAndUpdate(reservationId, {
        paymentStatus: refundedCents >= totalCents ? "refunded" : "partially_refunded",
        refundAmountCents: refundedCents,
      });

      logStripeCall("refund.confirmed", { reservationId, refundedCents });
      break;
    }

    case "transfer.created": {
      const transfer = event.data.object;
      const reservationId = transfer.metadata?.reservationId;
      if (!reservationId || !mongoose.Types.ObjectId.isValid(reservationId)) break;

      await Reservation.findByIdAndUpdate(reservationId, {
        payoutStatus: "released",
        transferId: transfer.id,
        transferredAt: new Date(),
      });
      logStripeCall("transfer.confirmed", { reservationId, transferId: transfer.id });
      break;
    }

    case "transfer.failed":
    case "transfer.reversed": {
      const transfer = event.data.object;
      const reservationId = transfer.metadata?.reservationId;

      if (reservationId && mongoose.Types.ObjectId.isValid(reservationId)) {
        await Reservation.findByIdAndUpdate(reservationId, {
          payoutStatus: "failed",
          payoutLastError: `Stripe reported ${event.type}`,
        });
      }

      await alertAdmin(`Host payout ${event.type}`, {
        transferId: transfer.id,
        reservationId,
        amount: transfer.amount,
      });
      break;
    }

    case "charge.dispute.created":
    case "charge.dispute.closed": {
      const dispute = event.data.object;
      const reservation = await Reservation.findOne({
        $or: [
          { paymentIntentId: dispute.payment_intent },
          { chargeId: dispute.charge },
        ],
      });

      if (reservation) {
        reservation.disputeId = dispute.id;
        reservation.disputeStatus = dispute.status;
        await reservation.save();
      }

      await alertAdmin(`Dispute ${event.type === "charge.dispute.created" ? "opened" : "closed"}`, {
        disputeId: dispute.id,
        status: dispute.status,
        amount: dispute.amount,
        reservationId: reservation?._id?.toString() || "unmatched",
      });
      break;
    }

    default:
      // Unhandled event types are acknowledged, not retried.
      break;
  }
}

/**
 * Record a settled Checkout Session against its reservation.
 *
 * The webhook is the primary caller. `verifyPayment` also calls it as a
 * reconciliation path, because a webhook can be delayed, misconfigured, or —
 * very commonly in local development — never delivered at all, which would
 * leave a genuinely paid booking showing as unpaid forever.
 *
 * That does NOT make the frontend the source of truth: the amounts are read
 * from Stripe here on the server, never accepted from the client, and the whole
 * operation is idempotent — the reservation write is conditional on the booking
 * not already being paid, and `finalizeReservation` claims atomically, so emails
 * and the calendar update happen exactly once no matter how many callers race.
 *
 * @returns {{ applied: boolean, reason?: string, reservationId?: string }}
 */
export const applyPaidCheckoutSession = async (stripe, session, { source = "webhook" } = {}) => {
  const reservationId = session.metadata?.reservationId;
  if (!reservationId || !mongoose.Types.ObjectId.isValid(reservationId)) {
    return { applied: false, reason: "no_reservation_id" };
  }
  if (session.payment_status !== "paid") {
    return { applied: false, reason: "not_paid", reservationId };
  }

  const paymentIntent = await stripe.paymentIntents.retrieve(session.payment_intent, {
    expand: ["latest_charge.balance_transaction"],
  });

  const { charge, stripeFeeCents } = await resolveChargeAndFee(stripe, paymentIntent);
  const totalAmountCents = capturedAmountCents(paymentIntent);
  const { platformFeeCents, hostPayoutCents } = calculateFees(totalAmountCents, stripeFeeCents);

  // Conditional update: whoever gets here first wins, the rest are no-ops.
  const updated = await Reservation.findOneAndUpdate(
    { _id: reservationId, paymentStatus: { $ne: "paid" } },
    {
      paymentStatus: "paid",
      isApproved: "approved",
      paymentIntentId: paymentIntent.id,
      chargeId: charge ? charge.id : undefined,
      stripeFeeCents,
      platformFeeCents,
      hostAmountCents: hostPayoutCents,
      totalPriceCents: totalAmountCents,
      currency: paymentIntent.currency || DEFAULT_CURRENCY,
      paidAt: new Date(),
    },
    { new: true }
  );

  if (!updated) {
    // Already recorded by the other path. Still make sure finalisation ran —
    // it is claim-guarded, so this is safe and cheap.
    await finalizeReservation(reservationId);
    return { applied: false, reason: "already_paid", reservationId };
  }

  logStripeCall("payment.confirmed", {
    reservationId,
    source,
    totalAmountCents,
    stripeFeeCents,
    platformFeeCents,
    hostPayoutCents,
  });

  // Calendar + confirmation emails, guarded internally.
  await finalizeReservation(reservationId);

  return { applied: true, reservationId };
};

/**
 * GET /api/payments/fee-preview?amountCents=10000
 *
 * The single source of truth for the fee split shown in the UI. The browser
 * never recomputes these numbers — a drift between what a host is shown and
 * what they are actually paid is exactly the kind of bug worth designing out.
 */
export const getFeePreview = async (req, res) => {
  try {
    const amountCents =
      req.query.amountCents != null
        ? Math.round(Number(req.query.amountCents))
        : Math.round((Number(req.query.amount) || 0) * 100);

    if (!Number.isFinite(amountCents) || amountCents < 0) {
      return res.status(400).json({ error: "A non-negative amount is required" });
    }

    res.json(buildFeeBreakdown(amountCents));
  } catch (err) {
    console.error("getFeePreview error:", err);
    res.status(500).json({ error: err.message });
  }
};

/** Remove a reservation's dates from its listing's occupancy calendar. */
export const releaseCalendarForReservation = async (reservation) => {
  try {
    // Drop any checkout hold this booking still owns first — an abandoned or
    // failed payment must not keep the dates off the market.
    await releaseHold(reservation);

    const accommodation = await Accommodation.findById(
      reservation.accommodationId?._id || reservation.accommodationId
    );
    if (!accommodation?.occupancyCalendar?.length) return;

    // Rows this booking owns can be removed precisely, without the range
    // matching below that has to guess which entry belongs to whom.
    const owned = accommodation.occupancyCalendar.filter(
      (entry) => String(entry.reservationId || "") === String(reservation._id)
    );
    if (owned.length) {
      accommodation.occupancyCalendar = accommodation.occupancyCalendar.filter(
        (entry) => String(entry.reservationId || "") !== String(reservation._id)
      );
      await accommodation.save();
      return;
    }

    const booked = new Set(
      eachDayOfInterval({
        start: new Date(reservation.checkInDate),
        end: new Date(reservation.checkOutDate),
      }).map((d) => format(d, "yyyy-MM-dd"))
    );

    // Drop only entries fully covered by this reservation's range, so a manual
    // or imported block that merely overlaps is left untouched.
    accommodation.occupancyCalendar = accommodation.occupancyCalendar.filter((entry) => {
      const range = eachDayOfInterval({
        start: new Date(entry.startDate),
        end: new Date(entry.endDate),
      }).map((d) => format(d, "yyyy-MM-dd"));
      return !range.every((d) => booked.has(d));
    });

    await accommodation.save();
    console.log(`Released calendar dates for reservation ${reservation._id}`);
  } catch (err) {
    console.error("releaseCalendarForReservation error:", err.message);
  }
};

/**
 * Can this platform key still reach the given connected account?
 *
 * Deliberately three-valued, because the two failure modes must not be confused:
 *
 *   true  — the account exists and is ours
 *   false — Stripe positively says otherwise: the account does not exist, or
 *           this key has no access to it. Safe to act on.
 *   null  — we could not find out (outage, rate limit, or a bad API key). NOT a
 *           licence to discard anything. A `StripeAuthenticationError` in
 *           particular means the KEY is wrong, not the account — treating that
 *           as `false` would wipe the stored account id of every host who
 *           happened to press the button during the misconfiguration.
 */
async function isConnectedAccountReachable(stripe, accountId) {
  try {
    await stripe.accounts.retrieve(accountId);
    return true;
  } catch (err) {
    const definitelyGone =
      err?.type === "StripePermissionError" ||
      err?.code === "resource_missing" ||
      err?.code === "account_invalid" ||
      (err?.type === "StripeInvalidRequestError" && err?.statusCode === 403);

    if (definitelyGone) {
      logStripeCall("accounts.retrieve", { accountId, verdict: "unreachable" }, "error", err);
      return false;
    }

    logStripeCall("accounts.retrieve", { accountId, verdict: "unknown" }, "error", err);
    return null;
  }
}

/**
 * GET /api/payments/host/:hostId/stripe-accounts
 *
 * Every connected account this host holds, for the "use an existing account"
 * dropdown. Newest first, because a host who has just connected an account is
 * almost always connecting it FOR the listing they are creating.
 *
 * Returns capability state per account but never the host's tax identity or
 * anything else from the record.
 *
 * `?refresh=1` re-reads every account from the Stripe API first. The payout
 * settings page asks for that, because the stored state is only as current as
 * the last `account.updated` webhook — and a webhook that was never delivered
 * is precisely the case where a host is staring at a status that has been wrong
 * for weeks. It is opt-in so the add-accommodation dropdown, which just needs
 * names to choose between, still costs no Stripe calls at all.
 */
export const listHostStripeAccounts = async (req, res) => {
  try {
    const { hostId } = req.params;
    if (!mongoose.Types.ObjectId.isValid(hostId)) {
      return res.status(400).json({ error: "Invalid hostId" });
    }

    // No `.select()` — `refreshAllHostStripeAccounts` saves the document, and a
    // projected document saves back only what was projected. The previous
    // narrow select was safe only because nothing wrote to it.
    let host = await Host.findById(hostId);
    if (!host) return res.status(404).json({ error: "Host not found" });

    let refreshFailed = [];
    if (req.query.refresh === "1" || req.query.refresh === "true") {
      // The refresh is an ENHANCEMENT, never a precondition. Whatever happens to
      // it, the host still gets the accounts we hold — a Stripe outage, a
      // missing API key or one unreachable account must not collapse into "we
      // couldn't load your payout accounts", which hides working data and names
      // no cause.
      try {
        const result = await refreshAllHostStripeAccounts(host);
        host = result.host || host;
        refreshFailed = result.failed || [];
      } catch (err) {
        console.error("listHostStripeAccounts: refresh failed, serving stored state:", err);
        refreshFailed = listPayoutAccounts(host).map((a) => a.accountId);
      }
    }

    res.json({
      accounts: listPayoutAccounts(host),
      defaultAccountId: host.stripeAccountId || null,
      // Named so the UI can say "we could not reach this one" rather than
      // silently showing stale figures as though they were fresh.
      refreshFailed,
    });
  } catch (err) {
    console.error("listHostStripeAccounts error:", err);
    res.status(500).json({ error: err.message });
  }
};

/**
 * POST /api/payments/host/account-link
 *
 * A fresh Stripe onboarding link for ONE named account.
 *
 * This is the gap that made a restricted account a dead end. The only way back
 * into Stripe was `create-express-account`, which always acts on
 * `host.stripeAccountId` — so a host whose SECOND account needed a document had
 * no route to it anywhere in the product. They could see "action needed" and do
 * nothing about it.
 *
 * The link type is chosen from what the account actually needs:
 *   `account_onboarding` while requirements are outstanding — the guided form
 *   `account_update`     once there are none — Stripe rejects `account_onboarding`
 *                        for a completed account, and the host may still want to
 *                        change their bank details
 */
export const createStripeAccountLink = async (req, res) => {
  try {
    const { hostId, accountId, returnTo } = req.body || {};
    if (!hostId || !mongoose.Types.ObjectId.isValid(hostId)) {
      return res.status(400).json({ error: "Valid hostId required" });
    }
    if (!accountId) return res.status(400).json({ error: "accountId required" });

    const host = await Host.findById(hostId);
    if (!host) return res.status(404).json({ error: "Host not found" });

    // Refuse an account this host does not hold. Without it, possession of any
    // acct_ id would mint an onboarding link into a stranger's account.
    const accounts = listPayoutAccounts(host);
    if (!accounts.some((a) => a.accountId === accountId)) {
      return res.status(400).json({
        error: "That payout account does not belong to this host.",
        code: "unknown_account",
      });
    }

    const stripe = getStripe();

    // Ask Stripe rather than trusting the cached row: the whole point of this
    // button is that the host thinks something is outstanding, and the cache is
    // exactly what may be wrong.
    let state = null;
    let prefillSource = null;
    try {
      const account = await stripe.accounts.retrieve(accountId);
      prefillSource = account;
      state = describeAccountState(account);
      await syncHostFromStripeAccount({
        ...account,
        metadata: { ...(account.metadata || {}), host_id: host._id.toString() },
      });
    } catch (err) {
      // A link is still worth minting — accountLinks.create will fail loudly
      // below if the account is genuinely unreachable.
      logStripeCall("accounts.retrieve", { hostId, accountId }, "error", err);
    }

    // Outside the try above on purpose: a failed status sync must not also cost
    // the host their prefill. Same rule as at creation: company details on any
    // account, personal details only on the default one. Never throws, and
    // retrieves the account itself if the read above failed.
    await prefillExistingAccount(stripe, host, prefillSource ?? accountId, {
      personalIdentity: accountId === host.stripeAccountId,
    });

    const type =
      state && !state.actionRequired && state.state === "active"
        ? "account_update"
        : "account_onboarding";

    const safeReturn =
      typeof returnTo === "string" && returnTo.startsWith("/") ? returnTo : "";
    const accountLink = await stripe.accountLinks.create({
      account: accountId,
      ...onboardReturnUrls(req, { accountId, returnTo: safeReturn }),
      type,
    });

    logStripeCall("accountLinks.create", { hostId, accountId, type });

    res.json({ onboardingUrl: accountLink.url, accountId, type });
  } catch (err) {
    console.error("createStripeAccountLink error:", err);
    logStripeCall("accountLinks.create", { hostId: req.body?.hostId }, "error", err);

    if (err?.type === "StripeInvalidRequestError") {
      return res
        .status(400)
        .json({ error: err.message, code: err.code || "stripe_invalid_request" });
    }
    res.status(500).json({ error: err.message });
  }
};

/**
 * POST /api/payments/host/dashboard-link
 *
 * A single-use link into the host's Stripe Express dashboard for ONE of their
 * accounts — where payouts land and balances are visible. Only works once the
 * account has submitted its details; before that the host needs the onboarding
 * link instead.
 */
export const createStripeDashboardLink = async (req, res) => {
  try {
    const { hostId, accountId } = req.body || {};
    if (!hostId || !mongoose.Types.ObjectId.isValid(hostId)) {
      return res.status(400).json({ error: "Valid hostId required" });
    }
    if (!accountId) return res.status(400).json({ error: "accountId required" });

    const host = await Host.findById(hostId);
    if (!host) return res.status(404).json({ error: "Host not found" });

    // Same ownership guard as createStripeAccountLink: no login links into strangers' accounts.
    if (!listPayoutAccounts(host).some((a) => a.accountId === accountId)) {
      return res.status(400).json({
        error: "That payout account does not belong to this host.",
        code: "unknown_account",
      });
    }

    const loginLink = await getStripe().accounts.createLoginLink(accountId);
    logStripeCall("accounts.createLoginLink", { hostId, accountId });
    res.json({ url: loginLink.url });
  } catch (err) {
    console.error("createStripeDashboardLink error:", err);
    logStripeCall("accounts.createLoginLink", { hostId: req.body?.hostId }, "error", err);
    if (err?.type === "StripeInvalidRequestError") {
      return res.status(400).json({ error: err.message, code: err.code || "stripe_invalid_request" });
    }
    res.status(500).json({ error: err.message });
  }
};

/**
 * POST /api/payments/host/default-account
 *
 * Which of the host's accounts every listing that names none falls back to.
 *
 * A host who holds several needs to be able to say so: the first account they
 * ever connected became the default automatically, and if that is the one they
 * have stopped using, every listing they have not explicitly repointed is still
 * paying into it.
 *
 * Changing the default changes which account those listings pay, so their
 * statuses are recomputed here rather than waiting for the next webhook — the
 * host should not have to wonder why a listing went quiet.
 */
export const setDefaultStripeAccount = async (req, res) => {
  try {
    const { hostId, accountId } = req.body || {};
    if (!hostId || !mongoose.Types.ObjectId.isValid(hostId)) {
      return res.status(400).json({ error: "Valid hostId required" });
    }
    if (!accountId) return res.status(400).json({ error: "accountId required" });

    const host = await Host.findById(hostId);
    if (!host) return res.status(404).json({ error: "Host not found" });

    const accounts = listPayoutAccounts(host);
    const target = accounts.find((a) => a.accountId === accountId);
    if (!target) {
      return res.status(400).json({
        error: "That payout account does not belong to this host.",
        code: "unknown_account",
      });
    }

    host.stripeAccountId = accountId;

    // The top-level fields mirror the DEFAULT account, so they have to move with
    // it. Leaving them behind would report the old account's readiness under the
    // new account's id — the one combination that can wave a transfer through to
    // an account Stripe has not enabled.
    host.chargesEnabled = Boolean(target.chargesEnabled);
    host.payoutsEnabled = Boolean(target.payoutsEnabled);
    host.stripeTransfersActive = target.transfersActive;
    host.onboardingComplete = isAccountPayoutReady(target);
    host.stripeRequirementsDue = target.requirementsDue || [];
    host.stripePastDue = target.pastDue || [];
    host.stripeDisabledReason = target.disabledReason || undefined;
    host.stripePayoutState = payoutStateOf(target);
    host.payoutIban = target.payoutIban || host.payoutIban;
    host.stripeStatusUpdatedAt = new Date();

    await host.save();

    const statusResult = await syncListingStatusForHost(host);

    logStripeCall("account.default_changed", {
      hostId: host._id.toString(),
      accountId,
      listingsUpdated: statusResult.updated,
    });

    res.json({
      defaultAccountId: host.stripeAccountId,
      accounts: listPayoutAccounts(host),
      listingsUpdated: statusResult.updated,
    });
  } catch (err) {
    console.error("setDefaultStripeAccount error:", err);
    res.status(500).json({ error: err.message });
  }
};

/**
 * POST /api/payments/host/connect-account
 *
 * Connect an ADDITIONAL account, alongside any the host already holds.
 *
 * Distinct from createHostExpressAccount below, which deliberately reuses the
 * existing account so a retry does not orphan it. Here a new account is the
 * point: a host with an apartment in their own name and a chalet under a
 * company needs two, and reusing the first would defeat the request.
 *
 * `returnTo` comes back on the onboarding return URL so the host lands where
 * they started — the add-accommodation form, with everything still filled in.
 */
export const connectAdditionalStripeAccount = async (req, res) => {
  try {
    const { hostId, country, email, label, returnTo } = req.body;
    if (!hostId) return res.status(400).json({ error: "hostId required" });
    if (!mongoose.Types.ObjectId.isValid(hostId)) {
      return res.status(400).json({ error: "Invalid hostId" });
    }

    const stripe = getStripe();
    const host = await Host.findById(hostId);
    if (!host) return res.status(404).json({ error: "Host not found" });

    // Both connect paths build the account the same way — see
    // utils/stripeHelpers.js -> connectedAccountCreateParams for why it requests
    // `transfers` only and leaves `business_type` for the host to declare. This
    // used to be a second, subtly different copy of the payload, which is how
    // one path could be fixed and the other left restricting accounts.
    //
    // The host's company details are prefilled on every account: they lock
    // nothing, only apply if the host picks "Company" in Stripe, and stay
    // editable. Personal details and `business_type` only on the FIRST account
    // (the panel's "Connect Stripe account" button comes through here even for
    // a host with none), since that one is the host's own. A later account may
    // be someone else's, and a prefilled `business_type` cannot be undone
    // inside the Express form.
    const isFirstAccount = listPayoutAccounts(host).length === 0;
    const account = await createConnectedAccount(stripe, host, {
      country,
      email,
      prefillIdentity: true,
      personalIdentity: isFirstAccount,
    });

    host.stripeAccounts = host.stripeAccounts || [];
    host.stripeAccounts.push({
      accountId: account.id,
      label: (label || "").trim().slice(0, 60),
      connectedAt: new Date(),
    });
    // The first account a host connects becomes the default every listing falls
    // back to. Later ones do not steal that role — a host adding a second
    // account for one property must not silently repoint the others.
    if (!host.stripeAccountId) host.stripeAccountId = account.id;
    await host.save();

    logStripeCall("accounts.create", {
      hostId: host._id.toString(),
      accountId: account.id,
      additional: true,
    });

    // Account Links expire within minutes — always mint a fresh one.
    const safeReturn = typeof returnTo === "string" && returnTo.startsWith("/") ? returnTo : "";
    const accountLink = await stripe.accountLinks.create({
      account: account.id,
      ...onboardReturnUrls(req, { accountId: account.id, returnTo: safeReturn }),
      type: "account_onboarding",
    });

    res.json({ onboardingUrl: accountLink.url, accountId: account.id });
  } catch (err) {
    console.error("connectAdditionalStripeAccount error:", err);
    logStripeCall("accounts.create", { hostId: req.body?.hostId }, "error", err);

    if (err?.type === "StripeInvalidRequestError") {
      return res.status(400).json({ error: err.message, code: err.code || "stripe_invalid_request" });
    }
    res.status(500).json({ error: err.message });
  }
};

// Create Host Express account and return onboarding link
export const createHostExpressAccount = async (req, res) => {
  try {
    const { hostId, country, email } = req.body;
    if (!hostId) return res.status(400).json({ error: "hostId required" });
    if (!mongoose.Types.ObjectId.isValid(hostId)) {
      return res.status(400).json({ error: "Invalid hostId" });
    }

    const stripe = getStripe();

    const host = await Host.findById(hostId);
    if (!host) return res.status(404).json({ error: "Host not found" });

    // Reuse the existing connected account instead of orphaning it on a retry.
    let accountId = host.stripeAccountId;

    // ...but only if this platform key can still reach it. A stored acct_ id
    // becomes unreachable when the platform's Stripe account or API key changes
    // (test vs live, or a different Stripe account entirely) — the id stays on
    // the host document and points at an account this key has no access to.
    //
    // Without this check the handler skipped creation, went straight to
    // accountLinks.create with a dead id, and Stripe threw — surfacing as a 500
    // on "Continue onboarding" that the host could never get past, because every
    // retry took the same branch.
    if (accountId) {
      const reachable = await isConnectedAccountReachable(stripe, accountId);

      if (reachable === false) {
        // Provably gone, not a blip: drop it and onboard afresh below. The id is
        // kept in history — it may still exist under whichever platform created
        // it, and this is the only trace that it was once this host's.
        host.stripeAccountIdHistory = [
          ...(host.stripeAccountIdHistory || []),
          {
            accountId,
            discardedAt: new Date(),
            reason: "unreachable_with_current_platform_key",
          },
        ];
        host.stripeAccountId = undefined;
        // These cached flags described the OLD account. Leaving them true would
        // let the payout gate wave through a transfer to an account that is no
        // longer ours.
        host.chargesEnabled = false;
        host.payoutsEnabled = false;
        host.onboardingComplete = false;
        host.stripeRequirementsDue = [];
        host.stripeStatusUpdatedAt = new Date();
        await host.save();

        accountId = null;

        console.warn(
          `[stripe] host ${host._id} had unreachable account ${host.stripeAccountIdHistory.at(-1).accountId} — creating a new one`
        );
        await alertAdmin("Host Stripe account was unreachable — re-onboarding", {
          hostId: host._id.toString(),
          discardedAccountId: host.stripeAccountIdHistory.at(-1).accountId,
          hint:
            "The stored acct_ id is not accessible with the current STRIPE_SECRET_KEY. " +
            "This is expected if the platform Stripe account or key changed; if it was not " +
            "supposed to change, fix the key BEFORE more hosts re-onboard.",
        });
      }
      // reachable === null means Stripe could not be asked (network/outage).
      // Fall through and use the existing id: refusing or recreating on an
      // unknown is how a working account gets orphaned by a transient failure.
    }

    if (!accountId) {
      // The connected account's country is Putko's own jurisdiction by default,
      // NOT the host's `countryCode`.
      //
      // That field is free-text profile data and holds values that have nothing
      // to do with where the host can legally be paid — "PAKISTAN", "PA" — and
      // driving account creation from it produced "PA is not currently supported
      // by Stripe" on a button the host had no way to get past. Validating the
      // shape locally does not help either: "PA" is a perfectly well-formed ISO
      // code that Stripe simply does not support, so only Stripe can rule on it.
      //
      // An explicit `country` in the request body still wins, for the case where
      // a genuinely non-Slovak host is being onboarded deliberately. Anything
      // Stripe rejects comes back as its own 400 via the handler below, which
      // states the actual reason.
      //
      // The payload itself is shared with connectAdditionalStripeAccount — see
      // utils/stripeHelpers.js -> connectedAccountCreateParams.
      //
      // The host's first account is theirs, so their billing details (name,
      // address, phone, IČO…) are prefilled into Stripe's onboarding form. A
      // resumed account gets the gentler top-up in the else branch below.
      const account = await createConnectedAccount(stripe, host, {
        country,
        email,
        prefillIdentity: true,
      });

      accountId = account.id;
      host.stripeAccountId = accountId;
      await host.save();

      logStripeCall("accounts.create", { hostId: host._id.toString(), accountId });
    } else {
      // Resuming an account created before prefill existed, or one the host
      // abandoned half-way: top up whatever it is still missing. Only empty
      // fields are touched and it never throws — see prefillExistingAccount.
      await prefillExistingAccount(stripe, host, accountId);
    }

    // Account Links expire within minutes — always mint a fresh one, never persist.
    const accountLink = await stripe.accountLinks.create({
      account: accountId,
      ...onboardReturnUrls(req, { accountId }),
      type: "account_onboarding",
    });

    res.json({ onboardingUrl: accountLink.url, accountId });
  } catch (err) {
    console.error("createHostExpressAccount error:", err);
    logStripeCall("accounts.create", { hostId: req.body?.hostId }, "error", err);

    // A rejected request is the caller's problem to fix, not a server fault, and
    // saying which is the difference between an actionable message and a 500
    // that looks like the site is broken. Stripe's own text is used verbatim —
    // it names the offending parameter, which is exactly what is needed here.
    if (err?.type === "StripeInvalidRequestError") {
      return res.status(400).json({ error: err.message, code: err.code || "stripe_invalid_request" });
    }

    res.status(500).json({ error: err.message });
  }
};

/**
 * Verify onboarding against the Stripe API rather than trusting the return_url.
 * Called when the host lands back on the site; account.updated covers the rest.
 */
export const refreshHostStripeStatus = async (req, res) => {
  try {
    const { hostId } = req.body;
    if (!hostId || !mongoose.Types.ObjectId.isValid(hostId)) {
      return res.status(400).json({ error: "Valid hostId required" });
    }

    const host = await Host.findById(hostId);
    if (!host) return res.status(404).json({ error: "Host not found" });

    // Billing is Putko's own record and has nothing to do with Stripe, so it is
    // reported on every path — including the two below that never reach the API.
    // Previously the no-account path returned `{ onboardingComplete: false }`
    // alone and the error path returned a 500, so a host without a connected
    // account (or with a broken one) got no billing answer at all.
    const billingOf = (doc) => {
      const missing = missingBillingFieldsOf(doc);
      return { billing: { complete: missing.length === 0, missing }, missingBillingFields: missing };
    };

    if (!host.stripeAccountId) {
      return res.json({
        onboardingComplete: false,
        reason: "no_stripe_account",
        payoutState: "not_connected",
        payoutDelayHours: PAYOUT_DELAY_HOURS,
        ...billingOf(host),
      });
    }

    const stripe = getStripe();

    let updated = null;
    try {
      const account = await stripe.accounts.retrieve(host.stripeAccountId);
      updated = await syncHostFromStripeAccount(account);
    } catch (err) {
      // A stored account this key cannot reach (see createHostExpressAccount)
      // used to 500 here, which took the whole payments page's status refresh
      // down with it — including the billing answer, which Stripe has no say in.
      // Report what is cached instead and let the host get on with onboarding.
      logStripeCall("accounts.retrieve", { hostId, accountId: host.stripeAccountId }, "error", err);
      return res.json({
        onboardingComplete: false,
        reason: "stripe_account_unreachable",
        chargesEnabled: false,
        payoutsEnabled: false,
        transfersActive: false,
        payoutState: "pending",
        requirementsDue: [],
        payoutDelayHours: PAYOUT_DELAY_HOURS,
        ...billingOf(host),
      });
    }

    // `syncHostFromStripeAccount` returns null when no Host matches the account.
    // Falling back to the record we already loaded matters for the billing block:
    // `null?.missingBillingFields?.() || []` reported an empty list, i.e. "billing
    // complete", which is the one direction this must never fail in.
    const current = updated || host;
    const defaultAccount = listPayoutAccounts(current).find((a) => a.isDefault);

    res.json({
      onboardingComplete: Boolean(current.onboardingComplete),
      chargesEnabled: Boolean(current.chargesEnabled),
      payoutsEnabled: Boolean(current.payoutsEnabled),
      transfersActive: Boolean(current.stripeTransfersActive),
      requirementsDue: current.stripeRequirementsDue || [],
      // Everything the host needs to tell "still filling in the form" apart
      // from "Stripe has restricted this account", which the old response could
      // not express at all — both arrived as onboardingComplete: false with an
      // empty requirements list.
      payoutState: payoutStateOf(defaultAccount),
      pastDue: current.stripePastDue || [],
      disabledReason: current.stripeDisabledReason || null,
      pendingVerification: defaultAccount?.pendingVerification || [],
      requirementErrors: defaultAccount?.requirementErrors || [],
      currentDeadline: defaultAccount?.currentDeadline || null,
      futureDue: defaultAccount?.futureDue || [],
      futureDeadline: defaultAccount?.futureDeadline || null,
      // So the UI's lock window matches the one the backend actually enforces.
      payoutDelayHours: PAYOUT_DELAY_HOURS,
      ...billingOf(current),
    });
  } catch (err) {
    console.error("refreshHostStripeStatus error:", err);
    res.status(500).json({ error: err.message });
  }
};

/**
 * Resolve the Host that owns a reservation.
 *
 * `accommodationProvider` was declared as ref 'User' but is populated with a
 * Host id, while other code paths resolve the host via the listing's `userId`.
 * Both are tried here, and a mismatch is reported rather than silently paying
 * the wrong account.
 *
 * `payoutIbanFull` is declared `select: false` on the schema, so it is absent
 * unless asked for by name. Every DAC7 write goes through this function, and
 * without the `+` it read as undefined — so `dac7.js` fell through to Stripe's
 * masked `SK****1234` for every host, including those who had supplied their
 * real IBAN, and filed the mask as the seller's financial account identifier.
 *
 * The value stays server-side: all three callers use the host locally (payout,
 * refund recording, DAC7 rebuild) and none of them serialise it into a response.
 */
const HOST_WITH_IBAN = "+payoutIbanFull";

export const resolveHostForReservation = async (reservation) => {
  const direct = reservation.accommodationProvider
    ? await Host.findById(reservation.accommodationProvider).select(HOST_WITH_IBAN)
    : null;

  const listing = await Accommodation.findById(
    reservation.accommodationId?._id || reservation.accommodationId
  ).select("userId");

  const viaListing = listing?.userId
    ? await Host.findById(listing.userId).select(HOST_WITH_IBAN)
    : null;

  if (direct && viaListing && String(direct._id) !== String(viaListing._id)) {
    await alertAdmin("Host mismatch on reservation — payout blocked", {
      reservationId: reservation._id.toString(),
      accommodationProvider: String(direct._id),
      listingOwner: String(viaListing._id),
    });
    return { host: null, conflict: true };
  }

  return { host: direct || viaListing, conflict: false };
};

/**
 * How old a cached Stripe account status may be before a payout refusal
 * re-checks it against the API. Short enough that a host who has just finished
 * onboarding can withdraw immediately; long enough that the nightly sweep does
 * not make one API call per booking.
 */
const STRIPE_STATUS_MAX_AGE_MS = 5 * 60 * 1000;

/**
 * Core payout. Shared by the manual endpoint and the daily sweep so both apply
 * exactly the same eligibility rules.
 *
 * @returns {{ ok: boolean, code?: string, error?: string, transferId?: string }}
 */
export const payoutReservation = async (reservation, { force = false, requireBillingDetails = false } = {}) => {
  const stripe = getStripe();

  if (reservation.paymentStatus !== "paid") {
    return { ok: false, code: "not_paid", error: "Reservation not paid" };
  }
  if (reservation.payoutStatus === "released" || reservation.transferId) {
    return { ok: false, code: "already_released", error: "Payout already released" };
  }
  if (reservation.isApproved === "cancelled") {
    return { ok: false, code: "cancelled", error: "Reservation is cancelled" };
  }
  if (reservation.refundAmountCents > 0) {
    return { ok: false, code: "refunded", error: "Reservation has been refunded" };
  }

  // Hold window: PAYOUT_DELAY_HOURS after check-in, measured in the business
  // timezone. Previously the backend released from check-in 00:00 while the UI
  // implied check-in + 24 h, so the backend was the more permissive of the two.
  if (!force) {
    const elapsed = hoursSinceCheckIn(reservation.checkInDate);
    if (elapsed < PAYOUT_DELAY_HOURS) {
      return {
        ok: false,
        code: "locked",
        error: `Payout unlocks ${PAYOUT_DELAY_HOURS}h after check-in (${PAYOUT_DELAY_HOURS - elapsed}h remaining)`,
      };
    }
  }

  const { host, conflict } = await resolveHostForReservation(reservation);
  if (conflict) {
    return { ok: false, code: "host_conflict", error: "Host record conflict — escalated to admin" };
  }
  if (!host?.stripeAccountId) {
    return { ok: false, code: "not_onboarded", error: "Host not onboarded for payouts" };
  }

  // WHICH of the host's connected accounts this booking pays. A host may run a
  // separate account per property, so the destination is a property of the
  // LISTING, not of the host — paying the host default here would quietly send
  // a chalet's takings to the account that belongs to their apartment.
  const payoutListing = await Accommodation.findById(
    reservation.accommodationId?._id || reservation.accommodationId
  ).select("payoutStripeAccountId");
  const payoutAccount = resolvePayoutAccount(payoutListing, host);

  if (!payoutAccount?.accountId) {
    return { ok: false, code: "not_onboarded", error: "Host not onboarded for payouts" };
  }

  // Putko deducts its intermediary fee from this payout and must issue a Slovak
  // VAT invoice for that fee. Without the host's IČO, DIČ and billing address the
  // monthly run cannot raise one — utils/invoiceJob.js records
  // `missing_host_billing_details` and gives up — so paying out first means
  // having taken a fee that can never be invoiced.
  //
  // Only the manual Withdraw button enforces this, which is where the host is
  // standing in front of a form that can fix it. The daily sweep deliberately
  // does NOT pass the flag: hard-blocking it would strand the money of every
  // existing host who has not yet filled these fields in, with nobody watching
  // the cron log to notice. That mirrors the opt-in stance in
  // utils/listingGating.js, and should be tightened once hosts are migrated.
  if (requireBillingDetails) {
    const missingBilling = host.missingBillingFields?.() || [];
    if (missingBilling.length) {
      return {
        ok: false,
        code: "billing_incomplete",
        error: "Host billing details are incomplete",
        missingBillingFields: missingBilling,
      };
    }
  }

  // `payoutsEnabled` is a CACHE of what Stripe last told us, refreshed by the
  // account.updated webhook and by the host opening their payouts page. Neither
  // is guaranteed: if the webhook is not configured (several hosts have
  // stripeStatusUpdatedAt unset), a host who finished onboarding stays blocked
  // here forever, pressing Withdraw and being told to finish onboarding they
  // already finished.
  //
  // So a refusal is never issued on stale data — ask Stripe first. Bounded by a
  // staleness window so the nightly sweep does not re-fetch every host it sees.
  // Checked against THIS booking's destination account, not the host's default.
  // With several accounts a host-level `payoutsEnabled` says nothing about the
  // one the money is actually going to — a verified default would wave through
  // a transfer to a second account Stripe has not enabled.
  //
  // Judged with `isAccountPayoutReady`, the same rule the listing gate and the
  // payouts page apply. It used to test `payoutsEnabled` alone, which is LOOSER
  // than every other gate in the system: an account can have payouts enabled
  // while its `transfers` capability is inactive, and this would then attempt a
  // transfer Stripe was always going to reject — surfacing to the host as a
  // failed withdrawal rather than as the "still verifying" they are shown
  // everywhere else.
  let destination = payoutAccount;
  if (!isAccountPayoutReady(destination)) {
    const lastSync = new Date(destination.statusUpdatedAt || 0).getTime();
    const isStale = Date.now() - lastSync > STRIPE_STATUS_MAX_AGE_MS;

    if (isStale) {
      try {
        const account = await stripe.accounts.retrieve(destination.accountId);
        const refreshed = await syncHostFromStripeAccount(account);
        if (refreshed) {
          Object.assign(host, refreshed.toObject ? refreshed.toObject() : refreshed);
          destination = resolvePayoutAccount(payoutListing, host) || destination;
        }
      } catch (err) {
        // A Stripe outage must not turn into a confusing payout error; fall
        // through and refuse on what we know, having logged why.
        logStripeCall(
          "accounts.retrieve",
          { hostId: host._id.toString(), accountId: destination.accountId },
          "error",
          err
        );
      }
    }

    if (!isAccountPayoutReady(destination)) {
      // A restricted account and an unfinished one need different instructions,
      // so they no longer collapse into one message.
      const restricted = payoutStateOf(destination) === "restricted";

      return {
        ok: false,
        code: restricted ? "account_restricted" : "payouts_disabled",
        error: restricted
          ? "Stripe has restricted the account this booking pays out to"
          : "Host's Stripe account cannot receive payouts yet",
        // What Stripe is actually still waiting for, so the host can be told
        // rather than left guessing. `past_due` first — those are the ones
        // already holding the money up.
        requirementsDue: [
          ...(destination.pastDue || []),
          ...(destination.requirementsDue || []).filter(
            (r) => !(destination.pastDue || []).includes(r)
          ),
        ],
        disabledReason: destination.disabledReason || null,
        accountId: destination.accountId,
      };
    }
  }

  const amount = Math.round(reservation.hostAmountCents || 0);
  if (!amount || amount <= 0) {
    return { ok: false, code: "no_amount", error: "No payout amount available" };
  }

  try {
    const transfer = await stripe.transfers.create(
      {
        amount,
        currency: reservation.currency || DEFAULT_CURRENCY,
        // The listing's own account, resolved above — never the host default
        // unless the listing named none.
        destination: destination.accountId,
        metadata: { reservationId: reservation._id.toString() },
      },
      {
        // Deterministic: a retry with the same key returns the ORIGINAL transfer
        // instead of creating a second one. The previous key embedded Date.now(),
        // which made every retry a fresh key and therefore a fresh payout.
        idempotencyKey: `transfer_booking_${reservation._id}`,
      }
    );

    reservation.transferId = transfer.id;
    reservation.payoutStatus = "released";
    reservation.transferredAt = new Date();
    reservation.payoutLastError = undefined;
    await reservation.save();

    logStripeCall("transfers.create", {
      reservationId: reservation._id.toString(),
      // Both forms: cents is what Stripe was actually sent, the formatted value
      // is so nobody reading a console mistakes 6357 for a wrong figure.
      amount: `${(amount / 100).toFixed(2)} ${(reservation.currency || DEFAULT_CURRENCY).toUpperCase()}`,
      amountCents: amount,
      transferId: transfer.id,
    });

    // Keep the annual DAC7 aggregate current instead of reconstructing it at
    // the 31 January deadline.
    await recordReservationForDac7(reservation, host);

    return { ok: true, transferId: transfer.id };
  } catch (err) {
    reservation.payoutAttempts = (reservation.payoutAttempts || 0) + 1;
    reservation.payoutLastAttemptAt = new Date();
    reservation.payoutLastError = err.message;

    if (err.code === "balance_insufficient") {
      // Stripe reports the same error code for two very different situations,
      // and telling them apart matters: one clears itself, the other never does.
      //
      //   a) The money is still settling. Retrying tomorrow works.
      //   b) The platform holds NO balance in the transfer's currency at all —
      //      e.g. a GBP Stripe account being asked to send EUR. No amount of
      //      waiting fixes that, so promising the host "a few days" is a lie and
      //      the daily sweep would retry it forever.
      const currency = (reservation.currency || DEFAULT_CURRENCY).toLowerCase();
      let holdsCurrency = true;
      let balanceSummary = null;

      try {
        const balance = await stripe.balance.retrieve();
        const inCurrency = (list) => list.find((b) => b.currency === currency);
        holdsCurrency = Boolean(inCurrency(balance.available) || inCurrency(balance.pending));
        balanceSummary = {
          requestedCurrency: currency,
          available: balance.available.map((b) => `${b.currency.toUpperCase()} ${(b.amount / 100).toFixed(2)}`),
          pending: balance.pending.map((b) => `${b.currency.toUpperCase()} ${(b.amount / 100).toFixed(2)}`),
        };
      } catch (balanceErr) {
        logStripeCall("balance.retrieve", { reservationId: reservation._id.toString() }, "error", balanceErr);
      }

      // Amounts are sent to Stripe in the smallest currency unit (6357 = EUR
      // 63.57) and stored that way throughout — never floats. Logs and alerts
      // additionally carry the formatted value, because reading bare cents off a
      // console is how "6357" gets mistaken for a wrong figure.
      const formatted = `${(amount / 100).toFixed(2)} ${currency.toUpperCase()}`;

      if (!holdsCurrency) {
        // A configuration problem, not a timing one. Mark it failed so the sweep
        // stops retrying, and tell the admin exactly what the mismatch is.
        reservation.payoutStatus = "failed";
        reservation.payoutLastError = `No ${currency.toUpperCase()} balance on the platform account — cannot fund a ${currency.toUpperCase()} transfer`;
        await reservation.save();

        await alertAdmin("Payout blocked: platform holds no balance in the payout currency", {
          reservationId: reservation._id.toString(),
          amount: formatted,
          amountCents: amount,
          host: host._id.toString(),
          ...balanceSummary,
          hint: "The UK Stay Hub Stripe account settles in a different currency than the bookings. Transfers can only be funded from a balance in the same currency.",
        });

        logStripeCall(
          "transfers.create",
          { reservationId: reservation._id.toString(), ...balanceSummary },
          "error",
          err
        );

        return {
          ok: false,
          code: "balance_currency_mismatch",
          error: `The platform Stripe account holds no ${currency.toUpperCase()} balance, so a ${currency.toUpperCase()} payout cannot be funded.`,
          retryable: false,
          balance: balanceSummary,
        };
      }

      // Recoverable: the platform balance will refill. Leave the reservation
      // eligible so the next sweep retries it, but make the failure loud.
      await reservation.save();
      await alertAdmin("Insufficient Stripe balance for payout", {
        reservationId: reservation._id.toString(),
        amount: formatted,
        amountCents: amount,
        host: host._id.toString(),
        ...balanceSummary,
      });
      logStripeCall("transfers.create", { reservationId: reservation._id.toString() }, "error", err);
      return { ok: false, code: "balance_insufficient", error: err.message, retryable: true };
    }

    reservation.payoutStatus = "failed";
    await reservation.save();
    logStripeCall("transfers.create", { reservationId: reservation._id.toString() }, "error", err);
    throw err;
  }
};

// Release payout to host (transfer)
/**
 * Host-facing wording for each payout refusal.
 *
 * Stripe's own messages are written for developers — `balance_insufficient`
 * arrives as "You have insufficient available funds in your Stripe account. Try
 * adding funds ... using the 4000000000000077 test card", which is meaningless
 * and alarming to a host who just pressed Withdraw. The technical detail stays
 * in the audit log and the admin alert; the host is told what it means for them.
 */
const PAYOUT_MESSAGES = {
  not_paid: "This booking has not been paid for yet.",
  already_released: "This payout has already been sent.",
  cancelled: "This booking was cancelled, so there is nothing to pay out.",
  refunded: "This booking was refunded, so there is nothing to pay out.",
  locked: null, // payoutReservation already returns a precise, friendly message
  not_onboarded: "Finish connecting your Stripe account before withdrawing.",
  payouts_disabled:
    "Stripe has not enabled payouts on your account yet. This usually means a verification step is still outstanding.",
  account_restricted:
    "Stripe has restricted the account this booking pays out to. Open your payout settings to see what it still needs.",
  host_conflict: "We could not confirm who owns this booking. Our team has been notified.",
  // Actionable by the host, and the UI reopens the billing form on this code —
  // so it says what is needed, not just that something is missing.
  billing_incomplete:
    "We need your billing details (IČO, DIČ and address) before releasing this payout. They go on the monthly invoice we issue you for the platform fee.",
  no_amount: "There is no payout amount recorded against this booking.",
  balance_insufficient:
    "Your payout is queued. The funds from this booking are still settling with Stripe — it will be released automatically, usually within a few days.",
  // Deliberately not phrased as "try again later": nothing about waiting fixes a
  // currency mismatch, and telling the host otherwise would have them pressing
  // Withdraw for days.
  balance_currency_mismatch:
    "This payout cannot be sent yet because of a currency setup issue on our side. Our team has been notified — you do not need to do anything.",
};

export const releasePayoutToHost = async (req, res) => {
  try {
    const { reservationId } = req.body;
    if (!reservationId) {
      return res.status(400).json({ error: "reservationId required" });
    }
    if (!mongoose.Types.ObjectId.isValid(reservationId)) {
      return res.status(400).json({ error: "Invalid reservationId" });
    }

    // Loaded and access-checked by requireReservationAccess.
    const reservation = req.reservation || (await Reservation.findById(reservationId));
    if (!reservation) {
      return res.status(404).json({ error: "Reservation not found" });
    }

    // Enforced only on this path — see the note in payoutReservation.
    const result = await payoutReservation(reservation, { requireBillingDetails: true });

    if (!result.ok) {
      const friendly = PAYOUT_MESSAGES[result.code];

      // A retryable failure is not the host's mistake and not a dead end: the
      // daily sweep will pick it up. 202 says "accepted, not done yet" rather
      // than 400, which reads as "you did something wrong".
      return res.status(result.retryable ? 202 : 400).json({
        error: friendly || result.error,
        code: result.code,
        retryable: Boolean(result.retryable),
        // Present on payouts_disabled: the exact Stripe onboarding steps still
        // outstanding, so the UI can list them instead of just saying "not yet".
        requirementsDue: result.requirementsDue || undefined,
        // Present on account_restricted: Stripe's own reason for the hold.
        disabledReason: result.disabledReason || undefined,
        // Present on billing_incomplete: which invoicing fields to ask for.
        missingBillingFields: result.missingBillingFields || undefined,
      });
    }

    res.json({ success: true, transferId: result.transferId });
  } catch (err) {
    console.error("releasePayoutToHost error:", err);
    res.status(500).json({ error: err.message });
  }
};
// Helper function to finalize reservation (update calendar + send email)
export const finalizeReservation = async (reservationId) => {
  try {
    // Claim the reservation atomically. Both the webhook and (historically) the
    // success page could reach this point; without the claim the guest and host
    // received duplicate confirmation emails and the calendar was written twice.
    const claimed = await Reservation.findOneAndUpdate(
      { _id: reservationId, finalizedAt: { $exists: false } },
      { $set: { finalizedAt: new Date() } },
      { new: true }
    );

    if (!claimed) {
      console.log(`finalizeReservation: ${reservationId} already finalized, skipping`);
      return;
    }

    const reservation = await Reservation.findById(reservationId).populate({
      path: "accommodationId",
      populate: { path: "userId" }
    });

    if (!reservation) throw new Error("Reservation not found");

    // FIX: Get accommodation directly from the populated reservation
    const accommodation = reservation.accommodationId;
    if (!accommodation) throw new Error("Accommodation not found");

    // FIX: The host is now inside the populated accommodation object
    const host = accommodation.userId;

    if (!host) {
      console.warn(`Warning: No host found for accommodation ${accommodation._id}`);
    }

    // 1. Update Occupancy Calendar
    //
    // Convert this booking's checkout hold into a confirmed booking. The old
    // code here filtered conflicting days out and booked whatever remained,
    // which meant a guest who lost a race paid in full and received a partial
    // stay, with nobody told. `confirmHold` refuses instead and raises an alert.
    const confirmed = await confirmHold(reservation);

    if (confirmed.ok) {
      console.log(`Updated calendar for reservation ${reservationId}`);
      // These nights are now sold. Any other open request for them — pending,
      // or accepted with a live payment link — is closed, so nobody else can
      // pay for the same dates.
      await closeCompetingRequests(reservation).catch((err) =>
        console.error(`closeCompetingRequests ${reservationId}:`, err.message)
      );
    } else {
      console.error(
        `Calendar conflict finalising reservation ${reservationId}: ` +
          `${confirmed.reason} ${JSON.stringify(confirmed.conflictDays || [])}`
      );
      // Deliberately not thrown: the guest HAS paid, and the payment record
      // must stand. An admin alert has already gone out from confirmHold.
    }

    // 2. Send Confirmation Email
    const transporter = getTransporter();

    // Emails are always sent in English.
    const lang = 'en';
    const locale = 'en-GB';

    const checkInDateFormatted = new Date(reservation.checkInDate).toLocaleDateString(locale, {
      month: 'long', day: 'numeric', year: 'numeric'
    });
    const checkOutDateFormatted = new Date(reservation.checkOutDate).toLocaleDateString(locale, {
      month: 'long', day: 'numeric', year: 'numeric'
    });

    // Calculate nights
    const diffTime = Math.abs(new Date(reservation.checkOutDate) - new Date(reservation.checkInDate));
    const nights = Math.ceil(diffTime / (1000 * 60 * 60 * 24));

    const propertyImage = accommodation.images[0] || "";
    const address = accommodation.locationDetails?.streetAndNumber || "";
    // On a listing split into units, which unit was booked (A1, A2, …). Empty
    // on every other booking, so those emails read exactly as before.
    const unitSuffix = reservation.unitName ? ` · ${reservation.unitName}` : "";
    const googleMapsLink = `https://www.google.com/maps?q=${encodeURIComponent(address)}`;

    // Translations
    const t = {
      en: {
        // Guest Email
        subjectGuest: `Reservation Confirmed: ${accommodation.name}${unitSuffix}`,
        titleGuest: "Your Reservation is Confirmed!",
        hi: "Hi",
        congrats: `Congratulations! Your reservation request for <strong>${accommodation.name}</strong> has been approved and paid.`,
        // Host Email
        subjectHost: `New Booking Received: ${accommodation.name}${unitSuffix}`,
        titleHost: "You have a new booking!",
        hostMsg: `Great news! Your property <strong>${accommodation.name}</strong> has been booked and paid for.`,
        // Shared
        stayDetails: "Stay Details",
        checkIn: "Check-in",
        checkOut: "Check-out",
        guests: "Number of Guests",
        nights: "Nights",
        pet: "Pet",
        pets: "Number of Pets",
        petTypes: { dog: "Dog", cat: "Cat", other: "Other" },
        totalPrice: "Total Price",
        unit: "Unit",
        guestDetails: "Guest Details",
        hostDetails: "Host Details",
        name: "Name",
        email: "Email",
        phone: "Phone Number",
        message: "Message",
        location: "Property Location",
        viewMap: "View Location on Map",
        regards: "Best regards",
        team: "The UK Stay Hub Team"
      },
    };

    const text = t.en;

    const hasMessage =
      typeof reservation.message === "string" &&
      reservation.message.trim().length > 0;

    // `forHost` adds the nights and the guest's pet type, which the host needs to
    // prepare. The number of pets is shown to both.
    const stayRows = (forHost) =>
      detailTable([
        reservation.unitName && [text.unit, reservation.unitName],
        [text.checkIn, checkInDateFormatted],
        [text.checkOut, checkOutDateFormatted],
        forHost && [text.nights, String(nights)],
        forHost && reservation.withPet && [
          text.pet,
          text.petTypes[reservation.petType] || reservation.petType || "—",
        ],
        reservation.withPet && [
          text.pets,
          String(Math.max(1, Number(reservation.numberOfPets) || 1)),
        ],
        reservation.extras?.length && ["Extras", extrasSummary(reservation.extras, reservation.currency)],
        [text.totalPrice, formatMoney(reservation.totalPrice, reservation.currency)],
      ]);

    // --- EMAIL 1: TO GUEST ---
    const guestMailOptions = {
      from: MAIL_FROM,
      to: reservation.email,
      subject: text.subjectGuest,
      attachments: logoAttachments(),
      html: brandShell({
        preheader: `${checkInDateFormatted} – ${checkOutDateFormatted} · ${formatMoney(reservation.totalPrice, reservation.currency)}`,
        title: text.titleGuest,
        bodyHtml: `
          ${heroImage(propertyImage, accommodation.name)}
          <p style="margin:0 0 14px 0;">${text.hi} <strong>${reservation.name}</strong>,</p>
          <p style="margin:0 0 4px 0;">${text.congrats}</p>
          ${section(text.stayDetails, stayRows(false))}
          ${section(
            text.hostDetails,
            detailTable([
              [text.name, host?.name || "—"],
              [text.email, host?.email || "—"],
              [text.phone, host?.phoneNumber ? `+${host.phoneNumber}` : "—"],
            ])
          )}
          ${address ? button(googleMapsLink, text.viewMap) : ""}`,
      }),
    };

    // --- EMAIL 2: TO HOST ---
    const hostMailOptions = {
      from: MAIL_FROM,
      to: host?.email,
      subject: text.subjectHost,
      attachments: logoAttachments(),
      html: brandShell({
        preheader: `${accommodation.name}${unitSuffix} · ${checkInDateFormatted} – ${checkOutDateFormatted}`,
        title: text.titleHost,
        bodyHtml: `
          <p style="margin:0 0 14px 0;">${text.hi} <strong>${host?.name || ""}</strong>,</p>
          <p style="margin:0 0 4px 0;">${text.hostMsg}</p>
          ${section(
            text.guestDetails,
            detailTable([
              [text.name, reservation.name],
              [text.email, reservation.email],
              [text.phone, reservation.phone ? `+${reservation.phone}` : "—"],
            ])
          )}
          ${hasMessage ? callout(`<strong>${esc(text.message)}:</strong> ${esc(reservation.message)}`) : ""}
          ${section(text.stayDetails, stayRows(true))}`,
      }),
    };

    // Send both emails
    await Promise.all([
      transporter.sendMail(guestMailOptions),
      transporter.sendMail(hostMailOptions)
    ]);
    
    console.log(`Emails sent to Guest (${reservation.email}) and Host (${host?.email})`);

  } catch (error) {
    console.error("Error finalizing reservation:", error);
    // Release the claim so a webhook retry can genuinely finish the job rather
    // than seeing it as already finalized and skipping it forever.
    try {
      await Reservation.findByIdAndUpdate(reservationId, { $unset: { finalizedAt: "" } });
    } catch (releaseErr) {
      console.error("Failed to release finalize claim:", releaseErr.message);
    }
    // Don't throw, just log, so we don't crash the webhook/response
  }
};

/**
 * Status check for the success page, with server-side reconciliation.
 *
 * This originally confirmed the booking straight from the browser's report,
 * which made the frontend a source of truth and duplicated everything the
 * webhook did. It was then made purely read-only — but that left a real hole:
 * if the webhook is delayed, misconfigured, or (typically in local development)
 * never delivered, a genuinely paid booking shows as UNPAID indefinitely.
 *
 * The fix is reconciliation, not client trust. The session is re-read from
 * Stripe here on the server; if Stripe says it is paid and our record disagrees,
 * the same idempotent path the webhook uses is invoked. The client supplies only
 * a session id — never an amount, never a status.
 */
export const verifyPayment = async (req, res) => {
  try {
    const { sessionId } = req.body;
    if (!sessionId) return res.status(400).json({ error: "sessionId required" });

    const stripe = getStripe();

    const session = await stripe.checkout.sessions.retrieve(sessionId);
    if (!session) return res.status(404).json({ error: "Session not found" });

    const reservationId = session.metadata?.reservationId;
    let reservation =
      reservationId && mongoose.Types.ObjectId.isValid(reservationId)
        ? await Reservation.findById(reservationId)
        : null;

    let reconciled = false;

    // Stripe took the money but we have not recorded it. Close the gap.
    if (session.payment_status === "paid" && reservation?.paymentStatus !== "paid") {
      const result = await applyPaidCheckoutSession(stripe, session, { source: "reconcile" });
      reconciled = result.applied;

      if (result.applied) {
        console.log(
          `[reconcile] reservation ${reservationId} marked paid from the success page — ` +
            `the Stripe webhook had not arrived. Check the webhook endpoint configuration.`
        );
      }

      reservation = await Reservation.findById(reservationId);
    }

    const settled = reservation?.paymentStatus === "paid";

    res.json({
      status: session.payment_status,
      settled,
      // True only if Stripe reports paid and reconciliation still could not
      // settle it — the client keeps polling while this holds.
      pending: session.payment_status === "paid" && !settled,
      reconciled,
      reservation,
    });
  } catch (err) {
    console.error("verifyPayment error:", err);
    res.status(500).json({ error: err.message });
  }
};

// POST /payments/cancel
export const cancelPayment = async (req, res) => {
  try {
    const { reservationId } = req.body;

    if (!reservationId) {
      return res.status(400).json({ error: "reservationId required" });
    }

    const reservation = await Reservation.findById(reservationId);
    if (!reservation) {
      return res.status(404).json({ error: "Reservation not found" });
    }

    // IMPORTANT:
    // Only reset if payment is NOT completed
    if (reservation.paymentStatus !== "paid") {
      reservation.paymentStatus = "unpaid";
      reservation.isApproved = "pending";
      reservation.checkoutSessionId = null; // optional but clean
      await reservation.save();

      // Give the dates back immediately. Without this the hold taken when
      // checkout started sat on the calendar for the rest of HOLD_MINUTES even
      // though the guest had explicitly walked away, so the listing showed as
      // unavailable to everyone — including the guest retrying.
      await releaseHold(reservation);
    }

    res.json({ success: true });
  } catch (err) {
    console.error("cancelPayment error:", err);
    res.status(500).json({ error: err.message });
  }
};

// Send Payment Email manually
export const sendPaymentEmail = async (req, res) => {
  try {
    const { reservationId } = req.body;
    if (!reservationId) return res.status(400).json({ error: "reservationId required" });

    const reservation = await Reservation.findById(reservationId).populate("accommodationId");
    if (!reservation) return res.status(404).json({ error: "Reservation not found" });

    if (reservation.paymentStatus === "paid") {
      return res.status(400).json({ error: "Reservation is already paid" });
    }

    const stripe = getStripe();
    await ensureBookingSnapshot(reservation);
    const amountCents = reservation.totalPriceCents || Math.round((reservation.totalPrice || 0) * 100);

    // Map language
    const language = "en";
    const locale = "en-GB";

    // Create new session
    const session = await stripe.checkout.sessions.create({
      // See createCheckoutSession: omitting payment_method_types lets the
      // Dashboard-enabled methods (incl. Apple Pay / Google Pay) apply.
      mode: "payment",
      locale,
      customer_email: reservation.email,
      line_items: [
        {
          price_data: {
            currency: reservation.currency || DEFAULT_CURRENCY,
            product_data: {
              name: `Reservation #${reservationId} - ${reservation.name}`,
            },
            unit_amount: amountCents,
          },
          quantity: 1,
        },
      ],
      metadata: {
        reservationId: reservation._id.toString(),
        hostId: reservation.accommodationProvider?.toString() || "",
        language,
      },
      payment_intent_data: {
        metadata: {
          reservationId: reservation._id.toString(),
          hostId: reservation.accommodationProvider?.toString() || "",
        },
      },
      // Emailed link: return to our /pay/:id pages (see returnUrls).
      ...returnUrls(reservation, payLinkBase(req)),
    });

    // Save session ID
    reservation.checkoutSessionId = session.id;
    await reservation.save();

    // Mail our /pay/:id link rather than the raw Stripe URL, so it opens the
    // app on a phone that has it (see utils/payLink.js).
    const { accessToken } =
      (await Reservation.findById(reservation._id).select("+accessToken").lean()) || {};
    const payUrl = payLinkUrl(req, reservation._id, accessToken);

    // Data Preparation for Email
    // The booked unit rides along with the name on a listing split into units.
    const accommodationName = [reservation.accommodationId?.name || "Accommodation", reservation.unitName]
      .filter(Boolean)
      .join(" · ");

    // Format Dates: DD / MM / YYYY
    const formatDate = (dateString) => {
      const d = new Date(dateString);
      const day = String(d.getDate()).padStart(2, '0');
      const month = String(d.getMonth() + 1).padStart(2, '0');
      const year = d.getFullYear();
      return `${day} / ${month} / ${year}`; // Explicit space as requested
    };

    const checkInStr = formatDate(reservation.checkInDate);
    const checkOutStr = formatDate(reservation.checkOutDate);

    // Calculate Nights
    const diffTime = Math.abs(new Date(reservation.checkOutDate) - new Date(reservation.checkInDate));
    const nights = Math.ceil(diffTime / (1000 * 60 * 60 * 24));

    // Calculate Guests - determine if it's a number or array length
    let guestCount = 1;
    if (Array.isArray(reservation.guests)) {
      guestCount = reservation.guests.length;
    } else if (reservation.numberOfGuests) {
      guestCount = reservation.numberOfGuests;
    } else if (reservation.guests && typeof reservation.guests === 'number') {
      guestCount = reservation.guests;
    }

    // Send Email
    const transporter = getTransporter();

    // Translations
    const t = {
      en: {
        subject: `Payment Request: ${accommodationName}`,
        title: "Complete Your Payment",
        greeting: `Hi ${reservation.name},`,
        message: `Your reservation at <strong>${accommodationName}</strong> is pending payment. Please verify the details below and proceed to payment to secure your booking.`,
        detailsTitle: "Reservation Details",
        checkIn: "Check-in",
        checkOut: "Check-out",
        nights: "Nights",
        guests: "Guests",
        totalPrice: "Total Price",
        buttonText: "Pay Now",
        expires: "Link expires in 24 hours.",
        regards: "Best regards,<br/>The UK Stay Hub Team"
      },
    };

    // Emails are always sent in English.
    const text = t.en;

    const mailOptions = {
      from: MAIL_FROM,
      to: reservation.email,
      subject: text.subject,
      attachments: logoAttachments(),
      html: brandShell({
        preheader: `${checkInStr} – ${checkOutStr} · ${formatMoney(reservation.totalPrice, reservation.currency)}`,
        title: text.title,
        bodyHtml: `
          <p style="margin:0 0 14px 0;">${text.greeting}</p>
          <p style="margin:0 0 4px 0;">${text.message}</p>
          ${section(
            text.detailsTitle,
            detailTable([
              [text.checkIn, checkInStr],
              [text.checkOut, checkOutStr],
              [text.nights, String(nights)],
              [text.guests, String(guestCount)],
              [text.totalPrice, formatMoney(reservation.totalPrice, reservation.currency)],
            ])
          )}
          ${button(payUrl, text.buttonText)}
          ${callout(text.expires, "warning")}`,
      }),
    };

    await transporter.sendMail(mailOptions);

    res.json({ success: true, message: "Payment email sent successfully" });

  } catch (err) {
    console.error("sendPaymentEmail error:", err);
    res.status(500).json({ error: err.message || "Failed to send payment email" });
  }
};

/**
 * Close every other unpaid request-to-book that wants nights this paid booking
 * now occupies: expire its Stripe session (so the emailed link cannot be paid)
 * and tell the guest. Without this a second accepted request stayed payable,
 * and its guest would be charged for dates already sold.
 */
export const closeCompetingRequests = async (paid) => {
  const listingId = paid.accommodationId?._id || paid.accommodationId;
  // Calendar rows are inclusive of the check-out day (see calendarHold.dayKeys).
  const rivals = await Reservation.find({
    _id: { $ne: paid._id },
    accommodationId: listingId,
    bookingMode: "request",
    paymentStatus: { $ne: "paid" },
    isApproved: { $ne: "cancelled" },
    checkInDate: { $lte: paid.checkOutDate },
    checkOutDate: { $gte: paid.checkInDate },
  });
  if (!rivals.length) return 0;

  const stripe = getStripe();
  const listing = await Accommodation.findById(listingId).select("name");
  let closed = 0;

  for (const r of rivals) {
    // A listing split into units: another unit's request is unaffected.
    if (paid.unitId && r.unitId && String(paid.unitId) !== String(r.unitId)) continue;

    if (r.checkoutSessionId) {
      await stripe.checkout.sessions.expire(r.checkoutSessionId).catch(() => {});
    }
    r.isApproved = "cancelled";
    r.cancelledAt = new Date();
    r.requestDeclinedAt = new Date();
    r.cancellationReason = "Dates booked by another guest";
    await r.save();
    closed++;

    sendGuestRequestClosedEmail({
      to: r.email,
      reservation: r,
      listingName: listing?.name,
      reason: "taken",
    }).catch((err) => console.error(`taken-email ${r._id}:`, err.message));
  }

  if (closed) console.log(`[calendar] closed ${closed} competing request(s) for paid booking ${paid._id}`);
  return closed;
};

/**
 * Where Stripe sends a host after Connect onboarding.
 *
 * The website handles its own /host/onboard/* pages. The mobile app (it sends
 * `X-Client: app`) has no web page to land on — CLIENT_SITE_URL may not even
 * be running — so it returns to this backend's /app-return/host/onboard/*
 * page, which hands the host straight back into the app.
 */
/**
 * True for the mobile app: it sends `X-Client: app`, and its HTTP client
 * identifies as "Dart/<version> (dart:io)" (covers builds made before the
 * header existed). Browsers — the website — never send either.
 */
const isAppRequest = (req) =>
  req?.get?.("x-client") === "app" || /^Dart\//.test(req?.get?.("user-agent") || "");

const onboardReturnUrls = (req, { accountId, returnTo } = {}) => {
  const q = new URLSearchParams();
  if (accountId) q.set("account", accountId);
  if (returnTo) q.set("returnTo", returnTo);
  const qs = q.toString() ? `?${q}` : "";
  // The website lands on this backend's /host/onboard/* page (hostOnboardWebReturn),
  // which checks the account with Stripe and links back to the host panel.
  const base =
    isAppRequest(req)
      ? `${payLinkBase(req)}/app-return/host/onboard`
      : `${(process.env.STRIPE_ONBOARD_BASE_URL || "").trim().replace(/\/+$/, "") || payLinkBase(req)}/host/onboard`;
  return { return_url: `${base}/success${qs}`, refresh_url: `${base}/refresh${qs}` };
};

const humanize = (r) => String(r).split(".").pop().replace(/_/g, " ");

// GET /host/onboard/:kind — Stripe onboarding return for hosts on the website.
// Landing here does not mean onboarding succeeded: the account is read from
// Stripe, and the page says "ready" or names what is still missing.
export const hostOnboardWebReturn = async (req, res) => {
  const returnTo = String(req.query.returnTo || "");
  const toListing = returnTo.startsWith("/host/listings");
  const back = {
    href: siteUrl(returnTo.startsWith("/") ? returnTo : "/host/payouts"),
    label: toListing ? "Back to your listing" : "Go to Account & earnings",
  };
  const issue = (title, body, status = 200) =>
    res.status(status).send(payPage({ icon: "warn", title, body, primary: back }));

  if (req.params.kind === "refresh") {
    return issue("Setup link expired",
      "Your Stripe setup link expired before it was finished. Go back to Account &amp; earnings and choose <b>Continue setup</b> to get a fresh link.");
  }

  const accountId = String(req.query.account || "");
  if (!/^acct_[A-Za-z0-9]+$/.test(accountId)) {
    return issue("We couldn't confirm your account",
      "Open Account &amp; earnings to see your payout status. If setup isn't finished there, choose <b>Continue setup</b>.");
  }

  try {
    const account = await getStripe().accounts.retrieve(accountId);
    // Same sync the account.updated webhook runs, so the host panel is current too.
    const host = await syncHostFromStripeAccount(account).catch((err) => {
      console.error("hostOnboardWebReturn sync failed:", err.message);
      return null;
    });
    const rows = [
      ["Details submitted", account.details_submitted ? "Yes" : "No"],
      ["Card payments", account.charges_enabled ? "Enabled" : "Pending"],
      ["Payouts", account.payouts_enabled ? "Enabled" : "Pending"],
    ];
    const due = [...new Set([...(account.requirements?.past_due || []), ...(account.requirements?.currently_due || [])])];
    const stripeDone = account.details_submitted && account.charges_enabled && account.payouts_enabled;

    if (!stripeDone) {
      const list = due.length
        ? `<br><br>Stripe still needs: <b>${due.slice(0, 8).map((r) => esc(humanize(r))).join(", ")}</b>`
        : account.details_submitted
          ? "<br><br>Stripe is reviewing your details. This usually takes a few minutes."
          : "";
      return res.send(payPage({ icon: "warn", title: "Stripe needs more information",
        body: `Your payout account isn't ready yet, so payouts are paused.${list}`,
        rows, primary: back }));
    }

    const missingBilling = host ? missingBillingFieldsOf(host) : [];
    if (missingBilling.length) {
      return res.send(payPage({ icon: "warn", title: "One last step",
        body: "Stripe has verified you. Add your billing details in Account &amp; earnings so your listings can be booked.",
        rows, primary: back }));
    }

    return res.send(payPage({ icon: "ok", title: "Your account is ready",
      body: "Stripe has verified your details. You can now receive payouts for your bookings.",
      rows, primary: back }));
  } catch (err) {
    logStripeCall("accounts.retrieve", { accountId }, "error", err);
    return issue("We couldn't confirm your account",
      "Stripe could not be reached just now. Open Account &amp; earnings to check your payout status.", 502);
  }
};

// GET /app-return/host/onboard/:kind — Stripe onboarding finished (success) or
// its link expired (refresh) for a host using the app.
//
// Redirects straight to ukstayhub://stripe-return/host/onboard/<kind>. The app
// runs onboarding in a system auth session (ASWebAuthenticationSession / a
// Custom Tab via flutter_web_auth_2) that watches for exactly that scheme: the
// moment it is reached the browser closes itself and the app shows its own
// /host/onboard/<kind> screen — no "Open in app?" prompt, no page to tap.
export const hostOnboardAppReturn = (req, res) => {
  const kind = req.params.kind === "refresh" ? "refresh" : "success";
  const q = new URLSearchParams();
  for (const k of ["account", "returnTo"]) if (req.query[k]) q.set(k, String(req.query[k]));
  res.redirect(302, `ukstayhub://stripe-return/host/onboard/${kind}${q.toString() ? `?${q}` : ""}`);
};

// ───────────────────────── Emailed payment link (/pay/:id) ─────────────────────────

/**
 * Where an emailed payment link stands, read from Stripe (never from the
 * client). Shared by the app's status call and the browser redirect.
 *
 *   paid         the booking is paid (reconciled here if the webhook lagged)
 *   ready        the Stripe session is open; `url` is where to pay
 *   expired      the link's Stripe session timed out
 *   unavailable  cancelled, declined, or no payment link was ever issued
 */
export const resolvePayLink = async (reservation) => {
  if (reservation.paymentStatus === "paid") return { state: "paid" };
  if (reservation.isApproved === "cancelled") return { state: "unavailable" };
  if (!reservation.checkoutSessionId) return { state: "unavailable" };

  const stripe = getStripe();
  let session;
  try {
    session = await stripe.checkout.sessions.retrieve(reservation.checkoutSessionId);
  } catch (err) {
    logStripeCall("checkout.sessions.retrieve", { reservationId: String(reservation._id) }, "error", err);
    return { state: "unavailable" };
  }

  if (session.payment_status === "paid") {
    await applyPaidCheckoutSession(stripe, session, { source: "reconcile" }).catch(() => {});
    return { state: "paid", sessionId: session.id };
  }
  if (session.status === "expired") return { state: "expired" };
  if (session.status !== "open" || !session.url) return { state: "unavailable" };

  // Someone else may have booked (or be mid-checkout for) these nights since
  // the link was mailed. Not expired here: a checkout hold can still lapse.
  // A PAID rival closes this request for good via closeCompetingRequests.
  const free = await checkAvailability(reservation);
  if (!free.ok) return { state: "taken" };

  return {
    state: "ready",
    url: session.url,
    sessionId: session.id,
    expiresAt: session.expires_at ? new Date(session.expires_at * 1000) : reservation.paymentLinkExpiresAt,
  };
};

// GET /api/payments/pay-link/:reservationId — the app's view of an emailed link.
export const getPayLink = async (req, res) => {
  try {
    const reservation = req.reservation;
    const link = await resolvePayLink(reservation);
    const fresh = await Reservation.findById(reservation._id).populate("accommodationId", "name slug images");
    res.json({ ...link, reservation: fresh });
  } catch (err) {
    console.error("getPayLink error:", err);
    res.status(500).json({ error: err.message || "Failed to load payment link" });
  }
};

const isPhone = (req) => /iphone|ipad|ipod|android/i.test(req.get("user-agent") || "");

/** In-app address for a path, e.g. ukstayhub://app/pay/123 (the app's custom scheme). */
const appUrl = (path) => `ukstayhub://app${path}`;

const closedPage = (res, link) => {
  if (link.state === "expired") {
    return res.status(410).send(payPage({ icon: "⏱️", title: "Payment link expired",
      body: "This payment link has expired and the dates have been released. Please make a new booking." }));
  }
  if (link.state === "taken") {
    return res.status(410).send(payPage({ icon: "📅", title: "Dates no longer available",
      body: "These dates have just been booked by another guest, so this link can't be paid right now. You have not been charged." }));
  }
  return res.status(410).send(payPage({ icon: "⚠️", title: "Payment not available",
    body: "This booking can no longer be paid for. It may have been cancelled or declined." }));
};

// GET /pay/:reservationId — the emailed link opened in a BROWSER (the app did
// not catch it: desktop, app not installed, or App Links not yet verified).
// On a phone: offer to open the app (and try it automatically), or pay here.
// On a desktop: straight on to Stripe Checkout.
export const openPayLinkInBrowser = async (req, res) => {
  try {
    const reservation = req.reservation;
    const link = await resolvePayLink(reservation);
    const id = String(reservation._id);
    const token = req.query.reservationToken ? `?reservationToken=${encodeURIComponent(req.query.reservationToken)}` : "";

    if (link.state === "paid") {
      return res.send(payPage({ icon: "✅", title: "Already paid",
        body: "This booking is paid and confirmed. A confirmation was sent to your email, and the receipt is in the UK Stay Hub app under My bookings.",
        primary: isPhone(req) ? { href: appUrl(`/payment-success?reservationId=${id}`), label: "Open in UK Stay Hub app" } : null }));
    }
    if (link.state !== "ready") return closedPage(res, link);

    if (!isPhone(req) || req.query.web === "1") return res.redirect(303, link.url);

    const inApp = appUrl(`/pay/${id}${token}`);
    const sep = token ? "&" : "?";
    return res.send(payPage({ icon: "💳", title: "Complete your payment",
      body: "Pay in the UK Stay Hub app, or continue here in your browser.",
      primary: { href: inApp, label: "Open in UK Stay Hub app" },
      secondary: { href: `/pay/${id}${token}${sep}web=1`, label: "Pay in browser" },
      autoOpen: inApp }));
  } catch (err) {
    console.error("openPayLinkInBrowser error:", err);
    res.status(500).send(payPage({ icon: "⚠️", title: "Something went wrong", body: "Please try the link again in a moment." }));
  }
};

// GET /pay/:reservationId/success?session_id=… — Stripe's return after an
// emailed link was paid IN A BROWSER. Authorised like /verify-payment: only
// completing that checkout yields the session id, and it must belong to :id.
export const payLinkSuccessPage = async (req, res) => {
  try {
    const { reservationId } = req.params;
    const sessionId = String(req.query.session_id || "");
    const stripe = getStripe();
    const session = sessionId ? await stripe.checkout.sessions.retrieve(sessionId).catch(() => null) : null;
    if (!session || session.metadata?.reservationId !== reservationId) {
      return res.status(404).send(payPage({ icon: "⚠️", title: "Payment not found", body: "We could not find this payment." }));
    }
    if (session.payment_status !== "paid") {
      return res.send(payPage({ icon: "❌", title: "Payment not completed",
        body: "You have not been charged. Use the link in your email to try again." }));
    }
    await applyPaidCheckoutSession(stripe, session, { source: "reconcile" }).catch(() => {});
    const r = await Reservation.findById(reservationId).populate("accommodationId", "name");
    const rows = r
      ? [
          ["Stay", [r.accommodationId?.name, r.unitName].filter(Boolean).join(" · ") || "—"],
          ["Dates", `${toCalendarDateString(r.checkInDate)} → ${toCalendarDateString(r.checkOutDate)}`],
          ["Guests", String(r.numberOfPersons || 1)],
          ["Total paid", formatCents(r.totalPriceCents || Math.round((r.totalPrice || 0) * 100), r.currency)],
          ["Transaction ID", String(r._id)],
        ]
      : null;
    const inApp = appUrl(`/payment-success?session_id=${encodeURIComponent(sessionId)}&reservationId=${reservationId}`);
    return res.send(payPage({ icon: "ok", title: "Payment successful",
      body: "Your booking has been confirmed. You will receive an email confirmation shortly. The receipt is in the UK Stay Hub app under My bookings.",
      rows,
      primary: isPhone(req) ? { href: inApp, label: "Open in UK Stay Hub app" } : null,
      autoOpen: isPhone(req) ? inApp : null }));
  } catch (err) {
    console.error("payLinkSuccessPage error:", err);
    res.status(500).send(payPage({ icon: "⚠️", title: "Something went wrong", body: "Your payment may still have gone through — check your email." }));
  }
};

// GET /pay/:reservationId/cancelled — guest backed out of Stripe in a browser.
export const payLinkCancelledPage = (req, res) =>
  res.send(payPage({ icon: "↩️", title: "Payment not completed",
    body: "You have not been charged. The link in your email still works until it expires — open it again to pay." }));
