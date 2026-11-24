// Chooses which blog posts stay in Google and which get `noindex`
// (SEO task "prune blog 491 → 100"). Posts are never deleted: a noindexed post
// stays readable on /blog, but its page sends a noindex tag and it is left out
// of the sitemap.
//
//   node utils/blogNoindex.js                 dry run: writes the proposal CSV
//   node utils/blogNoindex.js --apply <csv>   applies the (reviewed) CSV
//
// The dry run never writes to the database. The CSV's `decision` column
// ("keep" or "noindex") is what --apply uses, so a post can be moved between
// the two by editing that column before applying.
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

import mongoose from "mongoose";
import "../config/env.js";
import Blog from "../models/Blog.js";

export const KEEP_COUNT = 100;

// Topics Putko is about: stays, travel in Slovakia and the regions it has
// landing pages for. A post whose title and summary mention none of these is
// treated as off-topic.
const TOPIC = new RegExp(
  [
    "ubytov", "chat", "chalup", "apartm", "drevenic", "penzi", "glamp", "kemp",
    "dovolen", "výlet", "turist", "túr", "pobyt", "víkend", "rodin",
    "hory", "horsk", "tatr", "liptov", "orav", "pienin", "fatr", "horehron",
    "slovensk\\S* raj", "štiavnic", "kysuc", "spiš", "jaskyn", "hrad", "zámok",
    "kúpe", "termál", "wellness", "jazer", "pleso", "plesá", "vodopád", "lyž",
    "národn\\S* park", "príro",
  ].join("|"),
  "i"
);

export const wordCount = (html) =>
  String(html || "").replace(/<[^>]+>/g, " ").split(/\s+/).filter(Boolean).length;

// Share of very common Slovak words; the site is Slovak, so the few English
// posts are weak candidates regardless of topic.
const SK_COMMON = /(^|\s)(a|je|na|sa|v|pre|alebo|aj|so|že|ako|ktor\S*)(?=\s|$)/gi;
export const isSlovak = (html) => {
  const words = wordCount(html);
  return words > 0 && (String(html).replace(/<[^>]+>/g, " ").match(SK_COMMON) || []).length / words > 0.04;
};

/**
 * Score and reasons for one post. Pure, so the rule can be tested on its own.
 * Higher is better; off-topic and non-Slovak posts are never kept.
 */
export const scorePost = (post) => {
  const words = wordCount(post.content);
  const views = Number(post.views) || 0;
  const topical = TOPIC.test(`${post.title || ""} ${post.summary || ""}`);
  const slovak = isSlovak(post.content);
  const reasons = [];

  let score = 0;
  if (topical) score += 3;
  else reasons.push("off-topic");
  if (!slovak) reasons.push("not Slovak");

  if (words < 300) {
    score -= 3;
    reasons.push(`thin (${words} words)`);
  } else if (words >= 1000) score += 2;
  else if (words >= 600) score += 1;

  // Views are small (the most-read post has ~30), so they only break ties.
  score += Math.min(views, 30) / 10;
  if (views < 10) reasons.push(`${views} views`);

  return { score: Math.round(score * 10) / 10, words, views, eligible: topical && slovak, reasons };
};

/** The best KEEP_COUNT eligible posts are kept; everything else is noindexed. */
export const choosePosts = (posts, keepCount = KEEP_COUNT) => {
  const scored = posts.map((post) => ({ post, ...scorePost(post) }));
  const ranked = [...scored].sort(
    (a, b) =>
      Number(b.eligible) - Number(a.eligible) ||
      b.score - a.score ||
      b.views - a.views ||
      new Date(b.post.createdAt || 0) - new Date(a.post.createdAt || 0)
  );
  return ranked.map((row, index) => {
    const keep = row.eligible && index < keepCount;
    return {
      ...row,
      decision: keep ? "keep" : "noindex",
      // On-topic posts that only missed the cut say so in the CSV.
      reasons: row.eligible && !keep ? [`not in top ${keepCount}`, ...row.reasons] : row.reasons,
    };
  });
};

const csvCell = (value) => `"${String(value ?? "").replace(/"/g, '""')}"`;

// Splits one CSV line written by this script (quoted cells, "" escapes).
export const parseCsvLine = (line) => {
  const cells = [];
  let cell = "";
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quoted) {
      if (ch === '"' && line[i + 1] === '"') { cell += '"'; i++; }
      else if (ch === '"') quoted = false;
      else cell += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === "," || ch === ";") { cells.push(cell); cell = ""; }
    else cell += ch;
  }
  cells.push(cell);
  return cells;
};

const writeProposal = async (file) => {
  const posts = await Blog.find({}, "title slug summary content views createdAt noindex").lean();
  const rows = choosePosts(posts);
  const header = ["decision", "score", "views", "words", "reasons", "title", "url", "id"];
  const lines = rows.map((row) =>
    [
      row.decision,
      row.score,
      row.views,
      row.words,
      row.reasons.join(", "),
      row.post.title,
      `https://ukstayhub.co.uk/blog/${row.post.slug}`,
      String(row.post._id),
    ].map(csvCell).join(",")
  );
  // "sep=," makes Excel split the columns whatever the computer's locale is;
  // the BOM keeps Slovak letters intact.
  fs.writeFileSync(file, "﻿sep=,\n" + [header.map(csvCell).join(","), ...lines].join("\n") + "\n", "utf8");

  const keep = rows.filter((row) => row.decision === "keep").length;
  console.log(`${rows.length} posts: ${keep} keep, ${rows.length - keep} noindex`);
  console.log(`Proposal written to ${file} (dry run, nothing changed).`);
};

const applyProposal = async (file) => {
  const lines = fs.readFileSync(file, "utf8").replace(/^﻿/, "").split(/\r?\n/).filter(Boolean);
  const body = lines[0].startsWith("sep=") ? lines.slice(1) : lines;
  const header = parseCsvLine(body[0]);
  const at = (name) => header.indexOf(name);
  const decisions = body.slice(1).map(parseCsvLine).map((cells) => ({
    id: cells[at("id")],
    decision: String(cells[at("decision")] || "").trim().toLowerCase(),
  }));

  const bad = decisions.filter((row) => !["keep", "noindex"].includes(row.decision) || !mongoose.isValidObjectId(row.id));
  if (bad.length) throw new Error(`${bad.length} rows have no valid id or a decision other than keep/noindex`);

  const toNoindex = decisions.filter((row) => row.decision === "noindex").map((row) => row.id);
  const toKeep = decisions.filter((row) => row.decision === "keep").map((row) => row.id);
  const hidden = await Blog.updateMany({ _id: { $in: toNoindex } }, { $set: { noindex: true } });
  const shown = await Blog.updateMany({ _id: { $in: toKeep } }, { $set: { noindex: false } });
  console.log(`noindex set on ${hidden.modifiedCount} posts, cleared on ${shown.modifiedCount}.`);

  // The blog list and sitemap are cached in Redis; drop them so the change
  // shows up immediately.
  const { connectRedis } = await import("./redis.js");
  const { clearBlogCache } = await import("../Controllers/BlogController.js");
  await connectRedis();
  await clearBlogCache();
  const { default: redisClient } = await import("./redis.js");
  await redisClient.quit().catch(() => {});
};

const main = async () => {
  const applyAt = process.argv.indexOf("--apply");
  await mongoose.connect(process.env.MONGODB_URI);
  try {
    if (applyAt !== -1) {
      const file = process.argv[applyAt + 1];
      if (!file) throw new Error("Usage: node utils/blogNoindex.js --apply <proposal.csv>");
      await applyProposal(path.resolve(file));
    } else {
      await writeProposal(path.resolve("..", "blog-noindex-proposal.csv"));
    }
  } finally {
    await mongoose.disconnect();
  }
};

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
