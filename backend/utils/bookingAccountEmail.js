import {
  SITE,
  TEAL_LIGHT,
  MUTED,
  esc,
  brandShell,
  button,
  callout,
  logoAttachments,
} from "./emailLayout.js";

/**
 * The account created for a guest who booked without signing up.
 *
 * The password travels in this email, which is why the account is flagged
 * `mustChangePassword`: it is a one-time key to get in and set a real one, not
 * a credential to keep. Say so plainly here, because a password in an inbox
 * stays there — and people reuse them.
 *
 * @param {object} options
 *   name         who booked, for the greeting
 *   email        the address that is now the login
 *   password     the generated one-time password
 *   loginUrl     where to sign in
 */
export function buildBookingAccountEmail({ name, email, password, loginUrl } = {}) {
  const subject = "Your UK Stay Hub account";

  const text = `We've created an account for you

Hi${name ? ` ${name}` : ""},

we've created a UK Stay Hub account for your booking, so all your bookings are
in one place.

Your sign-in details:
  Email: ${email}
  Temporary password: ${password}

Sign in here:
${loginUrl}

This password is temporary — please set your own the first time you sign in,
then delete this email for security.

If you don't want an account, you can ignore this email; your booking is still valid.`;

  const html = brandShell({
    title: "We've created an account for you",
    bodyHtml: `
    <p style="margin:0 0 16px 0;">
      Hi${name ? ` ${esc(name)}` : ""}, we've created a <strong>UK Stay Hub</strong>
      account for your booking, so all your bookings are in one place.
    </p>

    <p style="margin:0 0 8px 0;"><strong>Your sign-in details</strong></p>
    <p style="margin:0 0 4px 0;font-size:15px;">Email: <strong>${esc(email)}</strong></p>
    <p style="margin:0 0 20px 0;font-size:15px;">
      Temporary password: <strong style="font-family:monospace;">${esc(password)}</strong>
    </p>

    ${button(loginUrl, "Sign in")}

    ${callout(
      `<strong>This password is temporary.</strong> Please set your own the first time
       you sign in, then delete this email.`
    )}

    <p style="margin:20px 0 8px 0;font-size:14px;color:${MUTED};">
      If the button doesn't work, copy this address into your browser:
    </p>
    <p style="margin:0 0 20px 0;font-size:13px;word-break:break-all;">
      <a href="${loginUrl}" style="color:${TEAL_LIGHT};">${esc(loginUrl)}</a>
    </p>

    <p style="margin:0 0 16px 0;">
      If you don't want an account, you can ignore this email — your booking is still valid.
    </p>

    <p style="margin:0;">
      Need help? Email us at
      <a href="mailto:support@ukstayhub.co.uk" style="color:${TEAL_LIGHT};">support@ukstayhub.co.uk</a>.
    </p>`,
  });

  return { subject, html, text, attachments: logoAttachments() };
}

export { SITE };
