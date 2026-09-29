#!/bin/sh
# Daily-use build check (issue #13, SPEC §13): runs scripts/install.sh into a scratch
# folder standing in for /Applications, then inspects the installed bundle. Never
# uses `open`, never touches /Applications, ~/.mick or ~/.claude; the only launches are
# tests/app/smoke.sh's --smoke runs of the signed build, against temporary MICK_HOMEs.
#
# Checks: signed with an Apple Development certificate, strict verification passes,
# hardened runtime on, not sandboxed, no get-task-allow (a Release build), an accessory
# app (LSUIElement), macOS 26 minimum, the bundled moves and lines, and the plugin and
# marketplace manifests validate with `claude plugin validate` (skipped without claude).
#
# Usage: tests/app/release-check.sh        (exit 0 = all passed)
#   MICK_RELEASE_IDENTITY=<SHA-1>          sign with this identity instead of the first one
#   MICK_RELEASE_SKIP_SMOKE=1              only inspect the bundle (no GUI session needed)

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mick-release-check.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; }

IDENTITY=${MICK_RELEASE_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Apple Development/ { print $2; exit }')}
if [ -z "$IDENTITY" ]; then
  echo "no Apple Development identity in the keychain; can't check the signed build"
  exit 1
fi

echo "== install into a scratch Applications folder"
mkdir -p "$WORK/Applications"
if sh "$ROOT/scripts/install.sh" --dest "$WORK/Applications" --identity "$IDENTITY" >"$WORK/install.out" 2>&1; then
  ok "scripts/install.sh built, signed and copied Mick.app"
else
  sed 's/^/     | /' "$WORK/install.out"
  fail "scripts/install.sh"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
grep -q '/plugin install mick@mick' "$WORK/install.out" && ok "install.sh prints the plugin install command" \
  || fail "install.sh doesn't print /plugin install mick@mick"
APP="$WORK/Applications/Mick.app"
[ -d "$APP" ] && ok "Mick.app is in the destination" || fail "no Mick.app in $WORK/Applications"

echo "== signature"
codesign --verify --strict --deep "$APP" 2>"$WORK/verify.err" && ok "codesign --verify --strict --deep" \
  || fail "codesign verify" "$(cat "$WORK/verify.err")"
codesign -dvvv "$APP" >"$WORK/sig.txt" 2>&1
grep -q '^Authority=Apple Development: ' "$WORK/sig.txt" && ok "signed with an Apple Development certificate" \
  || fail "not signed with Apple Development" "$(grep '^Authority' "$WORK/sig.txt")"
grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime.*\)' "$WORK/sig.txt" && ok "hardened runtime on" \
  || fail "hardened runtime off" "$(grep '^CodeDirectory' "$WORK/sig.txt")"
grep -q '^Identifier=dev.mick.Mick$' "$WORK/sig.txt" && ok "identifier dev.mick.Mick" \
  || fail "identifier" "$(grep '^Identifier' "$WORK/sig.txt")"
if grep -Eq '^TeamIdentifier=[A-Z0-9]{10}$' "$WORK/sig.txt"; then ok "has a team identifier"
else fail "no team identifier in the signature" "$(grep '^TeamIdentifier' "$WORK/sig.txt")"; fi

codesign -d --entitlements - --xml "$APP" >"$WORK/ent.plist" 2>/dev/null
if grep -q 'com.apple.security.app-sandbox' "$WORK/ent.plist"; then
  fail "sandboxed (it must not be: it reads ~/.mick written by the hooks)"
else
  ok "not sandboxed"
fi
if grep -q 'get-task-allow' "$WORK/ent.plist"; then fail "has get-task-allow (a debug entitlement)"
else ok "no get-task-allow"; fi

echo "== bundle"
PLIST="$APP/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$PLIST" 2>/dev/null)" = true ] && ok "LSUIElement (menu bar agent, no Dock icon)" \
  || fail "LSUIElement not set"
min=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST" 2>/dev/null)
case "$min" in 26*) ok "minimum macOS $min" ;; *) fail "minimum macOS is '$min', want 26" ;; esac
for f in moves.json lines.json; do
  if find "$APP/Contents/Resources" -name "$f" | grep -q .; then ok "bundles $f"; else fail "missing $f"; fi
done
lipo -archs "$APP/Contents/MacOS/Mick" >"$WORK/archs" 2>&1 && ok "executable: $(cat "$WORK/archs")" || fail "no executable"
# Release builds have no simulation mode (the strings would be in the binary).
if strings "$APP/Contents/MacOS/Mick" | grep -q 'Simulate (debug)'; then fail "Release build contains the Simulate (debug) menu"
else ok "no simulation menu in Release"; fi

echo "== plugin"
if command -v claude >/dev/null 2>&1; then
  (cd "$ROOT" && claude plugin validate . >"$WORK/v1" 2>&1) && ok "claude plugin validate . (marketplace)" || fail "marketplace validate" "$(cat "$WORK/v1")"
  (cd "$ROOT" && claude plugin validate ./plugin >"$WORK/v2" 2>&1) && ok "claude plugin validate ./plugin" || fail "plugin validate" "$(cat "$WORK/v2")"
else
  echo "skip claude plugin validate (no claude CLI)"
fi
jq -e '.name == "mick" and (.plugins | length == 1) and .plugins[0].name == "mick" and .plugins[0].source == "./plugin"' \
  "$ROOT/.claude-plugin/marketplace.json" >/dev/null && ok "marketplace mick lists plugin mick at ./plugin (install id mick@mick)" \
  || fail "marketplace.json doesn't give install id mick@mick"

echo "== the signed build runs (tests/app/smoke.sh against it, temporary MICK_HOME only)"
if [ "${MICK_RELEASE_SKIP_SMOKE:-0}" = 1 ]; then
  echo "skip smoke (MICK_RELEASE_SKIP_SMOKE)"
elif MICK_APP="$APP" sh "$ROOT/tests/app/smoke.sh" >"$WORK/smoke.out" 2>&1; then
  ok "smoke check passes on the signed build ($(tail -1 "$WORK/smoke.out"))"
else
  grep -E '^FAIL' "$WORK/smoke.out" | sed 's/^/     | /'
  fail "smoke check on the signed build ($(tail -1 "$WORK/smoke.out"))"
fi
if pgrep -f "$APP" >/dev/null; then fail "a Mick process from the check is still running"; pkill -f "$APP"; else ok "no Mick process left running"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
