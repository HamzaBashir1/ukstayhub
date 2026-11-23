// Shared by the host's own "change email" flow and the admin panel's.
// Whoever authorises the change, the rules and what moves with it are the same.
import Host from "../models/Host.js";
import User from "../models/User.js";
import Invoice from "../models/Invoice.js";

export const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const escapeRegex = (value) => String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
export const sameEmail = (email) => new RegExp(`^${escapeRegex(email)}$`, "i");

/** Lower-cased, trimmed; what gets stored. */
export const normaliseNewEmail = (value) => String(value || "").trim().toLowerCase();

/**
 * Why `newEmail` cannot be used: "invalid" | "same" | "taken", or null if fine.
 * A traveller account on the new address would be silently linked to this host
 * by the mode switch (which matches on email alone), so that is refused outright.
 */
export const emailProblemCode = async (host, newEmail) => {
  if (!EMAIL_PATTERN.test(newEmail)) return "invalid";
  if (sameEmail(host.email).test(newEmail)) return "same";
  const [hostClash, guestClash] = await Promise.all([
    Host.exists({ email: sameEmail(newEmail), _id: { $ne: host._id } }),
    User.exists({ email: sameEmail(newEmail) }),
  ]);
  return hostClash || guestClash ? "taken" : null;
};

/**
 * Switch `host` to `newEmail` (already validated). Listings, reservations and
 * invoices reference the host by id, so none of them move. Two things DO hold a
 * copy of the address and are carried over:
 *  - the traveller account the mode switch links to (matched on email)
 *  - invoices not yet sent, whose recipient was snapshotted when created
 * Returns the previous address. Throws (after restoring the host) if the linked
 * updates fail, so the two accounts never end up on different addresses.
 */
export const applyHostEmailChange = async (host, newEmail) => {
  const oldEmail = host.email;
  host.email = newEmail;
  host.isVerified = true; // the new address was proven (code) or set by an admin
  await host.save();

  try {
    await User.updateOne({ email: sameEmail(oldEmail) }, { $set: { email: newEmail } });
    await Invoice.updateMany(
      { host: host._id, status: { $in: ["draft", "creating", "issued", "failed"] } },
      { $set: { "hostSnapshot.email": newEmail } },
    );
  } catch (linkError) {
    host.email = oldEmail;
    await host.save();
    throw linkError;
  }

  console.log(`[putko-audit] host.email.changed host=${host._id} at=${new Date().toISOString()}`);
  return oldEmail;
};
