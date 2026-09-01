#!/usr/bin/env python3
"""Tests for the Python engine. Standard library only - no pytest needed:

    python3 -m unittest discover tests     (or)     python3 tests/test_gptcleaner.py

The clean/scan cases come from tests/cases.json, the same file the JavaScript
suite reads, so the two engines cannot drift apart without a test going red.
"""
import json
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "skills" / "gptcleaner" / "scripts"))

import gptcleaner  # noqa: E402

CASES = json.loads((pathlib.Path(__file__).parent / "cases.json").read_text())

# tests/cases.json uses the JavaScript spelling of each option.
JS_TO_PY = {
    "lineSpacing": "line_spacing",
    "keepLinks": "keep_links",
    "stripLists": "strip_lists",
    "maxBlankLines": "max_blank_lines",
    "collapseSpaces": "collapse_spaces",
}


def options_from(js_options):
    kwargs = {JS_TO_PY.get(k, k): v for k, v in (js_options or {}).items()}
    return gptcleaner.Options(**kwargs)


class SharedCases(unittest.TestCase):
    """Every case in cases.json, run through the Python engine."""


def _make_clean_test(case):
    def test(self):
        got, _ = gptcleaner.clean(case["in"], options_from(case.get("options")))
        self.assertEqual(got, case["out"])
    return test


def _make_scan_test(case):
    def test(self):
        rows = gptcleaner.scan(case["in"])
        got = [{"code": gptcleaner.code(ch), "name": gptcleaner.char_name(ch), "count": n}
               for ch, n, _, _ in rows]
        self.assertEqual(got, case["expect"])
    return test


for _i, _case in enumerate(CASES["cases"]):
    setattr(SharedCases, "test_clean_%02d_%s" % (_i, _case["name"].replace(" ", "_")),
            _make_clean_test(_case))
for _i, _case in enumerate(CASES["scans"]):
    setattr(SharedCases, "test_scan_%02d_%s" % (_i, _case["name"].replace(" ", "_")),
            _make_scan_test(_case))


class ReportAccounting(unittest.TestCase):
    """The counts the CLI and UI report have to add up."""

    def test_counts_hidden_and_punctuation_separately(self):
        text = "a​b “q” — c d"
        _, r = gptcleaner.clean(text)
        self.assertEqual(r["hidden_total"], 2)          # ZWSP + NBSP
        self.assertEqual(sum(r["replaced"].values()), 3)  # two quotes + em dash
        self.assertEqual(r["chars_in"], len(text))

    def test_scan_reports_position_of_first_hit(self):
        rows = gptcleaner.scan("ok\nline​two")
        self.assertEqual(len(rows), 1)
        _, count, line, col = rows[0]
        self.assertEqual((count, line, col), (1, 2, 5))

    def test_scan_never_modifies_input(self):
        text = "a​b"
        gptcleaner.scan(text)
        self.assertEqual(text, "a​b")


class Idempotence(unittest.TestCase):
    """Cleaning twice must equal cleaning once - otherwise -i would drift."""

    SAMPLES = [
        "﻿# T​itle\r\n\r\n\r\nIt’s “fine” — **bold**  text…",
        "- one\n\n\n* two\n\n\n\n three   ",
        "plain",
    ]

    def test_clean_is_idempotent(self):
        for markdown in (False, True):
            for s in self.SAMPLES:
                opt = gptcleaner.Options(markdown=markdown)
                once, _ = gptcleaner.clean(s, opt)
                twice, _ = gptcleaner.clean(once, opt)
                self.assertEqual(once, twice, "not idempotent (markdown=%s): %r" % (markdown, s))

    def test_cleaned_output_scans_clean(self):
        for s in self.SAMPLES:
            out, _ = gptcleaner.clean(s)
            self.assertEqual(gptcleaner.scan(out), [], "residue left in %r" % out)


class Safety(unittest.TestCase):
    """Things that must never be damaged."""

    def test_code_is_safe_without_markdown(self):
        code = "def f(a, *args, **kw):\n    return a_b * 2  # note\n"
        out, _ = gptcleaner.clean(code, gptcleaner.Options(markdown=False, spacing=False))
        self.assertEqual(out, code)

    def test_meaningful_format_chars_kept(self):
        for cp in (0x0600, 0x06DD, 0x110BD):
            ch = chr(cp)
            out, _ = gptcleaner.clean("x" + ch + "y")
            self.assertIn(ch, out, "dropped U+%04X, which is meaningful" % cp)

    def test_emoji_survive(self):
        for e in ("❤️", "👻", "👩‍💻", "🇮🇳"):
            out, _ = gptcleaner.clean(e)
            self.assertEqual(out, e, "mangled %r" % e)


if __name__ == "__main__":
    unittest.main(verbosity=2)
