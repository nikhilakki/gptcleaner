# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project uses [semantic versioning](https://semver.org/).

## [1.1.0] - 2026-09-01

### Added
- Native **macOS app** (`macos/`): menu-bar clipboard cleaner with a global
  ⌃⌥⌘C hotkey, plus the full web UI in a window. Universal binary, built by
  `macos/build.sh` with no Xcode project.
- **Web version** (`skills/gptcleaner/web/`): vanilla HTML/CSS/JS with a
  three.js ghost field, a live "ghost radar", and a JavaScript port of the
  engine (`cleaner.js`).
- **Test suite**: 55 Python tests and 58 JavaScript checks driven from one
  shared fixture file (`tests/cases.json`), plus a parity runner that asserts
  both engines produce identical output.

### Changed
- `--serve` now serves the static browser app instead of running an embedded
  Python UI with a `/clean` endpoint. Cleaning happens in the page, so text
  never reaches the Python process.
- `clean()` now takes options optionally (`clean(text)` works), matching the
  JavaScript API.
- `install.sh` handles multiple skills and takes skill names as arguments.

### Fixed
- **Invisible-character table was empty.** Adjacent string-literal concatenation
  bound tighter than the trailing slice, so `INVISIBLE_EXTRA` evaluated to `""`
  and hangul fillers, khmer inherent vowels and the braille blank were never
  removed. Both engines now use explicit codepoints.
- **ZWJ emoji sequences were being split.** `👩‍💻` (woman + ZWJ + laptop) lost
  its joiner and became two glyphs; family and flag sequences broke the same
  way. A ZWJ between two emoji is now kept, while a stray one in prose is still
  removed.

## [1.0.0] - 2026-08-31

### Added
- Initial release: single-file Python CLI, the `gptcleaner` Agent Skill, and
  `install.sh` for installing skills across AI harnesses.
