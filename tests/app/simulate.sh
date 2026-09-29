#!/bin/sh
# Simulation mode check (issue #12): builds Mick.app in Debug and plays every scripted
# scenario end to end in the real app, with the real panel, against temporary Mick
# homes (TMPDIR points into a scratch directory, so nothing lands anywhere else).
# Then builds Release and checks simulation mode isn't there. Never touches ~/.mick,
# never uses `open`, and leaves no process behind.
#
# Usage: tests/app/simulate.sh              (exit 0 = all passed)
#   MICK_SIM_SCENARIOS="normal-run hand-off"  only these (default: all seven)
#   MICK_SIM_SKIP_SLOW=1                      skip esc-interrupt (it takes 3 minutes)
#   MICK_SKIP_BUILD=1                         reuse the last builds
#
# Needs a logged-in GUI session (the status item and panel are real).

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DERIVED="$ROOT/app/build/DerivedData"
DEBUG_BIN="$DERIVED/Build/Products/Debug/Mick.app/Contents/MacOS/Mick"
RELEASE_BIN="$DERIVED/Build/Products/Release/Mick.app/Contents/MacOS/Mick"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mick-simulate-check.XXXXXX")
trap 'pkill -f "$DEBUG_BIN" 2>/dev/null; pkill -f "$RELEASE_BIN" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM
unset MICK_HOME
REAL_HOME_MICK="$HOME/.mick"
real_before=$( [ -e "$REAL_HOME_MICK" ] && find "$REAL_HOME_MICK" -type f -exec stat -f '%N %m %z' {} + 2>/dev/null | sort | shasum || echo absent)

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; }

build() {
  config=$1
  if ! xcodebuild -project "$ROOT/app/Mick.xcodeproj" -scheme Mick -configuration "$config" \
       -derivedDataPath "$DERIVED" build >"$WORK/build-$config.log" 2>&1; then
    tail -30 "$WORK/build-$config.log"
    echo "BUILD FAILED ($config)"
    exit 1
  fi
}
if [ "${MICK_SKIP_BUILD:-0}" != 1 ]; then
  echo "== building Mick.app (Debug and Release)"
  build Debug
  build Release
fi
[ -x "$DEBUG_BIN" ] || { echo "no Debug app at $DEBUG_BIN"; exit 1; }

# $1 = scenario, $2 = timeout seconds. Fixed 10 s idle so the 3 s input-gap wait
# passes whether or not someone is using the Mac.
run_scenario() {
  mkdir -p "$WORK/tmp-$1"
  TMPDIR="$WORK/tmp-$1/" /usr/bin/perl -e 'alarm shift; exec @ARGV or die' "$2" \
    "$DEBUG_BIN" --simulate "$1" --simulate-idle 10 --simulate-exit >"$WORK/$1.out" 2>"$WORK/$1.err"
}

SCENARIOS=${MICK_SIM_SCENARIOS:-"normal-run short-run esc-interrupt permission-pause three-sessions hand-off out-of-order"}
echo "== scenarios (Debug)"
for s in $SCENARIOS; do
  if [ "$s" = esc-interrupt ] && [ "${MICK_SIM_SKIP_SLOW:-0}" = 1 ]; then
    echo "skip $s (MICK_SIM_SKIP_SLOW)"
    continue
  fi
  timeout=60
  [ "$s" = esc-interrupt ] && timeout=260
  run_scenario "$s" "$timeout"
  status=$?
  sed 's/^/     | /' "$WORK/$s.out"
  if [ $status -eq 0 ] && grep -q '^SIMULATION OK' "$WORK/$s.out" && ! grep -q '^FAIL' "$WORK/$s.out"; then
    ok "scenario $s passed ($(grep -c '^PASS' "$WORK/$s.out") checks)"
  else
    fail "scenario $s (exit $status)" "$(tail -5 "$WORK/$s.err")"
  fi
  # Everything it wrote is under the scratch TMPDIR, in a mick-simulate-* root.
  sim_root=$(sed -n 's/^SIMULATION root //p' "$WORK/$s.out")
  case "$sim_root" in
    */tmp-"$s"/mick-simulate-*) [ -d "$WORK/tmp-$s/$(basename "$sim_root")" ] \
      && ok "$s used a temporary home ($sim_root)" || fail "$s home missing: '$sim_root'" ;;
    *) fail "$s home not under the scratch TMPDIR: '$sim_root'" ;;
  esac
  run_home=$(ls -d "$WORK/tmp-$s"/mick-simulate-*/01-"$s" 2>/dev/null | head -1)
  if [ -n "$run_home" ] && grep -q "simulation: $s passed" "$run_home/log.txt"; then
    ok "$s run logged in its home"
  else
    fail "$s run log missing"
  fi
done

# The same scenario chosen from the status item's Simulate menu.
echo "== from the menu (Debug)"
mkdir -p "$WORK/tmp-menu"
TMPDIR="$WORK/tmp-menu/" /usr/bin/perl -e 'alarm shift; exec @ARGV or die' 60 \
  "$DEBUG_BIN" --simulate normal-run --simulate-via-menu --simulate-idle 10 --simulate-exit >"$WORK/menu.out" 2>"$WORK/menu.err"
status=$?
sed 's/^/     | /' "$WORK/menu.out"
[ $status -eq 0 ] && grep -q '^PASS chose "Normal run" in the Simulate menu' "$WORK/menu.out" && grep -q '^SIMULATION OK' "$WORK/menu.out" \
  && ok "scenario started from the Simulate menu passed" || fail "menu-started scenario (exit $status)" "$(tail -5 "$WORK/menu.err")"

# The panel really showed (not just the engine's view): the checks read the
# window's visibility, and the log records the show.
if [ -n "$(ls -d "$WORK"/tmp-normal-run/mick-simulate-*/01-normal-run 2>/dev/null)" ]; then
  grep -q 'reminder shown for session sim-a' "$WORK"/tmp-normal-run/mick-simulate-*/01-normal-run/log.txt \
    && ok "normal run: log records the panel shown" || fail "normal run: no show in the log"
fi

# --- Release: no simulation mode ---------------------------------------------
echo "== release"
if [ -x "$RELEASE_BIN" ]; then
  mkdir -p "$WORK/tmp-release"
  TMPDIR="$WORK/tmp-release/" "$RELEASE_BIN" --simulate normal-run >"$WORK/release.out" 2>&1
  status=$?
  [ $status -eq 2 ] && grep -q 'unknown argument --simulate' "$WORK/release.out" \
    && ok "Release rejects --simulate (exit 2)" || fail "Release accepted --simulate (exit $status)" "$(cat "$WORK/release.out")"
  ls -d "$WORK/tmp-release"/mick-simulate-* >/dev/null 2>&1 && fail "Release created a simulation home" || ok "Release created no simulation home"
  strings "$RELEASE_BIN" | grep -q 'Simulate (debug)' && fail "Release binary contains the Simulate menu" || ok "Release binary has no Simulate menu"
else
  fail "no Release app at $RELEASE_BIN"
fi

# --- The real home is untouched ----------------------------------------------
real_after=$( [ -e "$REAL_HOME_MICK" ] && find "$REAL_HOME_MICK" -type f -exec stat -f '%N %m %z' {} + 2>/dev/null | sort | shasum || echo absent)
[ "$real_before" = "$real_after" ] && ok "~/.mick unchanged ($([ "$real_before" = absent ] && echo absent || echo present))" || fail "~/.mick changed"

sleep 0.3
if pgrep -f "$DEBUG_BIN" >/dev/null || pgrep -f "$RELEASE_BIN" >/dev/null; then
  fail "a Mick process is still running"; pkill -f "$DEBUG_BIN"; pkill -f "$RELEASE_BIN"
else
  ok "no Mick process left running"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
