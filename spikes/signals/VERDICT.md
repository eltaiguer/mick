# Spike verdict: macOS signals (issue #2)

Covers SPEC.md §6.3 and §9.3 spike items 5–7: system idle time, sleep/wake and
fast-user-switching messages, and App Nap. Machine: macOS 26.6, Xcode 26.2,
Swift 6.2.3, Swift 6 language mode (strict concurrency).

**Verdict: the spec's assumptions hold. Build the app as §6.3 describes.** Two
refinements and two open items:

- *Refinement:* the typed `NSWorkspace` messages are delivered **synchronously on
  the posting thread**. They don't hop to the main actor; an off-main post traps
  (proven by an exit test). AppKit is expected to post workspace notifications
  on the main thread, so this should hold in practice; the manual sleep/wake
  check confirms it (a background post would crash the app). Never re-post
  these messages yourself from a background context.
- *Refinement:* don't schedule Mick's deadlines (the 30 s check, the 3-minute
  untouched close, the 10-minute cap) with `DispatchQueue.main.asyncAfter`.
  Measured on its own, it fires about 5 % of the delay late, capped at 60 s:

  | delay | 30 s | 180 s | 600 s | 1980 s |
  |---|---|---|---|---|
  | `asyncAfter` late by | 1.5 s | 9.0 s | 29.9 s | 60.2 s (both App Nap runs) |

  A one-shot `Timer` (default zero tolerance) was never more than 0.12 s late
  over 67 fires, and a `DispatchSourceTimer` with an explicit 100 ms leeway
  was 0.10 s late. Use one of those. `Task.sleep` wasn't isolated (in the
  side-by-side run it coalesced with the other timers at +0.10 s), so measure
  it before relying on it. Scripts: `scripts/asyncafter.swift`,
  `scripts/leeway.swift`.
- *Open (manual):* the "no permission prompt when launched from Finder" and
  "not listed under Input Monitoring / Accessibility" checks need a person.
  Everything automatable points the right way (below).
- *Open (manual):* no sign of App Nap engaging during the 34-minute run, with
  or without the activity (details in §3), so the run shows that the activity
  does no harm, not that it's needed. Keep it as the spec says (it's cheap and
  Apple's documented remedy); a person should repeat the run while away from
  the Mac with Activity Monitor's App Nap column visible.

## What's here

```
spikes/signals/
  Package.swift                 SwiftPM, Swift 6 mode, macOS 26
  Sources/SignalsKit/           the pieces under test
    IdleTime.swift              CGEventSource any-input idle time
    WorkspaceSignals.swift      typed NSWorkspace messages on the workspace center
    ActivityPolicy.swift        App Nap activity options + a token holder
    Probes.swift                re-armed one-shot Timer probe, vnode file-watch probe, JSONL log
    Summary.swift               aggregates a results log
  Sources/SignalsSpike/main.swift
                                LSUIElement app: interactive mode (status item shows live
                                idle seconds and workspace signals), `appnap` experiment,
                                `writer`, `summarize`
  Tests/SignalsKitTests/        `swift test`
  scripts/make-app.sh           wraps the binary in SignalsSpike.app, signs it (Apple Development)
  scripts/run-appnap.sh         the 30+ minute App Nap experiment
  scripts/asyncafter.swift      asyncAfter lateness on its own
  scripts/leeway.swift          Timer / DispatchSourceTimer / Task.sleep / asyncAfter side by side
  results/                      logs from the run recorded below
```

Run the tests: `cd spikes/signals && swift test`.
Build the app: `scripts/make-app.sh` (prints the .app path).
Repeat the App Nap run: `scripts/run-appnap.sh /tmp/some-dir` (33 min; both apps quit themselves).

## 1. Idle time (§9.3 item 5)

`CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)`

- **Proven by test:** `CGEventType(rawValue: ~0)` bridges (raw value `~0`) under
  Swift 6.2; reads return a finite value `>= 0`; 100 reads take well under a
  second (no blocking, no prompt path).
- **Measured:** in the LaunchServices-launched (`open`) signed app bundle,
  `CGPreflightListenEventAccess()` and `AXIsProcessTrusted()` were both `false`,
  and idle readings were live anyway: logged every 30 s for 34 min, they ranged
  from 0.0004 s to 33 s and dropped back to near zero whenever someone used the
  Mac. So the read does not depend on either grant. Caveat: an `open` from a shell is not
  guaranteed to be a clean Finder launch for TCC attribution, so this is
  supporting evidence, not the Finder check itself.
- **Manual:** launch from Finder, watch the status item count up and reset
  when typing/moving the mouse in another app, confirm no prompt, confirm the
  app is absent from Privacy & Security → Input Monitoring and Accessibility.

## 2. Sleep/wake and fast user switching (§9.3 item 6)

Observed as specified: `NSWorkspace.shared.notificationCenter.addObserver(of: NSWorkspace.shared, for: .willSleep) { … }`
(and `.didWake`, `.sessionDidResignActive`, `.sessionDidBecomeActive`), tokens
retained, compiled in Swift 6 mode with no warnings.

- **Proven by test** (all four messages):
  - the typed message posted on the workspace center reaches the observer on
    the main thread, and the closure's `MainActor.assertIsolated()` passes;
  - the **legacy** `Notification` (what the system actually posts, e.g.
    `NSWorkspace.willSleepNotification`) bridges to the typed message;
  - an observer registered on `NotificationCenter.default` receives nothing
    (Apple's "different center" warning holds);
  - removing the tokens, or releasing the owner, stops delivery;
  - a legacy post from a **background** thread **traps** (exit test): delivery
    runs on the poster's thread, and the main-actor closure's isolation check
    fails. This is the refinement above.
- **Manual:** real sleep/wake and fast user switching with the interactive app
  running: the menu shows each signal with a time and the app doesn't crash
  (which also confirms AppKit posts them on main).

## 3. App Nap (§9.3 item 7)

`ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason:)`,
token retained by `ActivityHolder`. **Proven by test:** the options equal
`.userInitiatedAllowingIdleSystemSleep`, don't contain `.latencyCritical`, and
don't contain `.idleSystemSleepDisabled`; the holder retains and ends the token.

**The run** (`scripts/run-appnap.sh`, logs in `results/`): two copies of the
signed LSUIElement bundle, launched through LaunchServices (`open -n -g`), no
windows and no status item, one holding the activity (`activity-on`) and one
not (`activity-off`). Each re-armed a one-shot 30 s main-run-loop `Timer`
(the "check in 30 s") and watched a file with a vnode `DispatchSource` on the
main queue (the `events.jsonl` mechanism), while a plain CLI writer appended a
timestamp line every 47 s. Each app logged timer lateness and write-to-callback
latency, and a sampler recorded each app's scheduling priority every minute.

| | activity-on | activity-off |
|---|---|---|
| Duration | 34.0 min | 34.0 min |
| Timer fires (30 s) | 67 | 67 |
| Timer lateness mean / max | 0.005 s / 0.120 s | 0.005 s / 0.120 s |
| File-watch callbacks | 43 / 43 writes | 43 / 43 writes |
| File-watch latency mean / max | 0.003 s / 0.014 s | 0.003 s / 0.016 s |
| Scheduling priority (33 samples) | 46 every time | 46 every time |

- With the activity held: the timer fired on time (max 0.12 s late) and every
  file write reached the callback within 16 ms, far inside the 2 s budget.
  `latencyCritical` is not used. **Criterion met.**
- Without the activity: identical numbers, and no sign of napping by the
  proxy available: scheduling priority stayed at 46 in every sample instead of
  dropping to a background level (Activity Monitor's App Nap column is the
  authoritative signal, and needs a person). App Nap isn't disabled on this
  Mac (`NSAppSleepDisabled` is unset globally and for the bundle). Someone was using the Mac throughout (idle never exceeded 33 s),
  and the apps were launched from a shell session, either of which may keep
  the system from napping. So this doesn't show the activity is unnecessary,
  only that it isn't needed while the user is active. The spec's reasoning for
  holding it (Apple's App Nap criteria match a windowless accessory app) still
  stands; keep it. Recorded as a manual follow-up.
- The apps' own 33-minute `asyncAfter` shutdown fired 60.2 s late in both
  runs (the dispatch leeway finding above), independent of App Nap.

## Manual checks still needed

- [ ] Launch `SignalsSpike.app` from Finder: no permission prompt appears, the
      status item's idle seconds count up and reset when typing or moving the
      mouse in another app.
- [ ] System Settings → Privacy & Security → Input Monitoring and
      Accessibility: SignalsSpike is not listed.
- [ ] With the interactive app running, sleep the Mac and wake it; lock and
      use fast user switching into another account and back. The menu shows
      `willSleep`, `didWake`, `sessionDidResignActive`, `sessionDidBecomeActive`
      with times, and the app hasn't crashed.
- [ ] On a Mac with App Nap enabled, re-run `scripts/run-appnap.sh` while away from the Mac (display asleep
      or idle for 30+ min, not launched from a terminal session if possible)
      with Activity Monitor's App Nap column showing. Record whether
      `activity-off` naps and how late its timer and file-watch get.

