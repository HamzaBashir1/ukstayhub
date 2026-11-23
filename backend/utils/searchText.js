const variants = {
  a: "aáä", c: "cč", d: "dď", e: "eé", i: "ií", l: "lĺľ",
  n: "nň", o: "oóô", r: "rŕ", s: "sš", t: "tť", u: "uú", y: "yý", z: "zž",
};

export const searchKey = (text) => String(text || "").normalize("NFD")
  .replace(/\p{Diacritic}/gu, "").toLocaleLowerCase("sk").trim().replace(/\s+/g, " ");

// Build bounded, escaped regexes rather than interpolating user input into MongoDB regexes.
export const accentPattern = (text, exact = false) => {
  const key = searchKey(text).slice(0, 100);
  const pattern = [...key].map((letter) =>
    variants[letter] ? `[${variants[letter]}]` : /[.*+?^${}()|[\]\\]/.test(letter) ? `\\${letter}` : letter
  ).join("");
  return exact ? `^${pattern}$` : pattern;
};