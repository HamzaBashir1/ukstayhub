// Internal developer/test accounts. These sign up as hosts to test flows end
// to end, so they show up in host counts and Stripe-connect reports alongside
// real hosts unless explicitly filtered out here.
//
// Read from DEVELOPER_EMAILS in .env (comma-separated) rather than hardcoded,
// so the list can change per environment without a code deploy.

export const DEVELOPER_EMAILS = (process.env.DEVELOPER_EMAILS || "")
  .split(",")
  .map((email) => email.trim())
  .filter(Boolean);

// Team members' own accounts (comma-separated). The .env key is spelled
// `Team_emails`; TEAM_EMAILS is accepted too.
export const TEAM_EMAILS = (process.env.TEAM_EMAILS || process.env.Team_emails || "")
  .split(",")
  .map((email) => email.trim())
  .filter(Boolean);

const escapeRegExp =(value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// Case-insensitive exact-match patterns, for a Mongo `$nin` — emails aren't
// normalized to lowercase on the Host model, so a plain string `$nin` would
// miss anything not saved in this exact case.
export const DEVELOPER_EMAIL_PATTERNS = DEVELOPER_EMAILS.map(
  (email) => new RegExp(`^${escapeRegExp(email)}$`, 'i')
);

// Developer + team accounts: everything that is not a genuine host.
export const TEST_OR_TEAM_EMAIL_PATTERNS = [...DEVELOPER_EMAILS, ...TEAM_EMAILS].map(
  (email) => new RegExp(`^${escapeRegExp(email)}$`, 'i')
);
