import mongoose from "mongoose";

/**
 * The public Host Profile: what travellers may see about a host.
 *
 * Deliberately separate from the Host account row (name, phone and password
 * stay there) so a host can present a different public name or photo without
 * creating a second identity. One document per host, created on first save;
 * a host without one simply has no public profile yet.
 */
const HostProfileSchema = new mongoose.Schema(
  {
    hostId: {
      type: mongoose.Schema.Types.ObjectId,
      required: true,
      unique: true,
      index: true,
    },
    displayName: { type: String, required: true },
    avatarUrl: { type: String, default: null },
    about: { type: String, default: "" },
    // ISO 639-1 codes the host can communicate in, e.g. ["sk", "en"].
    languages: { type: [String], default: [] },
    // How quickly the host commits to answering; null = not stated.
    responseTime: { type: String, default: null },
  },
  { timestamps: true },
);

export default mongoose.model("HostProfile", HostProfileSchema);
