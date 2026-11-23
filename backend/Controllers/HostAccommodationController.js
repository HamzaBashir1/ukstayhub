/**
 * Host workspace — the host's real accommodations.
 *
 * The workspace's Listings section edits `HostListing` drafts, which only
 * exist for places created through its own editor. Everything else a host owns
 * — including every listing added through the traveller-side form — lives in
 * `Accommodation`, and the calendar has to work on those.
 *
 * This is the picker source: enough to choose a property and no more.
 */

import Accommodation from "../models/Accommodation.js";

// GET /api/host/accommodations
export const listOwnedAccommodations = async (req, res) => {
  try {
    const rows = await Accommodation.find({ userId: req.hostId })
      .select("name slug status listingStatus payoutStripeAccountId images locationDetails updatedAt units._id units.name")
      .sort({ updatedAt: -1 })
      .lean();

    res.status(200).json({
      accommodations: rows.map((row) => ({
        id: row._id.toString(),
        name: row.name || "",
        slug: row.slug || null,
        // The model's own lifecycle: DRAFT | PENDING | PUBLISHED.
        status: row.status || "DRAFT",
        // The Stripe-driven lifecycle the payouts screen reads, and which
        // account this property is paid through.
        listingStatus: row.listingStatus || row.status || "DRAFT",
        payoutStripeAccountId: row.payoutStripeAccountId || null,
        city: row.locationDetails?.city || "",
        coverUrl: Array.isArray(row.images) ? row.images[0] || null : null,
        updatedAt: row.updatedAt,
        // Sub-units (A1, A2, …) for pickers that can block one unit. Empty on
        // a listing without units.
        units: (Array.isArray(row.units) ? row.units : [])
          .filter((unit) => typeof unit?.name === "string" && unit.name.trim())
          .map((unit) => ({ id: unit._id.toString(), name: unit.name })),
      })),
    });
  } catch (error) {
    console.error("Error in listOwnedAccommodations controller:", error.message);
    res.status(500).json({ message: "Could not load your properties." });
  }
};
