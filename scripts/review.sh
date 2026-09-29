#!/bin/sh
# The two-week review (SPEC §1 "How we'll know it works", §12.3): summarizes the
# reminder log. Read only; it never writes anywhere.
#
# Usage: scripts/review.sh [reminders.jsonl]
#   default: ${MICK_HOME:-~/.mick}/reminders.jsonl
#
# Prints how many reminders were shown, how each one ended, the share that ended as
# Completed, Partial or Stood up (the goal is most of them), and one row per day.
# Stretch now reminders (manual) are counted separately, since they're voluntary.

set -eu
JQ=${MICK_JQ:-/usr/bin/jq}
LOG=${1:-${MICK_HOME:-$HOME/.mick}/reminders.jsonl}
if [ ! -f "$LOG" ]; then
  echo "No reminder log at $LOG yet. It gets a line each time a reminder settles."
  exit 0
fi

# Unparseable lines are skipped, not fatal: this is a hand-inspected log.
"$JQ" -R -r -n '
  [inputs | (try fromjson catch null) | select(type == "object" and has("outcome"))] as $all
  | ($all | map(select(.manual != true))) as $r
  | ($all | map(select(.manual == true))) as $m
  | def pct(n; d): if d == 0 then "-" else "\((n * 100 / d) | round)%" end;
    def count(o): map(select(.outcome == o)) | length;
    def good: map(select(.outcome == "completed" or .outcome == "partial" or .outcome == "stood_up")) | length;
    def judged: map(select(.outcome != "snoozed")) | length;
    def day: .shown_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | localtime | strftime("%Y-%m-%d");
  if ($all | length) == 0 then "No reminders logged yet."
  else
    "Reminders: \($r | length) from agent runs, \($m | length) from Stretch now",
    "Days: \($all | map(day) | unique | length) (\($all | map(day) | min) to \($all | map(day) | max))",
    "",
    "Agent-run reminders by outcome:",
    ( ["completed", "partial", "stood_up", "ignored", "snoozed"][] as $o
      | "  \($o | . + (" " * (10 - length)))\($r | count($o))" ),
    "",
    "Got up (completed, partial or stood up): \($r | good) of \($r | judged) not snoozed, \(pct($r | good; $r | judged))",
    "Average sitting time when shown: \(if ($r | length) == 0 then "-" else "\(($r | map(.sitting_minutes) | add) / ($r | length) | round) min" end)",
    "",
    "Per day (agent runs): date, shown, got up, ignored, snoozed",
    ( $r | map(. + {day: day}) | group_by(.day)[]
      | "  \(.[0].day)  \(length)  \(good)  \(count("ignored"))  \(count("snoozed"))" )
  end
' <"$LOG"
