/* gptcleaner engine - vanilla JS port of skills/gptcleaner/scripts/gptcleaner.py
   Pure functions, no DOM. Everything runs locally in the browser. */
(function (root) {
  "use strict";

  /* ---- character tables ------------------------------------------------ */

  // Format chars that are meaningful in real scripts - never removed.
  const CF_KEEP = new Set([0x0600, 0x0601, 0x0602, 0x0603, 0x0604, 0x0605,
    0x06DD, 0x070F, 0x08E2, 0x110BD, 0x110CD]);

  // Invisible letters the category check misses. Codepoints, not literals:
  // a literal zero-width character here would be invisible to reviewers and
  // destroyed by running this very tool over the repo.
  const INVISIBLE_EXTRA = new Set([
    0x115F, 0x1160, 0x3164, 0xFFA0,   // hangul fillers
    0x17B4, 0x17B5,                   // khmer inherent vowels
    0x2800,                           // braille pattern blank
  ]);

  const RE_CC_CF = /[\p{Cc}\p{Cf}]/u;
  const RE_ZS = /\p{Zs}/u;

  function isInvisible(ch) {
    if (ch === "\t" || ch === "\n" || ch === "\r") return false;
    const cp = ch.codePointAt(0);
    if (INVISIBLE_EXTRA.has(cp)) return true;
    if (cp >= 0xFE00 && cp <= 0xFE0F && cp !== 0xFE0F) return true;  // variation selectors, emoji VS16 kept
    if (cp >= 0xE0100 && cp <= 0xE01EF) return true;                 // VS supplement
    if (CF_KEEP.has(cp)) return false;
    return RE_CC_CF.test(ch);   // control + format: ZWSP, BOM, soft hyphen, bidi, tag block
  }

  function isOddSpace(ch) {
    return ch !== " " && RE_ZS.test(ch);
  }

  const ZWJ = 0x200D;

  // Roughly: could this character take part in an emoji ZWJ sequence?
  function isEmojiish(ch) {
    if (!ch) return false;
    const cp = ch.codePointAt(0);
    return (cp >= 0x1F000 && cp <= 0x1FAFF) ||   // pictographs, emoticons, transport
           (cp >= 0x2600 && cp <= 0x27BF) ||     // misc symbols and dingbats
           (cp >= 0x2B00 && cp <= 0x2BFF) ||
           cp === 0xFE0F ||
           (cp >= 0x1F3FB && cp <= 0x1F3FF);     // skin tone modifiers
  }

  // "woman + ZWJ + laptop" is one glyph; dropping the ZWJ would split it in two.
  // A ZWJ loose in prose is junk and still gets removed.
  function isJoiningZWJ(chars, i) {
    return i > 0 && i + 1 < chars.length &&
           isEmojiish(chars[i - 1]) && isEmojiish(chars[i + 1]);
  }

  const QUOTE_MAP = {
    "‘": "'", "’": "'", "‚": "'", "‛": "'",
    "′": "'", "‵": "'", "ʼ": "'", "ʹ": "'",
    "“": '"', "”": '"', "„": '"', "‟": '"',
    "″": '"', "‶": '"', "«": '"', "»": '"',
    "‹": "'", "›": "'",
    "…": "...", "⁄": "/", "´": "'",
  };
  const DASH_MAP = {
    "‐": "-", "‑": "-", "‒": "-", "–": "-",
    "—": "-", "―": "-", "−": "-", "⁃": "-",
  };

  /* ---- codepoint names (common offenders; fallback is U+XXXX) ---------- */

  const NAMES = {
    0x0000: "NULL", 0x0007: "BELL", 0x0008: "BACKSPACE", 0x000B: "VERTICAL TAB",
    0x000C: "FORM FEED", 0x001B: "ESCAPE", 0x007F: "DELETE",
    0x00A0: "NO-BREAK SPACE", 0x00AD: "SOFT HYPHEN",
    0x061C: "ARABIC LETTER MARK", 0x115F: "HANGUL CHOSEONG FILLER",
    0x1160: "HANGUL JUNGSEONG FILLER", 0x1680: "OGHAM SPACE MARK",
    0x17B4: "KHMER VOWEL INHERENT AQ", 0x17B5: "KHMER VOWEL INHERENT AA",
    0x180E: "MONGOLIAN VOWEL SEPARATOR",
    0x2000: "EN QUAD", 0x2001: "EM QUAD", 0x2002: "EN SPACE", 0x2003: "EM SPACE",
    0x2004: "THREE-PER-EM SPACE", 0x2005: "FOUR-PER-EM SPACE",
    0x2006: "SIX-PER-EM SPACE", 0x2007: "FIGURE SPACE",
    0x2008: "PUNCTUATION SPACE", 0x2009: "THIN SPACE", 0x200A: "HAIR SPACE",
    0x200B: "ZERO WIDTH SPACE", 0x200C: "ZERO WIDTH NON-JOINER",
    0x200D: "ZERO WIDTH JOINER", 0x200E: "LEFT-TO-RIGHT MARK",
    0x200F: "RIGHT-TO-LEFT MARK",
    0x202A: "LEFT-TO-RIGHT EMBEDDING", 0x202B: "RIGHT-TO-LEFT EMBEDDING",
    0x202C: "POP DIRECTIONAL FORMATTING", 0x202D: "LEFT-TO-RIGHT OVERRIDE",
    0x202E: "RIGHT-TO-LEFT OVERRIDE", 0x202F: "NARROW NO-BREAK SPACE",
    0x205F: "MEDIUM MATHEMATICAL SPACE", 0x2060: "WORD JOINER",
    0x2061: "FUNCTION APPLICATION", 0x2062: "INVISIBLE TIMES",
    0x2063: "INVISIBLE SEPARATOR", 0x2064: "INVISIBLE PLUS",
    0x2066: "LEFT-TO-RIGHT ISOLATE", 0x2067: "RIGHT-TO-LEFT ISOLATE",
    0x2068: "FIRST STRONG ISOLATE", 0x2069: "POP DIRECTIONAL ISOLATE",
    0x2800: "BRAILLE PATTERN BLANK", 0x3000: "IDEOGRAPHIC SPACE",
    0x3164: "HANGUL FILLER", 0xFEFF: "ZERO WIDTH NO-BREAK SPACE (BOM)",
    0xFFA0: "HALFWIDTH HANGUL FILLER", 0xFFFE: "REVERSED BOM",
    0x2013: "EN DASH", 0x2014: "EM DASH", 0x2026: "HORIZONTAL ELLIPSIS",
    0x2018: "LEFT SINGLE QUOTATION MARK", 0x2019: "RIGHT SINGLE QUOTATION MARK",
    0x201C: "LEFT DOUBLE QUOTATION MARK", 0x201D: "RIGHT DOUBLE QUOTATION MARK",
  };

  function hex(cp) {
    return "U+" + cp.toString(16).toUpperCase().padStart(4, "0");
  }

  function charName(ch) {
    const cp = ch.codePointAt(0);
    if (NAMES[cp]) return NAMES[cp];
    if (cp >= 0xFE00 && cp <= 0xFE0F) return "VARIATION SELECTOR-" + (cp - 0xFE00 + 1);
    if (cp >= 0xE0100 && cp <= 0xE01EF) return "VARIATION SELECTOR-" + (cp - 0xE0100 + 17);
    if (cp === 0xE0001) return "LANGUAGE TAG";
    if (cp === 0xE007F) return "CANCEL TAG";
    if (cp >= 0xE0020 && cp <= 0xE007E)
      return "TAG " + JSON.stringify(String.fromCodePoint(cp - 0xE0000)).slice(1, -1).toUpperCase();
    if (cp < 0x20 || (cp >= 0x80 && cp <= 0x9F)) return "CONTROL " + hex(cp);
    return hex(cp);
  }

  /* ---- options --------------------------------------------------------- */

  const DEFAULTS = {
    invisible: true, spaces: true, punctuation: true, dashes: true,
    spacing: true, collapseSpaces: true, maxBlankLines: 1,
    markdown: false, keepLinks: false, stripLists: false,
    lineSpacing: "keep",
  };

  /* ---- passes ---------------------------------------------------------- */

  function stripInvisible(text, opt, removed) {
    let out = "";
    const chars = [...text];
    for (let i = 0; i < chars.length; i++) {
      const ch = chars[i];
      if (ch.codePointAt(0) === ZWJ && isJoiningZWJ(chars, i)) {
        out += ch;                // part of an emoji, not junk
        continue;
      }
      if (opt.invisible && isInvisible(ch)) {
        removed.set(ch, (removed.get(ch) || 0) + 1);
        continue;
      }
      if (opt.spaces && isOddSpace(ch)) {
        removed.set(ch, (removed.get(ch) || 0) + 1);
        out += " ";
        continue;
      }
      out += ch;
    }
    return out;
  }

  function fixPunctuation(text, opt, replaced) {
    const table = {};
    if (opt.punctuation) Object.assign(table, QUOTE_MAP);
    if (opt.dashes) Object.assign(table, DASH_MAP);
    const keys = Object.keys(table);
    if (!keys.length) return text;
    const re = new RegExp("[" + keys.join("") + "]", "gu");
    return text.replace(re, (ch) => {
      replaced.set(ch, (replaced.get(ch) || 0) + 1);
      return table[ch];
    });
  }

  function stripMarkdown(text, opt) {
    // fenced code blocks -> keep the code, drop the fences
    text = text.replace(
      /^[ \t]{0,3}(`{3,}|~{3,})[^\n]*\n([\s\S]*?)(?:^[ \t]{0,3}\1[ \t]*$\n?|$(?![\s\S]))/gm,
      (_, __, body) => body);

    text = text.replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1");                 // images
    text = opt.keepLinks
      ? text.replace(/\[([^\]]*)\]\(\s*<?([^)\s]*)>?[^)]*\)/g, "$1 ($2)") // links
      : text.replace(/\[([^\]]*)\]\([^)]*\)/g, "$1");
    text = text.replace(/\[([^\]]*)\]\[[^\]]*\]/g, "$1");                 // reference links
    text = text.replace(/<((?:https?|mailto):[^>\s]+)>/g, "$1");          // autolinks

    text = text.replace(/^[ \t]{0,3}#{1,6}[ \t]*/gm, "");                 // headings
    text = text.replace(/[ \t]+#+[ \t]*$/gm, "");
    text = text.replace(/^[ \t]{0,3}(?:[-*_][ \t]*){3,}$/gm, "");         // rules
    text = text.replace(/^[ \t]{0,3}(?:>[ \t]?)+/gm, "");                 // blockquotes

    text = text.replace(/(?<!\\)\*\*\*(\S(?:[\s\S]*?\S)?)\*\*\*/g, "$1"); // emphasis
    text = text.replace(/(?<!\\)\*\*(\S(?:[\s\S]*?\S)?)\*\*/g, "$1");
    text = text.replace(/(?<!\\)\*(?!\s)([^*\n]+?)(?<!\s)\*/g, "$1");
    text = text.replace(/(?<![\w\\])___(\S(?:[\s\S]*?\S)?)___(?!\w)/g, "$1");
    text = text.replace(/(?<![\w\\])__(\S(?:[\s\S]*?\S)?)__(?!\w)/g, "$1");
    text = text.replace(/(?<![\w\\])_(?!\s)([^_\n]+?)(?<!\s)_(?!\w)/g, "$1");
    text = text.replace(/~~(\S(?:[\s\S]*?\S)?)~~/g, "$1");                // strikethrough
    text = text.replace(/(?<!`)`([^`\n]+)`(?!`)/g, "$1");                 // inline code

    if (opt.stripLists) {                                                 // list markers
      text = text.replace(/^([ \t]*)[-*+•‣▪●·][ \t]+/gm, "$1");
      text = text.replace(/^([ \t]*)\d+[.)][ \t]+/gm, "$1");
    } else {
      text = text.replace(/^([ \t]*)[-*+•‣▪●·][ \t]+/gm, "$1- ");
    }

    text = text.replace(                                                  // table separator rows
      /^[ \t]{0,3}\|?[ \t]*:?-{3,}:?[ \t]*(\|[ \t]*:?-{3,}:?[ \t]*)+\|?[ \t]*$/gm, "");
    text = text.replace(/\\([\\`*_{}\[\]()#+\-.!>~|])/g, "$1");           // escapes
    return text;
  }

  function fixSpacing(text, opt) {
    const lines = text.split("\n").map((line) => {
      if (opt.collapseSpaces) {
        const indent = line.match(/^[ \t]*/)[0];
        line = indent + line.slice(indent.length).replace(/[ \t]{2,}/g, " ");
      }
      return line.replace(/[ \t]+$/, "");
    });
    text = lines.join("\n");
    if (opt.maxBlankLines != null && opt.maxBlankLines >= 0) {
      const keep = opt.maxBlankLines + 1;
      text = text.replace(new RegExp("\\n{" + (keep + 1) + ",}", "g"), "\n".repeat(keep));
    }
    return text.replace(/^\n+|\n+$/g, "");
  }

  function applyLineSpacing(text, mode) {
    mode = String(mode || "keep").toLowerCase();
    if (mode === "keep" || mode === "") return text;
    if (mode === "single") return text.replace(/\n{2,}/g, "\n");
    if (mode === "1.5" || mode === "1,5") return text.replace(/\n{3,}/g, "\n\n");
    let gap = { double: 2, triple: 3 }[mode];
    if (!gap) gap = Math.max(1, parseInt(mode, 10) || 1);
    return text.split("\n").filter((l) => l.trim()).join("\n".repeat(gap));
  }

  /* ---- public API ------------------------------------------------------ */

  function clean(text, options) {
    const opt = Object.assign({}, DEFAULTS, options || {});
    const original = text;
    const removed = new Map();    // char -> count (deleted or space-normalized)
    const replaced = new Map();   // char -> count (punctuation)

    text = text.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
    if (opt.invisible || opt.spaces) text = stripInvisible(text, opt, removed);
    if (opt.markdown) text = stripMarkdown(text, opt);
    if (opt.punctuation || opt.dashes) text = fixPunctuation(text, opt, replaced);
    if (opt.spacing) text = fixSpacing(text, opt);
    text = applyLineSpacing(text, opt.lineSpacing);

    let hidden = 0;
    removed.forEach((n) => { hidden += n; });
    let fixed = 0;
    replaced.forEach((n) => { fixed += n; });

    return {
      text,
      report: {
        charsIn: [...original].length,
        charsOut: [...text].length,
        removed, replaced,
        hiddenTotal: hidden,
        punctuationTotal: fixed,
      },
    };
  }

  // Find hidden/odd characters without changing anything.
  function scan(text) {
    const counts = new Map();
    const first = new Map();
    const lines = text.split("\n");
    for (let li = 0; li < lines.length; li++) {
      let col = 0;
      for (const ch of lines[li]) {
        col++;
        if (isInvisible(ch) || isOddSpace(ch)) {
          counts.set(ch, (counts.get(ch) || 0) + 1);
          if (!first.has(ch)) first.set(ch, [li + 1, col]);
        }
      }
    }
    return [...counts.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([ch, n]) => ({
        char: ch, count: n, code: hex(ch.codePointAt(0)), name: charName(ch),
        line: first.get(ch)[0], col: first.get(ch)[1],
      }));
  }

  const api = { clean, scan, charName, hex, isInvisible, isOddSpace, DEFAULTS };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  root.GPTCleaner = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
