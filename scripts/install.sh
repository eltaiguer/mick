#!/bin/sh
# Builds Mick.app in Release, signed with your Apple Development certificate and the
# hardened runtime, and copies it into /Applications (SPEC §13). It doesn't open the
# app unless you pass --open; do that yourself the first time so you see onboarding.
#
# Usage: scripts/install.sh [--dest DIR] [--identity SHA1] [--open]
#   --dest DIR       where to put Mick.app (default /Applications)
#   --identity SHA1  signing identity (default: the first "Apple Development" one in
#                    `security find-identity -v -p codesigning`)
#   --open           open the installed app when done
#
# Then, in Claude Code:
#   /plugin marketplace add eltaiguer/mick
#   /plugin install mick@mick

set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST=/Applications
IDENTITY=
OPEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST=$2; shift 2 ;;
    --identity) IDENTITY=$2; shift 2 ;;
    --open) OPEN=1; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk '/"Apple Development/ { print $2; exit }')
fi
if [ -z "$IDENTITY" ]; then
  echo "No Apple Development signing identity found." >&2
  echo "Sign in to Xcode with your Apple ID (Settings > Accounts) and create one, or pass --identity." >&2
  exit 1
fi
[ -d "$DEST" ] || { echo "No such folder: $DEST" >&2; exit 1; }

# The identity's team (the certificate's OU). Xcode needs it to sign the MickCore
# resource bundle; the project itself keeps no team, since the repo is public.
TEAM=$(security find-certificate -a -Z -p -c "Apple Development" 2>/dev/null | awk -v want="$IDENTITY" '
  /^SHA-1 hash:/ { take = (toupper($3) == toupper(want)); next }
  take && /BEGIN CERTIFICATE/ { pem = 1 }
  take && pem { print }
  take && /END CERTIFICATE/ { exit }' |
  openssl x509 -noout -subject -nameopt multiline 2>/dev/null | sed -n 's/^ *organizationalUnitName *= *//p' | head -1)
if [ -z "$TEAM" ]; then
  echo "Couldn't read the team of signing identity $IDENTITY." >&2
  exit 1
fi

DERIVED="$ROOT/app/build/Install"
LOG="$DERIVED/build.log"
mkdir -p "$DERIVED"
echo "Building Mick (Release, signed with $IDENTITY, team $TEAM)..."
if ! xcodebuild -project "$ROOT/app/Mick.xcodeproj" -scheme Mick -configuration Release \
     -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual build >"$LOG" 2>&1; then
  tail -30 "$LOG" >&2
  echo "Build failed; full log in $LOG" >&2
  exit 1
fi
APP="$DERIVED/Build/Products/Release/Mick.app"
codesign --verify --strict --deep "$APP"

if pgrep -xq Mick && [ "$DEST" = /Applications ]; then
  echo "Mick is running. Quit it from its menu (Quit Mick) and run this again." >&2
  exit 1
fi
rm -rf "$DEST/Mick.app"
ditto "$APP" "$DEST/Mick.app"
codesign --verify --strict --deep "$DEST/Mick.app"
echo "Installed $DEST/Mick.app"
echo
echo "Next:"
echo "  1. open \"$DEST/Mick.app\"   (onboarding shows the plugin commands; open at login is on by default)"
echo "  2. In Claude Code: /plugin marketplace add eltaiguer/mick"
echo "                     /plugin install mick@mick"
[ "$OPEN" -eq 1 ] && open "$DEST/Mick.app"
exit 0
