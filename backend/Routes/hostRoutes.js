import express from "express";
import { 
    updateHost,
    deleteHost,
    getAllHosts,
    getSingleHost,
    getHostProfile,
    getHostById
} 
from "../Controllers/HostController.js";
import { authenticate, restrict } from "../auth/verifyToken.js";
import { requireHostSelf } from "../auth/authorize.js";

const router = express.Router();

// Public route for fetching host by ID
router.get("/:userId", getHostById);
router.get('/:id', authenticate, restrict(['host']), getSingleHost);
router.get('/', getAllHosts);
// Only the host themselves (or an admin) may edit a host. This was open to anyone
// who knew an id, which allowed overwriting another host's details.
router.put('/:id', requireHostSelf({ param: 'id', source: 'params' }), updateHost);
router.delete('/:id', deleteHost);
router.get('/profile/me/:id', authenticate, restrict(['host']), getHostProfile);

export default router;
