# gptcleaner reference

Loaded on demand. `SKILL.md` covers the common cases; this file has the full
surface: every flag, what each pass actually does, and the character tables.

## Pipeline order

```
CRLF/CR -> LF
  -> invisible characters removed        (--no-invisible to skip)
  -> odd spaces -> plain space           (--no-spaces)
  -> markdown stripped                   (opt-in: -m)
  -> smart punctuation normalized        (--no-punctuation / --keep-dashes)
  -> whitespace & blank lines collapsed  (--no-spacing)
  -> line spacing applied                (--line-spacing, default: keep)
```

Order matters: invisibles are removed before markdown so a zero-width space
hiding inside `**bold**` cannot defeat the emphasis regex.

## All flags

### Input / output
| Flag | Effect |
|---|---|
| `FILE` | input file; omit to read stdin |
| `-o, --output FILE` | write to a file |
| `-i, --in-place` | rewrite the input file |
| `-c, --clipboard` | read the clipboard, write the result back to it |
| `--serve`, `--port N`, `--host H` | local browser UI (default 127.0.0.1:8000) |

Clipboard support: `pbcopy/pbpaste` (macOS), `wl-copy/wl-paste` (Wayland),
`xclip` (X11), `clip.exe`/`Get-Clipboard` (WSL). Errors out if none is found.

### Presets (`--preset`)
| Preset | Passes enabled |
|---|---|
| `full` *(default)* | invisible, spaces, punctuation, dashes, spacing |
| `invisible` / `zero-width` / `watermark` | invisible only |
| `spaces` | odd spaces + spacing |
| `punctuation` | quotes, dashes, ellipsis |
| `markdown` | full + markdown stripping |
| `none` | nothing (use with explicit flags or `--line-spacing`) |

Flags apply *after* the preset, so `--preset markdown --keep-dashes` works.

### Cleaning switches
| Flag | Effect |
|---|---|
| `--no-invisible` | keep hidden characters |
| `--no-spaces` | keep nbsp and exotic spaces |
| `--no-punctuation` | keep curly quotes / ellipsis |
| `--keep-dashes` | keep em and en dashes |
| `--no-spacing` | keep original whitespace and blank lines |
| `-m, --markdown` | strip markdown formatting |
| `--strip-lists` | with `-m`, drop `- ` and `1. ` markers too |
| `--keep-links` | with `-m`, render links as `text (url)` |
| `--blank-lines N` | max consecutive blank lines (default 1; `0` = none) |
| `--line-spacing MODE` | `keep`, `single`, `1.5`, `double`, `triple`, or an integer |

### Reporting
| Flag | Effect |
|---|---|
| `-d, --detect` | table of hidden chars: codepoint, name, count, first line/col |
| `-s, --stats` | one-line summary on stderr |
| `--json` | `{text, chars_in, chars_out, hidden_removed, punctuation_fixed, summary}` |

## What counts as "invisible"

Detected by Unicode category rather than a fixed list, so new offenders are
caught automatically:

- **`Cc`** control characters, except `\t`, `\n`, `\r`
- **`Cf`** format characters - zero-width space/joiner/non-joiner (U+200B-200D),
  word joiner (U+2060), BOM (U+FEFF), soft hyphen (U+00AD), bidi marks and
  isolates (U+200E/200F, U+202A-202E, U+2066-2069), and the **tag block
  U+E0000-E007F** used to smuggle hidden text into AI output
- **Variation selectors** U+FE00-FE0F and U+E0100-E01EF - *except U+FE0F*, kept
  so emoji still render
- **Invisible letters**: hangul fillers U+115F, U+1160, U+3164, U+FFA0;
  khmer U+17B4/17B5; braille blank U+2800

Deliberately **kept**: format characters that are meaningful in real scripts -
U+0600-0605, U+06DD, U+070F, U+08E2, U+110BD, U+110CD (Arabic/Syriac/Kaithi).

## Odd spaces

Any `Zs` character other than U+0020 becomes a plain space: no-break space
(U+00A0), ogham space (U+1680), en/em/thin/hair spaces (U+2000-200A), narrow
no-break (U+202F), medium math (U+205F), ideographic (U+3000). They are
*replaced*, not deleted, so words never run together.

## Punctuation map

| From | To |
|---|---|
| `' ' ‚ ‛ ′ ‵ ʼ ʹ` | `'` |
| `" " „ ‟ ″ ‶ « »` | `"` |
| `‹ ›` | `'` |
| `‐ ‑ ‒ – — ― − ⁃` | `-` |
| `…` | `...` |
| `⁄` | `/` |
| `´` | `'` |

## Markdown stripping (`-m`)

Removed: fenced code fences (the code itself is kept), inline backticks,
`#` headings, `> ` blockquotes, `---`/`***`/`___` rules, table separator rows,
`**bold**`, `*italic*`, `__bold__`, `_italic_`, `***both***`, `~~strike~~`,
images (alt text kept), links (text kept, or `text (url)` with `--keep-links`),
reference links, autolinks, backslash escapes.

Normalized: bullets `* + • ‣ ▪ ● ·` all become `- `, unless `--strip-lists`
removes them.

Left alone on purpose: `snake_case` and `a_b_c` (underscores bounded by word
characters), `2 * 3` (asterisks surrounded by spaces), numbered lists, tables'
content, indentation.

## Exit codes

`0` success. `1` no input and stdin is a TTY (prints help). Anything else is an
unhandled error - report it rather than retrying.

## Embedding it

The module is importable:

```python
from gptcleaner import clean, Options, detect_report, scan
text, report = clean(raw, Options(markdown=True, dashes=False))
print(report["hidden_total"], report["removed"])   # Counter of char -> count
```

`scan(text)` returns `[(char, count, first_line, first_col), ...]` without
modifying anything.
