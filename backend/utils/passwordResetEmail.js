import {
  SITE,
  TEAL_LIGHT,
  MUTED,
  esc,
  brandShell,
  button,
  callout,
  logoAttachments,
  TEXT_SIGNOFF,
} from "./emailLayout.js";

const hours = (n) => `${n} hour${n === 1 ? "" : "s"}`;

/**
 * The reset link email.
 *
 * @param {object} options
 *   resetUrl        the full link, built by the caller
 *   expiresInHours  how long the link stays valid (matches resetPasswordExpires)
 */
export function buildPasswordResetEmail({ resetUrl, expiresInHours = 1 } = {}) {
  const subject = "Reset your UK Stay Hub password";

  const text = `Reset your password

We received a request to reset the password for your UK Stay Hub account.

Set a new password here:
${resetUrl}

This link is valid for ${hours(expiresInHours)} from when this email was sent.

If you didn't ask to reset your password, you can ignore this email — your password stays the same.

Need help? Email us at support@ukstayhub.co.uk.

${TEXT_SIGNOFF}`;

  const html = brandShell({
    preheader: "Your link to reset your UK Stay Hub password.",
    title: "Reset your password",
    bodyHtml: `
    <p style="margin:0 0 16px 0;">
      We received a request to reset the password for your <strong>UK Stay Hub</strong> account.
    </p>

    <p style="margin:0 0 8px 0;">
      Click the button below to set a new password.
    </p>

    ${button(resetUrl, "Set a new password")}

    ${callout(
      `<strong>This link is valid for ${hours(expiresInHours)}.</strong> After that, request a new one.`
    )}

    <p style="margin:20px 0 8px 0;font-size:14px;color:${MUTED};">
      If the button doesn't work, copy this address into your browser:
    </p>
    <p style="margin:0 0 20px 0;font-size:13px;word-break:break-all;">
      <a href="${resetUrl}" style="color:${TEAL_LIGHT};">${esc(resetUrl)}</a>
    </p>

    <p style="margin:0 0 16px 0;">
      If you <strong>didn't</strong> ask to reset your password, you can ignore this email —
      your password stays the same.
    </p>

    <p style="margin:0;">
      Need help? Email us at
      <a href="mailto:support@ukstayhub.co.uk" style="color:${TEAL_LIGHT};">support@ukstayhub.co.uk</a>.
    </p>`,
  });

  return { subject, html, text, attachments: logoAttachments() };
}

/** Confirmation that the password was actually changed. */
export function buildPasswordResetSuccessEmail() {
  const subject = "Your UK Stay Hub password was changed";

  const text = `Password changed

The password for your UK Stay Hub account has just been changed.

If you made this change, there's nothing else to do.

If you didn't change your password, contact us immediately at support@ukstayhub.co.uk — your account may be at risk.

${TEXT_SIGNOFF}`;

  const html = brandShell({
    preheader: "The password for your UK Stay Hub account was changed.",
    title: "Password changed",
    bodyHtml: `
    <p style="margin:0 0 16px 0;">
      The password for your <strong>UK Stay Hub</strong> account has just been changed.
    </p>

    <p style="margin:0 0 20px 0;">
      If you made this change, there's nothing else to do.
    </p>

    ${callout(
      `<strong>Didn't change your password?</strong> Contact us immediately at
       <a href="mailto:support@ukstayhub.co.uk" style="color:${TEAL_LIGHT};">support@ukstayhub.co.uk</a> —
       your account may be at risk.`,
      "warning"
    )}

    <p style="margin:20px 0 0 0;">
      <a href="${SITE}/login" style="color:${TEAL_LIGHT};">Sign in to UK Stay Hub</a>
    </p>`,
  });

  return { subject, html, text, attachments: logoAttachments() };
}
