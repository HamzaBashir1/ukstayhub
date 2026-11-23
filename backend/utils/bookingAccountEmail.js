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
  const subject = "Váš účet na Putko.sk";

  const text = `Vytvorili sme vám účet

Dobrý deň${name ? ` ${name}` : ""},

k vašej rezervácii sme vytvorili účet na Putko.sk, aby ste mali svoje rezervácie
na jednom mieste.

Prihlasovacie údaje:
  E-mail: ${email}
  Dočasné heslo: ${password}

Prihlásiť sa môžete tu:
${loginUrl}

Toto heslo je dočasné — pri prvom prihlásení si nastavte vlastné. Kvôli
bezpečnosti tento e-mail potom odstráňte.

Ak si účet neželáte, môžete ho ignorovať; vaša rezervácia platí aj tak.`;

  const html = brandShell({
    title: "Vytvorili sme vám účet",
    bodyHtml: `
    <p style="margin:0 0 16px 0;">
      Dobrý deň${name ? ` ${esc(name)}` : ""}, k vašej rezervácii sme vytvorili účet na
      <strong>Putko.sk</strong>, aby ste mali svoje rezervácie na jednom mieste.
    </p>

    <p style="margin:0 0 8px 0;"><strong>Prihlasovacie údaje</strong></p>
    <p style="margin:0 0 4px 0;font-size:15px;">E-mail: <strong>${esc(email)}</strong></p>
    <p style="margin:0 0 20px 0;font-size:15px;">
      Dočasné heslo: <strong style="font-family:monospace;">${esc(password)}</strong>
    </p>

    ${button(loginUrl, "Prihlásiť sa")}

    ${callout(
      `<strong>Toto heslo je dočasné.</strong> Pri prvom prihlásení si nastavte vlastné
       a tento e-mail potom odstráňte.`
    )}

    <p style="margin:20px 0 8px 0;font-size:14px;color:${MUTED};">
      Ak tlačidlo nefunguje, skopírujte do prehliadača túto adresu:
    </p>
    <p style="margin:0 0 20px 0;font-size:13px;word-break:break-all;">
      <a href="${loginUrl}" style="color:${TEAL_LIGHT};">${esc(loginUrl)}</a>
    </p>

    <p style="margin:0 0 16px 0;">
      Ak si účet neželáte, môžete tento e-mail ignorovať — vaša rezervácia platí aj tak.
    </p>

    <p style="margin:0;">
      Potrebujete pomoc? Napíšte nám na
      <a href="mailto:support@ukstayhub.co.uk" style="color:${TEAL_LIGHT};">support@ukstayhub.co.uk</a>.
    </p>`,
  });

  return { subject, html, text, attachments: logoAttachments() };
}

export { SITE };
