# Contributing

Thanks for taking a look. This project is small on purpose and has **no runtime
dependencies** - please keep it that way.

## Ground rules

1. **No dependencies.** The Python CLI is standard library only; the web app is
   vanilla HTML/CSS/JS; the macOS app uses only system frameworks. A PR that
   adds a package needs a very good reason.
2. **Two engines, one behaviour.** `skills/gptcleaner/scripts/gptcleaner.py`
   (Python) and `skills/gptcleaner/web/cleaner.js` (JavaScript) are separate
   implementations of the same rules. **Change one, change both**, then run the
   parity test.
3. **Never break real text.** Removing a character that carries meaning is a
   worse bug than leaving junk behind. Emoji sequences, `snake_case`, code, and
   format characters used by real scripts (Arabic, Syriac, Kaithi) must survive.

## Running the tests

```bash
python3 tests/test_gptcleaner.py    # Python engine  (stdlib unittest)
node    tests/test_cleaner.mjs      # JavaScript engine
python3 tests/test_parity.py        # both engines agree, character for character
```

All three run in CI on every push, across Linux, macOS and Windows.

## Adding a cleaning rule

Add the case to [`tests/cases.json`](tests/cases.json) **first** - both suites
read that file, so one entry tests both engines. Then implement it twice:

| Where | File |
|---|---|
| Python | `skills/gptcleaner/scripts/gptcleaner.py` |
| JavaScript | `skills/gptcleaner/web/cleaner.js` |

Write invisible characters as `\uXXXX` escapes, never as literal characters.
A literal zero-width character is invisible to reviewers and would be destroyed
the moment someone runs this tool over the repo.

## Building the macOS app

```bash
./macos/build.sh --run
```

Needs the Xcode command line tools (`xcode-select --install`). The app runs the
JavaScript engine through JavaScriptCore, so there is no third implementation to
keep in sync.

## Style

- Python: standard library, type hints on public functions, no formatter enforced.
- JavaScript: no build step, no transpiler. It must run as-is in a browser.
- Commit messages: plain description of what changed and why.

## Reporting a bug

Include the input text that misbehaves. If it contains invisible characters,
run `gptcleaner --detect` on it and paste that output - it names the exact
codepoints, which is usually the whole diagnosis.
