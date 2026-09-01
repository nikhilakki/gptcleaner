#!/usr/bin/env python3
"""
gptcleaner.py - an offline, local clone of gptcleanuptools.com

Strips the artifacts that AI chat UIs (ChatGPT, Claude, Gemini, ...), PDFs and
rich-text editors leave in text when you copy it out:

  1. invisible characters  zero-width spaces/joiners, BOMs, soft hyphens,
                           bidi marks, tag characters (hidden-text watermarks),
                           variation selectors, hangul fillers, control codes
  2. exotic spaces         no-break space, thin/em/ideographic space -> plain space
  3. smart punctuation     curly quotes -> straight, em/en dash -> hyphen, ... -> ...
  4. spacing               CRLF -> LF, trailing whitespace, doubled spaces,
                           runs of blank lines
  5. markdown (opt-in)     **bold**, *italic*, # headings, `code`, ``` fences,
                           [links](url), > quotes, --- rules, bullets

Usage
  python3 gptcleaner.py notes.txt                 clean a file -> stdout
  pbpaste | python3 gptcleaner.py                 clean stdin  -> stdout
  python3 gptcleaner.py -c                        clean the clipboard in place
  python3 gptcleaner.py notes.txt -o clean.txt    write to a file
  python3 gptcleaner.py notes.txt --markdown      also strip markdown
  python3 gptcleaner.py notes.txt --detect        report hidden characters only
  python3 gptcleaner.py --serve                   browser UI on http://localhost:8000

Presets mirror the individual tools on the site:
  --preset full | invisible | zero-width | watermark | spaces | punctuation | markdown

Everything runs locally; nothing is sent anywhere. Standard library only.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import unicodedata
from collections import Counter
from dataclasses import dataclass, asdict

__version__ = "1.1"

# --------------------------------------------------------------------------
# character tables
# --------------------------------------------------------------------------

# Invisible junk that is always safe to delete outright.
# Written as codepoints, not literal characters: a literal zero-width character
# in this source would be invisible to reviewers and destroyed by running this
# very tool over the repo.
INVISIBLE_EXTRA = frozenset({
    0x115F, 0x1160, 0x3164, 0xFFA0,   # hangul fillers - render as nothing
    0x17B4, 0x17B5,                   # khmer inherent vowels - invisible
    0x2800,                           # braille pattern blank
})

# Format chars (category Cf) that are *meaningful* in real scripts - never drop.
CF_KEEP = {
    0x0600, 0x0601, 0x0602, 0x0603, 0x0604, 0x0605,  # arabic number signs
    0x06DD, 0x070F, 0x08E2, 0x110BD, 0x110CD,
}

VARIATION_SELECTORS = set(range(0xFE00, 0xFE10)) | set(range(0xE0100, 0xE01F0))
VS16 = 0xFE0F  # emoji presentation selector - kept so emoji still render
ZWJ = 0x200D   # kept when it is fusing an emoji sequence (see is_joining_zwj)


def is_emoji_ish(ch: str) -> bool:
    """Roughly: could this character take part in an emoji ZWJ sequence?"""
    cp = ord(ch)
    return (0x1F000 <= cp <= 0x1FAFF      # pictographs, emoticons, transport, ...
            or 0x2600 <= cp <= 0x27BF     # misc symbols and dingbats
            or 0x2B00 <= cp <= 0x2BFF
            or cp == VS16
            or 0x1F3FB <= cp <= 0x1F3FF)  # skin tone modifiers


def is_joining_zwj(text: str, i: int) -> bool:
    """True when text[i] is a ZWJ doing real work between two emoji.

    'woman + ZWJ + laptop' is one glyph; deleting the ZWJ would split it into
    two. A ZWJ loose in prose is junk and still gets removed.
    """
    if i == 0 or i + 1 >= len(text):
        return False
    return is_emoji_ish(text[i - 1]) and is_emoji_ish(text[i + 1])

# Smart punctuation -> ASCII
QUOTE_MAP = {
    "‘": "'", "’": "'", "‚": "'", "‛": "'",
    "′": "'", "‵": "'", "ʼ": "'", "ʹ": "'",
    "“": '"', "”": '"', "„": '"', "‟": '"',
    "″": '"', "‶": '"', "«": '"', "»": '"',
    "‹": "'", "›": "'",
}
DASH_MAP = {
    "‐": "-", "‑": "-", "‒": "-", "–": "-",
    "—": "-", "―": "-", "−": "-", "⁃": "-",
}
MISC_MAP = {
    "…": "...", "⁄": "/", "´": "'", "˜": "~",
    "––": "--",
}


def char_name(ch: str) -> str:
    try:
        return unicodedata.name(ch)
    except ValueError:
        return "<unnamed control>"


def code(ch: str) -> str:
    return "U+%04X" % ord(ch)


def is_invisible(ch: str) -> bool:
    """True for characters that occupy no space and carry no meaning here."""
    cp = ord(ch)
    if ch in "\t\n\r":
        return False
    if cp in INVISIBLE_EXTRA:
        return True
    if cp in VARIATION_SELECTORS and cp != VS16:
        return True
    if cp in CF_KEEP:
        return False
    cat = unicodedata.category(ch)
    # Cc = control, Cf = format (zero-width, BOM, soft hyphen, bidi, tag chars)
    return cat in ("Cc", "Cf")


def is_odd_space(ch: str) -> bool:
    """A space-like character that is not a plain ASCII space."""
    return ch != " " and unicodedata.category(ch) == "Zs"


# --------------------------------------------------------------------------
# options
# --------------------------------------------------------------------------

@dataclass
class Options:
    invisible: bool = True        # remove zero-width / hidden characters
    spaces: bool = True           # nbsp & friends -> plain space
    punctuation: bool = True      # curly quotes, ellipsis
    dashes: bool = True           # em/en dash -> hyphen (part of punctuation)
    spacing: bool = True          # trailing whitespace, doubled spaces, blank lines
    collapse_spaces: bool = True  # "a  b" -> "a b"
    max_blank_lines: int = 1      # at most N blank lines in a row
    markdown: bool = False        # strip markdown formatting
    keep_links: bool = False      # [t](u) -> "t (u)" instead of "t"
    strip_lists: bool = False     # also remove "- " / "1. " list markers
    line_spacing: str = "keep"    # keep | single | 1.5 | double | triple | <int>


PRESETS = {
    "full": {},
    "invisible": dict(punctuation=False, dashes=False, spacing=False, spaces=False),
    "zero-width": dict(punctuation=False, dashes=False, spacing=False, spaces=False),
    "watermark": dict(punctuation=False, dashes=False, spacing=False, spaces=False),
    "spaces": dict(invisible=False, punctuation=False, dashes=False),
    "punctuation": dict(invisible=False, spacing=False, spaces=False),
    "markdown": dict(markdown=True),
    "none": dict(invisible=False, spaces=False, punctuation=False,
                 dashes=False, spacing=False),
}


# --------------------------------------------------------------------------
# cleaning steps
# --------------------------------------------------------------------------

def strip_invisible(text: str, opt: Options, report: Counter) -> str:
    out = []
    chars = list(text)
    for i, ch in enumerate(chars):
        if ord(ch) == ZWJ and is_joining_zwj(chars, i):
            out.append(ch)          # part of an emoji, not junk
            continue
        if opt.invisible and is_invisible(ch):
            report[ch] += 1
            continue
        if opt.spaces and is_odd_space(ch):
            report[ch] += 1
            out.append(" ")
            continue
        out.append(ch)
    return "".join(out)


def fix_punctuation(text: str, opt: Options, report: Counter) -> str:
    table = {}
    if opt.punctuation:
        table.update(QUOTE_MAP)
        table.update({"…": "...", "⁄": "/", "´": "'"})
    if opt.dashes:
        table.update(DASH_MAP)
    if not table:
        return text
    for ch in set(text) & set(table):
        report[ch] += text.count(ch)
    return text.translate({ord(k): v for k, v in table.items()})


_FENCE_RE = re.compile(
    r"^[ \t]{0,3}(`{3,}|~{3,})[^\n]*\n(.*?)(?:^[ \t]{0,3}\1[ \t]*$\n?|\Z)",
    re.S | re.M,
)


def strip_markdown(text: str, opt: Options) -> str:
    # fenced code blocks -> keep the code, drop the fences
    text = _FENCE_RE.sub(lambda m: m.group(2), text)

    # images and links
    text = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", text)
    if opt.keep_links:
        text = re.sub(r"\[([^\]]*)\]\(\s*<?([^)\s]*)>?[^)]*\)", r"\1 (\2)", text)
    else:
        text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\[[^\]]*\]", r"\1", text)
    text = re.sub(r"<((?:https?|mailto):[^>\s]+)>", r"\1", text)

    # headings, rules, blockquotes
    text = re.sub(r"^[ \t]{0,3}#{1,6}[ \t]*", "", text, flags=re.M)
    text = re.sub(r"[ \t]+#+[ \t]*$", "", text, flags=re.M)
    text = re.sub(r"^[ \t]{0,3}(?:[-*_][ \t]*){3,}$", "", text, flags=re.M)
    text = re.sub(r"^[ \t]{0,3}(?:>[ \t]?)+", "", text, flags=re.M)

    # emphasis
    text = re.sub(r"(?<!\\)\*\*\*(\S(?:.*?\S)?)\*\*\*", r"\1", text, flags=re.S)
    text = re.sub(r"(?<!\\)\*\*(\S(?:.*?\S)?)\*\*", r"\1", text, flags=re.S)
    text = re.sub(r"(?<!\\)\*(?!\s)([^*\n]+?)(?<!\s)\*", r"\1", text)
    text = re.sub(r"(?<![\w\\])___(\S(?:.*?\S)?)___(?!\w)", r"\1", text, flags=re.S)
    text = re.sub(r"(?<![\w\\])__(\S(?:.*?\S)?)__(?!\w)", r"\1", text, flags=re.S)
    text = re.sub(r"(?<![\w\\])_(?!\s)([^_\n]+?)(?<!\s)_(?!\w)", r"\1", text)
    text = re.sub(r"~~(\S(?:.*?\S)?)~~", r"\1", text, flags=re.S)

    # inline code
    text = re.sub(r"(?<!`)`([^`\n]+)`(?!`)", r"\1", text)

    # list markers
    bullets = r"[-*+•‣▪●·]"
    if opt.strip_lists:
        text = re.sub(r"^([ \t]*)" + bullets + r"[ \t]+", r"\1", text, flags=re.M)
        text = re.sub(r"^([ \t]*)\d+[.)][ \t]+", r"\1", text, flags=re.M)
    else:
        text = re.sub(r"^([ \t]*)" + bullets + r"[ \t]+", r"\1- ", text, flags=re.M)

    # table pipes and backslash escapes
    text = re.sub(r"^[ \t]{0,3}\|?[ \t]*:?-{3,}:?[ \t]*(\|[ \t]*:?-{3,}:?[ \t]*)+\|?[ \t]*$",
                  "", text, flags=re.M)
    text = re.sub(r"\\([\\`*_{}\[\]()#+\-.!>~|])", r"\1", text)
    return text


def fix_spacing(text: str, opt: Options) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = []
    for line in text.split("\n"):
        if opt.collapse_spaces:
            indent = re.match(r"[ \t]*", line).group()
            body = re.sub(r"[ \t]{2,}", " ", line[len(indent):])
            line = indent + body
        lines.append(line.rstrip())
    text = "\n".join(lines)
    if opt.max_blank_lines is not None and opt.max_blank_lines >= 0:
        keep = opt.max_blank_lines + 1
        text = re.sub(r"\n{%d,}" % (keep + 1), "\n" * keep, text)
    return text.strip("\n")


def apply_line_spacing(text: str, mode: str) -> str:
    mode = (mode or "keep").lower()
    if mode in ("keep", ""):
        return text
    if mode == "single":
        return re.sub(r"\n{2,}", "\n", text)
    if mode in ("1.5", "1,5"):
        return re.sub(r"\n{3,}", "\n\n", text)
    gap = {"double": 2, "triple": 3}.get(mode)
    if gap is None:
        try:
            gap = max(1, int(mode))
        except ValueError:
            raise SystemExit("unknown --line-spacing value: %r" % mode)
    lines = [ln for ln in text.split("\n") if ln.strip()]
    return ("\n" * gap).join(lines)


def clean(text: str, opt: Options | None = None) -> tuple[str, dict]:
    """Clean text; return (cleaned_text, report). Defaults to the full preset."""
    opt = opt or Options()
    original = text
    removed: Counter = Counter()
    replaced: Counter = Counter()

    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if opt.invisible or opt.spaces:
        text = strip_invisible(text, opt, removed)
    if opt.markdown:
        text = strip_markdown(text, opt)
    if opt.punctuation or opt.dashes:
        text = fix_punctuation(text, opt, replaced)
    if opt.spacing:
        text = fix_spacing(text, opt)
    text = apply_line_spacing(text, opt.line_spacing)

    report = {
        "chars_in": len(original),
        "chars_out": len(text),
        "words_out": len(text.split()),
        "lines_out": text.count("\n") + 1 if text else 0,
        "removed": removed,
        "replaced": replaced,
        "hidden_total": sum(removed.values()),
    }
    return text, report


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------

def scan(text: str) -> list[tuple[str, int, int, int]]:
    """Find hidden/odd characters: [(char, count, first_line, first_col)]."""
    counts: Counter = Counter()
    first: dict[str, tuple[int, int]] = {}
    for lineno, line in enumerate(text.split("\n"), 1):
        for col, ch in enumerate(line, 1):
            if is_invisible(ch) or is_odd_space(ch):
                counts[ch] += 1
                first.setdefault(ch, (lineno, col))
    return [(ch, n, first[ch][0], first[ch][1])
            for ch, n in counts.most_common()]


def detect_report(text: str) -> str:
    rows = scan(text)
    if not rows:
        return "No hidden or non-standard characters found. Text is clean."
    out = ["Found %d hidden/non-standard character(s) of %d kind(s):"
           % (sum(r[1] for r in rows), len(rows)), ""]
    out.append("  %-8s %-40s %6s  %s" % ("CODE", "NAME", "COUNT", "FIRST AT"))
    for ch, n, line, col in rows:
        out.append("  %-8s %-40s %6d  line %d, col %d"
                   % (code(ch), char_name(ch)[:40], n, line, col))
    return "\n".join(out)


def summary_line(report: dict) -> str:
    parts = ["%s chars -> %s chars" % (f"{report['chars_in']:,}",
                                       f"{report['chars_out']:,}")]
    hidden = report["hidden_total"]
    if hidden:
        detail = ", ".join("%s x%d" % (char_name(c), n)
                           for c, n in report["removed"].most_common(4))
        parts.append("%d hidden character%s removed (%s)"
                     % (hidden, "" if hidden == 1 else "s", detail))
    else:
        parts.append("no hidden characters found")
    fixed = sum(report["replaced"].values())
    if fixed:
        parts.append("%d smart punctuation mark%s normalized"
                     % (fixed, "" if fixed == 1 else "s"))
    return " | ".join(parts)


# --------------------------------------------------------------------------
# clipboard
# --------------------------------------------------------------------------

def _clip_cmds() -> tuple[list[str] | None, list[str] | None]:
    if shutil.which("pbpaste"):
        return ["pbpaste"], ["pbcopy"]
    if shutil.which("wl-paste"):
        return ["wl-paste"], ["wl-copy"]
    if shutil.which("xclip"):
        return ["xclip", "-selection", "clipboard", "-o"], \
               ["xclip", "-selection", "clipboard"]
    if shutil.which("powershell.exe"):
        return ["powershell.exe", "-command", "Get-Clipboard"], \
               ["clip.exe"]
    return None, None


def clipboard_read() -> str:
    read, _ = _clip_cmds()
    if not read:
        raise SystemExit("no clipboard tool found on this system")
    return subprocess.run(read, capture_output=True, text=True).stdout


def clipboard_write(text: str) -> None:
    _, write = _clip_cmds()
    if not write:
        raise SystemExit("no clipboard tool found on this system")
    subprocess.run(write, input=text, text=True)


# --------------------------------------------------------------------------
# local web UI: static server for the bundled JS app (no backend logic)
# --------------------------------------------------------------------------

def serve(host: str, port: int) -> None:
    """Serve the bundled browser app (../web). All cleaning runs in the page's
    own JavaScript engine (web/cleaner.js) - this process is just a static file
    server and never sees the text being cleaned."""
    import functools
    import pathlib
    from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

    web = pathlib.Path(__file__).resolve().parent.parent / "web"
    if not (web / "index.html").is_file():
        raise SystemExit("browser app not found at %s\n"
                         "(the skill bundle ships it; re-run install.sh)" % web)

    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, *a):  # quiet
            pass

    srv = ThreadingHTTPServer((host, port),
                              functools.partial(Handler, directory=str(web)))
    print("gptcleaner web -> http://%s:%d   (static files only; cleaning runs"
          " in your browser. ctrl-c to stop)"
          % (host if host != "0.0.0.0" else "localhost", port), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="gptcleaner",
        description="Clean AI/PDF/rich-text copy-paste artifacts out of text.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("Usage")[1] if "Usage" in __doc__ else None,
    )
    p.add_argument("input", nargs="?", help="input file (default: stdin)")
    p.add_argument("-o", "--output", help="output file (default: stdout)")
    p.add_argument("-c", "--clipboard", action="store_true",
                   help="read from and write back to the system clipboard")
    p.add_argument("-i", "--in-place", action="store_true",
                   help="rewrite the input file in place")
    p.add_argument("--preset", choices=sorted(PRESETS), default="full",
                   help="start from a preset (default: full)")

    g = p.add_argument_group("what to clean")
    g.add_argument("--no-invisible", action="store_true", help="keep hidden characters")
    g.add_argument("--no-spaces", action="store_true", help="keep nbsp and exotic spaces")
    g.add_argument("--no-punctuation", action="store_true", help="keep curly quotes")
    g.add_argument("--keep-dashes", action="store_true", help="keep em/en dashes as-is")
    g.add_argument("--no-spacing", action="store_true", help="keep original whitespace/blank lines")
    g.add_argument("-m", "--markdown", action="store_true", help="strip markdown formatting")
    g.add_argument("--strip-lists", action="store_true", help="with -m, drop list bullets too")
    g.add_argument("--keep-links", action="store_true", help="with -m, keep URLs as 'text (url)'")
    g.add_argument("--blank-lines", type=int, default=1, metavar="N",
                   help="max consecutive blank lines (default: 1)")
    g.add_argument("--line-spacing", default="keep", metavar="MODE",
                   help="keep | single | 1.5 | double | triple | <n>")

    r = p.add_argument_group("reporting")
    r.add_argument("-d", "--detect", action="store_true",
                   help="only report hidden characters, do not clean")
    r.add_argument("-s", "--stats", action="store_true", help="print a summary to stderr")
    r.add_argument("--json", action="store_true", help="emit JSON (text + report)")

    s = p.add_argument_group("web UI")
    s.add_argument("--serve", action="store_true",
                   help="serve the bundled browser app (cleaning runs in the page)")
    s.add_argument("--port", type=int, default=8000)
    s.add_argument("--host", default="127.0.0.1")

    p.add_argument("-V", "--version", action="version", version="gptcleaner " + __version__)
    return p


def options_from_args(a: argparse.Namespace) -> Options:
    opt = Options(**{**asdict(Options()), **PRESETS[a.preset]})
    if a.no_invisible:
        opt.invisible = False
    if a.no_spaces:
        opt.spaces = False
    if a.no_punctuation:
        opt.punctuation = False
    if a.keep_dashes:
        opt.dashes = False
    if a.no_spacing:
        opt.spacing = False
    if a.markdown:
        opt.markdown = True
    if a.strip_lists:
        opt.strip_lists = True
    if a.keep_links:
        opt.keep_links = True
    opt.max_blank_lines = a.blank_lines
    opt.line_spacing = a.line_spacing
    return opt


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if args.serve:
        serve(args.host, args.port)
        return 0

    # read
    if args.clipboard:
        text = clipboard_read()
    elif args.input:
        with open(args.input, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    else:
        if sys.stdin.isatty():
            build_parser().print_help()
            return 1
        text = sys.stdin.read()

    if args.detect:
        print(detect_report(text))
        return 0

    cleaned, report = clean(text, options_from_args(args))

    if args.json:
        out = json.dumps({
            "text": cleaned,
            "chars_in": report["chars_in"],
            "chars_out": report["chars_out"],
            "hidden_removed": {code(c): n for c, n in report["removed"].items()},
            "punctuation_fixed": {code(c): n for c, n in report["replaced"].items()},
            "summary": summary_line(report),
        }, ensure_ascii=False, indent=2)
        print(out)
        return 0

    # write
    dest = args.output or (args.input if args.in_place else None)
    ends = cleaned if cleaned.endswith("\n") else cleaned + "\n"

    if args.clipboard and not dest:
        clipboard_write(cleaned)
        print(summary_line(report), file=sys.stderr)
    elif dest:
        with open(dest, "w", encoding="utf-8") as fh:
            fh.write(ends)
        print("wrote %s | %s" % (dest, summary_line(report)), file=sys.stderr)
    else:
        sys.stdout.write(ends)

    if args.stats and not (args.clipboard or dest):
        print(summary_line(report), file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
