#!/usr/bin/env python3
"""Inline the web app into a single self-contained HTML file, on stdout.

    python3 tools/bundle.py > dist/gptcleaner.html

Useful for emailing the tool to someone, dropping it on a USB stick, or hosting
it as one file. The three.js and font CDN tags stay external; the page works
without them.
"""
import pathlib
import re
import sys

WEB = pathlib.Path(__file__).resolve().parent.parent / "skills" / "gptcleaner" / "web"


def main() -> int:
    html = (WEB / "index.html").read_text()
    # swap the two local <script src> tags for their inlined contents
    for name in ("cleaner.js", "app.js"):
        html = html.replace(
            '<script src="%s"></script>' % name,
            "<script>\n%s</script>" % (WEB / name).read_text())
    html = html.replace(
        '<link rel="stylesheet" href="style.css">',
        "<style>\n%s</style>" % (WEB / "style.css").read_text())
    # anything still pointing at a local file means the inlining missed something
    # (http(s) CDN tags and data: URIs are expected to remain)
    leftover = re.findall(r'<(?:script|link)[^>]*(?:src|href)="(?!https?:|data:)([^"]+)"', html)
    if leftover:
        print("warning: not inlined: %s" % ", ".join(leftover), file=sys.stderr)
    sys.stdout.write(html)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
