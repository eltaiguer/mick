#!/bin/sh
# Hook test suite for plugin/hooks/mick-event.sh (SPEC.md §6.1, §6.2, §16).
#
# Runs entirely against temporary MICK_HOME directories; never touches ~/.mick.
# Usage: tests/hooks/test-hooks.sh        (exit 0 = all passed)
# Timings are printed and also written to $MICK_TIMINGS_OUT if set.

set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HOOK="$ROOT/plugin/hooks/mick-event.sh"
HOOKS_JSON="$ROOT/plugin/hooks/hooks.json"
JQ=/usr/bin/jq

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mick-hook-tests.XXXXXX")
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM

# Make sure no inherited MICK_HOME can point the hook at real state.
unset MICK_HOME MICK_JQ

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; }

SECRET_PROMPT='SECRET-PROMPT-TEXT please refactor the billing module'
SECRET_REPLY='SECRET-ASSISTANT-MESSAGE I refactored it'
SECRET_TOOL='SECRET-TOOL-INPUT rm -rf /tmp/whatever'

payload_prompt() {
  cat <<EOF
{"session_id":"sess-$1","transcript_path":"/tmp/t.jsonl","cwd":"/Users/me/project $1","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"$SECRET_PROMPT"}
EOF
}
payload_stop() {
  cat <<EOF
{"session_id":"sess-$1","transcript_path":"/tmp/t.jsonl","cwd":"/Users/me/project","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"$SECRET_REPLY"}
EOF
}
payload_stop_failure() {
  cat <<EOF
{"session_id":"sess-$1","transcript_path":"/tmp/t.jsonl","cwd":"/Users/me/project","hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"$SECRET_REPLY"}
EOF
}
payload_permission() {
  cat <<EOF
{"session_id":"sess-$1","transcript_path":"/tmp/t.jsonl","cwd":"/Users/me/project","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"$SECRET_TOOL","description":"$SECRET_TOOL"},"permission_suggestions":[]}
EOF
}
payload_notification() {
  cat <<EOF
{"session_id":"sess-$1","transcript_path":"/tmp/t.jsonl","cwd":"/Users/me/project","hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"$2"}
EOF
}
payload_end() {
  cat <<EOF
{"session_id":"sess-$1","transcript_path":"/tmp/t.jsonl","cwd":"/Users/me/project","hook_event_name":"SessionEnd","reason":"prompt_input_exit"}
EOF
}

# run_hook <home> <event> <payload> [extra env assignments...]
# Captures stdout/stderr into files and the exit status into $RC.
run_hook() {
  home=$1; ev=$2; pl=$3; shift 3
  printf '%s\n' "$pl" | env MICK_HOME="$home" "$@" "$HOOK" "$ev" \
    >"$WORK/stdout" 2>"$WORK/stderr"
  RC=$?
}

assert_silent() {
  if [ -s "$WORK/stdout" ] || [ -s "$WORK/stderr" ]; then
    fail "$1: printed nothing" "stdout=$(cat "$WORK/stdout") stderr=$(cat "$WORK/stderr")"
  else
    ok "$1: printed nothing"
  fi
}

assert_rc0() {
  if [ "$RC" -eq 0 ]; then ok "$1: exit 0"; else fail "$1: exit 0" "got $RC"; fi
}

line_count() { if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }

# --- static checks on hooks.json ---------------------------------------------

check_hook() { # <HookName> <expected arg> <expected async true|false> [matcher]
  name=$1; arg=$2; async=$3; matcher=${4:-}
  got=$($JQ -r --arg h "$name" '
    .hooks[$h] as $g
    | if ($g | length) != 1 then "entries=\($g | length)"
      else $g[0] as $m
      | ($m.hooks | length) as $n
      | $m.hooks[0] as $c
      | "\($n)|\($c.type)|\($c.command)|\($c.args | tojson)|\($c.async // false)|\($m.matcher // "")"
      end' "$HOOKS_JSON")
  want="1|command|\${CLAUDE_PLUGIN_ROOT}/hooks/mick-event.sh|[\"$arg\"]|$async|$matcher"
  if [ "$got" = "$want" ]; then ok "hooks.json: $name -> $arg (async=$async)"
  else fail "hooks.json: $name -> $arg (async=$async)" "got: $got"; fi
}

check_hook UserPromptSubmit prompt true
check_hook Stop stop true
check_hook StopFailure stop true
check_hook PermissionRequest wait true
check_hook Notification wait true 'permission_prompt|elicitation_dialog|elicitation_url_dialog'
check_hook SessionEnd end false

extra=$($JQ -r '.hooks | keys - ["UserPromptSubmit","Stop","StopFailure","PermissionRequest","Notification","SessionEnd"] | join(",")' "$HOOKS_JSON")
if [ -z "$extra" ]; then ok "hooks.json: no other hooks"; else fail "hooks.json: no other hooks" "$extra"; fi

if $JQ -e '[.. | objects | select(has("command")) | .command | test("^sh |sh -c|bash")] | any | not' "$HOOKS_JSON" >/dev/null; then
  ok "hooks.json: exec form (no shell wrapper)"
else
  fail "hooks.json: exec form (no shell wrapper)"
fi

# The Notification matcher must accept exactly the three wait types.
m=$($JQ -r '.hooks.Notification[0].matcher' "$HOOKS_JSON")
for nt in permission_prompt elicitation_dialog elicitation_url_dialog; do
  if printf '%s' "$nt" | grep -Eqx "$m"; then ok "matcher accepts $nt"; else fail "matcher accepts $nt"; fi
done
for nt in idle_prompt agent_needs_input agent_completed auth_success; do
  if printf '%s' "$nt" | grep -Eqx "$m"; then fail "matcher rejects $nt"; else ok "matcher rejects $nt"; fi
done

if [ -x "$HOOK" ]; then ok "mick-event.sh is executable"; else fail "mick-event.sh is executable"; fi
if git -C "$ROOT" ls-files -s plugin/hooks/mick-event.sh 2>/dev/null | grep -q '^100755'; then
  ok "mick-event.sh is committed executable"
elif ! git -C "$ROOT" ls-files --error-unmatch plugin/hooks/mick-event.sh >/dev/null 2>&1; then
  ok "mick-event.sh is committed executable (not yet committed; skipped)"
else
  fail "mick-event.sh is committed executable" "git mode is not 100755"
fi

# --- one line per event, correct fields ---------------------------------------

H="$WORK/home-basic"
mkdir -m 700 "$H"
EV="$H/events.jsonl"

before=$(date +%s)
run_hook "$H" prompt "$(payload_prompt A)";                         assert_rc0 prompt; assert_silent prompt
run_hook "$H" stop "$(payload_stop A)";                             assert_rc0 stop; assert_silent stop
run_hook "$H" stop "$(payload_stop_failure A)";                     assert_rc0 stop-failure; assert_silent stop-failure
run_hook "$H" wait "$(payload_permission A)";                       assert_rc0 permission; assert_silent permission
run_hook "$H" wait "$(payload_notification A permission_prompt)";   assert_rc0 notification; assert_silent notification
run_hook "$H" wait "$(payload_notification A elicitation_dialog)";  assert_rc0 elicitation; assert_silent elicitation
run_hook "$H" end "$(payload_end A)";                               assert_rc0 end; assert_silent end
after=$(( $(date +%s) + 1 ))

n=$(line_count "$EV")
if [ "$n" -eq 7 ]; then ok "7 events -> 7 lines"; else fail "7 events -> 7 lines" "got $n"; fi

mode=$(stat -f '%Lp' "$EV" 2>/dev/null)
if [ "$mode" = "600" ]; then ok "events.jsonl created with mode 0600"; else fail "events.jsonl created with mode 0600" "got $mode"; fi

# Mode must be 0600 even if the caller's umask is permissive.
H2="$WORK/home-umask"; mkdir "$H2"
( umask 000; run_hook "$H2" prompt "$(payload_prompt U)" )
mode=$(stat -f '%Lp' "$H2/events.jsonl" 2>/dev/null)
if [ "$mode" = "600" ]; then ok "mode 0600 under umask 000"; else fail "mode 0600 under umask 000" "got $mode"; fi

# Each line: compact JSON, exactly the keys e,t,s,c,n, right types.
bad=$($JQ -c --argjson lo "$before" --argjson hi "$after" '
  select(
    (keys != ["c","e","n","s","t"])
    or ((.e | type) != "string")
    or ((.t | type) != "number") or (.t < $lo) or (.t > $hi)
    or ((.s | type) != "string")
    or ((.c | type) != "string")
    or (((.n | type) != "string") and (.n != null))
  )' "$EV" 2>&1)
if [ -z "$bad" ] && $JQ -e . "$EV" >/dev/null 2>&1; then ok "lines contain only allowed fields with right types"
else fail "lines contain only allowed fields with right types" "$bad"; fi

if grep -qv '^{"e":"[a-z]*","t":[0-9.e+]*,"s":' "$EV"; then fail "lines are compact, in e,t,s,c,n order"
else ok "lines are compact, in e,t,s,c,n order"; fi

got=$($JQ -r '[.e, .s, .c, (.n // "null")] | join("|")' "$EV")
want='prompt|sess-A|/Users/me/project A|null
stop|sess-A|/Users/me/project|null
stop|sess-A|/Users/me/project|null
wait|sess-A|/Users/me/project|null
wait|sess-A|/Users/me/project|permission_prompt
wait|sess-A|/Users/me/project|elicitation_dialog
end|sess-A|/Users/me/project|null'
if [ "$got" = "$want" ]; then ok "event names, session, cwd, notification type"
else fail "event names, session, cwd, notification type" "$got"; fi

if $JQ -e 'select(.t != (.t | floor))' "$EV" >/dev/null 2>&1; then ok "t is fractional seconds"
else ok "t is a number (no fractional part on this run)"; fi

for s in "$SECRET_PROMPT" "$SECRET_REPLY" "$SECRET_TOOL" SECRET transcript_path hook_event_name tool_name permission_mode \
         "needs your permission" rate_limit prompt_input_exit; do
  if grep -qF -- "$s" "$EV"; then fail "no payload content in file: $s"; else ok "no payload content in file: $s"; fi
done

# --- missing or unusual payload fields ---------------------------------------

H3="$WORK/home-fields"; mkdir "$H3"
run_hook "$H3" prompt '{"prompt":"SECRET-PROMPT-TEXT"}'
line=$(cat "$H3/events.jsonl" 2>/dev/null)
if [ "$RC" -eq 0 ] && printf '%s' "$line" | $JQ -e '.e=="prompt" and .s==null and .c==null and .n==null' >/dev/null; then
  ok "missing session_id/cwd -> null fields"
else fail "missing session_id/cwd -> null fields" "$line"; fi

run_hook "$H3" prompt '{"session_id":"x","cwd":"/tmp/quo\"te\\back\nslash é"}'
if [ "$(line_count "$H3/events.jsonl")" -eq 2 ] && tail -n 1 "$H3/events.jsonl" | $JQ -e '.c=="/tmp/quo\"te\\back\nslash é"' >/dev/null; then
  ok "cwd with quotes, backslash, newline, unicode stays one valid line"
else fail "cwd with quotes, backslash, newline, unicode stays one valid line"; fi
if grep -q SECRET "$H3/events.jsonl"; then fail "prompt-only payload leaks nothing"; else ok "prompt-only payload leaks nothing"; fi

# --- failure modes: always exit 0, never print --------------------------------

# jq missing (MICK_JQ override)
H4="$WORK/home-nojq"; mkdir "$H4"
run_hook "$H4" prompt "$(payload_prompt J)" MICK_JQ="$WORK/does-not-exist/jq"
assert_rc0 "jq missing"; assert_silent "jq missing"
if [ "$(line_count "$H4/events.jsonl")" -eq 0 ]; then ok "jq missing: no lines written"; else fail "jq missing: no lines written"; fi

# jq present but not executable
: >"$WORK/jq-noexec"
run_hook "$H4" prompt "$(payload_prompt J)" MICK_JQ="$WORK/jq-noexec"
assert_rc0 "jq not executable"; assert_silent "jq not executable"

# malformed payloads
H5="$WORK/home-malformed"; mkdir "$H5"
for pl in 'not json at all' '{"session_id":' '' '[1,2,3]' '"just a string"' '{"session_id":"a"} trailing garbage {'; do
  run_hook "$H5" stop "$pl"
  assert_rc0 "malformed payload [$pl]"; assert_silent "malformed payload [$pl]"
done
bad=$($JQ -c 'select(keys != ["c","e","n","s","t"])' "$H5/events.jsonl" 2>&1 || echo "invalid json")
if [ -z "$bad" ]; then ok "malformed payloads never produce an invalid line"; else fail "malformed payloads never produce an invalid line" "$bad"; fi

# no event argument
H6="$WORK/home-noarg"; mkdir "$H6"
printf '%s\n' "$(payload_stop N)" | env MICK_HOME="$H6" "$HOOK" >"$WORK/stdout" 2>"$WORK/stderr"; RC=$?
assert_rc0 "no event argument"; assert_silent "no event argument"

# directory absent: nothing created
ABSENT="$WORK/absent/home"
run_hook "$ABSENT" prompt "$(payload_prompt X)"
assert_rc0 "home absent"; assert_silent "home absent"
if [ ! -e "$WORK/absent" ]; then ok "home absent: nothing created"; else fail "home absent: nothing created" "$(ls -R "$WORK/absent")"; fi

# default location: with HOME pointing at an empty dir, ~/.mick is not created
FAKEHOME="$WORK/fakehome"; mkdir "$FAKEHOME"
printf '%s\n' "$(payload_prompt D)" | env -u MICK_HOME HOME="$FAKEHOME" "$HOOK" prompt >"$WORK/stdout" 2>"$WORK/stderr"; RC=$?
assert_rc0 "default home absent"; assert_silent "default home absent"
if [ -z "$(ls -A "$FAKEHOME")" ]; then ok "default home absent: ~/.mick not created"; else fail "default home absent: ~/.mick not created"; fi

# default location: with $HOME/.mick present, the hook writes there
mkdir "$FAKEHOME/.mick"
printf '%s\n' "$(payload_prompt D)" | env -u MICK_HOME HOME="$FAKEHOME" "$HOOK" prompt >/dev/null 2>&1
if [ "$(line_count "$FAKEHOME/.mick/events.jsonl")" -eq 1 ]; then ok "default home: writes \$HOME/.mick/events.jsonl"
else fail "default home: writes \$HOME/.mick/events.jsonl"; fi

# MICK_HOME is a file, not a directory
: >"$WORK/home-is-file"
run_hook "$WORK/home-is-file" prompt "$(payload_prompt F)"
assert_rc0 "home is a file"; assert_silent "home is a file"
if [ ! -s "$WORK/home-is-file" ]; then ok "home is a file: untouched"; else fail "home is a file: untouched"; fi

# directory unwritable
if [ "$(id -u)" -ne 0 ]; then
  H7="$WORK/home-ro"; mkdir "$H7"; chmod 500 "$H7"
  run_hook "$H7" prompt "$(payload_prompt R)"
  assert_rc0 "home unwritable"; assert_silent "home unwritable"
  if [ -z "$(ls -A "$H7")" ]; then ok "home unwritable: nothing created"; else fail "home unwritable: nothing created"; fi
  chmod 700 "$H7"

  # events file exists but is read-only
  H8="$WORK/home-rofile"; mkdir "$H8"; : >"$H8/events.jsonl"; chmod 400 "$H8/events.jsonl"
  run_hook "$H8" prompt "$(payload_prompt R)"
  assert_rc0 "events file read-only"; assert_silent "events file read-only"
  chmod 600 "$H8/events.jsonl"
else
  ok "home unwritable: skipped (running as root)"
fi

# --- concurrency ---------------------------------------------------------------

HC="$WORK/home-concurrent"; mkdir "$HC"
i=1
while [ $i -le 200 ]; do
  payload_permission "c$i" | env MICK_HOME="$HC" "$HOOK" wait >>"$WORK/conc-out" 2>&1 &
  i=$((i + 1))
done
wait
n=$(line_count "$HC/events.jsonl")
if [ "$n" -eq 200 ]; then ok "200 concurrent writers -> 200 lines"; else fail "200 concurrent writers -> 200 lines" "got $n"; fi
if $JQ -e . "$HC/events.jsonl" >/dev/null 2>&1 \
   && [ -z "$($JQ -c 'select(keys != ["c","e","n","s","t"] or .e != "wait")' "$HC/events.jsonl")" ]; then
  ok "200 concurrent writers -> every line intact"
else fail "200 concurrent writers -> every line intact"; fi
uniq=$($JQ -r .s "$HC/events.jsonl" | sort -u | wc -l | tr -d ' ')
if [ "$uniq" -eq 200 ]; then ok "200 concurrent writers -> 200 distinct sessions"; else fail "200 concurrent writers -> 200 distinct sessions" "got $uniq"; fi
if [ ! -s "$WORK/conc-out" ]; then ok "200 concurrent writers printed nothing"; else fail "200 concurrent writers printed nothing"; fi
if grep -q SECRET "$HC/events.jsonl"; then fail "concurrent: no tool_input in file"; else ok "concurrent: no tool_input in file"; fi

# --- timings (recorded, not asserted) -----------------------------------------
# "cold" is the first run in this suite; a truly cold run (after reboot or
# `sudo purge`) is slower (SPEC.md §6.1 measured about 0.9 s).

ms_now() { perl -MTime::HiRes=time -e 'printf "%.0f\n", time*1000'; }
HT="$WORK/home-timing"; mkdir "$HT"
PL=$(payload_prompt T)
t0=$(ms_now); printf '%s\n' "$PL" | MICK_HOME="$HT" "$HOOK" prompt; t1=$(ms_now)
cold=$((t1 - t0))
runs=20; total=0; max=0; i=0
while [ $i -lt $runs ]; do
  t0=$(ms_now); printf '%s\n' "$PL" | MICK_HOME="$HT" "$HOOK" prompt; t1=$(ms_now)
  d=$((t1 - t0)); total=$((total + d)); [ $d -gt $max ] && max=$d
  i=$((i + 1))
done
avg=$((total / runs))
timing="hook timing on $(sw_vers -productVersion 2>/dev/null || uname -r): first run ${cold} ms; warm avg ${avg} ms, max ${max} ms over ${runs} runs (includes perl timer overhead)"
printf 'info %s\n' "$timing"
[ -n "${MICK_TIMINGS_OUT:-}" ] && printf '%s\n' "$timing" >>"$MICK_TIMINGS_OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
