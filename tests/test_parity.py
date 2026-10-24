#!/usr/bin/env python3
"""Assert the Python and JavaScript engines produce identical output.

    python3 tests/test_parity.py        (needs node on PATH)

The two engines are separate implementations - Python for the CLI, JavaScript
for the browser and the macOS app. This runner feeds both the same inputs and
diffs the results, so a fix applied to one but not the other fails loudly.
"""
import json
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "skills" / "gptcleaner" / "scripts"))
import gptcleaner  # noqa: E402

CASES = json.loads((ROOT / "tests" / "cases.json").read_text())
JS_ENGINE = ROOT / "skills" / "gptcleaner" / "web" / "cleaner.js"

JS_TO_PY = {"lineSpacing": "line_spacing", "keepLinks": "keep_links",
            "stripLists": "strip_lists", "maxBlankLines": "max_blank_lines",
            "collapseSpaces": "collapse_spaces"}

# Inputs beyond the fixtures - awkward shapes both engines must agree on.
EXTRA = [
    ("", {}), ("   ", {}), ("\n\n\n", {}), ("\r\n\r\n", {}),
    ("a" * 500, {}), ("tab\tsep\tvalues", {}),
    ("mixed 👻 emoji ❤️ and 👩‍💻 sequences", {}),
    ("*a* _b_ **c** `d` # e\n> f\n- g", {"markdown": True}),
    ("nested **bold _and italic_ here**", {"markdown": True}),
    ("[a](b) ![c](d) <https://e.dev>", {"markdown": True}),
    ("| a | b |\n| --- | --- |\n| 1 | 2 |", {"markdown": True}),
    ("line\n\n\n\n\nline", {"maxBlankLines": 0}),
    ("one\ntwo", {"lineSpacing": "double"}),
    ("one\n\ntwo", {"lineSpacing": "single"}),
    ("quote 'straight' \"already\"", {}),
    ("url https://x.dev/a_b_c stays", {"markdown": True}),
    ("&#" + "0" * 50 + "32;{}", {"json": True}),
    ("[1]&toString;&__proto__;&#x110000;&#xD800;", {"json": True}),
    ("﻿```json\n{}\n```", {"json": True}),
    ("[1, 2]\\", {"json": True}),
    ('{\\"a\\": \\\\"}', {"json": True}),
    ('[" ​\U000e0041",  \U000e0041 1,\n\n]', {"json": True}),
    ("[ㅤ⠀­ 1 ,\t]", {"json": True}),
]


def js_clean(pairs):
    """Run every (text, options) pair through cleaner.js in one node process."""
    script = """
    const C = require(process.argv[1]);
    const jobs = JSON.parse(process.argv[2]);
    console.log(JSON.stringify(jobs.map(([t, o]) => C.clean(t, o).text)));
    """
    out = subprocess.run(
        ["node", "-e", script, str(JS_ENGINE), json.dumps(pairs)],
        capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def main():
    if not shutil.which("node"):
        print("node not found - skipping parity check")
        return 0

    jobs = [(c["in"], c.get("options", {})) for c in CASES["cases"]] + EXTRA
    labels = [c["name"] for c in CASES["cases"]] + ["extra: %r" % t[:40] for t, _ in EXTRA]

    js_results = js_clean(jobs)
    failures = []
    for label, (text, js_opts), js_out in zip(labels, jobs, js_results):
        kwargs = {JS_TO_PY.get(k, k): v for k, v in js_opts.items()}
        py_out, _ = gptcleaner.clean(text, gptcleaner.Options(**kwargs))
        if py_out != js_out:
            failures.append((label, text, py_out, js_out))

    if failures:
        print("\n%d of %d inputs DISAGREE between engines:\n" % (len(failures), len(jobs)))
        for label, text, py, js in failures:
            print("  %s\n    input:  %r\n    python: %r\n    js:     %r\n" % (label, text, py, js))
        return 1

    print("ok - %d inputs, Python and JavaScript agree on every one" % len(jobs))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
