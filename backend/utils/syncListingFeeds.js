/** Compare links the way a host means them, not byte for byte. */
const normalise = (url) => {
  const trimmed = String(url || "").trim();
  if (!trimmed) return "";
  const withScheme = /^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
  try {
    return new URL(withScheme).href.replace(/\/$/, "").toLowerCase();
  } catch {
    return trimmed.toLowerCase();
  }
};

const isHttp = (url) => /^https?:\/\//i.test(String(url || "").trim());

/** An imported row belonging to one feed. */
const isFeedRow = (row, feedId) =>
  row.source === "ics" && String(row.calendarSyncId || "") === String(feedId);

/**
 * Make `accommodation.calendarSync` match the draft's `calendarFeeds`.
 *
 * This was gated on a manual/connect choice in the editor, which meant a link
 * pasted while the listing still said "manual only" was saved into the draft
 * and mirrored nowhere — the host had added a calendar link and no calendar
 * link existed. The choice is gone; the list of links IS the intent, and an
 * empty list means nothing to import.
 *
 * Mutates `accommodation`; the caller saves.
 *
 * @returns {{added: number, updated: number, removed: number, skipped: boolean, addedFeeds: object[]}}
 */
export function syncListingFeeds(accommodation, data) {
  const result = { added: 0, updated: 0, removed: 0, skipped: true, addedFeeds: [] };
  if (!accommodation || !data) return result;

  result.skipped = false;

  const drafted = (Array.isArray(data.calendarFeeds) ? data.calendarFeeds : [])
    .filter((feed) => isHttp(feed?.url) || String(feed?.url || "").trim())
    .map((feed) => ({
      url: String(feed.url).trim(),
      label: typeof feed.label === "string" ? feed.label.trim() : "",
      key: normalise(feed.url),
    }))
    .filter((feed) => feed.key);

  // Last one wins on a duplicated link, so a host who pasted the same calendar
  // twice gets one connected feed rather than two importing the same dates.
  const wanted = new Map(drafted.map((feed) => [feed.key, feed]));

  accommodation.calendarSync = accommodation.calendarSync || [];

  // Drop links the host removed in the editor, and the dates they imported —
  // otherwise deleting a link leaves its blocked days behind forever, with
  // nothing left in the UI to remove them by.
  const doomed = accommodation.calendarSync.filter((feed) => !wanted.has(normalise(feed.url)));

  for (const feed of doomed) {
    accommodation.occupancyCalendar = (accommodation.occupancyCalendar || []).filter(
      (row) => !isFeedRow(row, feed._id),
    );
    accommodation.calendarSync.pull({ _id: feed._id });
    result.removed += 1;
  }

  for (const feed of accommodation.calendarSync) {
    const match = wanted.get(normalise(feed.url));
    if (!match) continue;

    // Keep the id, the last-fetch status and the imported dates; a relabel is
    // not a reason to make the host fetch the calendar again.
    if (feed.label !== match.label) {
      feed.label = match.label;
      result.updated += 1;
    }
    wanted.delete(normalise(feed.url));
  }

  for (const feed of wanted.values()) {
    accommodation.calendarSync.push({
      url: feed.url,
      label: feed.label,
      lastSyncStatus: "never",
    });
    // The just-pushed subdocument, so the caller can pull it right away
    // instead of leaving a freshly-connected link on "never" indefinitely.
    result.addedFeeds.push(accommodation.calendarSync[accommodation.calendarSync.length - 1]);
    result.added += 1;
  }

  return result;
}

export default syncListingFeeds;
