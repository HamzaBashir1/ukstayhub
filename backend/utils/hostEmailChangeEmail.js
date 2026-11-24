import { TEAL_LIGHT, esc, brandShell, callout, logoAttachments, TEXT_SIGNOFF } from "./emailLayout.js";

const COPY = {
  en: {
    noticeSubject: "Your account email was changed",
    noticeTitle: "Account email changed",
    noticeBody: (to) => `The email address of your UK Stay Hub host account was changed to ${to}. We will send all messages there from now on. Your listings and bookings are unaffected.`,
    noticeWarn: `<strong>Wasn't you?</strong> Contact us right away at <a href="mailto:support@ukstayhub.co.uk" style="color:${TEAL_LIGHT};">support@ukstayhub.co.uk</a>.`,
  },
};

const pick = () => COPY.en;

/** Sent to the OLD address after the change, so a hijacked session cannot do it silently. */
export function buildHostEmailChangedNotice({ newEmail, lang } = {}) {
  const c = pick(lang);
  const text = `${c.noticeTitle}\n\n${c.noticeBody(newEmail)}\n\n${TEXT_SIGNOFF}`;
  const html = brandShell({
    preheader: c.noticeTitle,
    title: c.noticeTitle,
    bodyHtml: `
    <p style="margin:0 0 16px 0;">${esc(c.noticeBody(newEmail))}</p>
    ${callout(c.noticeWarn, "warning")}`,
  });
  return { subject: c.noticeSubject, html, text, attachments: logoAttachments() };
}
