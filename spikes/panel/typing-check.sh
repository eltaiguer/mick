#!/bin/sh
# Manual keystroke-loss check (SPEC §9.3 item 1). Run it in Terminal while the spike
# toggles the panel (`open build/PanelSpike.app --args --cycle 3`). Type the phrase
# and press Return, over and over, without looking at the panel. Ctrl-D to finish.
# Any line that doesn't match exactly means a keystroke went somewhere else.
PHRASE="the quick brown fox jumps over the lazy dog"
echo "Type: $PHRASE   (Return after each, Ctrl-D to stop)"
ok=0; bad=0
while IFS= read -r line; do
    if [ "$line" = "$PHRASE" ]; then
        ok=$((ok + 1))
    else
        bad=$((bad + 1))
        echo "MISMATCH: '$line'"
    fi
done
echo "lines ok: $ok, mismatched: $bad"
[ "$bad" -eq 0 ]
