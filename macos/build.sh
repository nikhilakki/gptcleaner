#!/usr/bin/env bash
# Builds GPTCleaner.app - a native menu-bar app around the shared JS engine.
# No Xcode project, no dependencies: just the Swift toolchain that ships with
# the Xcode command line tools.
#
#   ./macos/build.sh              build to macos/build/GPTCleaner.app
#   ./macos/build.sh --install    build, then move it to /Applications
#   ./macos/build.sh --run        build, then launch it
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WEB="$ROOT/skills/gptcleaner/web"
BUILD="$HERE/build"
APP="$BUILD/GPTCleaner.app"
NAME="GPTCleaner"
VERSION="1.2.0"

INSTALL=0; RUN=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --run) RUN=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

command -v swiftc >/dev/null || {
  echo "swiftc not found. Install the Xcode command line tools:" >&2
  echo "  xcode-select --install" >&2; exit 1; }
[ -f "$WEB/cleaner.js" ] || { echo "missing $WEB/cleaner.js" >&2; exit 1; }

echo "==> cleaning"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> compiling"
FRAMEWORKS=(-framework AppKit -framework WebKit -framework JavaScriptCore -framework Carbon)
SLICES=()
for arch in arm64 x86_64; do
  if swiftc -O -swift-version 5 -target "$arch-apple-macos12.0" "${FRAMEWORKS[@]}" \
       -o "$BUILD/$NAME-$arch" "$HERE/Sources/main.swift" 2>"$BUILD/$arch.log"; then
    SLICES+=("$BUILD/$NAME-$arch")
    echo "    $arch ok"
  else
    echo "    $arch skipped (SDK not available)"
    [ "$arch" = "arm64" ] && { sed -n '1,15p' "$BUILD/$arch.log" >&2; exit 1; }
  fi
done
if [ "${#SLICES[@]}" -gt 1 ]; then
  lipo -create -output "$APP/Contents/MacOS/$NAME" "${SLICES[@]}"
  echo "    universal: $(lipo -archs "$APP/Contents/MacOS/$NAME")"
else
  cp "${SLICES[0]}" "$APP/Contents/MacOS/$NAME"
fi
rm -f "$BUILD/$NAME-"* "$BUILD"/*.log

echo "==> bundling the shared web engine"
cp -R "$WEB" "$APP/Contents/Resources/web"

echo "==> icon"
ICONSET="$BUILD/AppIcon.iconset"
if swiftc -O -swift-version 5 -framework AppKit -o "$BUILD/make-icon" "$HERE/make-icon.swift" 2>/dev/null; then
  "$BUILD/make-icon" "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
  rm -rf "$ICONSET" "$BUILD/make-icon"
fi

echo "==> Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>GPTCleaner</string>
  <key>CFBundleIdentifier</key><string>com.nikhilakki.gptcleaner</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHumanReadableCopyright</key><string>MIT licensed</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc signing"
codesign --force --deep --sign - "$APP" 2>/dev/null \
  && echo "    signed (ad-hoc)" \
  || echo "    unsigned - right-click > Open the first time"

echo "==> built $APP ($(du -sh "$APP" | cut -f1))"

if [ "$INSTALL" = 1 ]; then
  rm -rf "/Applications/$NAME.app"
  cp -R "$APP" /Applications/
  echo "==> installed /Applications/$NAME.app"
  APP="/Applications/$NAME.app"
fi
[ "$RUN" = 1 ] && { echo "==> launching"; open "$APP"; }
exit 0
