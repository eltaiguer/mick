#!/bin/sh
# Keeps docs/acceptance.md and README.md honest (issue #13):
# - every SPEC §15 bullet appears in the matrix word for word, numbered in order;
# - every `Suite/test` the matrix names exists in `swift test list`;
# - every AcceptanceTests/acNN test sits in row NN;
# - every simulation scenario it names is one tests/app/simulate.sh plays;
# - README.md has the install commands and the "not medical advice" line.
# Usage: tests/acceptance/check-matrix.sh   (exit 0 = all passed)
#   MICK_TEST_LIST=file   use this `swift test list` output instead of building

set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DOC="$ROOT/docs/acceptance.md"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mick-matrix.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; }

# --- §15 bullets -----------------------------------------------------------------
sed -n '/^## 15\. /,/^## 16\. /p' "$ROOT/SPEC.md" | sed -n 's/^- //p' >"$WORK/criteria"
n=$(wc -l <"$WORK/criteria" | tr -d ' ')
[ "$n" -gt 20 ] && ok "SPEC §15 has $n criteria" || fail "couldn't read §15 from SPEC.md (got $n)"
i=0
missing=0
while IFS= read -r c; do
  i=$((i + 1))
  if ! grep -qF -- "| $i | $c |" "$DOC"; then
    missing=$((missing + 1))
    fail "criterion $i not in the matrix as row $i" "$c"
  fi
done <"$WORK/criteria"
[ "$missing" -eq 0 ] && ok "all $n criteria are rows 1-$n of docs/acceptance.md, word for word"
rows=$(grep -cE '^\| [0-9]+ \| ' "$DOC")
[ "$rows" -eq "$n" ] && ok "no extra numbered rows" || fail "matrix has $rows numbered rows, §15 has $n"

# --- Test names --------------------------------------------------------------------
if [ -n "${MICK_TEST_LIST:-}" ]; then
  cp "$MICK_TEST_LIST" "$WORK/list"
else
  (cd "$ROOT/app/MickCore" && swift test list 2>/dev/null) >"$WORK/list"
fi
sed -E 's/^[A-Za-z]+Tests\.//; s/\(.*$//' "$WORK/list" | sort -u >"$WORK/known"
[ -s "$WORK/known" ] && ok "swift test list: $(wc -l <"$WORK/known" | tr -d ' ') tests" || fail "swift test list gave nothing"
grep -oE '`[A-Z][A-Za-z]*Tests/[A-Za-z0-9_]+`' "$DOC" | tr -d '`' | sort -u >"$WORK/named"
bad=0
while IFS= read -r t; do
  grep -qxF -- "$t" "$WORK/known" || { bad=$((bad + 1)); fail "matrix names a test that doesn't exist: $t"; }
done <"$WORK/named"
[ "$bad" -eq 0 ] && ok "all $(wc -l <"$WORK/named" | tr -d ' ') tests named in the matrix exist"

# Every acceptance test is in the row of its number, and every one is cited.
bad=0
grep -E '^AcceptanceTests/ac[0-9]+_' "$WORK/known" >"$WORK/ac"
while IFS= read -r t; do
  num=$(printf '%s' "$t" | sed -E 's/^AcceptanceTests\/ac0*([0-9]+)_.*/\1/')
  grep -E "^\| $num \| " "$DOC" | grep -qF -- "\`$t\`" || { bad=$((bad + 1)); fail "$t isn't cited in row $num"; }
done <"$WORK/ac"
[ "$bad" -eq 0 ] && ok "each of the $(wc -l <"$WORK/ac" | tr -d ' ') AcceptanceTests is cited in its own row"

# --- Simulation scenarios ------------------------------------------------------------
played=$(sed -n 's/^SCENARIOS=\${MICK_SIM_SCENARIOS:-"\(.*\)"}$/\1/p' "$ROOT/tests/app/simulate.sh")
[ -n "$played" ] && ok "simulate.sh plays: $played" || fail "couldn't read the scenario list from simulate.sh"
bad=0
for s in $(grep -oE 'Simulation: (`[a-z-]+`(, )?)+' "$DOC" | grep -oE '`[a-z-]+`' | tr -d '`' | sort -u); do
  case " $played " in *" $s "*) ;; *) bad=$((bad + 1)); fail "matrix names simulation scenario $s, which simulate.sh doesn't play" ;; esac
done
[ "$bad" -eq 0 ] && ok "every simulation scenario named is played by simulate.sh"

# --- README --------------------------------------------------------------------------
README="$ROOT/README.md"
for s in "/plugin marketplace add eltaiguer/mick" "/plugin install mick@mick" "/plugin uninstall mick@mick" \
         "scripts/install.sh" "not medical advice" "skip anything that hurts" "scripts/review.sh"; do
  grep -qF -- "$s" "$README" && ok "README.md has: $s" || fail "README.md is missing: $s"
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
