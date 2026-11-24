import crypto from "crypto";
import User from "../models/User.js";
import Host from "../models/Host.js";
import { getTransporter } from "./mailer.js";
import { buildEmailVerificationEmail } from "./emailVerificationEmail.js";

/**
 * Email verification by a 6-digit code instead of a link.
 *
 * A link has to point at a frontend URL, which differs per environment (every
 * `flutter run` on localhost picks a new port) and needs deep-link handling in
 * the app. A code is typed into whichever screen asked for it, so nothing
 * depends on where the app is running.
 *
 * Only a keyed hash of the code is stored. Traveller and host are separate
 * documents that may share an address, so one code is issued to every
 * unverified account with that email: typing it proves control of the inbox,
 * which is the same fact for both.
 */

export const CODE_TTL_MINUTES = 15;
export const RESEND_COOLDOWN_SECONDS = 60;
export const MAX_ATTEMPTS = 5;

const escapeRegex = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

export const emailQuery = (email) => ({
  email: { $regex: new RegExp(`^${escapeRegex(String(email || "").trim())}$`, "i") },
});

const hashCode = (code) =>
  crypto
    .createHmac("sha256", process.env.JWT_SECRET_KEY || "email-verification")
    .update(String(code))
    .digest("hex");

const generateCode = () => crypto.randomInt(0, 1_000_000).toString().padStart(6, "0");

const CODE_FIELDS =
  "+emailVerificationCode +emailVerificationExpires +emailVerificationAttempts +emailVerificationSentAt";

/** Every unverified guest/host document for this address. */
export async function unverifiedAccounts(email) {
  if (!email) return [];
  const q = { ...emailQuery(email), isVerified: { $ne: true } };
  const [guests, hosts] = await Promise.all([
    User.find(q).select(CODE_FIELDS),
    Host.find(q).select(CODE_FIELDS),
  ]);
  return [...guests, ...hosts];
}

/**
 * Issues a fresh code to every unverified account for `email` and mails it.
 *
 * Returns { sent: true } or { sent: false, reason: "none" | "cooldown", retryAfter }.
 * With `force`, the resend cooldown is skipped (used right after registration).
 */
export async function sendVerificationCode(email, { force = false } = {}) {
  const accounts = await unverifiedAccounts(email);
  if (!accounts.length) return { sent: false, reason: "none" };

  if (!force) {
    const lastSent = Math.max(...accounts.map((a) => a.emailVerificationSentAt?.getTime() || 0));
    const elapsed = (Date.now() - lastSent) / 1000;
    if (elapsed < RESEND_COOLDOWN_SECONDS) {
      return { sent: false, reason: "cooldown", retryAfter: Math.ceil(RESEND_COOLDOWN_SECONDS - elapsed) };
    }
  }

  const code = generateCode();
  const now = new Date();
  const expires = new Date(now.getTime() + CODE_TTL_MINUTES * 60 * 1000);

  await Promise.all(
    accounts.map((a) =>
      a.constructor.updateOne(
        { _id: a._id },
        {
          $set: {
            emailVerificationCode: hashCode(code),
            emailVerificationExpires: expires,
            emailVerificationAttempts: 0,
            emailVerificationSentAt: now,
          },
        },
      ),
    ),
  );

  const first = accounts[0];
  const { subject, html, text, attachments } = buildEmailVerificationEmail({
    name: first.name,
    code,
    expiresInMinutes: CODE_TTL_MINUTES,
  });

  if (process.env.NODE_ENV !== "production") {
    // Logged before sending, so local testing works even when SMTP doesn't.
    console.log(`[email-verification] code for ${first.email}: ${code}`);
  }

  await getTransporter().sendMail({
    from: '"UK Stay Hub Support" <support@ukstayhub.co.uk>',
    to: first.email,
    subject,
    html,
    text,
    attachments,
  });

  return { sent: true };
}

/**
 * Checks `code` for `email`. On success every unverified account with that
 * address is marked verified and returned.
 *
 * Returns { ok: true, accounts } or { ok: false, reason: "none" | "expired" | "tooManyAttempts" | "invalid", attemptsLeft }.
 */
export async function checkVerificationCode(email, code) {
  const accounts = (await unverifiedAccounts(email)).filter((a) => a.emailVerificationCode);
  if (!accounts.length) return { ok: false, reason: "none" };

  const clean = String(code || "").replace(/\D/g, "");
  const now = Date.now();
  const candidate = accounts.find((a) => (a.emailVerificationExpires?.getTime() || 0) > now);
  if (!candidate) return { ok: false, reason: "expired" };
  if ((candidate.emailVerificationAttempts || 0) >= MAX_ATTEMPTS) {
    return { ok: false, reason: "tooManyAttempts" };
  }

  const expected = Buffer.from(candidate.emailVerificationCode, "hex");
  const given = Buffer.from(hashCode(clean), "hex");
  const match = clean.length === 6 && expected.length === given.length && crypto.timingSafeEqual(expected, given);

  if (!match) {
    await Promise.all(
      accounts.map((a) => a.constructor.updateOne({ _id: a._id }, { $inc: { emailVerificationAttempts: 1 } })),
    );
    const attemptsLeft = Math.max(0, MAX_ATTEMPTS - (candidate.emailVerificationAttempts || 0) - 1);
    return { ok: false, reason: attemptsLeft === 0 ? "tooManyAttempts" : "invalid", attemptsLeft };
  }

  // Conditional on still being unverified, so a double submit can't send two
  // confirmation emails.
  const verified = [];
  for (const a of accounts) {
    const updated = await a.constructor.findOneAndUpdate(
      { _id: a._id, isVerified: { $ne: true } },
      {
        $set: { isVerified: true },
        $unset: {
          emailVerificationCode: 1,
          emailVerificationExpires: 1,
          emailVerificationAttempts: 1,
          emailVerificationSentAt: 1,
        },
      },
      { new: true },
    );
    if (updated) verified.push(updated);
  }
  return { ok: true, accounts: verified };
}
