#!/bin/sh
# mick-event.sh <prompt|stop|wait|end>; hook payload on stdin.
exec >/dev/null 2>/dev/null
d="${MICK_HOME:-$HOME/.mick}"
[ -d "$d" ] || exit 0          # the app creates the directory; no app, no writes
umask 077
"${MICK_JQ:-/usr/bin/jq}" -c --arg e "$1" \
  '{e:$e, t:now, s:.session_id, c:.cwd, n:(.notification_type // null)}' \
  >> "$d/events.jsonl"
exit 0
