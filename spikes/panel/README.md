# Panel spike (issue #1, SPEC §9.3 items 1-4)

Throwaway. Proves the reminder panel can appear and take clicks without ever taking
keyboard focus. Results are in [VERDICT.md](VERDICT.md).

## Layout

- `Sources/PanelSpikeKit/` — the pieces the real app will copy:
  - `ReminderPanel.swift`: the `NSPanel` subclass (`[.borderless, .nonactivatingPanel]`,
    never key or main, `hidesOnDeactivate = false`, the §9.3 collection behavior) and
    `FirstClickHostingView` (`acceptsFirstMouse` true, `needsPanelToBecomeKey` false).
  - `PanelPlacement.swift`: pure positioning (under the status item, clamped, top-right
    fallback, notch detection). Candidate for `MickCore`.
  - `PanelController.swift`: shows with `orderFrontRegardless()` only, reads the status
    item anchor, finds the active window's screen, focus snapshots, synthetic clicks.
  - `SpikeContent.swift`: stand-in SwiftUI content (checkbox toggles, plain buttons).
- `Sources/panel-spike/`: the menu bar app (own `NSStatusItem`, no `MenuBarExtra`).
- `Tests/PanelSpikeKitTests/`: automated checks.

## Run

```sh
swift test            # needs a logged-in GUI session (window server), no human
./make-app.sh         # builds build/PanelSpike.app (LSUIElement, ad-hoc signed)
./smoke.sh            # launches the app in 5 configurations with --smoke; each quits itself
```

Manual runs:

```sh
open build/PanelSpike.app                         # accessory, .statusBar level
open build/PanelSpike.app --args --level popUpMenu
open build/PanelSpike.app --args --regular        # .regular policy comparison
open build/PanelSpike.app --args --cycle 3 --log /tmp/panel-spike.log
```

Arguments: `--regular`, `--level statusBar|popUpMenu`, `--smoke`, `--prefer-right`
(ask for a status item slot near the right edge, useful on a crowded notched menu bar),
`--show-after SECONDS`, `--cycle SECONDS` (show/hide the panel repeatedly), `--log PATH`.

The status item menu has: Show panel now, Show panel in 5 s, Toggle panel every 5 s,
Hide panel, Level: statusBar / popUpMenu, and Quit. Every show logs the frontmost app,
whether Mick's app is active and whether the panel is key, before and 0.5 s after, plus
the status item's raw frame, visibility and occlusion. Every click logs the same.

`typing-check.sh` is the keystroke-loss check: run it in Terminal while the spike cycles
the panel and type the phrase over and over; it reports any line that doesn't match.

`--prefer-right` sets an autosave name, so AppKit persists the slot in the
`dev.mick.spike.panel` defaults domain; `smoke.sh` deletes that domain afterwards
(`defaults delete dev.mick.spike.panel` if you used the flag by hand).
