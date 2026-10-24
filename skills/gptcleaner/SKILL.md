---
name: gptcleaner
description: Clean copy-paste artifacts out of text - remove zero-width/invisible characters and hidden AI watermark codepoints, normalize smart quotes and em dashes, fix spacing and blank lines, and optionally strip markdown. Use when text contains invisible or hidden characters, when pasting ChatGPT/Claude/Gemini output into Word, Google Docs, a CMS or code, when asked to detect an AI watermark or "clean up"/"de-AI"/"remove em dashes from" some text, or when a diff shows non-ASCII whitespace.
license: MIT
allowed-tools: Bash(python3:*), Read, Write
---

# GPT Cleaner

Offline text sanitizer. One stdlib-only script, no dependencies, no network.

**Always call the script. Never hand-roll a regex for this** - invisible
characters are easy to miss, easy to mangle, and the script already covers the
whole Unicode surface (see `reference.md`).

## Quick start

```bash
python3 scripts/gptcleaner.py FILE                 # clean -> stdout
cat FILE | python3 scripts/gptcleaner.py           # stdin -> stdout
python3 scripts/gptcleaner.py FILE -o CLEAN.txt    # -> file
python3 scripts/gptcleaner.py FILE -i              # rewrite in place
python3 scripts/gptcleaner.py -c                   # clean the clipboard in place
python3 scripts/gptcleaner.py FILE --detect        # report only, change nothing
python3 scripts/gptcleaner.py --serve              # browser UI on :8000
```

Use the absolute path to `scripts/gptcleaner.py` inside this skill directory.

## Pick the mode from the ask

| The user says | Run |
|---|---|
| "clean this up", "make it paste-safe" | (default - no extra flags) |
| "what's hidden in here?", "is this watermarked?" | `--detect` |
| "remove the invisible/zero-width characters" only | `--preset zero-width` |
| "remove the em dashes", "fix the curly quotes" | `--preset punctuation` |
| "fix the spacing", "too many blank lines" | `--preset spaces` |
| "strip the markdown", "plain text please" | `-m` |
| "remove the bullets too" | `-m --strip-lists` |
| "keep the links" | `-m --keep-links` |
| "double space it" | `--line-spacing double` |
| needs machine-readable output | `--json` |
| "fix this JSON", pasted JSON will not parse | `--fix-json` |

Defaults clean invisibles + odd spaces + smart punctuation + spacing.
**Markdown stripping is opt-in (`-m`)** because it is the destructive one.

## Flags worth knowing

- `--no-punctuation` / `--keep-dashes` - leave quotes / dashes alone
- `--no-invisible`, `--no-spaces`, `--no-spacing` - turn off one pass
- `--blank-lines N` - max consecutive blank lines (default 1)
- `--line-spacing keep|single|1.5|double|triple|N`
- `-s` summary to stderr, `--json` full report, `-V` version

`--help` prints everything. Full flag table and the character tables live in
`reference.md` - read it only when a request needs a detail not listed above.

## Reporting back

After cleaning, tell the user what actually changed - the script prints it:

```
324 chars -> 254 chars | 7 hidden characters removed (ZERO WIDTH SPACE x1, ...)
| 6 smart punctuation marks normalized
```

Use `-s` (stderr summary) when the cleaned text goes to a file or the
clipboard, or `--json` when you need the per-codepoint counts.

## Guardrails

- For JSON, use `--fix-json`, never the default passes: they would rewrite
  quotes, dashes and spacing *inside* string values. `--fix-json` only touches
  what is outside strings and reports whether the result parses.
- Do not clean source code with `-m`: markdown stripping eats `*`, `_` and
  backticks. For code, use `--preset zero-width` (invisibles only).
- Do not run it on a file the user has not asked you to modify. `-i` rewrites
  in place; prefer `-o` or stdout when unsure.
- Em dash -> hyphen is a *style* change. If the user only wanted the invisible
  characters gone, pass `--keep-dashes` or use `--preset zero-width`.
- The script never touches meaning, citations, or numbers - if a request needs
  rewriting rather than sanitizing, that is not this skill.
- Everything runs locally. Never paste user text into a web service to do this.

## Verify

```bash
printf 'a​b — "c"\n' | python3 scripts/gptcleaner.py
# -> a b - "c"
```
