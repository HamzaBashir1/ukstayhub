import express from "express";
import {
  getGuestProfile,
  updateGuestProfile,
  changeGuestPassword,
  getGuestFavorites,
  addGuestFavorite,
  removeGuestFavorite,
} from "../Controllers/GuestAccountController.js";
import { authenticate, restrict } from "../auth/verifyToken.js";

const router = express.Router();

// Everything below acts on the signed-in guest and on nobody else, so the
// token check is mounted once for the whole router instead of per route.
router.use(authenticate, restrict(["guest"]));

router.get("/me", getGuestProfile);
router.patch("/me", updateGuestProfile);
router.post("/change-password", changeGuestPassword);

router.get("/favorites", getGuestFavorites);
router.post("/favorites", addGuestFavorite);
router.delete("/favorites/:accommodationId", removeGuestFavorite);

export default router;
