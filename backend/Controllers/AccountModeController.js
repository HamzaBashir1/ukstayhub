/**
 * Switching between traveller and host mode.
 *
 * A traveller is a `User` document and a host is a `Host` document — two rows,
 * two passwords, two tokens. Switching mode therefore means issuing a token for
 * the *other* account, and the only thing linking them is the email address.
 *
 * That makes the verified email a trust boundary, so the rules are strict:
 *
 * 1. The caller must already hold a valid token for the account they are
 *    leaving (`authenticate` has run), and that account's email must be
 *    verified — it is the only thing the switch is decided on.
 * 2. If a counterpart already exists, it is *claimed*, so it too must have a
 *    verified email. Without that, registering a host with someone else's
 *    address would hand over their traveller account.
 * 3. If no counterpart exists, one is created from the caller's own record —
 *    same name, email, password hash and verification state. Nothing existing
 *    is taken over, so this needs no extra proof, and one password opens both
 *    sides, which is what "the same person in two modes" should mean.
 * 4. Emails are compared case-insensitively but exactly — no normalisation
 *    beyond trimming and lowercasing, so `a+b@x.com` never matches `a@x.com`.
 *
 * Every switch is logged with both account ids, and whether the second was
 * created, so the trail exists if an address is ever re-assigned.
 */

import jwt from "jsonwebtoken";

import Host from "../models/Host.js";
import User from "../models/User.js";

const MODES = ["guest", "host"];

/** Same claims and lifetime as a normal sign-in, so nothing downstream cares. */
const generateToken = (account) =>
  jwt.sign(
    { id: account._id, role: account.role },
    process.env.JWT_SECRET_KEY,
    { expiresIn: "30d" },
  );

const messages = {
  en: {
    modeInvalid: 'Mode must be "guest" or "host".',
    alreadyInMode: "You are already in that mode.",
    accountMissing: "Your current account could not be found.",
    noEmail: "This account has no email address to match on.",
    sourceUnverified:
      "Verify your current account's email address before switching mode.",
    noCounterpartGuest:
      "No traveller account uses this email address yet. Sign up as a traveller to continue.",
    noCounterpartHost:
      "No host account uses this email address yet. Sign up as a host to continue.",
    counterpartUnverified:
      "The other account with this email address has not verified its email yet.",
    serverError: "Could not switch mode. Please try again.",
  },
};

const t = () => messages.en;

/** Case-insensitive but otherwise exact — no plus-address folding. */
const normaliseEmail = (email) =>
  typeof email === "string" ? email.trim().toLowerCase() : null;

// POST /api/auth/mode
export const switchAccountMode = async (req, res) => {
  const copy = t(req);

  try {
    const { mode } = req.body || {};
    if (!MODES.includes(mode)) {
      return res.status(400).json({ message: copy.modeInvalid, code: "modeInvalid" });
    }

    const currentRole = req.role === "host" ? "host" : "guest";
    if (mode === currentRole) {
      return res.status(409).json({ message: copy.alreadyInMode, code: "alreadyInMode" });
    }

    // The account being left, loaded from the token rather than the body.
    const SourceModel = currentRole === "host" ? Host : User;
    const source = await SourceModel.findById(req.userId).select("email isVerified");
    if (!source) {
      return res.status(404).json({ message: copy.accountMissing, code: "accountMissing" });
    }

    const email = normaliseEmail(source.email);
    if (!email) {
      return res.status(409).json({ message: copy.noEmail, code: "noEmail" });
    }
    if (!source.isVerified) {
      return res
        .status(403)
        .json({ message: copy.sourceUnverified, code: "sourceUnverified" });
    }

    // The account being entered. Matched on email only — never on an id from
    // the request, which the caller controls.
    const TargetModel = mode === "host" ? Host : User;
    let target = await TargetModel.findOne({
      email: new RegExp(`^${email.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`, "i"),
    });

    // No counterpart yet: create one from the account the caller is already
    // signed in to. This is safe in a way that *linking* is not — nothing
    // existing is being claimed, the new document is built from the caller's
    // own record, and the identity, password and verification state are copied
    // across rather than asserted. One password therefore opens both sides,
    // which is what "the same person in two modes" should mean.
    let created = false;
    if (!target) {
      const full = await SourceModel.findById(req.userId).select(
        "+password name lastName email photo gender language isVerified",
      );

      target = await TargetModel.create({
        name: full.name,
        lastName: full.lastName,
        email: full.email,
        password: full.password,
        photo: full.photo,
        gender: full.gender,
        language: full.language,
        // The address is the same one and was already proven on the other
        // side, so re-verifying it would ask the person to prove a fact they
        // have already proven. An unverified source stays unverified here.
        isVerified: full.isVerified,
        role: mode === "host" ? "host" : "guest",
      });
      created = true;
    } else if (!target.isVerified) {
      // Only reached for a pre-existing counterpart: that document was created
      // by someone, and until its address is verified there is nothing to say
      // that someone is this caller.
      return res.status(403).json({
        message: copy.counterpartUnverified,
        code: "counterpartUnverified",
      });
    }

    const token = generateToken(target);
    const { password: _password, booking: _booking, role, ...rest } = target._doc;

    // Both ids, so a switch can still be traced if an address is re-assigned.
    console.log(
      `[putko-audit] account.mode-switch from=${currentRole}:${req.userId} to=${mode}:${target._id} created=${created} at=${new Date().toISOString()}`,
    );

    // Same envelope as POST /api/auth/login, so the client stores the new
    // session exactly the way it stores one from signing in.
    res.status(200).json({
      status: true,
      token,
      data: { ...rest },
      role,
      // The UI shows onboarding the first time a mode is entered.
      created,
    });
  } catch (error) {
    console.error("Error in switchAccountMode controller:", error.message);
    res.status(500).json({ message: copy.serverError, code: "serverError" });
  }
};

/**
 * GET /api/auth/mode/available
 *
 * What the header dropdown should offer. Since a missing counterpart is now
 * created on demand, the switch is available to any verified account — what
 * this adds is `counterpartExists`, so the menu can say "Switch to hosting"
 * rather than "Become a host" without guessing.
 *
 * Deliberately returns booleans only — never the other account's details.
 */
export const getAvailableModes = async (req, res) => {
  try {
    const currentRole = req.role === "host" ? "host" : "guest";
    const SourceModel = currentRole === "host" ? Host : User;
    const source = await SourceModel.findById(req.userId).select("email isVerified");

    if (!source) {
      return res.status(404).json({ message: t(req).accountMissing });
    }

    const email = normaliseEmail(source.email);
    const other = currentRole === "host" ? "guest" : "host";

    // An unverified account cannot switch at all: the email is the only thing
    // the switch is decided on, so it has to be proven first.
    if (!email || !source.isVerified) {
      return res.status(200).json({
        currentMode: currentRole,
        canSwitchTo: [],
        counterpartExists: false,
        reason: "emailUnverified",
      });
    }

    const TargetModel = other === "host" ? Host : User;
    const target = await TargetModel.findOne({
      email: new RegExp(`^${email.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`, "i"),
    }).select("isVerified");

    // An existing but unverified counterpart is the one case the switch still
    // refuses, so it must not be offered.
    const blocked = Boolean(target) && !target.isVerified;

    res.status(200).json({
      currentMode: currentRole,
      canSwitchTo: blocked ? [] : [other],
      counterpartExists: Boolean(target),
      ...(blocked ? { reason: "counterpartUnverified" } : {}),
    });
  } catch (error) {
    console.error("Error in getAvailableModes controller:", error.message);
    res.status(500).json({ message: t(req).serverError });
  }
};
