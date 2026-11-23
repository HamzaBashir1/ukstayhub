import { test } from "node:test";
import assert from "node:assert/strict";
import { accentPattern, searchKey } from "./searchText.js";

test("accent-insensitive matching for titles and cities in both directions", () => {
  for (const [a, b] of [
    ["Tatranská Lomnica", "Tatranska Lomnica"],
    ["Žilina", "Zilina"], ["Štrbské pleso", "Strbske pleso"],
    ["Chata Čučoriedka", "Chata Cucoriedka"],
  ]) {
    assert.equal(searchKey(a), searchKey(b));
    assert.match(a, new RegExp(accentPattern(b, true), "i"));
    assert.match(b, new RegExp(accentPattern(a, true), "i"));
  }
});

test("user regex metacharacters are literal", () => {
  assert.doesNotMatch("other title", new RegExp(accentPattern(".*")));
  assert.match("a.b", new RegExp(accentPattern("a.b", true)));
});