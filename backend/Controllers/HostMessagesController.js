/**
 * Host workspace — messages.
 *
 * A thread is participant-only: the host side is whoever owns the listing, and
 * that is resolved on the server for every request, so a conversation id from
 * the client can never open someone else's thread.
 *
 * Read state lives on the conversation as `hostLastReadAt`, so "unread" means
 * "sent by the guest after that moment" — one update to mark read, one query
 * to count.
 *
 * There is no push transport: the screens poll while open.
 */

import mongoose from "mongoose";

import HostConversation from "../models/HostConversation.js";
import HostListing from "../models/HostListing.js";
import HostMessage from "../models/HostMessage.js";
import HostReservation from "../models/HostReservation.js";
import Reservation from "../models/Reservation.js";
import { isObjectId, ownedListingIds } from "../utils/hostWorkspace.js";

const NOT_FOUND = { message: "Conversation not found." };
const MAX_BODY_LENGTH = 4_000;

/**
 * The unit booked for each conversation tied to a booking, on a listing split
 * into units (A1, A2, …). Conversations without a booking, and bookings
 * without a unit, are simply absent from the map.
 */
const unitNamesFor = async (conversations) => {
  const ids = conversations.map((row) => row.reservationId).filter(Boolean);
  if (!ids.length) return new Map();
  const rows = await Reservation.find({ _id: { $in: ids }, unitName: { $nin: [null, ""] } })
    .select("unitName")
    .lean();
  return new Map(rows.map((row) => [row._id.toString(), row.unitName]));
};

const serializeConversation = (conversation, listing, extra = {}, unitNames = new Map()) => ({
  id: conversation._id.toString(),
  accommodationId: conversation.listingId.toString(),
  listing: listing
    ? { id: listing._id.toString(), name: listing.data?.name || "" }
    : null,
  guest: {
    name: conversation.guestName,
    email: conversation.guestEmail,
  },
  reservation: conversation.reservationId
    ? {
        id: conversation.reservationId.toString(),
        // Only present when the booking is for one unit of the listing.
        ...(unitNames.get(conversation.reservationId.toString())
          ? { unitName: unitNames.get(conversation.reservationId.toString()) }
          : {}),
      }
    : null,
  source: conversation.source,
  lastMessageAt: conversation.lastMessageAt,
  hostLastReadAt: conversation.hostLastReadAt,
  createdAt: conversation.createdAt,
  ...extra,
});

const serializeMessage = (message) => ({
  id: message._id.toString(),
  senderRole: message.sender,
  body: message.body,
  clientKey: message.clientKey,
  createdAt: message.createdAt,
});

// GET /api/host/host-conversations
export const listHostConversations = async (req, res) => {
  try {
    const listingIds = await ownedListingIds(req.hostId);
    if (listingIds.length === 0) return res.status(200).json({ conversations: [] });

    const query = { listingId: { $in: listingIds } };

    const { accommodationId } = req.query;
    if (accommodationId) {
      if (!isObjectId(accommodationId)) {
        return res.status(400).json({ message: "Unknown property filter." });
      }
      if (!listingIds.some((id) => id.toString() === accommodationId)) {
        return res.status(404).json({ message: "Listing not found." });
      }
      query.listingId = new mongoose.Types.ObjectId(accommodationId);
    }

    const conversations = await HostConversation.find(query).sort({ lastMessageAt: -1 });
    if (conversations.length === 0) return res.status(200).json({ conversations: [] });

    const conversationIds = conversations.map((row) => row._id);

    const [listings, lastMessages, unreadCounts] = await Promise.all([
      HostListing.find({ _id: { $in: listingIds } }).select("_id data"),
      // Newest message per thread, for the list preview.
      HostMessage.aggregate([
        { $match: { conversationId: { $in: conversationIds } } },
        { $sort: { createdAt: -1 } },
        { $group: { _id: "$conversationId", body: { $first: "$body" }, sender: { $first: "$sender" }, createdAt: { $first: "$createdAt" } } },
      ]),
      // Guest messages newer than the host's read mark.
      HostMessage.aggregate([
        { $match: { conversationId: { $in: conversationIds }, sender: "guest" } },
        {
          $lookup: {
            from: HostConversation.collection.name,
            localField: "conversationId",
            foreignField: "_id",
            as: "conversation",
          },
        },
        { $unwind: "$conversation" },
        {
          $match: {
            $expr: {
              $or: [
                { $eq: ["$conversation.hostLastReadAt", null] },
                { $gt: ["$createdAt", "$conversation.hostLastReadAt"] },
              ],
            },
          },
        },
        { $group: { _id: "$conversationId", count: { $sum: 1 } } },
      ]),
    ]);

    const unitNames = await unitNamesFor(conversations);
    const listingById = new Map(listings.map((l) => [l._id.toString(), l]));
    const lastById = new Map(lastMessages.map((m) => [m._id.toString(), m]));
    const unreadById = new Map(unreadCounts.map((u) => [u._id.toString(), u.count]));

    res.status(200).json({
      conversations: conversations.map((conversation) => {
        const key = conversation._id.toString();
        const last = lastById.get(key);
        return serializeConversation(
          conversation,
          listingById.get(conversation.listingId.toString()),
          {
            unreadCount: unreadById.get(key) || 0,
            lastMessage: last
              ? { body: last.body, senderRole: last.sender, createdAt: last.createdAt }
              : null,
          },
          unitNames,
        );
      }),
    });
  } catch (error) {
    console.error("Error in listHostConversations controller:", error.message);
    res.status(500).json({ message: "Could not load your messages." });
  }
};

/** A conversation plus its listing, only when this host owns the listing. */
const loadOwned = async (conversationId, hostId) => {
  if (!isObjectId(conversationId)) return null;

  const conversation = await HostConversation.findById(conversationId);
  if (!conversation) return null;

  const listing = await HostListing.findOne({
    _id: conversation.listingId,
    ownerId: hostId,
  });
  if (!listing) return null;

  return { conversation, listing };
};

// GET /api/host/host-conversations/:id
export const getHostConversation = async (req, res) => {
  try {
    const owned = await loadOwned(req.params.id, req.hostId);
    if (!owned) return res.status(404).json(NOT_FOUND);

    const messages = await HostMessage.find({
      conversationId: owned.conversation._id,
    }).sort({ createdAt: 1 });

    const unitNames = await unitNamesFor([owned.conversation]);

    const unreadCount = messages.filter(
      (message) =>
        message.sender === "guest" &&
        (!owned.conversation.hostLastReadAt ||
          message.createdAt > owned.conversation.hostLastReadAt),
    ).length;

    res.status(200).json({
      conversation: serializeConversation(owned.conversation, owned.listing, {
        unreadCount,
        lastMessage: messages.length
          ? {
              body: messages[messages.length - 1].body,
              senderRole: messages[messages.length - 1].sender,
              createdAt: messages[messages.length - 1].createdAt,
            }
          : null,
      }, unitNames),
      messages: messages.map(serializeMessage),
    });
  } catch (error) {
    console.error("Error in getHostConversation controller:", error.message);
    res.status(500).json({ message: "Could not load the conversation." });
  }
};

// POST /api/host/host-conversations/:id/messages
export const sendHostMessage = async (req, res) => {
  try {
    const owned = await loadOwned(req.params.id, req.hostId);
    if (!owned) return res.status(404).json(NOT_FOUND);

    const { body, clientKey } = req.body || {};
    if (typeof body !== "string" || !body.trim()) {
      return res.status(400).json({ message: "Write a message first.", code: "bodyRequired" });
    }
    if (body.length > MAX_BODY_LENGTH) {
      return res.status(400).json({ message: "That message is too long.", code: "bodyTooLong" });
    }

    // A retry after a lost response must not store the message twice, so the
    // sender's key is looked up first and the original is returned as-is.
    if (clientKey) {
      const existing = await HostMessage.findOne({
        conversationId: owned.conversation._id,
        clientKey,
      });
      if (existing) return res.status(200).json({ message: serializeMessage(existing) });
    }

    const message = await HostMessage.create({
      conversationId: owned.conversation._id,
      sender: "host",
      body: body.trim(),
      clientKey: typeof clientKey === "string" ? clientKey : null,
    });

    // Sending is also reading: the host has just seen everything above.
    owned.conversation.lastMessageAt = message.createdAt;
    owned.conversation.hostLastReadAt = message.createdAt;
    await owned.conversation.save();

    res.status(201).json({ message: serializeMessage(message) });
  } catch (error) {
    // The unique index on (conversationId, clientKey) is the last line of
    // defence against a duplicate that slipped past the lookup above.
    if (error?.code === 11000) {
      const existing = await HostMessage.findOne({
        conversationId: req.params.id,
        clientKey: req.body?.clientKey,
      });
      if (existing) return res.status(200).json({ message: serializeMessage(existing) });
    }
    console.error("Error in sendHostMessage controller:", error.message);
    res.status(500).json({ message: "Could not send that message." });
  }
};

// POST /api/host/host-conversations/:id/read
export const markHostConversationRead = async (req, res) => {
  try {
    const owned = await loadOwned(req.params.id, req.hostId);
    if (!owned) return res.status(404).json(NOT_FOUND);

    owned.conversation.hostLastReadAt = new Date();
    await owned.conversation.save();

    res.status(200).json({
      conversation: serializeConversation(owned.conversation, owned.listing, {
        unreadCount: 0,
      }),
    });
  } catch (error) {
    console.error("Error in markHostConversationRead controller:", error.message);
    res.status(500).json({ message: "Could not mark the conversation as read." });
  }
};

// POST /api/host/host-conversations/fixtures
export const createHostMessageFixture = async (req, res) => {
  try {
    const { accommodationId, conversationId } = req.body || {};

    // Reply into an existing thread…
    if (conversationId) {
      const owned = await loadOwned(conversationId, req.hostId);
      if (!owned) return res.status(404).json(NOT_FOUND);

      const message = await HostMessage.create({
        conversationId: owned.conversation._id,
        sender: "guest",
        body: "Thanks! One more question before we book — is early check-in possible?",
      });

      owned.conversation.lastMessageAt = message.createdAt;
      await owned.conversation.save();

      return res.status(201).json({
        conversation: serializeConversation(owned.conversation, owned.listing, {
          unreadCount: 1,
        }),
        messages: [serializeMessage(message)],
      });
    }

    // …or start a new one for a listing.
    if (!isObjectId(accommodationId)) {
      return res.status(400).json({ message: "A listing id is required." });
    }

    const listing = await HostListing.findOne({
      _id: accommodationId,
      ownerId: req.hostId,
    });
    if (!listing) return res.status(404).json({ message: "Listing not found." });

    const reservation = await HostReservation.findOne({
      listingId: listing._id,
      status: "requested",
    }).sort({ createdAt: -1 });

    const conversation = await HostConversation.create({
      listingId: listing._id,
      // A thread is tied to a reservation only when that reservation does not
      // already have one — the index allows at most one per reservation.
      reservationId:
        reservation &&
        !(await HostConversation.exists({ reservationId: reservation._id }))
          ? reservation._id
          : null,
      guestName: reservation?.guestName || "Martina Sedláková",
      guestEmail: reservation?.guestEmail || "martina@example.com",
      source: "fixture",
      lastMessageAt: new Date(),
    });

    const message = await HostMessage.create({
      conversationId: conversation._id,
      sender: "guest",
      body: "Hello! Is the apartment available for the dates I requested?",
    });

    conversation.lastMessageAt = message.createdAt;
    await conversation.save();

    res.status(201).json({
      conversation: serializeConversation(conversation, listing, { unreadCount: 1 }),
      messages: [serializeMessage(message)],
    });
  } catch (error) {
    console.error("Error in createHostMessageFixture controller:", error.message);
    res.status(500).json({ message: "Could not create the sample conversation." });
  }
};
