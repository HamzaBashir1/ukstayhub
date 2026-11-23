import express from "express";

import {
  listHostAccommodations,
  createHostAccommodation,
  getHostAccommodation,
  updateHostAccommodation,
  publishHostAccommodation,
  deleteHostAccommodation,
  adoptLegacyAccommodation,
} from "../Controllers/HostListingController.js";
import {
  getHostCalendar,
  blockHostCalendarRange,
  unblockHostCalendarRange,
  setHostCalendarMode,
  addHostCalendarFeed,
  updateHostCalendarFeed,
  removeHostCalendarFeed,
  removeAllHostCalendarFeeds,
  fetchHostCalendarFeed,
} from "../Controllers/HostCalendarController.js";
import {
  listHostReservations,
  getHostReservation,
} from "../Controllers/HostReservationController.js";
// Answering a request issues a payment link (or closes the request and mails
// the guest), so the workspace uses the existing, tested handlers rather than
// a second implementation of the same money operation.
import {
  approveBookingRequest,
  declineBookingRequest,
} from "../Controllers/ReservationController.js";
import {
  getHostProfile,
  saveHostProfile,
  createHostProfilePhotoUploadUrl,
  uploadHostProfilePhoto,
  prepareHostProfilePhoto,
  discardHostProfilePhoto,
  getHostPayoutReadiness,
} from "../Controllers/HostProfileController.js";
import {
  listHostConversations,
  getHostConversation,
  sendHostMessage,
  markHostConversationRead,
  createHostMessageFixture,
} from "../Controllers/HostMessagesController.js";
import { getHostDashboard } from "../Controllers/HostDashboardController.js";
import { listOwnedAccommodations } from "../Controllers/HostAccommodationController.js";
import {
  getHostAccount,
  updateHostAccount,
  changeHostPassword,
  changeHostEmail,
} from "../Controllers/HostAccountController.js";
import { authenticate } from "../auth/verifyToken.js";
import { requireHost } from "../utils/hostWorkspace.js";

const router = express.Router();

// Every route below acts on the signed-in host's own data, so the token check
// is mounted once for the whole router instead of being repeated per route.
router.use(authenticate, requireHost);

/* ------------------------------------------------------------- listings */

// The host's real properties, from the Accommodation collection. This is what
// the calendar and any other property picker choose from — `/host-accommodations`
// below lists only the drafts created in the workspace's own editor.
router.get("/accommodations", listOwnedAccommodations);

router.get("/host-accommodations", listHostAccommodations);
router.post("/host-accommodations", createHostAccommodation);

/*
 * The calendar sub-routes are declared before "/host-accommodations/:id" so a
 * path like ".../calendar/feeds" can never be swallowed by the bare id route.
 */
router.get("/host-accommodations/:id/calendar", getHostCalendar);
router.post("/host-accommodations/:id/calendar/blocks", blockHostCalendarRange);
router.post("/host-accommodations/:id/calendar/unblock", unblockHostCalendarRange);
router.post("/host-accommodations/:id/calendar/mode", setHostCalendarMode);
router.post("/host-accommodations/:id/calendar/feeds", addHostCalendarFeed);
router.post("/host-accommodations/:id/calendar/feeds/:feedId/fetch", fetchHostCalendarFeed);
router.patch("/host-accommodations/:id/calendar/feeds/:feedId", updateHostCalendarFeed);
router.delete("/host-accommodations/:id/calendar/feeds", removeAllHostCalendarFeeds);
router.delete("/host-accommodations/:id/calendar/feeds/:feedId", removeHostCalendarFeed);

// Declared with the other sub-routes, before the bare ":id" route below.
// `:id` here is an ACCOMMODATION id, not a draft's — this is what creates the
// draft in the first place.
router.post("/host-accommodations/:id/adopt", adoptLegacyAccommodation);
router.post("/host-accommodations/:id/publish", publishHostAccommodation);
router.get("/host-accommodations/:id", getHostAccommodation);
router.patch("/host-accommodations/:id", updateHostAccommodation);
router.delete("/host-accommodations/:id", deleteHostAccommodation);

/* --------------------------------------------------------- reservations */

router.get("/host-reservations", listHostReservations);
router.get("/host-reservations/:id", getHostReservation);
// Both check that the caller is the host the request belongs to, from the
// token, before touching anything.
router.post("/host-reservations/:id/accept", approveBookingRequest);
router.post("/host-reservations/:id/decline", declineBookingRequest);
// No cancel route: ending an accepted stay decides a refund tier, which is
// what the cancellation flow exists for. `allowedActions` never offers it
// here, so the workspace does not show a button that would land on a 404.

/* ------------------------------------------------------------- messages */

router.post("/host-conversations/fixtures", createHostMessageFixture);
router.get("/host-conversations", listHostConversations);
router.get("/host-conversations/:id", getHostConversation);
router.post("/host-conversations/:id/messages", sendHostMessage);
router.post("/host-conversations/:id/read", markHostConversationRead);

/* ---------------------------------------------------- profile & payouts */

router.get("/host-profile", getHostProfile);
router.put("/host-profile", saveHostProfile);

router.post("/host-profile-photo/upload-url", createHostProfilePhotoUploadUrl);
// The browser PUTs the raw file here, so this one route takes a binary body
// instead of JSON.
router.put(
  "/host-profile-photo/upload/:token",
  express.raw({ type: "image/*", limit: "10mb" }),
  uploadHostProfilePhoto,
);
router.post("/host-profile-photo/prepare", prepareHostProfilePhoto);
router.delete("/host-profile-photo/:uploadId", discardHostProfilePhoto);

router.get("/host-payouts", getHostPayoutReadiness);

/* -------------------------------------------------------------- account */

// The host's own name, phone and password. A host is a real account, so these
// live here rather than requiring a switch into traveller mode. The only other
// way to change a host was PUT /api/hosts/:id, which trusts the id in the URL.
router.get("/account", getHostAccount);
router.patch("/account", updateHostAccount);
router.post("/account/change-password", changeHostPassword);
router.patch("/account/email", changeHostEmail);

/* ------------------------------------------------------------ dashboard */

router.get("/host-dashboard", getHostDashboard);

export default router;
