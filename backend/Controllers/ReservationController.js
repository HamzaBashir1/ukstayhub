import crypto from 'crypto';
import bcrypt from 'bcryptjs';
import DeletedReservation from '../models/DeletedReservation.js';
import Reservation from '../models/Reservation.js';
import Accommodation from '../models/Accommodation.js';
import User from '../models/User.js';
import { buildBookingAccountEmail } from '../utils/bookingAccountEmail.js';
import mongoose from 'mongoose';
import {
  finalizeReservation,
  buildCheckoutSession,
  // Frees a booking's dates on its property: drops the rows it owns in
  // `Accommodation.occupancyCalendar`, which is the ONLY place any calendar
  // in this app reads availability from.
  releaseCalendarForReservation,
} from "./PaymentController.js";
import { getTransporter, MAIL_FROM } from "../utils/mailer.js";
import {
  brandShell,
  button,
  detailTable,
  esc,
  section,
  logoAttachments,
} from "../utils/emailLayout.js";
import { sendEvent } from "../utils/FacebookCAPI.js";
import { getTiersSnapshot, getPolicyNameSnapshot } from "../utils/cancellationPolicy.js";
import { calculateFees, DEFAULT_CURRENCY, PAYOUT_DELAY_HOURS } from "../config/payments.js";
import { checkStayLength, quoteStay, priceMismatch, extrasSummary } from "../utils/pricing.js";
import { applyUnit, findUnit, hasUnits } from "../utils/listingUnits.js";
import { calendarDateUtc, businessMidnightUtc } from "../utils/timezone.js";
import Host from "../models/Host.js";
import { isHostBookingReady } from "../utils/listingGating.js";
import {
  bookingModeForHost,
  requestPurposeForHost,
  requestExpiryFrom,
  paymentLinkExpiryFrom,
  PAYMENT_LINK_HOURS,
} from "../utils/requestToBook.js";
import {
  sendHostBookingRequestEmail,
  sendGuestRequestReceivedEmail,
  sendGuestPaymentLinkEmail,
  sendGuestRequestClosedEmail,
} from "../utils/requestToBookEmails.js";
import { hostOnboardingGuidance } from "../utils/hostOnboardingSteps.js";
import { isAccountPayoutReady, resolvePayoutAccount } from "../utils/payoutAccounts.js";
import { missingBillingFieldsOf } from "../utils/hostBilling.js";



/**
 * GET /api/reservation/quote/:accommodationId?checkIn=&checkOut=&adults=&children=&withPet=&unitId=
 *
 * `unitId` names the unit on a listing split into units; it is ignored on a
 * listing without them.
 *
 * The authoritative price for a stay, straight from the listing. The browser
 * should display THIS rather than its own arithmetic — the booking will be
 * created at this figure regardless of what the client sends.
 */
export const getStayQuote = async (req, res) => {
  try {
    const { accommodationId } = req.params;
    if (!mongoose.Types.ObjectId.isValid(accommodationId)) {
      return res.status(400).json({ error: "Invalid accommodation ID" });
    }

    const listing = await Accommodation.findById(accommodationId).select(
      "pricePerNight pricePerPerson weekendPricePerNight weekendDays includedGuests flexiblePrices lengthDiscounts guestDiscounts petFeePerNight cleaningFee localTaxPerPersonNight paidExtras units"
    );
    if (!listing) return res.status(404).json({ error: "Accommodation not found" });

    const unit = findUnit(listing, req.query.unitId);
    if (hasUnits(listing) && !unit) {
      return res.status(400).json({ error: "Choose a unit to price this stay", reason: "unit_required" });
    }

    const quote = quoteStay(applyUnit(listing, unit), {
      checkInDate: req.query.checkIn,
      checkOutDate: req.query.checkOut,
      adults: req.query.adults,
      children: req.query.children,
      withPet: req.query.withPet,
      // Comma-separated amenity values the guest ticked ("Hot Tub,Sauna").
      extras: String(req.query.extras || "").split(",").filter(Boolean),
    });

    if (!quote.ok) {
      return res.status(400).json({ error: "Could not price this stay", reason: quote.error });
    }

    res.json({
      totalCents: quote.totalCents,
      total: quote.totalCents / 100,
      currency: DEFAULT_CURRENCY,
      breakdown: quote.breakdown,
    });
  } catch (err) {
    console.error("getStayQuote error:", err);
    res.status(500).json({ error: err.message });
  }
};

// Create a new reservation
export const createReservation = async (req, res) => {
  try {
    // The amount is NEVER taken from the request body. Whatever the client sent
    // is stripped here and recomputed from the listing below; without this a
    // guest could post totalPrice: 1 for a 500 EUR stay and every downstream
    // figure (fee, payout, refund, DAC7) would inherit the forged number.
    // `extras` is the guest's choice of amenity values; the priced snapshot of
    // it is set from the quote below, never taken from the body.
    const { totalPrice: claimedPrice, totalPriceCents: claimedCents, extras: chosenExtras, ...safeBody } = req.body;
    const reservation = new Reservation(safeBody);

    // Check-in and check-out are calendar dates, not instants. A browser date
    // picker serialises the guest's LOCAL midnight, so a guest in Karachi (UTC+5)
    // picking 10 September sends 2026-09-09T19:00:00Z — which reads back as the
    // 9th anywhere west of them. Snapping to UTC midnight of the intended day
    // stores the date the guest actually chose, so every later reader agrees.
    reservation.checkInDate = calendarDateUtc(reservation.checkInDate);
    reservation.checkOutDate = calendarDateUtc(reservation.checkOutDate);

    if (!reservation.checkInDate || !reservation.checkOutDate) {
      return res.status(400).json({ error: "Valid check-in and check-out dates are required" });
    }

    // Freeze the cancellation terms and the money figures at booking time.
    // The guest is agreeing to THESE terms; a later edit to the listing (or to
    // the standard policy definitions) must not change this booking.
    // `payoutStripeAccountId` is not part of the policy snapshot — it is here so
    // the request-to-book email can describe the account THIS listing pays into.
    // Without it every multi-account host would be told about their default.
    const listing = await Accommodation.findById(reservation.accommodationId).select(
      "name cancellationPolicyType customPolicyTiers pricePerNight pricePerPerson weekendPricePerNight weekendDays includedGuests flexiblePrices lengthDiscounts guestDiscounts petFeePerNight cleaningFee localTaxPerPersonNight paidExtras pet payoutStripeAccountId nightMin nightMax units"
    );
    if (!listing) {
      return res.status(404).json({ error: "Accommodation not found" });
    }

    // --- Unit ---
    // A listing split into units (A1, A2, …) is booked one unit at a time, and
    // that unit's price, capacity and calendar apply. The id is checked against
    // the listing and the name taken from it, never from the request. On a
    // listing without units nothing is stored and nothing changes.
    const unit = findUnit(listing, req.body?.unitId);
    if (hasUnits(listing) && !unit) {
      return res.status(400).json({
        error: "Please choose which unit you want to book.",
        code: "unit_required",
      });
    }
    reservation.unitId = unit ? unit._id : undefined;
    reservation.unitName = unit ? unit.name : undefined;
    // What the stay is priced and judged against: the unit where it has its
    // own values, the listing everywhere else.
    const priced = applyUnit(listing, unit);

    // --- Pet ---
    // The guest says at checkout whether they bring a pet, and which kind.
    // The pet fee is charged only when they do.
    reservation.withPet = req.body?.withPet === true || req.body?.withPet === "true";
    if (reservation.withPet) {
      if (listing.pet?.en === "Not Allowed") {
        return res.status(400).json({
          error: "Pets are not allowed at this place.",
          code: "pets_not_allowed",
        });
      }
      if (!["dog", "cat", "other"].includes(reservation.petType)) {
        return res.status(400).json({
          error: "Please select your pet type.",
          code: "pet_type_required",
        });
      }
      // How many pets. Informational only — the pet fee does not scale with it.
      const pets = Math.floor(Number(req.body?.numberOfPets) || 1);
      reservation.numberOfPets = Math.min(10, Math.max(1, pets));
    } else {
      reservation.petType = "";
      reservation.numberOfPets = 0;
    }

    // --- Stay length ---
    //
    // The host's minimum and maximum stay were enforced only in the browser:
    // on the listing page, in the date modals and again at checkout. Nothing
    // checked them here, so a booking that reached this endpoint any other way
    // was accepted whatever its length — dates left in localStorage from before
    // the host tightened the rule, a tab open across the change, or a direct
    // POST. That applies to a request-to-book exactly as it does to an instant
    // booking: both are created here, and a request the host cannot honour is
    // worse than a refusal, because it reaches them as a real booking to answer.
    //
    // Both fields are `required` on the model, so the fallbacks below only cover
    // documents written before that was true.
    const nights = Math.round(
      (reservation.checkOutDate.getTime() - reservation.checkInDate.getTime()) / 86400000
    );

    if (nights < 1) {
      return res.status(400).json({
        error: "The check-out date must be after the check-in date.",
        code: "stay_invalid",
      });
    }

    const nightMin = Math.max(1, Number(listing.nightMin) || 1);
    // 365 rather than the 15 the browser assumes: that is what the publish
    // mapper stores for a host who set no maximum, so refusing at 15 here would
    // reject stays the host never ruled out.
    const nightMax = Math.max(nightMin, Number(listing.nightMax) || 365);

    // Paying guests, counted the way `quoteStay` counts them below, so a
    // flexible-price offer's guest range is judged on the same party.
    const payingGuests = req.body?.guests || req.body?.adults != null
      ? (Number(req.body?.guests?.adults ?? req.body?.adults) || 0) +
        (Number(req.body?.guests?.children ?? req.body?.children) || 0)
      : Number(reservation.numberOfPersons) || 0;

    // Stay length. A flexible-price offer the stay falls in replaces the
    // listing's min/max nights with its own night ranges.
    const stayRule = checkStayLength(
      priced,
      reservation.checkInDate,
      reservation.checkOutDate,
      payingGuests,
      nightMin,
      nightMax,
    );
    if (!stayRule.ok) {
      const nightsWord = (n) => (n === 1 ? "night" : "nights");
      const forOffer = stayRule.offerName ? ` for these dates (${stayRule.offerName})` : "";
      const error =
        stayRule.reason === "too_short"
          ? `This place has a minimum stay of ${stayRule.min} ${nightsWord(stayRule.min)}${forOffer}.`
          : stayRule.reason === "too_long"
            ? `This place takes stays of at most ${stayRule.max} ${nightsWord(stayRule.max)}${forOffer}.`
            : `This place takes stays of ${stayRule.ranges
                .map(([low, high]) => (low === high ? `${low}` : `${low}-${high}`))
                .join(" or ")} nights${forOffer}.`;
      return res.status(400).json({
        error,
        code: stayRule.reason === "too_short" ? "stay_too_short" : stayRule.reason === "too_long" ? "stay_too_long" : "stay_length_not_offered",
        nightMin: stayRule.min,
        nightMax: stayRule.max,
        nights,
      });
    }

    reservation.cancellationPolicySnapshot = getPolicyNameSnapshot(listing);
    reservation.cancellationTiersSnapshot = getTiersSnapshot(listing, reservation.checkInDate);

    // --- Authoritative price, computed from the listing ---
    const quote = quoteStay(priced, {
      checkInDate: reservation.checkInDate,
      checkOutDate: reservation.checkOutDate,
      withPet: reservation.withPet,
      extras: chosenExtras,
      adults: req.body?.guests?.adults ?? req.body?.adults,
      children: req.body?.guests?.children ?? req.body?.children,
      // numberOfPersons is the only guest count the schema stores, so fall back
      // to it when the request did not break the party down by age.
      ...(req.body?.guests || req.body?.adults != null
        ? {}
        : { adults: reservation.numberOfPersons }),
    });

    if (!quote.ok) {
      return res.status(400).json({ error: "Could not price this stay", reason: quote.error });
    }

    const mismatch = priceMismatch(
      claimedCents ?? Math.round((Number(claimedPrice) || 0) * 100),
      quote.totalCents
    );
    if (mismatch) {
      // Not fatal: the server figure is correct by construction, so the booking
      // proceeds at the listing's real price. It is logged loudly because it
      // means either a tampered request or a genuine frontend/backend drift.
      console.warn(
        `[pricing] reservation quote mismatch on listing ${listing._id}: ` +
          `client ${mismatch.claimedCents}c vs server ${mismatch.serverCents}c ` +
          `(${mismatch.direction})`
      );
    }

    reservation.totalPriceCents = quote.totalCents;
    reservation.totalPrice = quote.totalCents / 100;
    reservation.priceBreakdown = quote.breakdown;
    reservation.extras = quote.breakdown.extras.length ? quote.breakdown.extras : undefined;
    if (!reservation.currency) reservation.currency = DEFAULT_CURRENCY;

    // Expected split, so the host can see what they will receive before payment.
    const { platformFeeCents, hostPayoutCents } = calculateFees(reservation.totalPriceCents);
    reservation.platformFeeCents = platformFeeCents;
    reservation.hostAmountCents = hostPayoutCents;

    // --- Instant booking, or a request? ---
    //
    // Decided by REQUEST_TO_BOOK_MODE (see utils/requestToBook.js). On
    // `unonboarded` that is every listing, whatever its status; on `published`
    // only listings whose host can already be paid, so they can vet the guest.
    //
    // Either way a request charges nothing here, creates no Stripe session, and
    // leaves the dates on the market until the host approves and the guest
    // actually pays.
    const host = await Host.findById(reservation.accommodationProvider).catch(() => null);
    reservation.bookingMode = bookingModeForHost(host);

    if (reservation.bookingMode === "request") {
      reservation.requestExpiresAt = requestExpiryFrom();
      reservation.isApproved = "pending";
      reservation.paymentStatus = "unpaid";
    }

    const savedReservation = await reservation.save();

    // Fire-and-forget: the booking is already recorded, and failing it because
    // an account could not be created — or SMTP blinked — would be far worse
    // than the guest simply not getting an account.
    void ensureGuestAccountForBooking(savedReservation).catch((err) =>
      console.error("[booking-account] failed:", err.message),
    );

    if (savedReservation.bookingMode === "request") {
      // Both mails are fire-and-forget. The request is already recorded, and
      // losing it because SMTP blinked would be far worse than a missing email
      // the host can still see in their dashboard.
      const hostEmail = host?.email;
      if (hostEmail) {
        sendHostBookingRequestEmail({
          to: hostEmail,
          reservation: savedReservation,
          listingName: listing?.name,
          hostName: host?.name,
          // Which of the two purposes this request serves — an un-onboarded
          // host is being persuaded to connect an account, an onboarded one is
          // simply vetting the guest. Decides the wording, not the flow.
          needsOnboarding: requestPurposeForHost(host) === "onboarding",
          // ...and, for the first of those, exactly what is still outstanding.
          // Computed against THIS listing, so a host holding several payout
          // accounts is told about the one this booking would pay into.
          onboarding: hostOnboardingGuidance(host, listing),
        }).then((sent) => {
          if (sent) {
            Reservation.updateOne(
              { _id: savedReservation._id },
              { $set: { requestEmailSentAt: new Date() } }
            ).catch(() => {});
          }
        });
      } else {
        console.error(
          `[request-to-book] no email on host ${reservation.accommodationProvider} — ` +
            `request ${savedReservation._id} cannot be delivered`
        );
      }

      sendGuestRequestReceivedEmail({
        to: savedReservation.email,
        reservation: savedReservation,
        listingName: listing?.name,
      });
    }

    // Facebook CAPI - InitiateCheckout
    const { fbp, fbc } = req.body;
    try {
        const eventData = {
            eventName: 'InitiateCheckout',
            productId: savedReservation._id.toString(),
            quantity: 1,
            currency: savedReservation.currency || 'eur',
            value: savedReservation.totalPrice || 0,
            contentName: 'Reservation',
            eventSourceUrl: req.headers.referer || req.headers.origin || '', 
        };

        const listItems = [
             {
                id: savedReservation.accommodationId.toString(),
                quantity: 1,
                delivery_category: 'home_delivery' // or 'in_store' or whatever fits
             }
        ];
        
        // We can pass more user data if available
        const userPayload = {
            email: savedReservation.email,
            clientIp: req.ip || req.connection.remoteAddress,
            clientUserAgent: req.headers['user-agent'],
            fbp: fbp,
            fbc: fbc
        };

        sendEvent('InitiateCheckout', eventData, userPayload); // async, don't await to not block response
    } catch (e) {
        console.error("FB CAPI Error (InitiateCheckout):", e);
    }

    // The capability token is returned exactly once, here. It is the only proof
    // an anonymous guest has that this booking is theirs, so the client must
    // keep it for checkout, receipt download and cancellation.
    res.status(201).json({
      ...savedReservation.toObject(),
      accessToken: savedReservation.accessToken,
    });
  } catch (error) {
    res.status(400).json({ message: error.message });
  }
};

// Get all reservations
export const getAllReservations = async (req, res) => {
  try {
    const reservations = await Reservation.find().lean();

    // Admin-only route: attach the listing slug and the host's contact details
    // so the reservations page can show (and copy) everything about a booking
    // without a per-row lookup. Host phone is not exposed by the public
    // listing API, so it has to come from here.
    const accommodationIds = [...new Set(reservations.map((r) => String(r.accommodationId || "")).filter(Boolean))];
    const accommodations = await Accommodation.find({ _id: { $in: accommodationIds } })
      .select("slug userId phoneNumber payoutStripeAccountId")
      .lean();
    // Full host documents: the Stripe-ready and billing checks below read many
    // fields. Only the two derived booleans leave this function.
    const hosts = await Host.find({ _id: { $in: accommodations.map((a) => a.userId).filter(Boolean) } }).lean();

    const accommodationById = new Map(accommodations.map((a) => [String(a._id), a]));
    const hostById = new Map(hosts.map((h) => [String(h._id), h]));

    const enriched = reservations.map((reservation) => {
      const accommodation = accommodationById.get(String(reservation.accommodationId || ""));
      const host = accommodation ? hostById.get(String(accommodation.userId || "")) : null;
      return {
        ...reservation,
        listingSlug: accommodation?.slug || null,
        host: host
          ? {
              name: [host.name, host.lastName].filter(Boolean).join(" "),
              email: host.email || "",
              phone: host.phone || host.phoneNumber || accommodation?.phoneNumber || "",
              // Same rules the payout code applies: the account THIS listing pays
              // into (not just the default) and the invoicing fields.
              stripeOnboardingComplete: isAccountPayoutReady(resolvePayoutAccount(accommodation, host)),
              missingBillingFields: missingBillingFieldsOf(host),
            }
          : null,
      };
    });

    res.status(200).json(enriched);
  } catch (error) {
    res.status(500).json({ message: error.message });
  }
};

/**
 * Give a guest who booked without signing up an account to come back to.
 *
 * Does nothing when an account already uses that address — in either
 * collection — so a host who books a stay, or a returning guest, is never
 * handed a second account or a new password for the one they have.
 *
 * The generated password is emailed, which is the whole point and also its
 * weakness: it will sit in that inbox forever. So it is random, long, never
 * logged, and the account is flagged `mustChangePassword` so it is replaced at
 * first sign-in rather than kept.
 */
export const ensureGuestAccountForBooking = async (reservation) => {
  const email = String(reservation.email || "").trim();
  if (!email) return null;

  const pattern = new RegExp(`^${email.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`, "i");

  const [existingUser, existingHost] = await Promise.all([
    User.findOne({ email: pattern }).select("_id"),
    Host.findOne({ email: pattern }).select("_id"),
  ]);
  if (existingUser || existingHost) return null;

  // 18 bytes of base64url — long enough that emailing it is the weak link,
  // not the password itself.
  const password = crypto.randomBytes(18).toString("base64url");
  const salt = await bcrypt.genSalt(10);

  const user = await User.create({
    name: reservation.name || "Guest",
    email,
    password: await bcrypt.hash(password, salt),
    phoneNumber: reservation.phone || undefined,
    role: "guest",
    // The address is not proven: anyone can type someone else's into a booking
    // form. Leaving it unverified is what stops this account from reading that
    // person's other bookings through /reservation/mine.
    isVerified: false,
    mustChangePassword: true,
  });

  const { subject, html, text, attachments } = buildBookingAccountEmail({
    name: reservation.name,
    email,
    password,
    loginUrl: `${process.env.CLIENT_SITE_URL || "https://putko.sk"}/login`,
  });

  await getTransporter().sendMail({
    from: MAIL_FROM,
    to: email,
    subject,
    html,
    text,
    attachments,
  });

  // The password is deliberately absent from this line.
  console.log(
    `[putko-audit] booking.account-created user=${user._id} reservation=${reservation._id} at=${new Date().toISOString()}`,
  );

  return user;
};

/**
 * GET /api/reservation/mine — the signed-in traveller's own bookings.
 *
 * A reservation carries no guest user id (guests book without an account), so
 * the only link between an account and its bookings is the email address the
 * booking was made with. That makes the email a credential, and an unverified
 * one proves nothing: anyone could register with someone else's address and
 * read their stays. So this refuses until the account's email is verified, and
 * says so rather than answering with an empty list, which would look like
 * "you have no bookings".
 *
 * The match is case-insensitive but otherwise exact — no plus-address folding,
 * so `a+b@x.com` never reads `a@x.com`'s bookings.
 */
export const getMyReservations = async (req, res) => {
  try {
    // Sign-up creates a `Host` document, so that is where almost every account
    // lives; `User` holds the few traveller-only accounts. The token says
    // which, and either may have made a booking.
    const account =
      (await Host.findById(req.userId).select("email isVerified")) ||
      (await User.findById(req.userId).select("email isVerified"));

    if (!account) {
      return res.status(404).json({ message: "Account not found." });
    }
    if (!account.email) {
      return res
        .status(409)
        .json({ message: "This account has no email address.", code: "noEmail" });
    }
    if (!account.isVerified) {
      return res.status(403).json({
        message: "Verify your email address to see your bookings.",
        code: "emailUnverified",
      });
    }

    const email = account.email.trim();
    const reservations = await Reservation.find({
      email: new RegExp(`^${email.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`, "i"),
    })
      .populate("accommodationId")
      .sort({ checkInDate: -1 });

    // `accessToken` is `select: false`, so it cannot ride along here — this
    // list is read with the account's own session and needs no capability
    // token, and handing them out in bulk would make one leaked response a
    // master key to every booking in it.
    res.status(200).json({ reservations });
  } catch (error) {
    console.error("Error in getMyReservations controller:", error.message);
    res.status(500).json({ message: "Could not load your bookings." });
  }
};

// Get all deleted reservations
export const getDeletedReservations = async (req, res) => {
  try {
    const reservations = await DeletedReservation.find();
    res.status(200).json(reservations);
  } catch (error) {
    res.status(500).json({ message: "Server error", error: error.message });
  }
};

// Permanently delete a reservation
export const deleteReservationPermanently = async (req, res) => {
  try {
    const { id } = req.params;

    const deletedRes = await DeletedReservation.findByIdAndDelete(id);

    if (!deletedRes) {
      return res.status(404).json({ message: "Reservation not found" });
    }

    res.status(200).json({ message: "Reservation permanently deleted" });
  } catch (error) {
    res.status(500).json({ message: "Server error", error: error.message });
  }
};


export const restoreReservation = async (req, res) => {
  try {
    const { id } = req.params;

    // Find the deleted reservation
    const deletedReservation = await DeletedReservation.findById(id);
    if (!deletedReservation) {
      return res.status(404).json({ message: "Reservation not found" });
    }

    // Move back to Reservations collection
    const restoredReservation = new Reservation({
      ...deletedReservation.toObject(),
      createdAt: deletedReservation.createdAt, // Keep original creation date
    });

    await restoredReservation.save(); // Save the restored reservation
    await DeletedReservation.findByIdAndDelete(id); // Remove from deleted collection

    res.status(200).json({ message: "Reservation restored successfully!" });
  } catch (error) {
    res.status(500).json({ message: "Server error", error: error.message });
  }
};

// Get a single reservation by ID
export const getReservationById = async (req, res) => {
    try {
      let { id } = req.params;
      
      // Log the received id for debugging
    //   console.log("Received ID:", id);
  
      // Remove any leading/trailing characters like curly braces
      id = id.replace(/[^a-fA-F0-9]/g, ''); // This strips out anything that isn't a valid hex character
      
      // Validate if the cleaned id is a valid MongoDB ObjectId
      if (!mongoose.Types.ObjectId.isValid(id)) {
        return res.status(400).json({ message: 'Invalid reservation ID' });
      }
  
      // `userId` is NOT on the reservation schema — it is commented out in
      // models/Reservation.js, because a guest books without an account. Asking
      // Mongoose to populate it throws StrictPopulateError (strictPopulate has
      // defaulted to true since Mongoose 6), so this endpoint answered 500 to
      // every request. The guest-facing "request sent" page reads it, and a 500
      // there is indistinguishable from a missing booking: it told guests their
      // request could not be found moments after it was created.
      const reservation = await Reservation.findById(id).populate('accommodationId');
      
      if (!reservation) {
        return res.status(404).json({ message: 'Reservation not found' });
      }
  
      res.status(200).json(reservation);
    } catch (error) {
      res.status(500).json({ message: error.message });
    }
  };

// Update a reservation
export const updateReservationByName = async (req, res) => {
  try {
    const { name } = req.params; // Extract reservation name from URL parameters
    const updates = req.body; // Reservation updates from the request body

    // Find the reservation by name (case-insensitive search) and update it
    const updatedReservation = await Reservation.findOneAndUpdate(
      { name: { $regex: name, $options: 'i' } }, // Case-insensitive search by name
      { $set: updates }, // Apply updates to the fields
      { new: true, runValidators: true } // Return the updated document and run validators
    )
    .populate('accommodationId') // Populate accommodationId if needed
    .select('-userId'); // Exclude userId from results

    // If reservation not found
    if (!updatedReservation) {
      return res.status(404).json({ message: `No reservation found for the name "${name}"` });
    }

    res.status(200).json(updatedReservation);
  } catch (error) {
    res.status(500).json({ message: error.message });
  }
};


// Delete a reservation
export const deleteReservation = async (req, res) => {
  try {
    const deletedReservation = await Reservation.findByIdAndDelete(req.params.id);
    if (!deletedReservation) {
      return res.status(404).json({ message: 'Reservation not found' });
    }

    // Free the dates this booking was occupying.
    //
    // Deleting the Reservation used to be the whole of this handler, which left
    // the row it had written into `Accommodation.occupancyCalendar` behind. No
    // calendar in this app reads the Reservation collection — the host calendar
    // is built from `occupancyCalendar` alone (HostCalendarController's
    // `buildSnapshot`), and every guest-facing picker goes through
    // `utlis/availability.js` against the same array — so the orphaned row went
    // on withholding the dates for good. It also kept displaying the guest's
    // name, which is denormalised onto the row, next to an "Open reservation"
    // link pointing at a booking that no longer exists.
    //
    // This is the same helper the cancellation flow uses, so a deleted booking
    // and a cancelled one leave the calendar in the same state. It handles its
    // own errors, so a failure here cannot turn a completed delete into a 500.
    await releaseCalendarForReservation(deletedReservation);

    res.status(200).json({ message: 'Reservation deleted successfully' });
  } catch (error) {
    res.status(500).json({ message: error.message });
  }
};

// Get reservations by name
export const getReservationByName = async (req, res) => {
  try {
    const { name } = req.params;

    // Find reservations where the name matches (case-insensitive search)
    const reservations = await Reservation.find({
      name: { $regex: name, $options: 'i' } // Case-insensitive search
    })
    .populate('accommodationId') // Populate accommodationId as needed
    .select('-userId'); // Exclude userId field from results

    if (!reservations.length) {
      return res.status(404).json({ message: 'No reservations found for the given name' });
    }

    res.status(200).json(reservations);
  } catch (error) {
    res.status(500).json({ message: error.message });
  }
};

// Get reservations by accommodation provider ID
export const getReservationByAccommodationProvider = async (req, res) => {
  try {
    const { providerId } = req.params;

    // Validate if the provided providerId is a valid MongoDB ObjectId
    if (!mongoose.Types.ObjectId.isValid(providerId)) {
      return res.status(400).json({ message: 'Invalid accommodation provider ID' });
    }

    // Find reservations that match the accommodation provider ID
    const reservations = await Reservation.find({
      accommodationProvider: providerId
    })
      // The payouts screen reads only the property's name and payout account.
      .populate('accommodationId', 'name slug payoutStripeAccountId')
      .lean();

    if (!reservations.length) {
      return res.status(404).json({ message: 'No reservations found for the given accommodation provider' });
    }

    // When each booking's payout unlocks, decided HERE rather than in the
    // browser.
    //
    // The payouts page used to reconstruct this rule for itself, comparing the
    // browser's local midnight for the check-in date against a local midnight
    // "today". Two things drift out of that. The viewer's midnight is not
    // Europe/Bratislava's, so a host abroad got a window shifted by hours; and
    // flooring "now" to midnight makes the client coarse to the nearest day,
    // which agrees with the server only while PAYOUT_DELAY_HOURS happens to be a
    // multiple of 24. At any other value the host is shown a locked, disabled
    // Withdraw button for hours after the money became withdrawable — or, worse,
    // an enabled one before it did, which fails when pressed.
    //
    // `businessMidnightUtc` + PAYOUT_DELAY_HOURS is exactly what
    // `payoutReservation` enforces, so the button and the gate cannot disagree.
    const withPayoutTiming = reservations.map((r) => ({
      ...r,
      payoutUnlocksAt: new Date(
        businessMidnightUtc(r.checkInDate).getTime() + PAYOUT_DELAY_HOURS * 3600 * 1000
      ),
      payoutDelayHours: PAYOUT_DELAY_HOURS,
    }));

    res.status(200).json(withPayoutTiming);
  } catch (error) {
    res.status(500).json({ message: error.message });
  }
};

// Get reservations by user ID
export const getReservationsByUserId = async (req, res) => {
  try {
    const { userId } = req.params;

    // Validate if the provided userId is a valid MongoDB ObjectId
    if (!mongoose.Types.ObjectId.isValid(userId)) {
      return res.status(400).json({ message: 'Invalid user ID' });
    }

    // Find reservations that match the user ID.
    // Same StrictPopulateError as getReservationById above: `userId` is not on
    // the schema, so populating it threw and this endpoint answered 500 rather
    // than the list — or the 404 below when the guest genuinely had none.
    const reservations = await Reservation.find({ userId: userId }).populate('accommodationId');

    if (!reservations.length) {
      return res.status(404).json({ message: 'No reservations found for the given user' });
    }

    res.status(200).json(reservations);
  } catch (error) {
    res.status(500).json({ message: error.message });
  }
};

// Delete reservations by user ID
export const deleteReservationsByUserId = async (req, res) => {
  try {
    const { userId } = req.params;

    // Validate if the provided userId is a valid MongoDB ObjectId
    if (!mongoose.Types.ObjectId.isValid(userId)) {
      return res.status(400).json({ message: 'Invalid user ID' });
    }

    // Read them before deleting: freeing a booking's dates needs the booking
    // itself, and `deleteMany` does not hand back the documents it removed.
    const doomed = await Reservation.find({ userId: userId });

    if (doomed.length === 0) {
      return res.status(404).json({ message: 'No reservations found for the given user' });
    }

    // Free each booking's dates first, for the reason given in
    // `deleteReservation` above: `occupancyCalendar` is the only source any
    // calendar reads, so a row left there outlives its reservation and blocks
    // those dates permanently.
    for (const reservation of doomed) {
      await releaseCalendarForReservation(reservation);
    }

    // Deleted by the ids just read rather than by the filter again, so a
    // booking created in between is not swept up by it.
    await Reservation.deleteMany({ _id: { $in: doomed.map((r) => r._id) } });

    res.status(200).json({ message: 'Reservations deleted successfully' });
  } catch (error) {
    res.status(500).json({ message: error.message });
  }
};


// Update Reservation Controller
export const updateReservation = async (req, res) => {
  const { id } = req.params; // Reservation ID from the URL
  const updateData = req.body; // Data to update from the request body
  const { language } = req.body; // Extract language if provided

  try {
    // Validate reservation ID
    if (!mongoose.Types.ObjectId.isValid(id)) {
      return res.status(400).json({ error: "Invalid reservation ID" });
    }

    // Find the reservation first to check current state
    let reservation = await Reservation.findById(id).populate('accommodationId');
    if (!reservation) {
      return res.status(404).json({ error: "Reservation not found" });
    }

    // Update language if provided
    if (language) {
      reservation.language = language;
      await reservation.save();
    }

    // Check if we are approving the reservation and it's not already approved
    if (updateData.isApproved === "approved" && reservation.isApproved !== "approved") {
      // Check if total price is 0 (or very small)
      const amountCents = reservation.totalPriceCents || Math.round((reservation.totalPrice || 0) * 100);

      if (amountCents <= 0) {
        // Zero price: Skip payment, finalize immediately
        console.log(`Reservation ${id} has 0 price. Auto-confirming.`);

        // Update reservation status directly
        reservation.paymentStatus = "paid"; // Mark as paid/free
        reservation.isApproved = "approved";
        await reservation.save();

        // Trigger calendar block + confirmation email
        await finalizeReservation(reservation._id);

        return res.status(200).json({
          message: "Reservation approved and confirmed (Free stay)",
          reservation
        });
      }

      // Normal flow: Create Stripe Session.
      //
      // This used to hand-roll its own session with a second Stripe client. It
      // had drifted from the guest-facing path: card-only (no Apple/Google Pay),
      // no PaymentIntent metadata, no locale, no snapshot backfill and no audit
      // line. It now goes through the same builder as every other checkout.
      if (amountCents > 0) {
        try {
          const { session } = await buildCheckoutSession(reservation, {
            language: reservation.language,
            // Same rule as the host workspace's Accept above: approving emails
            // a payment link, so the nights stay available until it is paid.
            reserveDates: false,
          });

          // Save session ID to updates
          updateData.checkoutSessionId = session.id;
          updateData.paymentStatus = "unpaid"; // Ensure it's unpaid initially

          // 2. Send Email to Guest
          const transporter = getTransporter();

          const checkInDate = new Date(reservation.checkInDate).toLocaleDateString();
          const checkOutDate = new Date(reservation.checkOutDate).toLocaleDateString();

          const lang = reservation.language || 'sk'; // Default to Slovak

          const t = {
            en: {
              subject: "Your Reservation is Approved – Complete Payment",
              title: "Your Reservation is Approved!",
              greeting: "Dear",
              approvedMessage: `Good news! Your reservation for <strong>${reservation.accommodationId?.name || "Accommodation"}</strong> has been approved by the host.`,
              detailsHeader: "Reservation Details",
              checkIn: "Check-in",
              checkOut: "Check-out",
              guests: "Guests",
              pets: "Number of Pets",
              totalAmount: "Total Amount",
              paymentInstruction: "To confirm your booking, please complete the payment by clicking the button below:",
              payButton: "Pay Now",
              fallbackLink: "If the button above doesn't work, copy and paste this link into your browser:"
            },
            sk: {
              subject: "Vaša rezervácia je schválená – Dokončite platbu",
              title: "Vaša rezervácia je schválená!",
              greeting: "Vážený/á",
              approvedMessage: `Dobrá správa! Vaša rezervácia pre <strong>${reservation.accommodationId?.name || "Ubytovanie"}</strong> bola schválená hostiteľom.`,
              detailsHeader: "Podrobnosti rezervácie",
              checkIn: "Príchod",
              checkOut: "Odchod",
              guests: "Hostia",
              pets: "Počet zvierat",
              totalAmount: "Celková suma",
              paymentInstruction: "Na potvrdenie vašej rezervácie prosím dokončite platbu kliknutím na tlačidlo nižšie:",
              payButton: "Zaplatiť teraz",
              fallbackLink: "Ak tlačidlo vyššie nefunguje, skopírujte a vložte tento odkaz do vášho prehliadača:"
            }
          };

          const text = t[lang] || t.sk;

          const mailOptions = {
            from: MAIL_FROM,
            to: reservation.email,
            subject: text.subject,
            attachments: logoAttachments(),
            html: brandShell({
              preheader: `${checkInDate} – ${checkOutDate} · €${(amountCents / 100).toFixed(2)}`,
              title: text.title,
              bodyHtml: `
                <p style="margin:0 0 14px 0;">${text.greeting} <strong>${esc(reservation.name)}</strong>,</p>
                <p style="margin:0 0 4px 0;">${text.approvedMessage}</p>
                ${section(
                  text.detailsHeader,
                  detailTable([
                    reservation.unitName && [lang === "en" ? "Unit" : "Jednotka", reservation.unitName],
                    [text.checkIn, checkInDate],
                    [text.checkOut, checkOutDate],
                    [text.guests, String(reservation.numberOfPersons)],
                    reservation.withPet && [
                      text.pets,
                      String(Math.max(1, Number(reservation.numberOfPets) || 1)),
                    ],
                    reservation.extras?.length && [lang === "en" ? "Extras" : "Doplnky", extrasSummary(reservation.extras, lang)],
                    [text.totalAmount, `€${(amountCents / 100).toFixed(2)}`],
                  ])
                )}
                <p style="margin:18px 0 0 0;">${text.paymentInstruction}</p>
                ${button(session.url, text.payButton)}
                <p style="margin:0;color:#6B7280;font-size:13px;word-break:break-all;">
                  ${text.fallbackLink}<br />${esc(session.url)}
                </p>`,
            }),
          };

          await transporter.sendMail(mailOptions);
          console.log(`Payment email sent to ${reservation.email}`);

        } catch (err) {
          console.error("Error generating Stripe session or sending email:", err);
          // We don't block the approval, but we should probably log it or alert
        }
      }
    }

    // Perform the update
    const updatedReservation = await Reservation.findByIdAndUpdate(
      id,
      updateData, // Fields to update
      { new: true, runValidators: true } // Return the updated document and validate data
    );

    // Check if the reservation exists
    if (!updatedReservation) {
      return res.status(404).json({ error: "Reservation not found" });
    }

    // Respond with the updated reservation
    res.status(200).json({
      message: "Reservation updated successfully",
      reservation: updatedReservation,
    });
  } catch (error) {
    // Handle errors
    res.status(500).json({ error: error.message });
  }
};

/* ────────────────────────────────────────────────────────────────────────────
 * Request to book — host responds
 * ──────────────────────────────────────────────────────────────────────────── */

/** Load a request and confirm the caller is the host it belongs to. */
const loadRequestForHost = async (req, res) => {
  const { id } = req.params;
  if (!mongoose.Types.ObjectId.isValid(id)) {
    res.status(400).json({ error: "Invalid reservation id" });
    return null;
  }

  const reservation = await Reservation.findById(id);
  if (!reservation) {
    res.status(404).json({ error: "Reservation not found" });
    return null;
  }

  // The host id must come from the verified token, never the body — otherwise
  // anyone could approve anyone else's request and mail out a payment link.
  const callerId = String(req.userId || req.user?._id || "");
  if (!callerId || callerId !== String(reservation.accommodationProvider)) {
    res.status(403).json({ error: "Not your reservation" });
    return null;
  }

  if (reservation.bookingMode !== "request") {
    res.status(409).json({
      error: "This booking was paid at checkout — there is nothing to approve.",
      code: "not_a_request",
    });
    return null;
  }

  return reservation;
};

/**
 * POST /api/reservation/:id/approve
 *
 * The host accepts. This is the moment the guest is asked for money, so it is
 * also the moment the host must genuinely be able to receive it — hence the
 * check below, which is about the host's live Stripe state rather than the
 * listing's published status. A listing can be PUBLISHED and its host's account
 * restricted an hour later, and there is no version of this flow where charging
 * a guest for a host with nowhere to be paid is acceptable.
 */
export const approveBookingRequest = async (req, res) => {
  try {
    const reservation = await loadRequestForHost(req, res);
    if (!reservation) return;

    if (reservation.isApproved === "cancelled") {
      return res.status(409).json({
        error: "This request has already been cancelled or has expired.",
        code: "request_closed",
      });
    }
    if (reservation.paymentStatus === "paid") {
      return res.status(409).json({ error: "Already paid", code: "already_paid" });
    }

    const host = await Host.findById(reservation.accommodationProvider);
    if (!isHostBookingReady(host)) {
      // 409, not 403: the host is who they say they are, they simply cannot be
      // paid yet. The client turns this into "connect your payout account".
      return res.status(409).json({
        error:
          "Connect a payout account before accepting — there would be nowhere to send the money.",
        code: "host_not_payout_ready",
      });
    }

    // Accepting mails a payment link; it does not take the nights off the
    // market. The guest may open that link hours later or never, and holding
    // the dates in the meantime blocked the host's own calendar on the strength
    // of an intention nobody had paid for. The dates are written by
    // `confirmHold` when the payment settles, and not before.
    //
    // The session still refuses dates that are ALREADY booked, so accepting a
    // request into a known conflict is not possible. What it no longer does is
    // reserve them: two requests for the same nights can both be accepted, and
    // whoever pays first gets them. The other guest is refused at payment time
    // rather than at accept time.
    let session;
    try {
      ({ session } = await buildCheckoutSession(reservation, {
        language: reservation.language,
        // The link is mailed, so it must outlive the browser session a normal
        // checkout assumes.
        expiresInHours: PAYMENT_LINK_HOURS,
        reserveDates: false,
      }));
    } catch (err) {
      if (err.code === "dates_unavailable") {
        return res.status(409).json({
          error: "Those dates have since been taken by a confirmed booking.",
          code: err.code,
          conflictDays: err.conflictDays || [],
        });
      }
      throw err;
    }

    reservation.isApproved = "approved";
    reservation.requestApprovedAt = new Date();
    reservation.paymentLinkUrl = session.url;
    // Take the deadline from the session Stripe actually created. Our requested
    // window is clamped to fit Stripe's limits, so recomputing it here would
    // promise the guest minutes that the link no longer has.
    reservation.paymentLinkExpiresAt = session.expires_at
      ? new Date(session.expires_at * 1000)
      : paymentLinkExpiryFrom();
    await reservation.save();

    const listing = await Accommodation.findById(reservation.accommodationId).select("name");

    await sendGuestPaymentLinkEmail({
      to: reservation.email,
      reservation,
      listingName: listing?.name,
      paymentUrl: session.url,
      expiresAt: reservation.paymentLinkExpiresAt,
    });

    res.status(200).json({
      message: "Request approved. The guest has been sent a payment link.",
      reservation,
      paymentUrl: session.url,
      paymentLinkExpiresAt: reservation.paymentLinkExpiresAt,
    });
  } catch (error) {
    console.error("approveBookingRequest error:", error);
    res.status(500).json({ error: error.message });
  }
};

/**
 * POST /api/reservation/:id/decline
 *
 * The host says no. Nothing was ever charged, so there is no refund to make —
 * the request is simply closed and the guest is told, with somewhere to go next.
 */
export const declineBookingRequest = async (req, res) => {
  try {
    const reservation = await loadRequestForHost(req, res);
    if (!reservation) return;

    if (reservation.paymentStatus === "paid") {
      return res.status(409).json({
        error: "This booking is already paid — cancel it instead so the guest is refunded.",
        code: "already_paid",
      });
    }
    if (reservation.isApproved === "cancelled") {
      return res.status(200).json({ message: "Already closed.", reservation });
    }

    reservation.isApproved = "cancelled";
    reservation.cancelledBy = "host";
    reservation.cancelledAt = new Date();
    reservation.requestDeclinedAt = new Date();
    if (req.body?.reason) reservation.cancellationReason = String(req.body.reason).slice(0, 500);
    await reservation.save();

    const listing = await Accommodation.findById(reservation.accommodationId).select("name");

    await sendGuestRequestClosedEmail({
      to: reservation.email,
      reservation,
      listingName: listing?.name,
      reason: "declined",
      hostMessage: req.body?.reason,
    });

    res.status(200).json({ message: "Request declined. The guest has been notified.", reservation });
  } catch (error) {
    console.error("declineBookingRequest error:", error);
    res.status(500).json({ error: error.message });
  }
};

/**
 * Close out requests nobody answered.
 *
 * Run on a schedule. An unanswered request costs the guest nothing, but leaving
 * it open forever means they never learn to look elsewhere — so after the
 * window it lapses and they get alternatives.
 */
export const expireStaleBookingRequests = async () => {
  const now = new Date();

  try {
    const stale = await Reservation.find({
      bookingMode: "request",
      isApproved: "pending",
      paymentStatus: { $ne: "paid" },
      requestExpiresAt: { $lt: now },
      requestExpiredAt: { $exists: false },
    }).limit(200);

    if (!stale.length) return;

    console.log(`[request-to-book] expiring ${stale.length} unanswered request(s)`);

    for (const reservation of stale) {
      try {
        reservation.isApproved = "cancelled";
        reservation.requestExpiredAt = now;
        reservation.cancelledAt = now;
        reservation.cancellationReason = "Host did not respond in time";
        await reservation.save();

        if (reservation.requestExpiryEmailSentAt) continue;

        const listing = await Accommodation.findById(reservation.accommodationId).select("name");
        const sent = await sendGuestRequestClosedEmail({
          to: reservation.email,
          reservation,
          listingName: listing?.name,
          reason: "expired",
        });

        if (sent) {
          reservation.requestExpiryEmailSentAt = new Date();
          await reservation.save();
        }
      } catch (err) {
        console.error(
          `[request-to-book] could not expire request ${reservation._id}:`,
          err.message
        );
      }
    }
  } catch (err) {
    console.error("[request-to-book] expiry sweep failed:", err.message);
  }
};

export const checkReservationsForAccommodation = async (req, res) => {
  try {
    const { accommodationId, providerId } = req.params;

    const today = new Date();

    const count = await Reservation.countDocuments({
      accommodationId,
      accommodationProvider: providerId,
      isApproved: "approved",               // ignore cancelled or rejected
      checkOutDate: { $gte: today }         // ignore past stays
    });

    return res.json({ count });
  } catch (error) {
    console.error("Error checking reservations:", error);
    return res.status(500).json({ message: "Server error" });
  }
};
