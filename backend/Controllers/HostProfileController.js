/**
 * Host workspace — the public Host Profile and its photo.
 *
 * The profile is keyed by the authenticated host, so no id travels in any
 * request: there is exactly one profile per account and it is always the
 * caller's own.
 *
 * The photo is a three-step flow, matching the screen:
 *   1. `upload-url` hands back a one-time URL to PUT the original to,
 *   2. the browser PUTs the file there,
 *   3. `prepare` applies the chosen crop and returns the final URLs.
 * Step 2 goes to this server rather than straight to storage because the
 * Cloudinary credentials must not reach the browser. The crop in step 3 is a
 * Cloudinary transformation, so the original is never re-encoded here.
 */

import { randomUUID } from "node:crypto";

import cloudinary from "../utils/cloudinary.js";
import Host from "../models/Host.js";
import HostListing from "../models/HostListing.js";
import HostProfile from "../models/HostProfile.js";

/** Uploads that have been promised a URL but not yet received a file. */
const pendingUploads = new Map();

/** A promised upload slot expires so an abandoned one cannot be used later. */
const UPLOAD_TTL_MS = 15 * 60 * 1000;
const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;
const ALLOWED_TYPES = ["image/jpeg", "image/png", "image/webp"];

const RESPONSE_TIMES = ["within_an_hour", "within_a_day", "within_a_few_days"];

const sweepExpired = () => {
  const now = Date.now();
  for (const [token, entry] of pendingUploads) {
    if (entry.expiresAt < now) pendingUploads.delete(token);
  }
};

/**
 * The profile as the screen wants it, read from the HOST document.
 *
 * `legacy` is the old `HostProfile` row and is consulted ONLY for a host who
 * has never saved through this path (`profileSavedAt` still null). It exists so
 * a host who filled this in before the move does not open the screen to an
 * empty form; the first save writes to the Host document and this is never
 * looked at again. Nothing is migrated and nothing is deleted.
 */
const serialize = (host, legacy = null) => {
  // Once the host has saved, the Host document is the whole truth — otherwise a
  // cleared field (a discarded photo, say) would keep falling back to the stale
  // legacy value and reappear.
  const old = host?.profileSavedAt ? null : legacy;

  return {
    displayName:
      host?.displayName ||
      old?.displayName ||
      [host?.name, host?.lastName].filter(Boolean).join(" ").trim(),
    // `photo` is the Host document's own avatar field; `avatarUrl` is what the
    // screen calls it.
    avatarUrl: host?.photo || old?.avatarUrl || null,
    about: host?.aboutYou || old?.about || "",
    languages:
      (Array.isArray(host?.hostLanguages) && host.hostLanguages.length
        ? host.hostLanguages
        : old?.languages) || [],
    responseTime: host?.responseTime || old?.responseTime || null,
    // The screen shows "Saved <time>"; null means nothing has been saved yet.
    // Never the Host document's `updatedAt` — Stripe webhooks write that.
    savedAt: host?.profileSavedAt || old?.updatedAt || null,
  };
};

/** Only the fields `serialize` reads, as a plain object (this is a read path). */
const loadHost = (hostId) =>
  Host.findById(hostId)
    .select("displayName photo aboutYou hostLanguages responseTime profileSavedAt name lastName")
    .lean();

/** The pre-move row, read only when this host has never saved since. */
const loadLegacy = async (host, hostId) =>
  host?.profileSavedAt ? null : HostProfile.findOne({ hostId }).lean();

// GET /api/host/host-profile
export const getHostProfile = async (req, res) => {
  try {
    const host = await loadHost(req.hostId);
    if (!host) {
      return res.status(401).json({ message: "Host account not found." });
    }

    const legacy = await loadLegacy(host, req.hostId);
    res.status(200).json({ profile: serialize(host, legacy) });
  } catch (error) {
    console.error("Error in getHostProfile controller:", error.message);
    res.status(500).json({ message: "Could not load your host profile." });
  }
};

// PUT /api/host/host-profile
export const saveHostProfile = async (req, res) => {
  try {
    const { displayName, about, languages, responseTime, avatarUrl } = req.body || {};

    if (typeof displayName !== "string" || !displayName.trim()) {
      return res.status(400).json({
        message: "Enter a public display name.",
        code: "displayNameRequired",
      });
    }
    if (displayName.trim().length > 80) {
      return res.status(400).json({
        message: "The display name is too long.",
        code: "displayNameTooLong",
      });
    }
    if (about !== undefined && typeof about !== "string") {
      return res.status(400).json({ message: "About must be text.", code: "aboutInvalid" });
    }
    if (about && about.length > 2_000) {
      return res.status(400).json({ message: "The about text is too long.", code: "aboutTooLong" });
    }
    if (languages !== undefined && !Array.isArray(languages)) {
      return res.status(400).json({ message: "Languages must be a list.", code: "languagesInvalid" });
    }
    if (
      responseTime !== undefined &&
      responseTime !== null &&
      !RESPONSE_TIMES.includes(responseTime)
    ) {
      return res.status(400).json({
        message: "Choose a valid response time.",
        code: "responseTimeInvalid",
      });
    }

    // Written to the Host document, which is where every one of these fields
    // now lives. `about` maps to `aboutYou` and `avatarUrl` to `photo` — the
    // Host document already had both, so nothing is stored twice.
    const host = await Host.findByIdAndUpdate(
      req.hostId,
      {
        $set: {
          displayName: displayName.trim(),
          aboutYou: typeof about === "string" ? about.trim() : "",
          hostLanguages: Array.isArray(languages)
            ? languages
                .filter((code) => typeof code === "string" && code.trim())
                .map((code) => code.trim().toLowerCase())
                .slice(0, 10)
            : [],
          responseTime: responseTime ?? null,
          // The avatar is only ever set through the photo flow below; a client
          // may hand back the URL it was given, but nothing else is accepted.
          ...(typeof avatarUrl === "string" || avatarUrl === null
            ? { photo: avatarUrl }
            : {}),
          // Marks this document as the authority from here on — see `serialize`.
          profileSavedAt: new Date(),
        },
      },
      { new: true },
    );

    if (!host) {
      return res.status(401).json({ message: "Host account not found." });
    }

    res.status(200).json({ profile: serialize(host) });
  } catch (error) {
    console.error("Error in saveHostProfile controller:", error.message);
    res.status(500).json({ message: "Could not save your host profile." });
  }
};

// POST /api/host/host-profile-photo/upload-url
export const createHostProfilePhotoUploadUrl = async (req, res) => {
  try {
    sweepExpired();

    const { name, size, contentType } = req.body || {};

    if (!ALLOWED_TYPES.includes(contentType)) {
      return res.status(400).json({
        message: "Upload a JPEG, PNG or WebP image.",
        code: "contentTypeInvalid",
      });
    }
    if (typeof size !== "number" || !Number.isFinite(size) || size <= 0) {
      return res.status(400).json({ message: "A file size is required.", code: "sizeInvalid" });
    }
    if (size > MAX_UPLOAD_BYTES) {
      return res.status(413).json({ message: "That image is larger than 10 MB.", code: "tooLarge" });
    }

    const token = randomUUID();
    pendingUploads.set(token, {
      hostId: req.hostId.toString(),
      contentType,
      size,
      name: typeof name === "string" ? name.slice(0, 200) : null,
      expiresAt: Date.now() + UPLOAD_TTL_MS,
      objectPath: null,
    });

    // Relative so the browser targets whichever origin served the app; the
    // token is the whole authorisation for this one PUT.
    res.status(201).json({
      uploadUrl: `/api/host/host-profile-photo/upload/${token}`,
      objectPath: token,
      expiresIn: Math.floor(UPLOAD_TTL_MS / 1000),
    });
  } catch (error) {
    console.error("Error in createHostProfilePhotoUploadUrl controller:", error.message);
    res.status(500).json({ message: "Could not start the upload." });
  }
};

// PUT /api/host/host-profile-photo/upload/:token
export const uploadHostProfilePhoto = async (req, res) => {
  try {
    sweepExpired();

    const pending = pendingUploads.get(req.params.token);
    // The slot belongs to the host who asked for it; a token alone is not
    // enough, so a leaked one cannot be redeemed by another account.
    if (!pending || pending.hostId !== req.hostId.toString()) {
      return res.status(404).json({ message: "Upload slot not found or expired." });
    }

    const body = req.body;
    if (!Buffer.isBuffer(body) || body.length === 0) {
      return res.status(400).json({ message: "No image data received." });
    }
    if (body.length > MAX_UPLOAD_BYTES) {
      return res.status(413).json({ message: "That image is larger than 10 MB." });
    }

    const uploaded = await new Promise((resolve, reject) => {
      cloudinary.uploader
        .upload_stream(
          {
            folder: `putko/host-profiles/${req.hostId}`,
            public_id: req.params.token,
            resource_type: "image",
            overwrite: true,
          },
          (error, result) => (error ? reject(error) : resolve(result)),
        )
        .end(body);
    });

    pending.objectPath = uploaded.public_id;
    pendingUploads.set(req.params.token, pending);

    res.status(200).json({ objectPath: req.params.token });
  } catch (error) {
    console.error("Error in uploadHostProfilePhoto controller:", error.message);
    res.status(500).json({ message: "Could not store that image." });
  }
};

// POST /api/host/host-profile-photo/prepare
export const prepareHostProfilePhoto = async (req, res) => {
  try {
    sweepExpired();

    const { objectPath, crop } = req.body || {};
    const pending = pendingUploads.get(objectPath);

    if (!pending || pending.hostId !== req.hostId.toString() || !pending.objectPath) {
      return res.status(404).json({ message: "Upload not found or expired." });
    }

    // The crop comes from the browser as fractions of the image, so it is
    // clamped rather than trusted; an out-of-range box would make Cloudinary
    // reject the transformation.
    const clamp = (value, fallback) => {
      const n = Number(value);
      return Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : fallback;
    };
    const box = {
      x: clamp(crop?.x, 0),
      y: clamp(crop?.y, 0),
      width: clamp(crop?.width, 1) || 1,
      height: clamp(crop?.height, 1) || 1,
    };

    const cropTransform = {
      crop: "crop",
      x: `${box.x}`,
      y: `${box.y}`,
      width: `${box.width}`,
      height: `${box.height}`,
    };

    const url = (size) =>
      cloudinary.url(pending.objectPath, {
        secure: true,
        transformation: [
          cropTransform,
          { width: size, height: size, crop: "fill", gravity: "center" },
          { quality: "auto", fetch_format: "webp" },
        ],
      });

    const avatarUrl = url(256);
    const profileUrl = url(640);

    // The slot is single-use: once a crop is prepared the token must not be
    // redeemable again.
    pendingUploads.delete(objectPath);

    // Straight onto the Host document's own `photo`. `profileSavedAt` is
    // stamped with it so this document becomes the authority immediately —
    // without it a host whose legacy row still holds an old avatar would see
    // the old one come back on the next load.
    await Host.findByIdAndUpdate(req.hostId, {
      $set: { photo: avatarUrl, profileSavedAt: new Date() },
    });

    res.status(200).json({ avatarUrl, profileUrl });
  } catch (error) {
    console.error("Error in prepareHostProfilePhoto controller:", error.message);
    res.status(500).json({ message: "Could not prepare that photo." });
  }
};

// DELETE /api/host/host-profile-photo/:uploadId
export const discardHostProfilePhoto = async (req, res) => {
  try {
    pendingUploads.delete(req.params.uploadId);

    await cloudinary.uploader
      .destroy(`putko/host-profiles/${req.hostId}/${req.params.uploadId}`)
      // A photo that was never stored is not an error for the caller: the
      // point of discard is that the photo is gone either way.
      .catch(() => null);

    await Host.findByIdAndUpdate(req.hostId, {
      // Stamped for the same reason as in `prepare`: a cleared photo must not
      // be undone by the legacy fallback on the next read.
      $set: { photo: null, profileSavedAt: new Date() },
    });

    res.status(200).json({ discarded: true });
  } catch (error) {
    console.error("Error in discardHostProfilePhoto controller:", error.message);
    res.status(500).json({ message: "Could not discard that photo." });
  }
};

/**
 * GET /api/host/host-payouts
 *
 * Read-only readiness: this backend has no payout provider wired to the host
 * workspace yet, so the endpoint reports what is blocking rather than
 * pretending an account exists.
 */
export const getHostPayoutReadiness = async (req, res) => {
  try {
    const [host, listings] = await Promise.all([
      Host.findById(req.hostId).select("stripeAccountId"),
      HostListing.find({ ownerId: req.hostId }).select("status data").lean(),
    ]);

    const connected = Boolean(host?.stripeAccountId);

    const total = listings.length;
    const live = listings.filter((listing) => listing.status === "LIVE").length;
    // The editor's last step asks the host to acknowledge how payouts work;
    // the screen shows how many listings have got that far.
    const acknowledged = listings.filter(
      (listing) => listing.data?.payoutAcknowledged === true,
    ).length;

    res.status(200).json({
      payouts: {
        connected,
        provider: connected ? "stripe" : null,
        listings: { total, live, acknowledged },
        // Machine-readable codes the screen turns into localized copy; they
        // are what still stands between this host and being paid.
        requirements: connected
          ? []
          : ["payout_provider", "identity", "bank_account", "listing_assignment"],
        // The single reason payouts are not ready, or null once they are.
        blocker: connected ? null : { reason: "notConnected", liveListings: live },
      },
    });
  } catch (error) {
    console.error("Error in getHostPayoutReadiness controller:", error.message);
    res.status(500).json({ message: "Could not load payout status." });
  }
};
