/**
 * Host workspace — the host's own account: personal details and password.
 *
 * The mirror of `GuestAccountController` for the other collection. It exists
 * because a host is a real account with its own name, email and password, so
 * editing those should not require switching into traveller mode — and because
 * the only existing way to change a host was `PUT /api/hosts/:id`, which takes
 * the id from the URL and checks nothing.
 *
 * Like the guest routes, everything here is resolved from the token: the host
 * being edited is always `req.hostId`, never an id from the request.
 */

import bcrypt from "bcryptjs";

import Host from "../models/Host.js";
import { applyHostEmailChange, emailProblemCode, normaliseNewEmail } from "../utils/hostEmailChange.js";
import { getTransporter, MAIL_FROM } from "../utils/mailer.js";
import { buildHostEmailChangedNotice } from "../utils/hostEmailChangeEmail.js";
import { missingBillingFieldsOf } from "../utils/hostBilling.js";

/** What the account screen may change about itself. */
const EDITABLE_FIELDS = ["name", "lastName", "phoneNumber", "gender", "address", "aboutYou"];

/**
 * Invoicing identity — same fields EditProfile / BillingDetailsModal collect
 * on the traveller side, saved through this authenticated, `req.hostId`-scoped
 * endpoint instead of the legacy `PUT /api/hosts/:id` (which takes the id from
 * the URL and checks nothing).
 */
const BILLING_EDITABLE_FIELDS = [
  "billingSubjectType",
  "companyName",
  "ico",
  "dic",
  "icDph",
  "streetNumber",
  "city",
  "zipcode",
  "countryCode",
  "isVatPayer",
  "vatinParagraph",
];

const GENDERS = ["male", "female", "other"];
const BILLING_SUBJECT_TYPES = ["business", "individual"];

/** E.164, matching the client-side check. */
const PHONE_PATTERN = /^\+[1-9][0-9]{7,14}$/;

/** Digits only, so "811 01" and "81101" are the same ZIP. */
const digits = (value) => String(value ?? "").replace(/\D/g, "");

const messages = {
  en: {
    notFound: "Account not found.",
    nameRequired: "Enter your first and last name.",
    phoneInvalid: "Enter a valid international phone number.",
    genderInvalid: "Choose a valid gender.",
    currentPasswordRequired: "Enter your current password.",
    passwordTooShort: "New password must have at least 8 characters.",
    currentPasswordWrong: "Your current password is incorrect.",
    noPasswordSet: "This account signs in with Google and has no password to change.",
    passwordChanged: "Password changed successfully.",
    serverError: "Something went wrong. Please try again.",
    subjectTypeInvalid: "Choose a valid billing type.",
    billingNameRequired: "Enter a billing name.",
    icoRequired: "IČO is required for a business.",
    icoInvalid: "IČO must contain 6 to 8 digits.",
    dicRequired: "DIČ is required for a business.",
    dicInvalid: "A Slovak DIČ is 10 digits.",
    icDphInvalid: "IČ DPH looks like SK2020123456, or leave it empty.",
    streetRequired: "Street and number are required.",
    cityRequired: "City is required.",
    zipRequired: "ZIP code is required.",
    zipInvalid: "A Slovak ZIP is 5 digits.",
    countryRequired: "Country is required.",
    emailInvalid: "Enter a valid email address.",
    emailSame: "That is already your email address.",
    emailTaken: "This email address is already used by another account.",
    emailChanged: "Your email address was updated.",
  },
};

const t = () => messages.en;

/**
 * The account as the screen may see it.
 *
 * An allow-list rather than "delete password", so a field added to the Host
 * schema later — and that schema carries payout and Stripe state — stays
 * private until someone opts it in here.
 */
const publicAccount = (host) => {
  const missing = missingBillingFieldsOf(host);
  return {
    _id: host._id,
    email: host.email,
    name: host.name || "",
    lastName: host.lastName || "",
    phoneNumber: host.phoneNumber || host.phone || "",
    photo: host.photo || "",
    gender: host.gender || "other",
    address: host.address || "",
    aboutYou: host.aboutYou || "",
    role: host.role,
    isVerified: Boolean(host.isVerified),
    createdAt: host.createdAt,
    // Invoicing identity for the platform-fee invoice and the annual DAC7
    // filing — never shown to guests. Falls back to the legacy free-text
    // columns so a host who filled those in years ago is not asked twice.
    billing: {
      subjectType: host.billingSubjectType || "business",
      companyName: host.companyName || "",
      ico: host.ico || host.idNumber || "",
      dic: host.dic || host.tin || "",
      icDph: host.icDph || host.vatNumber || "",
      streetNumber: host.streetNumber || "",
      city: host.city || "",
      zipcode: host.zipcode || "",
      countryCode: host.countryCode || host.country || "GB",
      isVatPayer: Boolean(host.isVatPayer),
      vatinParagraph: host.vatinParagraph || "",
      complete: missing.length === 0,
      missing,
    },
  };
};

// GET /api/host/account
export const getHostAccount = async (req, res) => {
  try {
    const host = await Host.findById(req.hostId);
    if (!host) return res.status(404).json({ message: t(req).notFound });

    res.status(200).json({ account: publicAccount(host) });
  } catch (error) {
    console.error("Error in getHostAccount controller:", error.message);
    res.status(500).json({ message: t(req).serverError });
  }
};

// PATCH /api/host/account
export const updateHostAccount = async (req, res) => {
  const copy = t(req);

  try {
    const host = await Host.findById(req.hostId);
    if (!host) return res.status(404).json({ message: copy.notFound });

    // Only the allow-listed fields are read, so `email`, `role` and the Stripe
    // payout state cannot be changed through this endpoint.
    const patch = {};
    for (const field of [...EDITABLE_FIELDS, ...BILLING_EDITABLE_FIELDS]) {
      if (req.body[field] !== undefined) patch[field] = req.body[field];
    }

    if (patch.name !== undefined) patch.name = String(patch.name).trim();
    if (patch.lastName !== undefined) patch.lastName = String(patch.lastName).trim();
    if (patch.name === "" || patch.lastName === "") {
      return res.status(400).json({ message: copy.nameRequired });
    }

    if (patch.phoneNumber !== undefined) {
      patch.phoneNumber = String(patch.phoneNumber).replace(/\s/g, "");
      if (!PHONE_PATTERN.test(patch.phoneNumber)) {
        return res.status(400).json({ message: copy.phoneInvalid });
      }
    }

    // Billing identity: same rules BillingDetailsModal / EditProfile enforce in
    // the browser, checked again here since the server is the one that must
    // actually be able to raise a compliant invoice from what gets saved.
    if (Object.keys(patch).some((field) => BILLING_EDITABLE_FIELDS.includes(field))) {
      const subjectType = patch.billingSubjectType ?? host.billingSubjectType ?? "business";
      if (patch.billingSubjectType !== undefined && !BILLING_SUBJECT_TYPES.includes(subjectType)) {
        return res.status(400).json({ message: copy.subjectTypeInvalid });
      }
      const isBusiness = subjectType === "business";
      const countryCode = (patch.countryCode ?? host.countryCode ?? "GB").trim().toUpperCase();
      const isSlovak = countryCode === "SK";

      const companyName = (patch.companyName ?? host.companyName ?? "").trim();
      if (patch.companyName !== undefined) patch.companyName = companyName;
      if (!companyName) return res.status(400).json({ message: copy.billingNameRequired });

      if (isBusiness) {
        const ico = (patch.ico ?? host.ico ?? "").trim();
        if (patch.ico !== undefined) patch.ico = ico;
        if (!ico) return res.status(400).json({ message: copy.icoRequired });
        const icoDigits = digits(ico).length;
        if (icoDigits < 6 || icoDigits > 8) return res.status(400).json({ message: copy.icoInvalid });

        const dic = (patch.dic ?? host.dic ?? "").trim();
        if (patch.dic !== undefined) patch.dic = dic;
        if (!dic) return res.status(400).json({ message: copy.dicRequired });
        if (isSlovak && digits(dic).length !== 10) {
          return res.status(400).json({ message: copy.dicInvalid });
        }
      }

      if (patch.icDph !== undefined) {
        const icDph = patch.icDph.replace(/\s/g, "").toUpperCase();
        if (icDph && !/^[A-Z]{2}\d{8,12}$/.test(icDph)) {
          return res.status(400).json({ message: copy.icDphInvalid });
        }
        // Writing an empty string would flip a VAT-registered host to "no VAT
        // ID" on the next invoice, so only a real value updates anything.
        if (icDph) {
          patch.icDph = icDph;
          patch.isVatPayer = true;
        } else {
          delete patch.icDph;
        }
      }

      const streetNumber = (patch.streetNumber ?? host.streetNumber ?? "").trim();
      if (patch.streetNumber !== undefined) {
        patch.streetNumber = streetNumber;
        if (!streetNumber) return res.status(400).json({ message: copy.streetRequired });
      }
      const city = (patch.city ?? host.city ?? "").trim();
      if (patch.city !== undefined) {
        patch.city = city;
        if (!city) return res.status(400).json({ message: copy.cityRequired });
      }
      const zipcode = (patch.zipcode ?? host.zipcode ?? "").trim();
      if (patch.zipcode !== undefined) {
        patch.zipcode = zipcode;
        if (!zipcode) return res.status(400).json({ message: copy.zipRequired });
        if (isSlovak && digits(zipcode).length !== 5) {
          return res.status(400).json({ message: copy.zipInvalid });
        }
      }
      if (patch.countryCode !== undefined) {
        patch.countryCode = countryCode;
        if (!countryCode) return res.status(400).json({ message: copy.countryRequired });
      }
    }

    if (patch.gender !== undefined && !GENDERS.includes(patch.gender)) {
      return res.status(400).json({ message: copy.genderInvalid });
    }

    Object.assign(host, patch);
    await host.save();

    res.status(200).json({ account: publicAccount(host) });
  } catch (error) {
    console.error("Error in updateHostAccount controller:", error.message);
    res.status(500).json({ message: copy.serverError });
  }
};

// POST /api/host/account/change-password
export const changeHostPassword = async (req, res) => {
  const copy = t(req);
  const { currentPassword, newPassword } = req.body;

  try {
    const host = await Host.findById(req.hostId);
    if (!host) return res.status(404).json({ message: copy.notFound });

    if (!currentPassword) {
      return res.status(400).json({ message: copy.currentPasswordRequired });
    }
    if (!newPassword || String(newPassword).length < 8) {
      return res.status(400).json({ message: copy.passwordTooShort });
    }
    // Google accounts have no local password; there is nothing to verify
    // against, so setting one here would be setting it without proof.
    if (!host.password) {
      return res.status(400).json({ message: copy.noPasswordSet });
    }

    const matches = await bcrypt.compare(currentPassword, host.password);
    if (!matches) {
      return res.status(401).json({ message: copy.currentPasswordWrong });
    }

    const salt = await bcrypt.genSalt(10);
    host.password = await bcrypt.hash(newPassword, salt);
    await host.save();

    res.status(200).json({ message: copy.passwordChanged });
  } catch (error) {
    console.error("Error in changeHostPassword controller:", error.message);
    res.status(500).json({ message: copy.serverError });
  }
};

/* ------------------------------------------------------------ email change */

// PATCH /api/host/account/email
//
// One step: the host types the new address and their current password, and the
// email is updated straight away. The password is the proof it is really them
// (a stolen session alone cannot re-route their mail or lock them out).
// The shared helper also moves the linked traveller account and unsent invoices.
export const changeHostEmail = async (req, res) => {
  const copy = t(req);
  try {
    const host = await Host.findById(req.hostId);
    if (!host) return res.status(404).json({ message: copy.notFound });

    const { currentPassword } = req.body;
    const newEmail = normaliseNewEmail(req.body.newEmail);

    if (!currentPassword) return res.status(400).json({ message: copy.currentPasswordRequired });
    if (!host.password) return res.status(400).json({ message: copy.noPasswordSet });
    if (!(await bcrypt.compare(currentPassword, host.password))) {
      return res.status(401).json({ message: copy.currentPasswordWrong });
    }

    const problem = await emailProblemCode(host, newEmail);
    if (problem) {
      const key = { invalid: "emailInvalid", same: "emailSame", taken: "emailTaken" }[problem];
      return res.status(problem === "taken" ? 409 : 400).json({ message: copy[key] });
    }

    const oldEmail = await applyHostEmailChange(host, newEmail);

    // Tell the OLD address, so a hijacked session cannot re-route mail silently.
    // Best effort: the change has already happened.
    try {
      const notice = buildHostEmailChangedNotice({ newEmail, lang: req.body?.lang });
      await getTransporter().sendMail({ from: MAIL_FROM, to: oldEmail, ...notice });
    } catch (mailError) {
      console.error("host email change: could not notify old address:", mailError.message);
    }

    res.status(200).json({ message: copy.emailChanged, account: publicAccount(host) });
  } catch (error) {
    if (error?.code === 11000) return res.status(409).json({ message: copy.emailTaken });
    console.error("Error in changeHostEmail controller:", error.message);
    res.status(500).json({ message: copy.serverError });
  }
};
