import {
  SITE,
  TEAL,
  TEAL_LIGHT,
  MUTED,
  esc,
  brandShell,
  button,
  callout,
  logoAttachments,
  TEXT_SIGNOFF,
} from "./emailLayout.js";

const greetingFor = (name) => {
  const n = (name || "").trim();
  return n ? `Hi ${n},` : "Hi there,";
};

/**
 * The verification code email.
 *
 * @param {object} options
 *   name             the registrant's first name, optional
 *   code             the 6-digit code to type into the app
 *   expiresInMinutes how long the code stays valid
 */
export function buildEmailVerificationEmail({
  name,
  code,
  expiresInMinutes = 15,
} = {}) {
  const subject = `${code} is your UK Stay Hub verification code`;
  const greeting = greetingFor(name);

  const text = `${greeting}

Thanks for signing up to UK Stay Hub. To finish creating your account, enter this verification code in the app:

${code}

The code is valid for ${expiresInMinutes} minutes. After that, request a new one in the app.

Never share this code with anyone. If you didn't sign up, you can ignore this email — the account won't be activated without it.

Need help? Email us at support@ukstayhub.co.uk.

${TEXT_SIGNOFF}`;

  const html = brandShell({
    preheader: `Your verification code is ${code}.`,
    title: "Verify your email address",
    bodyHtml: `
    <p style="margin:0 0 16px 0;">${esc(greeting)}</p>

    <p style="margin:0 0 8px 0;">
      Thanks for signing up to <strong>UK Stay Hub</strong>. To finish creating your
      account, enter this verification code in the app:
    </p>

    <div style="margin:24px 0;text-align:center;">
      <span style="display:inline-block;padding:14px 24px;border-radius:12px;background:#F4F6F4;border:1px solid #E4E9E5;font-family:'Courier New',monospace;font-size:32px;font-weight:700;letter-spacing:8px;color:${TEAL};">${esc(code)}</span>
    </div>

    ${callout(
      `<strong>This code is valid for ${expiresInMinutes} minutes.</strong> After that, request a new one in the app. Never share this code with anyone.`
    )}

    <p style="margin:20px 0 16px 0;">
      If you <strong>didn't sign up</strong>, you can ignore this email — the account
      won't be activated without it.
    </p>

    <p style="margin:0;font-size:14px;color:${MUTED};">
      Need help? Email us at
      <a href="mailto:support@ukstayhub.co.uk" style="color:${TEAL_LIGHT};">support@ukstayhub.co.uk</a>.
    </p>`,
  });

  return { subject, html, text, attachments: logoAttachments() };
}

/** Confirmation that the address has been verified and the account is active. */
export function buildEmailVerifiedEmail({ name } = {}) {
  const subject = "Your email is verified – welcome to UK Stay Hub";
  const greeting = greetingFor(name);

  const text = `${greeting}

Your email address has been verified and your UK Stay Hub account is now active.

You can sign in and get started here:
${SITE}/login

Need help? Email us at support@ukstayhub.co.uk.

${TEXT_SIGNOFF}`;

  const html = brandShell({
    preheader: "Your email address is verified — your UK Stay Hub account is active.",
    title: "Email address verified",
    bodyHtml: `
    <p style="margin:0 0 16px 0;">${esc(greeting)}</p>

    <p style="margin:0 0 8px 0;">
      Your email address has been verified and your <strong>UK Stay Hub</strong> account
      is now active. You can sign in and get started.
    </p>

    ${button(`${SITE}/login`, "Sign in")}

    <p style="margin:0;">
      Need help? Email us at
      <a href="mailto:support@ukstayhub.co.uk" style="color:${TEAL_LIGHT};">support@ukstayhub.co.uk</a>.
    </p>`,
  });

  return { subject, html, text, attachments: logoAttachments() };
}
