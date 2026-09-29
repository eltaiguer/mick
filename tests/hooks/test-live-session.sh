#!/bin/sh
# Opt-in live test: validates the marketplace and plugin manifests, then runs
# two real headless Claude Code sessions with the plugin loaded via
# --plugin-dir (nothing is installed) against a temporary MICK_HOME, and checks
# that each agent event appends exactly one correct line.
#
# Needs the `claude` CLI and a logged-in account; it makes two small API calls.
# Never touches ~/.mick or ~/.claude.
# Usage: tests/hooks/test-live-session.sh

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
JQ=/usr/bin/jq
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mick-live.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; }

if ! command -v claude >/dev/null 2>&1; then
  echo "claude CLI not found; skipping live test"; exit 0
fi

if claude plugin validate "$ROOT" >/dev/null 2>&1; then ok "claude plugin validate . (marketplace)"
else fail "claude plugin validate . (marketplace)"; fi
if claude plugin validate "$ROOT/plugin" >/dev/null 2>&1; then ok "claude plugin validate ./plugin"
else fail "claude plugin validate ./plugin"; fi

# live_run <name> <expected e sequence> <claude args...>
live_run() {
  name=$1; want=$2; shift 2
  home="$WORK/$name-home"; proj="$WORK/$name-proj"
  mkdir -m 700 "$home"; mkdir "$proj"
  (cd "$proj" && MICK_HOME="$home" claude -p --plugin-dir "$ROOT/plugin" "$@" >/dev/null 2>&1)
  sleep 2 # async hooks may still be finishing
  ev="$home/events.jsonl"
  got=$($JQ -r .e "$ev" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
  if [ "$got" = "$want" ]; then ok "$name: events are [$want]"; else fail "$name: events are [$want]" "got [$got]"; fi
  sess=$($JQ -r .s "$ev" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  if [ "$sess" = 1 ]; then ok "$name: one session id"; else fail "$name: one session id" "got $sess"; fi
  real_proj=$(cd "$proj" && pwd -P)
  if [ -z "$($JQ -c --arg p "$real_proj" --arg q "$proj" 'select(keys != ["c","e","n","s","t"] or (.c != $p and .c != $q))' "$ev" 2>/dev/null)" ]; then
    ok "$name: only allowed fields, cwd is the project"
  else fail "$name: only allowed fields, cwd is the project" "$(cat "$ev")"; fi
  mode=$(stat -f '%Lp' "$ev" 2>/dev/null)
  if [ "$mode" = 600 ]; then ok "$name: events.jsonl mode 0600"; else fail "$name: events.jsonl mode 0600" "got $mode"; fi
  if grep -q MICKCANARY "$ev"; then fail "$name: prompt text not written"; else ok "$name: prompt text not written"; fi
  printf '     %s\n' "$(cat "$ev" 2>/dev/null | tr '\n' ' ')" | cut -c1-400
}

live_run basic "prompt stop end" "Reply with just the word ok. MICKCANARY"
live_run permission "prompt wait stop end" --permission-mode default \
  "Use the Bash tool to run exactly: curl -sI https://example.com . If permission is denied just say denied. MICKCANARY"

# With MICK_HOME absent, a real session creates nothing.
absent="$WORK/absent/home"; mkdir "$WORK/absent-proj"
(cd "$WORK/absent-proj" && MICK_HOME="$absent" claude -p --plugin-dir "$ROOT/plugin" "Reply with just ok" >/dev/null 2>&1)
sleep 2
if [ ! -e "$WORK/absent" ]; then ok "absent MICK_HOME: nothing created"; else fail "absent MICK_HOME: nothing created"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
