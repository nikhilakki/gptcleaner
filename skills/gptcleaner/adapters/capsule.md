## gptcleaner — clean AI / copy-paste text artifacts

When text needs invisible or zero-width characters removed, hidden AI watermark
codepoints detected, smart quotes or em dashes normalized, spacing and blank
lines fixed, or markdown stripped — run the bundled script instead of writing a
regex. It is stdlib-only Python, offline, and safe on any size input.

```bash
CLEAN={{SKILL_DIR}}/scripts/gptcleaner.py

python3 $CLEAN FILE              # clean -> stdout   (also reads stdin)
python3 $CLEAN FILE --detect     # report hidden characters, change nothing
python3 $CLEAN FILE -o OUT.txt   # or -i to rewrite in place
python3 $CLEAN FILE -m           # also strip markdown (opt-in: destructive)
python3 $CLEAN -c                # clean the system clipboard in place
python3 $CLEAN --help            # every flag
```

Defaults remove invisibles + odd spaces + smart punctuation and fix spacing.
Never use `-m` on source code — use `--preset zero-width` (invisibles only)
there. `--keep-dashes` preserves em dashes when the user only wanted the hidden
characters gone. `--json` gives per-codepoint counts.

Full instructions: {{SKILL_DIR}}/SKILL.md
Flag and character tables: {{SKILL_DIR}}/reference.md
