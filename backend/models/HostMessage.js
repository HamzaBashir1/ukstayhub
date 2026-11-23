import mongoose from "mongoose";

/**
 * One message in a host ↔ guest thread.
 *
 * `clientKey` is supplied by the sender and unique within a conversation, so a
 * retried send after a lost response can never store the same message twice.
 */
const HostMessageSchema = new mongoose.Schema(
  {
    conversationId: {
      type: mongoose.Schema.Types.ObjectId,
      ref: "HostConversation",
      required: true,
      index: true,
    },
    sender: {
      type: String,
      enum: ["host", "guest"],
      required: true,
    },
    body: { type: String, required: true },
    clientKey: { type: String, default: null },
  },
  { timestamps: true },
);

HostMessageSchema.index({ conversationId: 1, createdAt: 1 });
HostMessageSchema.index(
  { conversationId: 1, clientKey: 1 },
  { unique: true, partialFilterExpression: { clientKey: { $type: "string" } } },
);

export default mongoose.model("HostMessage", HostMessageSchema);
