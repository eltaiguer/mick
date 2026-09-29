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
MOVES=$(find "$APP/Contents/Resources" -name moves.json -path '*MickIO*' 2>/dev/null | head -1)
[ -n "$MOVES" ] && [ "$(/usr/bin/jq length "$MOVES")" = 11 ] && ok "moves.json bundled with 11 moves" || fail "moves.json missing from the bundle"
LINES=$(find "$APP/Contents/Resources" -name lines.json -path '*MickIO*' 2>/dev/null | head -1)
[ -n "$LINES" ] && /usr/bin/jq -e 'length == 14 and ([.[] | length] | min) >= 5 and ([.opener, .opener_ignored_1, .opener_ignored_2, .opener_ignored_3, .opener_long_sit] | map(length) | min) >= 8' "$LINES" >/dev/null \
  && ok "lines.json bundled with all 14 pools" || fail "lines.json missing from the bundle or short a pool"

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

# --- 4. Sitting timer and icon states (#5) -----------------------------------
# --smoke-idle fixes the idle reading, so these don't depend on someone using the Mac.
echo "== sitting timer"
iso() { date -u -v"$1" +%Y-%m-%dT%H:%M:%SZ; }
# $1 = dir, $2 = sitting_since offset, $3 = last_active_at offset
sit_state() {
  mkdir -m 700 -p "$1"
  printf '{"sitting_since":"%s","last_active_at":"%s","last_event_at":"%s"}\n' "$(iso "$2")" "$(iso "$3")" "$(iso -1M)" >"$1/state.json"
}
sitting_since_of() { /usr/bin/jq -r .sitting_since "$1/state.json"; }

HOME4="$WORK/sit-armed"; sit_state "$HOME4" -60M -1M
run_smoke "$HOME4" "$WORK/armed.out" --smoke-idle 0
[ $? -eq 0 ] && grep -q 'icon=armed ' "$WORK/armed.out" && grep -q 'detail=Sitting 1h · reminder armed' "$WORK/armed.out" \
  && ok "60 min sitting: armed icon and detail line" || fail "armed state" "$(grep -E 'INFO icon|FAIL' "$WORK/armed.out")"

HOME5="$WORK/sit-glaring"; sit_state "$HOME5" -110M -1M
run_smoke "$HOME5" "$WORK/glaring.out" --smoke-idle 0
[ $? -eq 0 ] && grep -q 'icon=glaring ' "$WORK/glaring.out" && ok "110 min sitting: glaring icon" \
  || fail "glaring state" "$(grep -E 'INFO icon|FAIL' "$WORK/glaring.out")"
/usr/bin/jq -e '(.sitting_since | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) < (now - 6500)' "$HOME5/state.json" >/dev/null \
  && ok "sitting_since kept across relaunch" || fail "sitting_since changed: $(sitting_since_of "$HOME5")"

HOME6="$WORK/sit-relaunch"; sit_state "$HOME6" -110M -10M
run_smoke "$HOME6" "$WORK/relaunch-reset.out" --smoke-idle 0
[ $? -eq 0 ] && grep -q 'icon=calm ' "$WORK/relaunch-reset.out" && grep -q 'detail=Sitting 0m · reminder at 50m' "$WORK/relaunch-reset.out" \
  && ok "away 10 min before launch: sitting time reset" || fail "relaunch reset" "$(grep -E 'INFO icon|FAIL' "$WORK/relaunch-reset.out")"
grep -q 'sitting timer reset (away' "$HOME6/log.txt" && ok "relaunch reset logged" || fail "relaunch reset not logged"

HOME7="$WORK/sit-idle"; sit_state "$HOME7" -110M -1M
run_smoke "$HOME7" "$WORK/idle.out" --smoke-idle 600
[ $? -eq 0 ] && grep -q 'icon=calm ' "$WORK/idle.out" && ok "idle 10 min: sitting time reset" \
  || fail "idle reset" "$(grep -E 'INFO icon|FAIL' "$WORK/idle.out")"

# --- 5. First real reminder (#6) -------------------------------------------
# Armed (sitting 60 min, hooks known), 2 s show delay, a fixed 10 s idle reading so
# the 3 s input-gap check passes. Real hook events drive each scenario.
echo "== reminder"
for scenario in show-stop short-run tick-stays; do
  H="$WORK/reminder-$scenario"; sit_state "$H" -60M -1M
  printf '{"sit_threshold_minutes":50,"show_delay_seconds":2}\n' >"$H/config.json"
  run_smoke "$H" "$WORK/reminder-$scenario.out" --smoke-hook "$HOOK" --smoke-reminder "$scenario" --smoke-idle 10
  status=$?
  sed 's/^/     | /' "$WORK/reminder-$scenario.out"
  [ $status -eq 0 ] && grep -q '^SMOKE OK' "$WORK/reminder-$scenario.out" && ok "reminder scenario $scenario passed" \
    || fail "reminder scenario $scenario (exit $status)" "$(tail -5 "$WORK/reminder-$scenario.out.stderr")"
done
grep -q 'reminder shown for session smoke-reminder' "$WORK/reminder-show-stop/log.txt" && grep -q 'reminder closed (agentStopped)' "$WORK/reminder-show-stop/log.txt" \
  && ok "log.txt records the show and the close" || fail "reminder show/close not logged"
grep -q 'reminder shown' "$WORK/reminder-short-run/log.txt" && fail "short run showed a reminder" || ok "short run: no reminder in log.txt"
/usr/bin/jq -e '(.rotation.used_move_ids | length) == 2 and (.rotation.last_areas | length) == 2 and .rotation.last_areas[0] != .rotation.last_areas[1]' \
  "$WORK/reminder-show-stop/state.json" >/dev/null && ok "rotation saved to state.json" || fail "rotation not saved" "$(/usr/bin/jq -c .rotation "$WORK/reminder-show-stop/state.json")"

# --- 5b. Routines (#8): a long sit (2x threshold) gets Stand up + Walk + 1 move,
# and a relaunch on the same home keeps the rotation.
echo "== routines"
H="$WORK/reminder-long-sit"; sit_state "$H" -100M -1M
printf '{"sit_threshold_minutes":50,"show_delay_seconds":2}\n' >"$H/config.json"
run_smoke "$H" "$WORK/long-sit.out" --smoke-hook "$HOOK" --smoke-reminder show-stop --smoke-idle 10
status=$?
[ $status -eq 0 ] && grep -q '^SMOKE OK' "$WORK/long-sit.out" && grep -q 'routine (long sit): stand, walk, ' "$H/log.txt" \
  && /usr/bin/jq -e '.rotation.last_areas[0] == "walk"' "$H/state.json" >/dev/null \
  && ok "long sit: Stand up + Walk + 1 move" || fail "long sit routine (exit $status)" "$(grep 'routine' "$H/log.txt")"
FIRST=$(/usr/bin/jq -c '.rotation.used_move_ids' "$H/state.json")
run_smoke "$H" "$WORK/long-sit-2.out" --smoke-hook "$HOOK" --smoke-reminder show-stop --smoke-idle 10
/usr/bin/jq -e --argjson first "$FIRST" '(.rotation.used_move_ids | length) == 3 and .rotation.used_move_ids[0:2] == $first' "$H/state.json" >/dev/null \
  && ok "rotation kept across relaunch" || fail "rotation after relaunch" "before $FIRST, after $(/usr/bin/jq -c .rotation "$H/state.json")"

# --- 5c. Snooze, pause, Stretch now (#10) -----------------------------------
echo "== snooze, pause, stretch now"
for scenario in panel-snooze stretch-now menu-controls; do
  H="$WORK/controls-$scenario"; sit_state "$H" -60M -1M
  printf '{"sit_threshold_minutes":50,"show_delay_seconds":2}\n' >"$H/config.json"
  SITTING_BEFORE=$(sitting_since_of "$H")
  run_smoke "$H" "$WORK/controls-$scenario.out" --smoke-hook "$HOOK" --smoke-reminder "$scenario" --smoke-idle 10
  status=$?
  sed 's/^/     | /' "$WORK/controls-$scenario.out"
  [ $status -eq 0 ] && grep -q '^SMOKE OK' "$WORK/controls-$scenario.out" && ok "scenario $scenario passed" \
    || fail "scenario $scenario (exit $status)" "$(tail -5 "$WORK/controls-$scenario.out.stderr")"
  # The saved sitting_since keeps its instant (only the fraction digits may differ).
  /usr/bin/jq -e --arg b "$SITTING_BEFORE" '(.sitting_since | sub("\\.[0-9]+Z$"; "Z")) == ($b | sub("\\.[0-9]+Z$"; "Z"))' "$H/state.json" >/dev/null \
    && ok "$scenario: sitting_since unchanged in state.json" || fail "$scenario: sitting_since changed" "$SITTING_BEFORE -> $(sitting_since_of "$H")"
done
/usr/bin/jq -e '.snoozed_until != null' "$WORK/controls-panel-snooze/state.json" >/dev/null \
  && ok "panel snooze saved snoozed_until" || fail "snoozed_until not saved"
grep -q '"outcome":"snoozed"' "$WORK/controls-panel-snooze/reminders.jsonl" 2>/dev/null \
  && ok "reminders.jsonl records the panel snooze" || fail "panel snooze not logged"
grep -q 'routine (stretch now): stand, ' "$WORK/controls-stretch-now/log.txt" && grep -q 'stretch now shown' "$WORK/controls-stretch-now/log.txt" \
  && ok "log.txt records Stretch now" || fail "Stretch now not logged"
H="$WORK/controls-menu-controls"
/usr/bin/jq -e '.paused == true' "$H/state.json" >/dev/null && ok "pause saved to state.json" || fail "pause not saved"
run_smoke "$H" "$WORK/controls-relaunch.out" --smoke-idle 0
[ $? -eq 0 ] && grep -q 'icon=paused ' "$WORK/controls-relaunch.out" && ok "pause persists across relaunch (paused icon)" \
  || fail "pause after relaunch" "$(grep -E 'INFO icon|FAIL' "$WORK/controls-relaunch.out")"

# Quiet hours covering the whole day except one minute (so crossing midnight): the paused icon.
H="$WORK/controls-quiet"; sit_state "$H" -60M -1M
NEXT=$(date -v+2M +%H:%M); START=$(date -v+1M +%H:%M)
printf '{"quiet_hours":{"start":"%s","end":"%s"}}\n' "$NEXT" "$START" >"$H/config.json"
run_smoke "$H" "$WORK/controls-quiet.out" --smoke-idle 0
[ $? -eq 0 ] && grep -q 'icon=paused ' "$WORK/controls-quiet.out" && ok "inside quiet hours (across midnight): paused icon" \
  || fail "quiet hours icon" "$(grep -E 'INFO icon|FAIL' "$WORK/controls-quiet.out")"

# --- 6. Refuses to run --smoke without MICK_HOME ----------------------------
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
