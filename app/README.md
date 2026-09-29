# Mick app

- `Mick.xcodeproj`: the menu bar app (`LSUIElement`, own `NSStatusItem`, no `MenuBarExtra`).
  Sources live in `Mick/`, a folder-synchronized group, so new files there are picked up
  without editing the project file.
- `MickCore/`: a Swift package with two libraries.
  - `MickCore`: pure logic and data types. No file system and no clock (everything
    takes `now`): event parsing, ordering, backlog, session bookkeeping, events-file
    offset and rotation decisions, the hooks warning state, the sitting timer and icon
    state (`SittingTimer`, `MenuBarIcon`), the reminder lifecycle (`Reminder`: trigger
    decisions, check hand-off, show-time input-gap wait, panel lifetime and the settle
    window, as a pure value with explicit deadlines), routine composition (`Routine`:
    Stand up + 2 moves, or Stand up + Walk + 1 move for a long sit, with the rotation
    and area rules of §10.1), reminder outcomes and Mick's memory (`Outcome`,
    `MickMemory`, `ReminderRecord`: the §8 table, `nag_after`, `ignored_today` and its
    midnight rollover, the reminder log line), snooze, pause and quiet hours
    (`SnoozeOption`, `Controls`, `StatusNotice`; Stretch now is `Reminder.stretchNow`),
    Mick's voice (`LinePool`, `LineCatalog`, `Lines`, `Voice`, `SpokenTime`,
    `VoiceRules`: the line pools of §10.2, opener precedence, rotation without repeats,
    `{minutes}`/`{hours}` spelled out, and the voice rules every line is linted against),
    panel placement (`PanelPlacement`), the `state.json` and `config.json` models, the
    forgiving reader for hand-edited config (`ConfigFile`: one bad value only costs that
    value), the open-at-login status and its plain lines (`LoginItemStatus`,
    `LoginItemNote`), Mick's bell (`BellSound`, an original ding synthesized into a WAV,
    no sampled audio), and the simulation scripts (`SimulationScenario`).
  - `MickIO`: the Foundation layer around it. Mick's home directory, loading files with
    defaults and moving corrupted ones aside, the rotating `log.txt`, the `events.jsonl`
    tailer, the App Nap activity (`ActivityAssertion`), `reminders.jsonl`
    (`ReminderLog`), the bundled move catalogue and line pools
    (`Sources/MickIO/Resources/moves.json` and `lines.json`, package resources so the
    app and `swift test` read the same files), and `MickEngine`, the one
    object that owns state, feeds live events to the reminder, runs its one-shot timer
    and that the app observes, plus `Simulation`/`SimulationRun` (temporary homes and
    scenario playback).
  - Also in `MickIO`: `ConfigWatcher` (hand edits to `config.json` are picked up
    without a relaunch; the engine compares bytes, so its own saves don't count),
    `LoginItemController` over `SMAppService.mainApp` (`SystemLoginItem`) or an
    in-memory `RecordingLoginItem`, and `MickEngine.uninstall(loginItem:)`.
- Open at login only touches the real system login item on a normal launch with
  `MICK_HOME` unset. With `MICK_HOME` set (tests, simulation, `--smoke`) it's simulated
  in memory: a login item started by macOS wouldn't see `MICK_HOME` (§12), and tests
  must never register one. It's turned on once, on the launch that creates `~/.mick`.
- `Mick/Settings.swift`: the Settings window (§6.5). `Mick/Uninstall.swift`: Uninstall…
  (§13). `Mick/BellPlayer.swift`: plays the bell when a panel appears, if it's on.
- `Mick/ReminderPanel.swift`: the production reminder panel from the panel spike (#1):
  a non-activating `NSPanel` that never becomes key, shown with `orderFrontRegardless()`.

## Build and run

```sh
xcodebuild -project app/Mick.xcodeproj -scheme Mick -configuration Release \
  -derivedDataPath app/build/DerivedData build
```

The project signs ad hoc by default (with the hardened runtime in Release), so it builds
on any machine with no team set. To sign with your Apple Development certificate, pick
your team in Xcode or pass `CODE_SIGN_IDENTITY="<SHA-1 from security find-identity -p codesigning>"`.

Mick uses `~/.mick` unless `MICK_HOME` is set. `MICK_HOME` is for tests and simulation
only, and `open` doesn't pass it through, so run the binary directly to use one:

```sh
MICK_HOME=/tmp/mick-try app/build/DerivedData/Build/Products/Release/Mick.app/Contents/MacOS/Mick
```

## Simulation mode (debug builds only)

Every Debug build has a **Simulate (debug)** submenu in the status item's menu, and
accepts `--simulate [SCENARIO|all]`. Each scenario run gets its own fresh temporary
Mick home (`$TMPDIR/mick-simulate-*/NN-<scenario>`, never `~/.mick` or `MICK_HOME`),
already armed, with 1-minute thresholds and a 5-second show delay, and replays
scripted hook events into that home's `events.jsonl` against the real panel. The
scripts and their expectations are `SimulationScenario` in `MickCore`; `SimulationRun`
in `MickIO` plays one against an engine.

| Scenario | What you should see |
|---|---|
| `normal-run` | Panel 5 s after the prompt; closes within 2 s of the stop at 15 s |
| `short-run` | Stop at 3 s: nothing shown |
| `esc-interrupt` | No stop ever: the untouched panel closes 3 minutes after it appeared |
| `permission-pause` | A `wait` at 10 s while the panel is up: closes within 2 s |
| `three-sessions` | Three sessions, a re-prompt while visible, a prompt while settling: one reminder |
| `hand-off` | A stops before its check, B is running: the check and the panel move to B |
| `out-of-order` | A stop lands before its (older) prompt: session not running, nothing shown |

```sh
xcodebuild -project app/Mick.xcodeproj -scheme Mick -configuration Debug \
  -derivedDataPath app/build/DerivedData build
app/build/DerivedData/Build/Products/Debug/Mick.app/Contents/MacOS/Mick --simulate normal-run
```

A `--simulate` launch gives the app's own engine a temporary home too, and prints each
step and check (`PASS`/`FAIL`) to stdout; every run also logs to its home's `log.txt`.
Idle time is real by default, so the panel waits for a 3 s gap in your typing (the
manual focus test). Ticking items changes what a scenario expects, so its checks will
say FAIL; that's fine when you're poking at the panel. For unattended runs,
`--simulate-idle SECONDS` fixes the idle reading, `--simulate-exit` quits with 0/1 when
done, and `--simulate-via-menu` starts the scenario by choosing it in the menu. Release
builds reject all of these.

## Tests

```sh
(cd app/MickCore && swift test)   # unit and file-system tests, temporary MICK_HOME only
tests/app/smoke.sh                # builds the app and runs its --smoke self-check (needs a GUI session)
tests/hooks/test-hooks.sh         # the plugin's hook script
tests/app/simulate.sh             # Debug build: plays every simulation scenario in the real app (~4 min; MICK_SIM_SKIP_SLOW=1 skips the 3-minute one), checks Release has none
```

`Mick --smoke [--smoke-hook plugin/hooks/mick-event.sh]` runs inside the real app: it
checks the accessory policy, status item, menu, files and onboarding, then (with
`--smoke-hook`) fires a real hook event and checks that the warning clears and onboarding
shows its check mark within 2 s. It refuses to run without `MICK_HOME`.
`--smoke-reminder show-stop|short-run|tick-stays` (with `--smoke-hook`) runs one reminder
scenario with real hook events against an armed state that `smoke.sh` prepares: the panel
appears after the show delay without taking focus, closes within 2 s of a stop, never
appears for a short run, and stays after a stop once something is ticked.
`panel-snooze|stretch-now|menu-controls` cover snooze, pause and Stretch now: Snooze ▾ →
1 hour on the panel settles it as Snoozed; Stretch now from the menu shows a panel that
agent stops don't close; Pause, Resume and Snooze from the menu show Mick's line in the
status line and never move `sitting_since` (the scenario ends paused so `smoke.sh` can
check the pause survives a relaunch).
`--smoke-settings settings` opens Settings from the menu, changes values and checks
`config.json`, hand-edits the file (valid and invalid values) and checks Mick follows
without a relaunch, and drives the simulated login item through approval and an
error. `--smoke-settings uninstall` (with `--smoke-hook`) runs Uninstall… past its
confirmation, checks the folder is gone and the login item unregistered, fires a hook
to check it creates nothing, and quits through the uninstalled window. The bell is
muted in the smoke check; `smoke.sh` checks from `log.txt` that it rang once for a
panel with the sound on and never with it off.
Set `MICK_SMOKE_SNAPSHOT=/path/panel.png` to save a picture of the panel
(`MICK_SMOKE_SETTINGS_SNAPSHOT` and `MICK_SMOKE_UNINSTALL_SNAPSHOT` for those windows).
`--smoke-idle SECONDS` (smoke only) replaces the real idle reading with a fixed one, so
the sitting-timer scenarios in `smoke.sh` don't depend on whether someone is at the Mac.

## Mick's lines

`MickCore/Sources/MickIO/Resources/lines.json` maps each pool name (§10.2) to a list of
`{ "id", "text" }`. Ids key the rotation in `state.json` (`rotation.used_line_ids`), so
reword a line in place and add new ones with new ids. Opener pools need at least 8
lines and the others 5. Lines never hardcode a duration: write `{minutes} minutes` or
`{hours}` (which includes its unit) and Mick spells it out. `swift test` checks every
line against the voice rules (mild language, sitting-only insults, no pushing through
pain, no film names or quotes, no numbers or time units), but a person still has to
read new lines for originality and tone.
