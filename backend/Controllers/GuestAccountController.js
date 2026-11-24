/**
 * Guest account screen (`/guest`).
 *
 * Every route here is scoped to the authenticated guest: the account is always
 * loaded from `req.userId`, which `authenticate` reads out of the verified JWT.
 * No id is ever taken from the body, the query or the path, so one guest can
 * never read or edit another guest's profile, password or saved stays.
 */

import bcrypt from "bcryptjs";
import mongoose from "mongoose";

import User from "../models/User.js";
import Accommodation from "../models/Accommodation.js";

/** Fields the guest account screen is allowed to change about itself. */
const EDITABLE_FIELDS = ["name", "lastName", "phoneNumber", "gender", "language"];

const GENDERS = ["male", "female", "other"];
const LANGUAGES = ["Slovak", "English"];

/** E.164, matching the client-side check in GuestLayout. */
const PHONE_PATTERN = /^\+[1-9][0-9]{7,14}$/;

const messages = {
  en: {
    notFound: "Account not found.",
    nameRequired: "Enter your first and last name.",
    phoneInvalid: "Enter a valid international phone number.",
    genderInvalid: "Choose a valid gender.",
    languageInvalid: "Choose a valid language.",
    currentPasswordRequired: "Enter your current password.",
    passwordTooShort: "New password must have at least 8 characters.",
    currentPasswordWrong: "Your current password is incorrect.",
    noPasswordSet: "This account signs in with Google and has no password to change.",
    passwordChanged: "Password changed successfully.",
    accommodationRequired: "An accommodation id is required.",
    accommodationInvalid: "That accommodation id is not valid.",
    accommodationMissing: "Accommodation not found.",
    serverError: "Something went wrong. Please try again.",
  },
};

/** The screen sends `lang`; fall back to Slovak like the rest of the app. */
const t = () => messages.en;

/**
 * The account as the client may see it.
 *
 * Built from an explicit allow-list rather than by deleting `password`, so a
 * field added to the schema later is private until someone opts it in here.
 */
const publicProfile = (user) => ({
  _id: user._id,
  email: user.email,
  name: user.name || "",
  lastName: user.lastName || "",
  phoneNumber: user.phoneNumber || user.phone || "",
  photo: user.photo || "",
  gender: user.gender || "other",
  language: user.language || "Slovak",
  role: user.role,
  isVerified: Boolean(user.isVerified),
  createdAt: user.createdAt,
});

/** Favorites travel as plain id strings; the screen fetches each listing itself. */
const favoriteIds = (user) =>
  (user.favorites || []).map((id) => id.toString());

const loadGuest = async (req, res) => {
  const user = await User.findById(req.userId);
  if (!user) {
    res.status(404).json({ message: t(req).notFound });
    return null;
  }
  return user;
};

// GET /api/guest/me
export const getGuestProfile = async (req, res) => {
  try {
    const user = await loadGuest(req, res);
    if (!user) return;

    res.status(200).json(publicProfile(user));
  } catch (error) {
    console.error("Error in getGuestProfile controller:", error.message);
    res.status(500).json({ message: t(req).serverError });
  }
};

// PATCH /api/guest/me
export const updateGuestProfile = async (req, res) => {
  const copy = t(req);

  try {
    const user = await loadGuest(req, res);
    if (!user) return;

    // Only the allow-listed fields are read, so `role`, `email` and
    // `favorites` cannot be escalated through this endpoint.
    const patch = {};
    for (const field of EDITABLE_FIELDS) {
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

    if (patch.gender !== undefined && !GENDERS.includes(patch.gender)) {
      return res.status(400).json({ message: copy.genderInvalid });
    }

    if (patch.language !== undefined && !LANGUAGES.includes(patch.language)) {
      return res.status(400).json({ message: copy.languageInvalid });
    }

    Object.assign(user, patch);
    await user.save();

    // The screen writes this straight back into AuthContext, so it must be
    // the whole profile and not just the fields that changed.
    res.status(200).json(publicProfile(user));
  } catch (error) {
    console.error("Error in updateGuestProfile controller:", error.message);
    res.status(500).json({ message: copy.serverError });
  }
};

// POST /api/guest/change-password
export const changeGuestPassword = async (req, res) => {
  const copy = t(req);
  const { currentPassword, newPassword } = req.body;

  try {
    const user = await loadGuest(req, res);
    if (!user) return;

    if (!currentPassword) {
      return res.status(400).json({ message: copy.currentPasswordRequired });
    }
    if (!newPassword || String(newPassword).length < 8) {
      return res.status(400).json({ message: copy.passwordTooShort });
    }
    // Google accounts have no local password; there is nothing to verify
    // against, so changing one here would set a password without proof.
    if (!user.password) {
      return res.status(400).json({ message: copy.noPasswordSet });
    }

    const matches = await bcrypt.compare(currentPassword, user.password);
    if (!matches) {
      return res.status(401).json({ message: copy.currentPasswordWrong });
    }

    const salt = await bcrypt.genSalt(10);
    user.password = await bcrypt.hash(newPassword, salt);
    // An account created at checkout carries a password that was emailed. Once
    // the guest has chosen their own, the prompt to do so must stop.
    user.mustChangePassword = false;
    await user.save();

    res.status(200).json({ message: copy.passwordChanged });
  } catch (error) {
    console.error("Error in changeGuestPassword controller:", error.message);
    res.status(500).json({ message: copy.serverError });
  }
};

// GET /api/guest/favorites
export const getGuestFavorites = async (req, res) => {
  try {
    const user = await loadGuest(req, res);
    if (!user) return;

    res.status(200).json({ favorites: favoriteIds(user) });
  } catch (error) {
    console.error("Error in getGuestFavorites controller:", error.message);
    res.status(500).json({ message: t(req).serverError });
  }
};

// POST /api/guest/favorites
export const addGuestFavorite = async (req, res) => {
  const copy = t(req);
  const { accommodationId } = req.body;

  try {
    if (!accommodationId) {
      return res.status(400).json({ message: copy.accommodationRequired });
    }
    if (!mongoose.Types.ObjectId.isValid(accommodationId)) {
      return res.status(400).json({ message: copy.accommodationInvalid });
    }

    const user = await loadGuest(req, res);
    if (!user) return;

    const accommodation = await Accommodation.findById(accommodationId).select("_id");
    if (!accommodation) {
      return res.status(404).json({ message: copy.accommodationMissing });
    }

    // Saving an already-saved stay is a no-op rather than a 400: the heart on
    // a listing can be double-tapped, and the screen only wants the new list.
    if (!favoriteIds(user).includes(accommodationId)) {
      user.favorites.push(accommodationId);
      await user.save();
    }

    res.status(200).json({ favorites: favoriteIds(user) });
  } catch (error) {
    console.error("Error in addGuestFavorite controller:", error.message);
    res.status(500).json({ message: copy.serverError });
  }
};

// DELETE /api/guest/favorites/:accommodationId
export const removeGuestFavorite = async (req, res) => {
  const copy = t(req);
  const { accommodationId } = req.params;

  try {
    const user = await loadGuest(req, res);
    if (!user) return;

    // No existence check on the accommodation: a listing that was deleted
    // upstream must still be removable from a guest's saved stays.
    user.favorites = (user.favorites || []).filter(
      (id) => id.toString() !== accommodationId,
    );
    await user.save();

    res.status(200).json({ favorites: favoriteIds(user) });
  } catch (error) {
    console.error("Error in removeGuestFavorite controller:", error.message);
    res.status(500).json({ message: copy.serverError });
  }
};
