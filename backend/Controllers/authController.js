import User from "../models/User.js";
import jwt from "jsonwebtoken";
import bcrypt from "bcryptjs";
import { getTransporter } from '../utils/mailer.js';
import {
  buildPasswordResetEmail,
  buildPasswordResetSuccessEmail,
} from "../utils/passwordResetEmail.js";
import { buildEmailVerifiedEmail } from "../utils/emailVerificationEmail.js";
import {
  sendVerificationCode,
  checkVerificationCode,
  MAX_ATTEMPTS,
} from "../utils/emailVerificationCode.js";
import Host from "../models/Host.js";
import LoginHistory from "../models/LoginHistory.js";
import { payLinkBase } from "../utils/payLink.js";
import { payPage, siteUrl } from "../utils/resultPage.js";

const generateToken = (user) => {
  return jwt.sign({ id: user._id, role: user.role }, process.env.JWT_SECRET_KEY, {
    expiresIn: "30d",
  });
};

export const register = async (req, res) => {
  const { email, password, name, lastName, role, photo, gender, language, lang } = req.body;

  // Translation messages
  const messages = {
    en: {
      userExists: "User already exists",
      serverError: "Internal server error",
      success: "User successfully created",
    },
  };

  const t = messages.en;

  try {
    let existingUser = null;

    // Check for existing user in the appropriate collection
    if (role === "guest") {
      existingUser = await User.findOne({ email });
    } else if (role === "host") {
      existingUser = await Host.findOne({ email: { $regex: new RegExp(`^${email}$`, 'i') } });
    }

    if (existingUser) {
      return res.status(400).json({ message: t.userExists });
    }

    // Hash password
    const salt = await bcrypt.genSalt(10);
    const hashPassword = await bcrypt.hash(password, salt);

    // Create a new user or host document based on the role
    let user;
    if (role === "guest") {
      user = new User({
        name,
        lastName,
        email,
        password: hashPassword,
        photo,
        language,
        gender,
        role,
      });
    } else if (role === "host") {
      user = new Host({
        name,
        lastName,
        email,
        password: hashPassword,
        photo,
        language,
        gender,
        role,
      });
    }

    await user.save();

    // Email a 6-digit code; the app asks for it on the next screen. A mail
    // failure must not fail the registration: the account already exists, and
    // the code screen has a "Resend code" button.
    let emailSent = true;
    try {
      await sendVerificationCode(email, { force: true });
    } catch (mailErr) {
      emailSent = false;
      console.error("[email-verification] code email not sent:", mailErr.message);
    }

    res.status(201).json({ success: true, message: t.success, emailSent });
  } catch (err) {
    res.status(500).json({ success: false, message: `${t.serverError}, ${err.message}`, });
  }
};

export const login = async (req, res) => {
  const { email, password, lang } = req.body; // Get language from request body

  // Define translations
  const messages = {
    en: {
      userNotFound: "User not found",
      verifyEmail: "Please verify your email first",
      invalidCredentials: "Invalid credentials",
      loginSuccess: "Successfully logged in",
      loginFailed: "Failed to login",
    },
  };

  const t = messages.en;

  try {
    let user = null;

    const guest = await User.findOne({ email: { $regex: new RegExp(`^${email}$`, "i") } });
    const host = await Host.findOne({ email: { $regex: new RegExp(`^${email}$`, "i") } });

    // Identifiers only — logging the document printed the bcrypt hash into
    // the server log on every sign-in attempt.
    console.log(
      `[login] email=${email} guest=${guest?._id ?? "none"} host=${host?._id ?? "none"}`,
    );

    if (guest) user = guest;
    if (host) user = host;

    // Check if user exists
    if (!user) {
      console.log('User not found');
      return res.status(404).json({ message: t.userNotFound });
    }

    // An account with no local password signs in through Google; there is
    // nothing to compare against, and bcrypt throws on a null hash.
    if (!user.password) {
      return res.status(400).json({ status: false, message: t.invalidCredentials });
    }

    // The password is checked BEFORE the verification gate below, because for
    // one kind of account the password is what proves the address.
    const isPasswordMatch = await bcrypt.compare(password, user.password);
    if (!isPasswordMatch) {
      console.log('Password does not match');
      return res.status(400).json({ status: false, message: t.invalidCredentials });
    }

    if (!user.isVerified) {
      // An account created for a guest who checked out without signing up
      // never received a verification link — it received a generated password,
      // sent to that address and nowhere else. Signing in with it proves
      // control of the inbox exactly as clicking a link would, so this first
      // successful sign-in IS the verification.
      //
      // Without this the flow dead-ends: we mail someone credentials, then
      // refuse the login those credentials are for, and offer no way out.
      if (user.mustChangePassword) {
        user.isVerified = true;
        await user.save();
        console.log(
          `[putko-audit] account.verified-by-credential user=${user._id} at=${new Date().toISOString()}`,
        );
      } else {
        console.log('User not verified');
        // Send a fresh code (subject to the resend cooldown) so the app can go
        // straight to the code screen.
        await sendVerificationCode(user.email).catch((err) =>
          console.error("[email-verification] send failed:", err.message),
        );
        return res.status(400).json({
          message: t.verifyEmail,
          code: "emailUnverified",
          email: user.email,
        });
      }
    }

    // Login history is host-specific by design: `hostId` is required on the
    // model and refs Host, so a guest sign-in has nothing to record. This read
    // `host._id` unconditionally and so threw on every guest sign-in, failing
    // the whole login after the password had already been accepted.
    //
    // Recorded best-effort as well: a history row that cannot be written must
    // not cost someone their session.
    if (host) {
      await LoginHistory.create({
        hostId: host._id,
        ip: req.ip,
        userAgent: req.get("User-Agent"),
      }).catch((err) => console.error("[login-history] not recorded:", err.message));
    }

    // Generate authentication token
    const token = generateToken(user);

    // Remove password from response
    const { password: _, role, booking, ...rest } = user._doc;

    res.status(200).json({
      status: true,
      message: t.loginSuccess,
      token,
      data: { ...rest },
      role,
      // True for an account created automatically at checkout, whose password
      // was emailed. The client should send them straight to a password change:
      // that password is sitting in an inbox and should stop working.
      mustChangePassword: Boolean(user.mustChangePassword),
    });
  } catch (err) {
    console.error('Login error:', err);
    res.status(400).json({ status: false, message: t.loginFailed });
  }
};

export const requestPasswordReset = async (req, res) => {
  const { email, role } = req.body;

  try {
    let user = null;

    const guest = await User.findOne({ email: { $regex: new RegExp(`^${email}$`, 'i') } });
    const host = await Host.findOne({ email: { $regex: new RegExp(`^${email}$`, 'i') } });

    if (guest) {
      user = guest;
    }
    if (host) {
      user = host;
    }

    //check if user exist or not
    if (!user) {
      return res.status(404).json({ message: "User not found" });
    }

    const resetToken = generateToken(user);
    user.resetPasswordToken = resetToken;
    user.resetPasswordExpires = Date.now() + 3600000;

    await user.save();

    const transporter = getTransporter();

    // Served by this backend (resetPasswordPage), so it works whether or not the website is up.
    const resetBase = (process.env.PASSWORD_RESET_BASE_URL || "").trim().replace(/\/+$/, "") || payLinkBase(req);
    const resetUrl = `${resetBase}/reset-password/${encodeURIComponent(resetToken)}`;
    const { subject, html, text, attachments } = buildPasswordResetEmail({
      resetUrl,
      // Kept in step with resetPasswordExpires above (Date.now() + 3600000).
      expiresInHours: 1,
    });

    await transporter.sendMail({
      from: '"UK Stay Hub Support" <support@ukstayhub.co.uk>',
      to: email,
      subject,
      html,
      text,
      attachments,
    });

    res.status(200).json({ message: 'Password reset link sent to your email' });
  } catch (err) {
    res.status(500).json({ message: 'Error requesting password reset' });
  }
};

const sendResetSuccessEmail = async (userEmail) => {
  const transporter = getTransporter();
  const { subject, html, text, attachments } = buildPasswordResetSuccessEmail();

  await transporter.sendMail({
    from: '"UK Stay Hub Support" <support@ukstayhub.co.uk>',
    to: userEmail,
    subject,
    html,
    text,
    attachments,
  });
};

const findByResetToken = async (token, role) => {
  const q = { resetPasswordToken: String(token), resetPasswordExpires: { $gt: Date.now() } };
  return (
    (role !== "host" && (await User.findOne(q))) ||
    (role !== "guest" && (await Host.findOne(q))) ||
    null
  );
};

// GET /reset-password/:token — the emailed link. Shows the new-password form
// (it posts to /api/auth/reset-password), or an "expired" page straight away.
export const resetPasswordPage = async (req, res) => {
  const { token } = req.params;
  const forgot = { href: siteUrl("/zabudnute-heslo"), label: "Request a new link" };
  try {
    if (!(await findByResetToken(token))) {
      return res.status(410).send(payPage({ icon: "fail", title: "Link expired or invalid",
        body: "This password reset link has expired or was already used. Request a new one and use it within an hour.",
        primary: forgot }));
    }
    const form = `<form id="f" style="text-align:left;margin-top:24px" novalidate>
<label for="p1">New password</label><input id="p1" type="password" autocomplete="new-password" minlength="8" required>
<label for="p2">Confirm new password</label><input id="p2" type="password" autocomplete="new-password" minlength="8" required>
<div class="err" id="e" role="alert"></div>
<button class="b p" id="go" type="submit">Reset password</button></form>
<a class="b p" id="login" href="${siteUrl("/login")}" style="display:none">Go to login</a>`;
    // JSON.stringify + "<" escape keeps the token inert inside the script tag.
    const script = `<script>
var T=${JSON.stringify(String(token)).replace(/</g, "\\u003c")};
document.getElementById("f").onsubmit=async function(ev){ev.preventDefault();
var p1=document.getElementById("p1").value,p2=document.getElementById("p2").value,e=document.getElementById("e"),b=document.getElementById("go");
if(p1.length<8){e.textContent="Password must be at least 8 characters.";return}
if(p1!==p2){e.textContent="Passwords do not match.";return}
e.textContent="";b.disabled=true;b.textContent="Resetting…";
try{var r=await fetch("/api/auth/reset-password",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({token:T,newPassword:p1})});
var d=await r.json().catch(function(){return{}});
if(!r.ok)throw new Error(d.message||"Something went wrong. Please try again.");
document.querySelector("h1").textContent="Password updated";
document.querySelector(".w > p").textContent="Your password has been reset. You can now log in with your new password.";
document.querySelector(".ic").style.background="#319a81";
document.querySelector(".ic svg").innerHTML='<path d="M20 6 9 17l-5-5"/>';
document.getElementById("f").style.display="none";document.getElementById("login").style.display="block";
}catch(x){e.textContent=x.message;b.disabled=false;b.textContent="Reset password"}};
</script>`;
    return res.send(payPage({ icon: "lock", title: "Set a new password",
      body: "Choose a new password for your UK Stay Hub account. Use at least 8 characters.",
      html: form, script }));
  } catch (err) {
    console.error("resetPasswordPage error:", err);
    return res.status(500).send(payPage({ icon: "warn", title: "Something went wrong",
      body: "Please open the link from your email again in a moment.", primary: forgot }));
  }
};

export const resetPassword = async (req, res) => {
  const { token, newPassword, role } = req.body;

  try {
    
    if (!token || typeof newPassword !== "string" || newPassword.length < 8) {
      return res.status(400).json({ message: "Password must be at least 8 characters" });
    }
    // The emailed link carries no role, so a missing role checks both account types.
    const user = await findByResetToken(token, role);

    if (!user) {
      return res.status(400).json({ message: 'Invalid or expired token' });
    }

    const salt = await bcrypt.genSalt(10);
    user.password = await bcrypt.hash(newPassword, salt);
    user.resetPasswordToken = undefined;
    user.resetPasswordExpires = undefined;

    await user.save();

    await sendResetSuccessEmail(user.email);

    res.status(200).json({ message: 'Password has been reset successfully' });
  } catch (err) {
    res.status(500).json({ message: 'Error resetting password' });
  }
};

export const changePassword = async (req, res) => {
  const { userId, newPassword, role } = req.body;

  try {
    // Find user based on role
    const user = role === "guest" 
      ? await User.findById(userId) 
      : await Host.findById(userId);

    if (!user) {
      return res.status(404).json({ message: "User not found" });
    }

    // Hash the new password
    const salt = await bcrypt.genSalt(10);
    user.password = await bcrypt.hash(newPassword, salt);

    await user.save();

    res.status(200).json({ message: "Password changed successfully" });
  } catch (err) {
    res.status(500).json({ message: "Error changing password" });
  }
};

export const verifyEmail = async (req, res) => {
  const { token, role } = req.params;

  try {
     // Verify the JWT token
     const decoded = jwt.verify(token, process.env.JWT_SECRET_KEY);
     console.log("Decoded ID:", decoded.id); // Log the decoded ID for debugging
 
     // Retrieve user based on role
     const UserModel = role === "guest" ? User : Host;
     const user = await UserModel.findById(decoded.id);
       console.log("Role:", role);
 
     // Check if user exists
     if (!user) {
       const roleMessage = role === "guest" ? 'Guest' : 'Host';
       return res.status(400).json({ message: `${roleMessage} user not found. Invalid verification link.` });
     }
 
     // Check if user is already verified
     if (user.isVerified) {
       return res.status(200).json({ message: 'User already verified', alreadyVerified: true });
     }
 
     // Atomic update prevents duplicate requests (for example React Strict
     // Mode's development effect replay) from sending multiple confirmation
     // emails or turning the second request into a false failure.
     const verifiedUser = await UserModel.findOneAndUpdate(
       { _id: user._id, isVerified: { $ne: true } },
       { $set: { isVerified: true } },
       { new: true }
     );
     if (!verifiedUser) {
       return res.status(200).json({ message: 'User already verified', alreadyVerified: true });
     }

    const transporter = getTransporter();

    const { subject, html, text, attachments } = buildEmailVerifiedEmail({
      name: verifiedUser.name,
    });

    // Send verification success email
    await transporter.sendMail({
      from: '"UK Stay Hub Support" <support@ukstayhub.co.uk>',
      to: verifiedUser.email,
      subject,
      html,
      text,
      attachments,
    });

    res.status(200).json({ message: "Email verified successfully" });
  } catch (err) {
    console.error(err); // Log the error for debugging
    // Handle specific JWT errors
    if (err.name === 'JsonWebTokenError') {
      return res.status(400).json({ message: 'Invalid token' });
    }
    if (err.name === 'TokenExpiredError') {
      return res.status(400).json({ message: 'Token has expired' });
    }
    res.status(500).json({ message: 'Failed to verify email' });
  }
};

const codeMessages = {
  en: {
    missing: "Email and code are required",
    none: "No pending verification for this email. It may already be verified — try signing in.",
    expired: "This code has expired. Request a new one.",
    tooManyAttempts: "Too many incorrect attempts. Request a new code.",
    invalid: "Incorrect code.",
    verified: "Email verified successfully",
    sent: "A new code has been sent to your email.",
    cooldown: "Please wait before requesting another code.",
    failed: "Failed to verify email",
  },
};

/**
 * POST /auth/verify-email-code { email, code, role?, lang? }
 *
 * Marks the address verified and signs the user in, so they don't have to
 * type their password again straight after registering.
 */
export const verifyEmailCode = async (req, res) => {
  const { email, code, role, lang } = req.body || {};
  const t = codeMessages.en;
  if (!email || !code) return res.status(400).json({ message: t.missing });

  try {
    const result = await checkVerificationCode(email, code);
    if (!result.ok) {
      const message =
        result.reason === "invalid"
          ? `${t.invalid} (${result.attemptsLeft}/${MAX_ATTEMPTS})`
          : t[result.reason] || t.failed;
      return res.status(400).json({ message, code: result.reason, attemptsLeft: result.attemptsLeft });
    }

    const { accounts } = result;
    // Same preference as login: the requested role, else host over guest.
    const user =
      accounts.find((a) => a.role === role) ||
      accounts.find((a) => a.role === "host") ||
      accounts[0];

    const transporter = getTransporter();
    const { subject, html, text, attachments } = buildEmailVerifiedEmail({ name: user.name });
    transporter
      .sendMail({
        from: '"UK Stay Hub Support" <support@ukstayhub.co.uk>',
        to: user.email,
        subject,
        html,
        text,
        attachments,
      })
      .catch((err) => console.error("[email-verification] confirmation not sent:", err.message));

    const token = generateToken(user);
    const { password: _, role: userRole, booking, ...rest } = user._doc;
    res.status(200).json({
      status: true,
      message: t.verified,
      token,
      data: { ...rest },
      role: userRole,
      mustChangePassword: Boolean(user.mustChangePassword),
    });
  } catch (err) {
    console.error("[email-verification] verify failed:", err);
    res.status(500).json({ message: t.failed });
  }
};

/** POST /auth/resend-verification-code { email, lang? } */
export const resendVerificationCode = async (req, res) => {
  const { email, lang } = req.body || {};
  const t = codeMessages.en;
  if (!email) return res.status(400).json({ message: t.missing });

  try {
    const result = await sendVerificationCode(email);
    if (result.reason === "cooldown") {
      return res.status(429).json({ message: t.cooldown, code: "cooldown", retryAfter: result.retryAfter });
    }
    // "none" answers the same as "sent" so this can't be used to probe which
    // addresses have pending accounts.
    res.status(200).json({ message: t.sent });
  } catch (err) {
    console.error("[email-verification] resend failed:", err);
    res.status(500).json({ message: t.failed });
  }
};
