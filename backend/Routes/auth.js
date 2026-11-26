import express from 'express';
import { register, login, requestPasswordReset, resetPassword, verifyEmail, verifyEmailCode, resendVerificationCode, changePassword } from '../Controllers/authController.js';
import { switchAccountMode, getAvailableModes } from '../Controllers/AccountModeController.js';
import { authenticate } from '../auth/verifyToken.js';

const router = express.Router();

// Existing routes for email/password authentication
router.post('/register', register);
router.post('/login', login);
router.post('/password-reset-request', requestPasswordReset); // New route
router.post('/reset-password', resetPassword); // New route
// Old link-based verification, kept so links already sent still work.
router.get('/verify-email/:role/:token', verifyEmail);
router.post('/verify-email-code', verifyEmailCode);
router.post('/resend-verification-code', resendVerificationCode);
router.post("/change-password", changePassword);

// Traveller <-> host mode. Both require a valid session for the account being
// left; the counterpart is resolved from its verified email, never from an id
// in the request.
router.get('/mode/available', authenticate, getAvailableModes);
router.post('/mode', authenticate, switchAccountMode);

export default router;
