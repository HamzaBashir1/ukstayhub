import { describe, expect, it } from "vitest";
import { syncListingFeeds } from "./syncListingFeeds.js";

/**
 * A stand-in for the mongoose subdocument array: `pull` by _id and `push`
 * assigning one, which is all `syncListingFeeds` uses.
 */
const makeAccommodation = (feeds = [], occupancy = []) => {
  let next = feeds.length + 1;
  const list = feeds.map((feed) => ({ lastSyncStatus: "never", ...feed }));

  list.pull = ({ _id }) => {
    const index = list.findIndex((feed) => String(feed._id) === String(_id));
    if (index >= 0) list.splice(index, 1);
  };
  list.push = function push(feed) {
    Array.prototype.push.call(this, { _id: `new-${next++}`, ...feed });
  };

  return { calendarSync: list, occupancyCalendar: occupancy };
};

const connect = (calendarFeeds) => ({ calendarFeeds });

describe("syncListingFeeds", () => {
  it("connects a link the editor added", () => {
    const accommodation = makeAccommodation([]);
    const result = syncListingFeeds(accommodation, connect([{ url: "https://a.test/c.ics", label: "Airbnb" }]));

    expect(result).toMatchObject({ added: 1, removed: 0, skipped: false });
    expect(accommodation.calendarSync[0]).toMatchObject({
      url: "https://a.test/c.ics",
      label: "Airbnb",
      lastSyncStatus: "never",
    });
  });

  it("keeps an existing link's id, status and imported dates", () => {
    const accommodation = makeAccommodation(
      [{ _id: "f1", url: "https://a.test/c.ics", label: "Old", lastSyncStatus: "ok", lastImportedCount: 4 }],
      [{ source: "ics", calendarSyncId: "f1" }],
    );

    const result = syncListingFeeds(accommodation, connect([{ url: "https://a.test/c.ics", label: "Airbnb" }]));

    expect(result).toMatchObject({ added: 0, updated: 1, removed: 0 });
    expect(accommodation.calendarSync).toHaveLength(1);
    expect(accommodation.calendarSync[0]).toMatchObject({
      _id: "f1",
      label: "Airbnb",
      lastSyncStatus: "ok",
      lastImportedCount: 4,
    });
    expect(accommodation.occupancyCalendar).toHaveLength(1);
  });

  it("treats a link differing only by scheme or trailing slash as the same one", () => {
    const accommodation = makeAccommodation([{ _id: "f1", url: "https://a.test/c.ics" }]);
    syncListingFeeds(accommodation, connect([{ url: "a.test/c.ics/" }]));

    expect(accommodation.calendarSync).toHaveLength(1);
    expect(accommodation.calendarSync[0]._id).toBe("f1");
  });

  it("removes a link the host deleted, and the dates it had imported", () => {
    const accommodation = makeAccommodation(
      [
        { _id: "f1", url: "https://a.test/c.ics" },
        { _id: "f2", url: "https://b.test/c.ics" },
      ],
      [
        { source: "ics", calendarSyncId: "f1" },
        { source: "ics", calendarSyncId: "f2" },
        { source: "manual" },
      ],
    );

    const result = syncListingFeeds(accommodation, connect([{ url: "https://a.test/c.ics" }]));

    expect(result.removed).toBe(1);
    expect(accommodation.calendarSync.map((feed) => feed._id)).toEqual(["f1"]);
    // f2's imported dates are gone; f1's and the host's own block remain.
    expect(accommodation.occupancyCalendar).toHaveLength(2);
    expect(accommodation.occupancyCalendar.some((row) => row.calendarSyncId === "f2")).toBe(false);
  });

  it("collapses the same link pasted twice into one feed", () => {
    const accommodation = makeAccommodation([]);
    syncListingFeeds(
      accommodation,
      connect([
        { url: "https://a.test/c.ics", label: "First" },
        { url: "https://a.test/c.ics", label: "Second" },
      ]),
    );

    expect(accommodation.calendarSync).toHaveLength(1);
    expect(accommodation.calendarSync[0].label).toBe("Second");
  });

  it("mirrors a link regardless of any legacy calendarChoice left on the draft", () => {
    // The manual/connect choice is gone from the editor, but drafts saved
    // before it was removed still carry it. A link must not be ignored because
    // of a field nothing sets any more.
    const accommodation = makeAccommodation([]);
    const result = syncListingFeeds(accommodation, {
      calendarChoice: "none",
      calendarFeeds: [{ url: "https://a.test/c.ics" }],
    });

    expect(result.skipped).toBe(false);
    expect(accommodation.calendarSync).toHaveLength(1);
  });

  it("clears the connected links when the host removed the last one", () => {
    const accommodation = makeAccommodation(
      [{ _id: "f1", url: "https://a.test/c.ics" }],
      [{ source: "ics", calendarSyncId: "f1" }],
    );

    const result = syncListingFeeds(accommodation, connect([]));

    expect(result.removed).toBe(1);
    expect(accommodation.calendarSync).toHaveLength(0);
    expect(accommodation.occupancyCalendar).toHaveLength(0);
  });

  it("ignores blank rows the editor leaves behind", () => {
    const accommodation = makeAccommodation([]);
    const result = syncListingFeeds(accommodation, connect([{ url: "   ", label: "" }, { url: "" }]));

    expect(result.added).toBe(0);
    expect(accommodation.calendarSync).toHaveLength(0);
  });
});
