#!/bin/sh
# Launches the built spike app in each configuration with --smoke. Each run shows
# the panel, checks focus, delivers first clicks, prints PASS/FAIL lines and quits.
# Needs a logged-in GUI session. Leaves no process and no defaults behind.
set -u
cd "$(dirname "$0")"
[ -x build/PanelSpike.app/Contents/MacOS/PanelSpike ] || ./make-app.sh >/dev/null
BIN=build/PanelSpike.app/Contents/MacOS/PanelSpike

status=0
run() {
    echo "== $*"
    "$BIN" "$@" 2>/dev/null || status=1
}
run --smoke
run --smoke --level popUpMenu
run --smoke --prefer-right
run --smoke --prefer-right --level popUpMenu
run --smoke --regular

# --prefer-right sets an autosave name, which makes AppKit persist the slot.
defaults delete dev.mick.spike.panel >/dev/null 2>&1 || true
if pgrep -f "$BIN" >/dev/null; then
    echo "FAIL a spike process is still running"; pkill -f "$BIN"; status=1
fi
[ "$status" -eq 0 ] && echo "ALL SMOKE RUNS OK" || echo "SMOKE FAILURES"
exit "$status"
