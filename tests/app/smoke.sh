#!/bin/sh
# App smoke test (issue #4): builds Mick.app and runs its --smoke self-check against
# temporary MICK_HOME directories. Never touches ~/.mick, never uses `open` (which
# wouldn't pass MICK_HOME through), and leaves no process behind.
#
# Usage: tests/app/smoke.sh            (exit 0 = all passed)
#   SIGN_IDENTITY=<name or SHA-1>      sign with an Apple Development identity instead of ad hoc
#   MICK_SKIP_BUILD=1                  reuse the last build
#
# Needs a logged-in GUI session (the status item and onboarding window are real).

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HOOK="$ROOT/plugin/hooks/mick-event.sh"
DERIVED="$ROOT/app/build/DerivedData"
APP="$DERIVED/Build/Products/Release/Mick.app"
BIN="$APP/Contents/MacOS/Mick"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mick-app-smoke.XXXXXX")
trap 'pkill -f "$BIN" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM
unset MICK_HOME

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; }

if [ "${MICK_SKIP_BUILD:-0}" != 1 ]; then
  echo "== building Mick.app (Release)"
  set -- -project "$ROOT/app/Mick.xcodeproj" -scheme Mick -configuration Release -derivedDataPath "$DERIVED"
  [ -n "${SIGN_IDENTITY:-}" ] && set -- "$@" CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
  if ! xcodebuild "$@" build >"$WORK/build.log" 2>&1; then
    tail -30 "$WORK/build.log"
    echo "BUILD FAILED"
    exit 1
  fi
fi
[ -x "$BIN" ] || { echo "no app at $APP"; exit 1; }

# Runs the app's self-check with a 30 s safety timeout. $1 = MICK_HOME, $2 = output file.
run_smoke() {
  home=$1; out=$2; shift 2
  MICK_HOME="$home" /usr/bin/perl -e 'alarm shift; exec @ARGV or die' 30 "$BIN" --smoke "$@" >"$out" 2>"$out.stderr"
}

mode_of() { stat -f '%Lp' "$1" 2>/dev/null; }

# --- Bundle -----------------------------------------------------------------
echo "== bundle"
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist" 2>/dev/null)" = true ] \
  && ok "Info.plist has LSUIElement (menu bar agent, no Dock icon)" || fail "LSUIElement missing"
codesign --verify --strict "$APP" 2>/dev/null && ok "app is code signed" || fail "codesign --verify failed"
codesign -dv "$APP" 2>&1 | grep -q 'runtime' && ok "hardened runtime" || fail "hardened runtime flag missing"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q 'app-sandbox' && fail "app is sandboxed" || ok "not sandboxed"

# --- 1. First launch, then a real hook event --------------------------------
echo "== first launch"
HOME1="$WORK/fresh/mick-home"
mkdir -p "$WORK/fresh"
run_smoke "$HOME1" "$WORK/first.out" --smoke-hook "$HOOK"
status=$?
sed 's/^/     | /' "$WORK/first.out"
[ $status -eq 0 ] && grep -q '^SMOKE OK' "$WORK/first.out" && ok "first-launch self-check passed" \
  || fail "first-launch self-check (exit $status)" "$(tail -5 "$WORK/first.out.stderr")"
[ "$(mode_of "$HOME1")" = 700 ] && ok "MICK_HOME created with mode 0700" || fail "MICK_HOME mode $(mode_of "$HOME1")"
[ "$(mode_of "$HOME1/events.jsonl")" = 600 ] && ok "events.jsonl mode 0600" || fail "events.jsonl mode $(mode_of "$HOME1/events.jsonl")"
grep -q SMOKE-SECRET "$HOME1"/* 2>/dev/null && fail "prompt text leaked into MICK_HOME" || ok "no prompt text in MICK_HOME"
/usr/bin/jq -e '.last_event_at != null and .sessions["smoke-session"].running == true' "$HOME1/state.json" >/dev/null \
  && ok "state.json records the event and the running session" || fail "state.json not updated"
grep -q 'Claude Code hooks detected' "$HOME1/log.txt" && ok "log.txt records the detection" || fail "detection not logged"

# --- 2. Relaunch: hooks already detected, no onboarding ---------------------
echo "== relaunch"
run_smoke "$HOME1" "$WORK/relaunch.out"
status=$?
[ $status -eq 0 ] && ok "relaunch self-check passed" || fail "relaunch self-check (exit $status)"
grep -q 'hooks=detected' "$WORK/relaunch.out" && ok "hooks still detected after relaunch" || fail "hooks not detected after relaunch"
grep -q 'createdHome=false' "$WORK/relaunch.out" && ok "existing MICK_HOME reused" || fail "MICK_HOME recreated"

# --- 3. Corrupted state and config, malformed event lines --------------------
echo "== corrupted files"
HOME3="$WORK/corrupt"
mkdir -m 700 "$HOME3"
printf '{"sit_threshold_minutes": "fifty"' >"$HOME3/config.json"
printf 'this is not json' >"$HOME3/state.json"
printf 'garbage line\n{"e":"launch","t":1,"s":"x"}\n' >"$HOME3/events.jsonl"
run_smoke "$HOME3" "$WORK/corrupt.out"
status=$?
[ $status -eq 0 ] && ok "app ran with corrupted files (no crash)" || fail "corrupted-files run (exit $status)" "$(tail -5 "$WORK/corrupt.out.stderr")"
ls "$HOME3"/config.json.corrupt-* >/dev/null 2>&1 && ok "corrupted config.json moved aside" || fail "config.json not moved aside"
ls "$HOME3"/state.json.corrupt-* >/dev/null 2>&1 && ok "corrupted state.json moved aside" || fail "state.json not moved aside"
/usr/bin/jq -e '.sit_threshold_minutes == 50' "$HOME3/config.json" >/dev/null && ok "config.json replaced with defaults" || fail "config.json not replaced"
/usr/bin/jq -e '.events_offset > 0' "$HOME3/state.json" >/dev/null && ok "state.json replaced and malformed lines consumed" || fail "state.json not replaced"
grep -q 'config.json corrupted' "$HOME3/log.txt" && grep -q 'state.json corrupted' "$HOME3/log.txt" \
  && ok "corruption logged" || fail "corruption not logged"
[ "$(grep -c 'skipped malformed event line' "$HOME3/log.txt")" = 2 ] && ok "both malformed lines skipped and logged" || fail "malformed lines not logged"

# --- 4. Refuses to run --smoke without MICK_HOME ----------------------------
echo "== guard"
env -u MICK_HOME HOME="$WORK/fakehome" "$BIN" --smoke >/dev/null 2>&1
[ $? -eq 2 ] && [ ! -e "$WORK/fakehome/.mick" ] && ok "--smoke refuses to run without MICK_HOME" || fail "--smoke ran without MICK_HOME"

# --- Nothing left running ----------------------------------------------------
sleep 0.3
if pgrep -f "$BIN" >/dev/null; then
  fail "a Mick process is still running"; pkill -f "$BIN"
else
  ok "no Mick process left running"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
