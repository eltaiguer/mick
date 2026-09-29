#!/bin/sh
# App Nap experiment (SPEC.md §9.3 item 7). Launches two copies of the windowless
# LSUIElement spike app through LaunchServices, one holding the
# .userInitiatedAllowingIdleSystemSleep activity and one without, plus a plain CLI
# writer that appends a timestamp line to a watched file every WRITE_INTERVAL
# seconds. Each app records how late its re-armed one-shot Timer fires and how long
# the vnode file-watch callback takes after each write. Everything lives in OUT_DIR
# (never ~/.mick); both apps quit themselves after DURATION seconds.
#
# Usage: scripts/run-appnap.sh OUT_DIR [DURATION=1980] [TIMER_INTERVAL=30] [WRITE_INTERVAL=47]
set -eu
cd "$(dirname "$0")/.."
OUT="$1"
DURATION="${2:-1980}"
INTERVAL="${3:-30}"
WRITE_INTERVAL="${4:-47}"
mkdir -p "$OUT"
APP="$(./scripts/make-app.sh)"
BIN="$APP/Contents/MacOS/SignalsSpike"
: > "$OUT/watch-on.txt"
: > "$OUT/watch-off.txt"

cleanup() {
  for f in "$OUT"/*.pid; do
    [ -f "$f" ] || continue
    kill "$(cat "$f")" 2>/dev/null || true
    rm -f "$f"
  done
}
trap cleanup EXIT INT TERM

# Writers are plain processes (not app bundles), so App Nap doesn't apply to them.
"$BIN" writer --file "$OUT/watch-on.txt" --interval "$WRITE_INTERVAL" --duration "$DURATION" &
echo $! > "$OUT/writer-on.pid"
"$BIN" writer --file "$OUT/watch-off.txt" --interval "$WRITE_INTERVAL" --duration "$DURATION" &
echo $! > "$OUT/writer-off.pid"

for v in on off; do
  open -n -g "$APP" --args appnap --results "$OUT/results-$v.jsonl" --watch "$OUT/watch-$v.txt" \
    --duration "$DURATION" --interval "$INTERVAL" --activity "$v" --label "activity-$v"
done
sleep 2
pgrep -f "SignalsSpike appnap --results $OUT/results-on" > "$OUT/app-on.pid" || true
pgrep -f "SignalsSpike appnap --results $OUT/results-off" > "$OUT/app-off.pid" || true

# Once a minute, record each app's scheduling priority (a napped app drops to a
# background priority, typically 4, instead of the usual 31-46).
ON_PID="$(cat "$OUT/app-on.pid")"
OFF_PID="$(cat "$OUT/app-off.pid")"
(
  while kill -0 "$ON_PID" 2>/dev/null || kill -0 "$OFF_PID" 2>/dev/null; do
    printf '%s on:%s off:%s\n' "$(date +%H:%M:%S)" \
      "$(ps -o pri= -p "$ON_PID" | tr -d ' ')" "$(ps -o pri= -p "$OFF_PID" | tr -d ' ')" >> "$OUT/priority.txt"
    sleep 60
  done
) &
echo $! > "$OUT/sampler.pid"

# Wait for both apps to exit on their own (with a margin), then summarize.
deadline=$(( $(date +%s) + DURATION + 60 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if ! pgrep -f "SignalsSpike appnap --results $OUT/" >/dev/null; then break; fi
  sleep 5
done
wait || true
"$BIN" summarize "$OUT/results-on.jsonl" "$OUT/results-off.jsonl" | tee "$OUT/summary.txt"
