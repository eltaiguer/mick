#!/bin/sh
# Builds build/PanelSpike.app: the spike binary wrapped as an LSUIElement app, so it
# can be launched from Finder or with `open`. Ad-hoc signed by default; set
# SIGN_IDENTITY to an Apple Development identity (name or SHA-1) to sign with it.
set -eu
cd "$(dirname "$0")"

swift build -c release --product panel-spike
BIN="$(swift build -c release --show-bin-path)/panel-spike"

APP=build/PanelSpike.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/PanelSpike"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.mick.spike.panel</string>
    <key>CFBundleName</key><string>PanelSpike</string>
    <key>CFBundleExecutable</key><string>PanelSpike</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "$APP"
