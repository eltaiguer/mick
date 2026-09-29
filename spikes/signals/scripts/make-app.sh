#!/bin/sh
# Builds SignalsSpike and wraps it in an LSUIElement .app bundle so it can be
# launched from Finder (TCC attributes a Finder launch to the app itself, not to
# Terminal) and so App Nap treats it as a real accessory app.
#
# Usage: scripts/make-app.sh [output-dir]   (default: .build/app)
# SIGN_IDENTITY overrides the signing identity (defaults to the first Apple
# Development identity; "-" means ad hoc).
set -eu
cd "$(dirname "$0")/.."
OUT="${1:-.build/app}"
swift build -c release --product SignalsSpike >/dev/null
BIN="$(swift build -c release --show-bin-path)/SignalsSpike"
APP="$OUT/SignalsSpike.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SignalsSpike"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.eltaiguer.mick.signals-spike</string>
  <key>CFBundleName</key><string>SignalsSpike</string>
  <key>CFBundleExecutable</key><string>SignalsSpike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')"
  [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="-"
fi
codesign --force --options runtime --timestamp=none -s "$SIGN_IDENTITY" "$APP" >/dev/null 2>&1
codesign --verify --strict "$APP"
echo "$APP"
