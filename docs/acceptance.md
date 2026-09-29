# Mick v1 acceptance (SPEC §15)

Every §15 criterion, and how it's verified. `tests/acceptance/check-matrix.sh` keeps this
honest: it fails if a §15 bullet is missing here word for word, or if a test named here
doesn't exist.

How each one is verified:

- **Unit**: `swift test` in `app/MickCore`. Named as `Suite/test`. The `AcceptanceTests/acNN_…`
  tests walk criterion NN end to end through the engine, the real `events.jsonl` tailer and
  a temporary `MICK_HOME`.
- **Hook**: `tests/hooks/test-hooks.sh` (the real `mick-event.sh` against temporary homes).
  `tests/hooks/test-live-session.sh` repeats it with real `claude -p` sessions (opt-in; it
  makes two small API calls).
- **Smoke**: `tests/app/smoke.sh`, the built app's `--smoke` self-check with the real panel,
  status item and menu. `tests/app/release-check.sh` runs it again on the signed build.
- **Simulation**: `tests/app/simulate.sh`, the Debug build's `--simulate <scenario>` against
  the real panel.
- **Manual**: needs a person at the Mac. These are in the checklist at the bottom.

| # | Criterion | Verified by |
|---|---|---|
| 1 | The reminder panel never takes keyboard focus: typing continuously in Terminal while it appears loses no keystrokes. | **Manual** (focus test below). Smoke: panel can't become key or main, Mick has no key window, and Mick never becomes frontmost or active on show, click, snooze and close (another app coming forward on its own during the check is logged as INFO, not failed). Spike: `spikes/panel/typing-check.sh`. |
| 2 | Panel checkboxes respond to the first click without activating Mick. | Smoke: "content takes the first click without key", `tick-stays` clicks a checkbox and checks the panel isn't key, Mick isn't active and the frontmost app is unchanged. **Manual** with Full Keyboard Access on. |
| 3 | The panel appears over a fullscreen app. | **Manual** (fullscreen Space). Smoke checks what makes it work: `.statusBar` level, `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, accessory policy. |
| 4 | With the threshold set to 1 minute, a reminder appears on the next agent run lasting longer than the show delay. | Unit: `AcceptanceTests/ac04_oneMinuteThresholdShowsOnTheNextRunLongerThanTheDelay`, `ReminderTests/livePromptWhenArmedSchedulesACheckAfterTheShowDelay`. Simulation: `normal-run` (1-minute thresholds). Smoke: `show-stop`. |
| 5 | Agent runs shorter than the show delay never produce a reminder. | Unit: `AcceptanceTests/ac05_runsShorterThanTheDelayNeverShow`, `ReminderTests/runsShorterThanTheShowDelayNeverProduceAReminder`, `ReminderEngineTests/runShorterThanTheDelayNeverShows`. Simulation: `short-run`. Smoke: `short-run`. |
| 6 | With nothing ticked, the panel closes within 2 seconds of the agent finishing, failing on an API error, or asking for tool permission, including after 30+ minutes with no Mick windows visible (App Nap). For MCP elicitation dialogs, Claude Code itself reports the dialog about 6 s late, so the panel closes within 2 s of that report. | Unit: `AcceptanceTests/ac06_untouchedPanelClosesWithinTwoSecondsOfStopFailureOrPermission` (real clock and timer, real hook script fed `Stop`, `StopFailure`, `PermissionRequest` and elicitation `Notification` payloads), `ReminderEngineTests/realTimerShowsAndAStopClosesWithinTwoSeconds`, `ReminderEngineTests/realActivityAssertionUsesTheSpecOptions`. Hook: `StopFailure -> stop`, `PermissionRequest -> wait`, the `Notification` matcher. Simulation: `permission-pause`. **Manual**: the 30-minute App Nap case. |
| 7 | A run whose `stop` event lands before its `prompt` event (async ordering) leaves the session not running. | Unit: `AcceptanceTests/ac07_stopLandingBeforeItsPromptLeavesTheSessionNotRunning`, `SessionBookTests/aPromptLandingAfterItsOwnStopIsDropped`. Simulation: `out-of-order`. |
| 8 | After an Esc interrupt during the show delay, a panel that does appear closes after 3 minutes untouched. | Unit: `AcceptanceTests/ac08_escDuringTheDelayPanelClosesAfterThreeMinutesUntouched`, `ReminderTests/untouchedClosesAfterThreeMinutes`, `SimulationTests/escInterruptClosesAfterThreeMinutesUntouched`. Simulation: `esc-interrupt`. |
| 9 | The panel never appears while you're typing; it waits for a 3 s input gap. | Unit: `AcceptanceTests/ac09_waitsForAThreeSecondInputGap`, `ReminderTests/waitsForAThreeSecondInputGap`, `ReminderTests/givesUpAfterThirtySecondsWithoutAGapWithNoPenalty`, `SimulationTests/typingThroughoutFailsTheShowExpectations`. **Manual**: part of the focus test. |
| 10 | A reminder that's waiting to settle blocks new reminders: a prompt 1 minute after an auto-dismissed panel never schedules another. | Unit: `AcceptanceTests/ac10_aPromptAMinuteAfterAnAutoDismissNeverSchedules`, `OutcomeTests/aPromptWhileSettlingNeverSchedulesAnother`, `OutcomeEngineTests/anAutoDismissedReminderSettlesAsIgnoredSavesAndLogsOneLine`. Simulation: `three-sessions`. |
| 11 | If the session a check was scheduled for stops early while another session is running, the check is handed to the running session. | Unit: `AcceptanceTests/ac11_anEarlyStopHandsTheCheckToTheRunningSession`, `ReminderTests/stoppedSessionHandsItsCheckToTheMostRecentlyStartedRunningSession`, `SimulationTests/earlyStopHandsTheCheckToTheRunningSession`. Simulation: `hand-off`. |
| 12 | With one item ticked, the panel stays after the agent finishes, and closes 2 minutes after the last tick. | Unit: `AcceptanceTests/ac12_oneTickKeepsThePanelUntilTwoMinutesAfterTheLastTick`, `ReminderTests/withATickItStaysAfterTheAgentStopsUntilTwoMinutesAfterTheLastTick`. Smoke: `tick-stays`. |
| 13 | Three concurrent sessions never produce more than one reminder at once. | Unit: `AcceptanceTests/ac13_threeConcurrentSessionsNeverShowTwoAtOnce`, `ReminderTests/threeConcurrentSessionsNeverProduceMoreThanOneReminder`, `ReminderEngineTests/handOffAndOneReminderAcrossThreeSessions`. Simulation: `three-sessions`. |
| 14 | After an Esc interrupt, the session's next prompt behaves normally. | Unit: `AcceptanceTests/ac14_afterAnEscTheNextPromptBehavesNormally`, `SessionBookTests/rePromptResetsTheRunStart`, `ReminderTests/aSecondPromptOnTheSameSessionReschedules`. |
| 15 | Being idle for 5+ minutes, sleeping the Mac for 5+ minutes, or having Mick quit for 5+ minutes resets the sitting timer. | Unit: `AcceptanceTests/ac15_idleSleepOrQuitForFiveMinutesResetsSitting`, `SittingTimerIdleTests/idleAtTheBreakResetMovesSittingSinceToNow`, `SittingTimerSignalTests/sleepingForTheBreakResetResetsToTheWakeTime`, `SittingTimerSignalTests/quittingForTheBreakResetResetsOnRelaunch`, `SittingEngineTests/relaunchAfterTheBreakResetResetsSittingTime`. Smoke: the sitting-timer relaunch scenarios. **Manual**: a real sleep. |
| 16 | Snooze and pause never reset the sitting timer. | Unit: `AcceptanceTests/ac16_snoozeAndPauseNeverResetSitting`, `ControlsTests/controlsNeverResetTheSittingTimer`, `ControlsEngineTests/pausePersistsAcrossRelaunchAndNeverResetsSitting`. Smoke: `menu-controls`, `panel-snooze`. |
| 17 | Coming back from a 40-minute break shows sitting time near zero, not 35 minutes. | Unit: `AcceptanceTests/ac17_aFortyMinuteBreakLeavesSittingNearZero`, `SittingTimerIdleTests/aFortyMinuteBreakLeavesSittingTimeNearZero`, `SittingEngineTests/pollingThroughAFortyMinuteBreak`. |
| 18 | An ignored reminder brings the next one about 25 minutes later with an `opener_ignored_*` line; a completed one waits the full threshold. | Unit: `AcceptanceTests/ac18_ignoredComesBackInTwentyFiveMinutesCompletedWaitsTheThreshold`, `OutcomeTests/ignoredComesBackAboutTwentyFiveMinutesLaterCompletedWaitsTheFullThreshold`, `VoiceEngineTests/theOpenerFollowsPrecedence`. |
| 19 | Ignoring a reminder never lowers the displayed sitting time; ignoring repeatedly still reaches the glaring icon and the long-sit routine. | Unit: `AcceptanceTests/ac19_repeatedIgnoresReachGlaringAndTheLongSitWalk`, `OutcomeTests/ignoringNeverLowersSittingTimeAndRepeatedIgnoresStillReachGlaring`, `OutcomeTests/settlingNeverMovesSittingSinceBackwards`. |
| 20 | Nothing ticked but idle >= 60 s counts as Stood up, not Ignored. | Unit: `AcceptanceTests/ac20_nothingTickedButAMinuteIdleIsStoodUp`, `OutcomeTests/aMinuteOfIdleAfterTheCloseCountsAsStoodUp`, `OutcomeEngineTests/standingUpWithoutTickingCountsAsStoodUp`. |
| 21 | Mick's memory resets at local midnight. | Unit: `AcceptanceTests/ac21_memoryResetsAtLocalMidnight`, `OutcomeTests/ignoredTodayResetsAtLocalMidnight`, `OutcomeTests/midnightFollowsTheLocalTimeZone`, `OutcomeEngineTests/midnightRollsTheCountOverOnLaunchAndOnPolls`. |
| 22 | Sitting for 2× the threshold produces the long-sit routine with a walk. | Unit: `AcceptanceTests/ac22_twiceTheThresholdIsTheLongSitRoutineWithAWalk`, `RoutineCompositionTests/longSitIsStandUpPlusWalkPlusOneMove`, `RoutineEngineTests/aLongSitGetsTheWalk`. |
| 23 | No routine contains two moves from the same area. | Unit: `AcceptanceTests/ac23_noRoutineHasTwoMovesFromTheSameArea`, `RoutineCompositionTests/normalIsStandUpPlusTwoMovesFromDifferentAreas`, `RoutineCompositionTests/theAreaRuleRelaxesWhenNothingIsLeft`. |
| 24 | Hooks are async (except `SessionEnd`), never print, always exit 0 (including with jq missing or `~/.mick` unwritable), and never write prompt text or agent output. | Hook: `hooks.json` async flags and exec form, "printed nothing" and "exit 0" for every event, jq missing or not executable, unwritable home, malformed payloads, "no payload content in file", 200 concurrent writers. Unit: `AcceptanceTests/ac06_untouchedPanelClosesWithinTwoSecondsOfStopFailureOrPermission` (no payload text in `events.jsonl`). Live (opt-in): `tests/hooks/test-live-session.sh`. |
| 25 | Hooks never create `~/.mick`; with the directory absent they write nothing. | Hook: "home absent: nothing created", "default home absent: ~/.mick not created". Unit: `SettingsEngineTests/hookAfterUninstallCreatesNothing`. Smoke: `uninstall` (hooks after uninstall recreate nothing). |
| 26 | Events written while Mick isn't running never trigger a reminder at launch. | Unit: `AcceptanceTests/ac26_eventsWrittenWhileQuitNeverTriggerAtLaunch`, `ReminderEngineTests/backlogPromptAtLaunchNeverTriggers`, `ReminderTests/backlogPromptNeverSchedules`, `SessionBookTests/recentBacklogUpdatesBookkeepingButNeverTriggers`. |
| 27 | Corrupted state, config or event lines never crash the app; they're reset or skipped and logged. | Unit: `AcceptanceTests/ac27_corruptedStateConfigAndEventLinesAreResetOrSkippedAndLogged`, `MickEngineTests/corruptedStateAndConfigAreMovedAsideAndLogged`, `JSONFileStoreTests/corruptStateIsMovedAsideTwiceWithoutClobbering`, `EventParsingTests/rejectsMalformedLines`, `SettingsEngineTests/launchStillMovesACorruptFileAside`. Smoke: corrupted files at launch. |
| 28 | Uninstall leaves nothing behind except the plugin, which onboarding tells you how to remove. | Unit: `SettingsEngineTests/uninstallRemovesEverythingAndUnregisters`, `SettingsEngineTests/hookAfterUninstallCreatesNothing`. Smoke: `uninstall` (folder gone, login item unregistered, shows `/plugin uninstall mick@mick`, quits, nothing left next to it). |

## Issue #13: daily-use readiness

| Item | Verified by |
|---|---|
| Built with the Apple Development certificate and hardened runtime, unsandboxed | `tests/app/release-check.sh`: `scripts/install.sh` into a scratch folder, then `codesign --verify --strict`, `Authority=Apple Development`, a team identifier, the `runtime` flag, no `app-sandbox` and no `get-task-allow` entitlement, `LSUIElement`, macOS 26 minimum, and the whole smoke check run on that signed build. |
| Sits in /Applications, opens at login | `scripts/install.sh` (default destination `/Applications`). Open at login defaults to on at first launch: `SettingsEngineTests/openAtLoginIsOnByDefaultOnFirstLaunchOnly`. **Manual**: the real install and the Login Items entry. |
| Plugin installed from the marketplace | `claude plugin validate .` and `./plugin` in `release-check.sh`; install id `mick@mick` checked against `marketplace.json`. **Manual**: the real `/plugin install`. |
| README: install steps and "not medical advice; skip anything that hurts" | `tests/acceptance/check-matrix.sh` checks `README.md` for both commands, `scripts/install.sh` and the line. |
| The reminder log is being written | Unit: `OutcomeEngineTests/anAutoDismissedReminderSettlesAsIgnoredSavesAndLogsOneLine` (every field of §12.3, mode 0600), `AcceptanceTests/ac18_ignoredComesBackInTwentyFiveMinutesCompletedWaitsTheThreshold`. Smoke: `reminders.jsonl records the panel snooze`. `scripts/review.sh` reads it for the two-week review (`tests/scripts/test-review.sh`). **Manual**: check `~/.mick/reminders.jsonl` grows during the first real days. |

## Manual checklist

For a person at the Mac, after `scripts/install.sh`. None of these can be done unattended.

- [ ] **Focus test** (criteria 1, 9): run `app/build/DerivedData/Build/Products/Debug/Mick.app/Contents/MacOS/Mick --simulate normal-run`, then type continuously in Terminal (for example, hold a key in `cat > /dev/null`). The panel waits for a pause in typing, then appears; Terminal keeps focus and no keystroke goes missing.
- [ ] Click a checkbox and the Snooze ▾ menu on the panel while Terminal is frontmost: the first click works and Terminal keeps focus. Repeat with Full Keyboard Access on (System Settings → Keyboard).
- [ ] Put an app in fullscreen and run `--simulate normal-run`: the panel appears over it.
- [ ] Multiple displays: the panel appears under the status item on the display with the menu bar.
- [ ] Status item pushed into notch overflow (many menu bar items): the panel goes top-right of the active screen.
- [ ] App Nap: leave Mick with no windows for 30+ minutes, then run an agent past the show delay and let it finish: the panel closes within 2 s.
- [ ] Sleep the Mac for 5+ minutes with Mick running: sitting time restarts.
- [ ] Launch `/Applications/Mick.app` from Finder: no Input Monitoring or Accessibility prompt, and Mick isn't listed under either in Privacy & Security.
- [ ] Onboarding: the two plugin commands copy correctly; run them in Claude Code (`/plugin marketplace add eltaiguer/mick`, `/plugin install mick@mick`) and the "waiting for your first prompt" step turns into a check mark.
- [ ] Open at login: Mick appears in System Settings → General → Login Items, and is running after a restart.
- [ ] Turn the bell on in Settings and listen to it once a panel appears.
- [ ] Read a day's worth of Mick's lines in the panel and menu for tone.
- [ ] After a day, `scripts/review.sh` shows reminders in `~/.mick/reminders.jsonl`. After two weeks, review it: most shown reminders should be Completed, Partial or Stood up.
