// utils/requestToBookEmails.js
//
// The four messages the request-to-book flow sends.
//
// None of them throw. A booking request that was recorded must not be rolled
// back because SMTP was briefly unreachable, so every sender logs its failure
// and returns false; the caller decides whether that matters.

import { getTransporter, MAIL_FROM } from "./mailer.js";
import {
  brandShell,
  button,
  callout,
  esc,
  section,
  logoAttachments,
  SITE,
  INK,
  MUTED,
  TEAL,
  HAIRLINE,
  FOREST,
} from "./emailLayout.js";
import { onboardingStepsHtml } from "./hostOnboardingSteps.js";
import { extrasSummary } from "./pricing.js";
import { formatCents } from "./money.js";

const money = (cents, currency) => formatCents(cents, currency);

const day = (date) =>
  date
    ? new Date(date).toLocaleDateString("en-GB", {
        day: "numeric",
        month: "long",
        year: "numeric",
        timeZone: "UTC",
      })
    : "";

const PET_TYPES = { dog: "Dog", cat: "Cat", other: "Other" };

/** The stay, as a small table. Used in every message so the facts never drift. */
const stayTable = (reservation, listingName) => {
  const rows = [
    [listingName ? "Accommodation" : null, listingName],
    // The unit asked for, on a listing split into units.
    [reservation.unitName ? "Unit" : null, reservation.unitName],
    ["Dates", `${day(reservation.checkInDate)} – ${day(reservation.checkOutDate)}`],
    ["Guests", String(reservation.numberOfPersons || 1)],
    [reservation.withPet ? "Pet" : null, PET_TYPES[reservation.petType] || reservation.petType || "—"],
    [
      reservation.withPet ? "Number of pets" : null,
      String(Math.max(1, Number(reservation.numberOfPets) || 1)),
    ],
    [reservation.extras?.length ? "Extras" : null, extrasSummary(reservation.extras, reservation.currency)],
    ["Total", money(reservation.totalPriceCents, reservation.currency)],
  ].filter(([label]) => label);

  return `
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%"
           style="margin:8px 0 4px 0;font-family:Arial,Helvetica,sans-serif;font-size:15px;">
      ${rows
        .map(
          ([label, value]) => `
        <tr>
          <td style="padding:7px 12px 7px 0;color:${MUTED};white-space:nowrap;">${esc(label)}</td>
          <td style="padding:7px 0;color:${INK};font-weight:bold;">${esc(value)}</td>
        </tr>`
        )
        .join("")}
    </table>`;
};

const send = async (options, label) => {
  try {
    await getTransporter().sendMail({
      from: MAIL_FROM,
      attachments: logoAttachments(),
      ...options,
    });
    return true;
  } catch (err) {
    console.error(`[request-to-book] ${label} email failed:`, err.message);
    return false;
  }
};

/**
 * To the HOST: a real booking is waiting, and the only thing standing between
 * them and the money is onboarding.
 *
 * The amount is in the subject line on purpose. "You have a €340 booking" is a
 * far stronger reason to finish setting up payouts than a reminder to complete
 * a profile, and that is the entire point of this flow.
 *
 * `onboarding` is the object from `hostOnboardingGuidance()`. When the host
 * cannot be paid yet — in ANY listing status, including PUBLISHED, where the
 * missing piece is billing details rather than Stripe — the mail carries the
 * actual sequence of steps, with the ones already behind them ticked off. That
 * matters because this is the one message such a host is guaranteed to open:
 * telling them only that "something is missing" spends the strongest nudge the
 * product has on a sentence they cannot act on.
 *
 * `needsOnboarding` remains accepted on its own so an older caller that has no
 * guidance object still produces the short version rather than throwing.
 */
export const sendHostBookingRequestEmail = async ({
  to,
  reservation,
  listingName,
  hostName,
  needsOnboarding,
  onboarding = null,
}) => {
  const amount = money(reservation.totalPriceCents, reservation.currency);
  const dates = `${day(reservation.checkInDate)} – ${day(reservation.checkOutDate)}`;
  const link = `${SITE}/host/reservations/${encodeURIComponent(reservation._id)}`;
  const payoutsLink = `${SITE}/host/payouts`;

  // The guidance object is the authority when it is present: it is computed
  // from the same blockers the accept endpoint enforces, so the mail cannot
  // promise a one-click approval the API will then refuse.
  const blocked = onboarding ? onboarding.needsOnboarding : Boolean(needsOnboarding);

  // Two quite different messages behind one subject line. An onboarded host has
  // nothing to connect, and telling them to "connect a payout account" reads as
  // a bug — so they are simply asked to approve the guest.
  const onboardingBlock = blocked
    ? `
      ${callout(
        `<strong>${esc(
          onboarding?.headline ||
            "To accept this request, connect a payout account."
        )}</strong><br />
         Once that's done, accept the request in one click and we'll send the guest
         a payment link automatically.`,
        "warning"
      )}
      ${
        onboarding?.steps?.length
          ? section("How to finish", onboardingStepsHtml(onboarding.steps, {
              ink: INK,
              muted: MUTED,
              teal: TEAL,
              hairline: HAIRLINE,
            }))
          : ""
      }
      ${button(payoutsLink, onboarding?.ctaLabel || "Connect account and accept request")}
      <p style="margin:0 0 14px 0;color:${MUTED};font-size:13px;">
        The request won't go anywhere in the meantime — you'll find it in your profile under
        <strong>Reservations</strong>.
      </p>`
    : `
      ${callout(
        `Accept or decline the request under <strong>Reservations</strong>.
         Once you accept, we'll send the guest a payment link valid for 24 hours —
         the booking is confirmed only after payment.`
      )}
      ${button(link, "View request")}`;

  const bodyHtml = `
    <p style="margin:0 0 14px 0;">Hi${hostName ? ` ${esc(hostName)}` : ""},</p>
    <p style="margin:0 0 16px 0;">
      You have a new booking request for <strong>${amount}</strong>.
    </p>
    ${stayTable(reservation, listingName)}
    ${onboardingBlock}
    <p style="margin:0 0 8px 0;color:${MUTED};font-size:14px;">
      The guest hasn't paid anything yet and the dates aren't blocked. If you don't reply
      within 48 hours, the request expires automatically.
    </p>`;

  return send(
    {
      to,
      subject: `New booking request — ${dates}, ${amount}`,
      html: brandShell({
        preheader: `${dates} · ${reservation.numberOfPersons} guest${Number(reservation.numberOfPersons) === 1 ? "" : "s"} · ${amount}`,
        title: "New booking request",
        bodyHtml,
      }),
    },
    "host-request"
  );
};

/** To the GUEST: the request is in, nothing has been charged. */
export const sendGuestRequestReceivedEmail = async ({ to, reservation, listingName }) => {
  const bodyHtml = `
    <p style="margin:0 0 14px 0;">Hi${reservation.name ? ` ${esc(reservation.name)}` : ""},</p>
    <p style="margin:0 0 16px 0;">
      We've sent your booking request to the host. <strong>You haven't been charged anything yet.</strong>
    </p>
    ${stayTable(reservation, listingName)}
    ${callout(
      `The host has 48 hours to reply. If they accept, we'll send you a payment link,
       and the booking is confirmed once you pay. The dates aren't held until then.`
    )}
    <p style="margin:0;color:${MUTED};font-size:14px;">
      Request number: ${esc(String(reservation._id))}
    </p>`;

  return send(
    {
      to,
      subject: "Your booking request has been sent",
      html: brandShell({
        preheader: "You haven't been charged — we're waiting for the host to reply.",
        title: "Request sent",
        bodyHtml,
      }),
    },
    "guest-request-received"
  );
};

/** To the GUEST: approved — here is the payment link, valid 24 hours. */
export const sendGuestPaymentLinkEmail = async ({
  to,
  reservation,
  listingName,
  paymentUrl,
  expiresAt,
}) => {
  const bodyHtml = `
    <p style="margin:0 0 14px 0;">Hi${reservation.name ? ` ${esc(reservation.name)}` : ""},</p>
    <p style="margin:0 0 16px 0;">
      Good news — the host has <strong>accepted</strong> your request. Pay now to confirm your booking.
    </p>
    ${stayTable(reservation, listingName)}
    ${button(paymentUrl, "Pay and confirm booking")}
    ${callout(
      `This link is valid until <strong>${esc(
        new Date(expiresAt).toLocaleString("en-GB", { timeZone: "Europe/London", dateStyle: "long", timeStyle: "short" })
      )}</strong>. The dates are held for you until then — after that they're released.`,
      "warning"
    )}
    <p style="margin:0;color:${MUTED};font-size:13px;word-break:break-all;">
      If the button doesn't work, open this link:<br />${esc(paymentUrl)}
    </p>`;

  return send(
    {
      to,
      subject: "Your booking request was accepted — complete payment",
      html: brandShell({
        preheader: "The host accepted your request. The payment link is valid for 24 hours.",
        title: "Request accepted",
        bodyHtml,
      }),
    },
    "guest-payment-link"
  );
};

/**
 * To the GUEST: declined, or lapsed after 48 hours.
 *
 * Both cases end the same way for the guest, so both offer somewhere to go
 * next rather than a dead end.
 */
export const sendGuestRequestClosedEmail = async ({
  to,
  reservation,
  listingName,
  reason = "declined",
  hostMessage,
}) => {
  const expired = reason === "expired";
  const searchLink = `${SITE}/listings`;

  const bodyHtml = `
    <p style="margin:0 0 14px 0;">Hi${reservation.name ? ` ${esc(reservation.name)}` : ""},</p>
    <p style="margin:0 0 16px 0;">
      ${
        expired
          ? "The host didn't reply to your booking request, so it has expired."
          : "Unfortunately, the host couldn't accept your booking request."
      }
      <strong>You haven't been charged.</strong>
    </p>
    ${stayTable(reservation, listingName)}
    ${hostMessage ? callout(`<em>${esc(hostMessage)}</em>`) : ""}
    <p style="margin:16px 0 0 0;">
      There are other places available for the same dates — take a look and book instantly.
    </p>
    ${button(searchLink, "See available stays")}`;

  return send(
    {
      to,
      subject: expired
        ? "Your booking request has expired"
        : "Your booking request was declined",
      html: brandShell({
        preheader: "You haven't been charged.",
        title: expired ? "Request expired" : "Request declined",
        bodyHtml,
      }),
    },
    "guest-request-closed"
  );
};
