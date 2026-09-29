# Verdict: panel that never takes focus

Run on macOS 26.6, Xcode 26.2, Swift 6.2.3 (strict concurrency), one built-in notched
display (1728 x 1117 pt). This run was unattended: everything below marked **verified**
was checked by `swift test` or `smoke.sh`. Items marked **pending** need a person, and
are in the manual checklist at the end.

## Short answer

- The §9.3 recipe works as written for focus: showing the panel with
  `orderFrontRegardless()` never activated the app, never made the panel key, and never
  changed `NSWorkspace.frontmostApplication`, at both window levels. First clicks on a
  checkbox `Toggle` and a `.plain` `Button` registered with the panel never becoming key.
- **Window level: use `.statusBar`.** `.popUpMenu` behaved identically in every automated
  check, so there's no reason to go higher than needed. This stays provisional until the
  fullscreen check below is done by hand; if `.statusBar` fails over a fullscreen Space
  and `.popUpMenu` works, switch (it's one line: `PanelLevel`).
- **Fallbacks: no evidence either §9.3 fallback is needed.** Focus-on-click is not needed
  based on everything automated here; the fullscreen notification fallback is unresolved
  until the manual fullscreen check.
- **Spec change needed for positioning:** a status item pushed into notch overflow is
  *not* off-screen or empty, so §9.1's detection rule misses it. See below.

## What was verified

| Check | Result |
|---|---|
| Style mask `[.borderless, .nonactivatingPanel]`, `canBecomeKey`/`canBecomeMain` false, `becomesKeyOnlyIfNeeded` true, `hidesOnDeactivate` false (set explicitly) | verified (unit test) |
| `collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, accepted at runtime, never `.moveToActiveSpace` | verified (unit test asserts the exact set and the absence) |
| Hosting view: `acceptsFirstMouse` true, `needsPanelToBecomeKey` false | verified |
| Calling `makeKey` / `makeKeyAndOrderFront` on the panel still leaves it non-key | verified |
| `orderFrontRegardless()`: panel on screen at the expected window layer (`CGWindowListCopyWindowInfo`), app not active, no key window, frontmost app unchanged | verified at `.statusBar` and `.popUpMenu`, accessory policy, in the test process and in the built app |
| Same with `.regular` activation policy | verified: showing didn't steal focus either, so the non-activating style mask, not the activation policy, is what prevents activation on show. Caveat: that binary was launched from the shell, so LaunchServices never activated it at launch; an `open`ed `.regular` app starts active |
| Single click on a checkbox toggle and on each plain button changes state exactly once; afterwards the panel isn't key, the app isn't active, frontmost unchanged | verified with synthetic events (see limits) |
| Anchored under the status item: centered on it, top edge 4 pt below it, clamped to the visible frame | verified in the app (`--prefer-right`) and in unit tests, including left/right clamping, a second display to the right and one below |
| Status item in notch overflow → top-right fallback | verified for real on this machine (see below) |
| Status item empty or off every screen (auto-hidden menu bar) → top-right fallback | verified in unit tests only |

## Findings

**Notch overflow isn't "off-screen or empty".** With a crowded menu bar the spike's status
item overflowed. Its button window still reported `isVisible == true` and a normal,
on-screen frame (x 821-843, y 1085) that sits behind the camera housing (the screen's
`auxiliaryTopLeftArea` ends at x 771 and `auxiliaryTopRightArea` starts at x 956).
§9.1's rule ("frame is off-screen or empty") would have anchored the panel under the
notch. Two signals caught it, and the spike uses both:

1. `button.window.occlusionState` lacks `.visible` (it had `.visible` when the item was
   given a slot right of the notch).
2. The anchor's center is outside both `NSScreen.auxiliaryTopLeftArea` and
   `auxiliaryTopRightArea` (pure check, `ScreenGeometry.isBehindNotch`, unit-tested with
   the real numbers from this machine).

Recommendation for the app: treat the status item as hidden when its frame is empty,
off every screen, its window isn't visible, its window's occlusion state lacks
`.visible`, or it sits behind the notch.

**"The screen with the active window" without permissions.** An accessory app can't ask
another app for its focused window without Accessibility. The spike reads the window
list (`CGWindowListCopyWindowInfo`, on-screen only) and takes the topmost layer-0 window
owned by `frontmostApplication`; window bounds don't need Screen Recording (only titles
do). If there's none, it uses the screen under the mouse, then the first screen. In the
smoke runs this picked the right screen (Chrome frontmost), but with one display that
proves little; multi-display is a manual check.

**Window frames snap to whole points.** The anchored top edge landed 0.5 pt off the ideal
(the status button is at y 1085.5); harmless, and the smoke check allows 1 pt.

## Limits of the automated checks

- Synthetic clicks go through `NSWindow.sendEvent`, after the point where the window
  server decides whether a click on a non-key window of an inactive app is delivered or
  swallowed. A plain `NSHostingView` (no `acceptsFirstMouse` override) also passed the
  synthetic click, so this test does not prove the override matters; only a real click
  can. Posting real `CGEvent`s needs the Accessibility permission and moves the user's
  pointer, so it was out of scope for an unattended run.
- Keystroke loss can only be measured with real typing (`typing-check.sh`).
- Fullscreen Spaces, multiple displays, auto-hidden menu bar and Full Keyboard Access
  weren't exercised.

## Manual checklist (pending)

- [ ] Typing: `open build/PanelSpike.app --args --cycle 3 --log /tmp/panel-spike.log`,
      run `./typing-check.sh` in Terminal and type for a minute. Expect 0 mismatches and
      every `show after` line in the log ending in `OK`.
- [ ] Real click: "Show panel in 5 s", switch to Terminal and keep typing, then click a
      checkbox once and "Not now" once. Each must react on the first click, and typing
      must keep going into Terminal without clicking back into it.
- [ ] Same click check with Full Keyboard Access on (System Settings → Keyboard →
      Keyboard navigation). Revert afterwards.
- [ ] Fullscreen: put an app fullscreen (Terminal or Safari), trigger "Show panel in 5 s",
      switch to it. Try both `Level:` items in the menu. Then repeat with
      `--args --regular` (it starts active when opened: click back into the fullscreen
      app before triggering the show). Record which level(s) show over the fullscreen Space and
      whether the policy matters.
- [ ] Auto-hidden menu bar in fullscreen: the panel goes top-right of that screen.
- [ ] Multiple displays: status item on each display's menu bar → panel under it on that
      display; with the item hidden, the panel goes top-right of the display with the
      frontmost window.
- [ ] Notch overflow on your machine: without `--prefer-right` on a crowded menu bar, the
      panel goes top-right (log line `anchor=nil`).
- [ ] Update this file with the results and settle the level and fallback questions.
