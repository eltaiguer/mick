#!/bin/sh
# scripts/review.sh (the two-week review of reminders.jsonl) against fixture logs in a
# temporary MICK_HOME. Never reads or writes ~/.mick.
# Usage: tests/scripts/test-review.sh   (exit 0 = all passed)

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
REVIEW="$ROOT/scripts/review.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mick-review.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
export TZ=UTC

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; }
has()  { if grep -qF -- "$2" "$1"; then ok "$3"; else fail "$3" "$(cat "$1")"; fi; }

H="$WORK/mick"
mkdir -p "$H"
rec() {  # day, hour, outcome, manual, sitting
  printf '{"shown_at":"2026-10-%sT%s:00:00.000000Z","settled_at":"2026-10-%sT%s:03:00.000000Z","session_id":"s","cwd":"/tmp/p","sitting_minutes":%s,"routine":["stand","back-bend","shoulder-rolls"],"ticked":[],"max_idle_seconds":3,"outcome":"%s","manual":%s}\n' \
    "$1" "$2" "$1" "$2" "$5" "$3" "$4"
}
{
  rec 01 09 completed false 50
  rec 01 11 partial false 60
  rec 01 14 ignored false 70
  rec 02 10 stood_up false 52
  rec 02 15 snoozed false 55
  rec 02 16 completed true 10
  echo 'not json at all'
  echo '{"half":'
} >"$H/reminders.jsonl"
before=$(shasum "$H/reminders.jsonl")

MICK_HOME="$H" sh "$REVIEW" >"$WORK/out" 2>"$WORK/err"
[ $? -eq 0 ] && ok "exit 0" || fail "exit 0"
[ ! -s "$WORK/err" ] && ok "no stderr (bad lines skipped)" || fail "stderr" "$(cat "$WORK/err")"
has "$WORK/out" "Reminders: 5 from agent runs, 1 from Stretch now" "counts agent-run and Stretch now reminders apart"
has "$WORK/out" "Days: 2 (2026-10-01 to 2026-10-02)" "day range"
has "$WORK/out" "  completed 1" "completed count leaves out Stretch now"
has "$WORK/out" "  ignored   1" "ignored count"
has "$WORK/out" "  snoozed   1" "snoozed count"
has "$WORK/out" "Got up (completed, partial or stood up): 3 of 4 not snoozed, 75%" "share that got up"
has "$WORK/out" "Average sitting time when shown: 57 min" "average sitting time"
has "$WORK/out" "  2026-10-01  3  2  1  0" "per-day row, day one"
has "$WORK/out" "  2026-10-02  2  1  0  1" "per-day row, day two"
[ "$(shasum "$H/reminders.jsonl")" = "$before" ] && ok "log left untouched" || fail "log changed"
[ "$(ls -A "$H")" = reminders.jsonl ] && ok "wrote nothing next to it" || fail "wrote files: $(ls -A "$H")"

# Local days: 23:30 UTC on the 1st is the 2nd in Tokyo.
printf '%s\n' "$(rec 01 23 completed false 50 | sed 's/T23:00/T23:30/')" >"$WORK/tz.jsonl"
TZ=Asia/Tokyo sh "$REVIEW" "$WORK/tz.jsonl" >"$WORK/tz.out"
has "$WORK/tz.out" "  2026-10-02  1  1  0  0" "days are local days"

# A path argument, and no log yet.
sh "$REVIEW" "$H/reminders.jsonl" >"$WORK/out2" && has "$WORK/out2" "Reminders: 5" "reads a path argument"
MICK_HOME="$WORK/nothing" sh "$REVIEW" >"$WORK/out3"
[ $? -eq 0 ] && has "$WORK/out3" "No reminder log at" "no log yet: says so, exit 0"
[ ! -e "$WORK/nothing" ] && ok "no log yet: creates nothing" || fail "created $WORK/nothing"
: >"$WORK/empty.jsonl"
sh "$REVIEW" "$WORK/empty.jsonl" >"$WORK/out4" && has "$WORK/out4" "No reminders logged yet." "empty log"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
