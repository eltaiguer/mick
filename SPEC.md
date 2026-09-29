# Spec: Mick, a menu bar corner man for the agent era (v1)

Mick is a macOS menu bar app. When you've been sitting too long and you hand work to a Claude Code agent, Mick shows up with a short stretch routine and the personality of Mickey Goldmill, Rocky's trainer: gruff, impatient, insulting, and completely in your corner.

Name: `Mick` (app), `~/.mick/` (data), `MICK_HOME` (override). Standalone project, not part of the Seta tool family.

---

## 1. Product context

### The story

Working from home, it's easy to get carried away. You sit down, open a few Claude Code sessions, and suddenly three hours have passed without standing up once. Your back is the first to let you know.

At the same time, the way we work has changed. A big part of the day now is prompting an agent and then waiting while it reads files, runs tests, and writes code. Those gaps are real, they happen dozens of times a day, and today they mostly go to watching the terminal scroll or checking Slack.

Mick connects those two things. The moment you hand work to an agent is the best possible moment to stand up and stretch. You're not in the middle of a thought, you're not typing, and the agent keeps working while you move. When it's done, you come back to results.

And instead of a polite wellness app you learn to ignore, you get an old boxing trainer yelling at you to get off your can.

### Who it's for

- Developers who work with AI coding agents for most of the day, especially remote and from home.
- People who have tried break reminder apps and turned them off because they interrupted at the worst moments, or were too polite to take seriously.
- First user: Jose. v1 is built and run locally for daily personal use. Public distribution comes later (§17).

### Why this and not an existing break app

Break reminders already exist (Stretchly, Time Out, and others). They run on a fixed timer and fire whenever the timer ends, which usually means mid-flow. That's why people disable them.

The difference here is timing, plus personality. Mick only shows up when two things are true: you've been sitting for a long time, and an agent just started working. It uses the natural pause in agent-era work instead of creating a new interruption. And when it does show up, it's funny enough that you don't mind.

### How we see it (positioning)

- **Personal tool first.** Solve a real problem for ourselves and use it for a couple of weeks.
- **Free and open source (MIT).**
- **A good story.** It shows how agent-era work actually feels, and that tools should take care of the humans using them, not just the output. The launch post writes itself if it works.

### Product principles

1. **Never interrupt flow.** Only show up at the start of an agent run, never while the person is actively working. No agent run, no reminder, however long you've been sitting. Showing a reminder never steals keyboard focus.
2. **Stand up, move, stretch.** Every reminder is a short routine: stand up first, then 2 moves. About 60 to 90 seconds. Instructions are specific ("hands on your lower back, lean back, 20s"), never "take a break."
3. **Gets out of the way.** If you haven't started the routine when the agent finishes, the reminder disappears on its own. If you have, it waits for you to finish.
4. **Full Mickey, no scoreboard.** Mick insults you, remembers when you ignored him today, and lets you have it. But there are no streaks, no scores, and no history in the UI. Every day starts clean. Snoozing and pausing are always one click away.
5. **Invisible to Claude Code.** It must never slow down, break, or change how Claude Code behaves, and never add anything to Claude's context.
6. **Private.** Everything stays local. No accounts, no network, no telemetry. Prompts and agent output are never read or stored.

### Mick's voice

Mick is Mickey Goldmill's personality: a gravelly old trainer who's seen it all. Short sentences. Bossy. Impatient. Calls you "kid" and "ya bum." Occasionally yells in capitals. Underneath it, he wants you to make it.

Rules for every line Mick says:

- **Original writing only.** Written in his style, never quoted from the films. No film stills, likeness, logos or artwork anywhere in the app or repo.
- **He insults sitting and laziness, nothing else.** Never your body, appearance, weight, health, age, or identity. No slurs.
- **Mild language only.** "Bum", "crap", "damn" are fine. Nothing stronger; this is a public repo.
- **He never says push through pain.** The move instructions stay plain and gentle, and the README keeps the line: these are general suggestions, not medical advice; skip anything that hurts.
- **Plain voice for problems.** Errors, setup steps and permission problems are written plainly so they're clear. Mick can add a line after, but the instruction comes first.

Where the voice appears: the reminder panel, the menu bar dropdown's status line, snooze/pause/resume confirmations, and onboarding. Menu item labels themselves stay plain ("Snooze 1 hour") so they're easy to scan.

### How we'll know it works

- After two weeks of daily use, Jose is still running it and hasn't turned it off.
- Most shown reminders end as Completed, Partial or Stood up (not Ignored), according to the local reminder log (§12.3).
- It never once takes focus mid-typing or slows down an agent session.
- Fewer end-of-day back complaints.
- Mick still gets a laugh in week two (§10.2 exists to make this true).

---

## 2. Summary

A native macOS menu bar app plus a tiny Claude Code plugin. The plugin's hooks append one line per agent event to a local file. The app watches that file, tracks how long you've been sitting from system idle time, and when you're past the threshold and an agent run is underway, drops a small non-activating panel under the menu bar icon with a 3-item checklist and a line from Mick. The panel goes away when the agent finishes if you ignored it, or stays until you finish if you started.

## 3. Goals

- Reduce long unbroken sitting sessions during agent-heavy work.
- Show up only at natural pauses (agent running), never mid-typing, never taking focus.
- Be funny enough that you keep it on.
- Must never slow down, break, or change the behavior of Claude Code.
- Setup: two installs (the app and the Claude Code plugin). In v1 the app is built from source (§13).

## 4. Non-goals (v1)

- No Windows or Linux support. macOS 26 only.
- No agents other than Claude Code (the event file format leaves room, §6.2).
- No fallback reminder when no agent is running.
- No macOS notification-style reminders; the panel is the only surface (unless the spike in §9.3 fails for fullscreen).
- No time-of-day awareness in routine selection.
- No streaks, scores, totals, or history in the UI. No analytics or telemetry.
- No hold timers or countdowns; you tick when you're done.
- No character portrait in v1.
- No health or medical claims.
- No notarized distribution yet.

## 5. User experience

1. You work normally. Mick sits in the menu bar with a calm icon and tracks how long you've been sitting.
2. After 50 minutes of continuous sitting, the icon changes to "armed."
3. The next time you submit a prompt to Claude Code, Mick waits 30 seconds. If that agent run is still going (and you're not mid-keystroke, §7), a small panel drops down under the menu bar icon:

   ```
   ┌───────────────────────────────────────────┐
   │  On your feet, ya bum. The robot's doin'  │
   │  your job, now you do mine.               │
   │                                           │
   │  ☐ Stand up                               │
   │  ☐ Back bend: hands on your lower back,   │
   │    lean back gently. 20s                  │
   │  ☐ Shoulder rolls: roll back slowly. ×10  │
   │                                           │
   │  [Not now]                    [Snooze ▾]  │
   └───────────────────────────────────────────┘
   ```

   The panel never takes keyboard focus. If you're typing in another window, your keystrokes stay there.
4. You tick items as you do them. Tick all three and Mick gives you a line ("That's it. Wasn't so hard, was it?"), then the panel closes after a few seconds.
5. If the agent finishes (or stops to ask for permission) and you haven't ticked anything, the panel disappears. An untouched panel also disappears after 3 minutes on its own. If you've ticked at least one item, it stays until you finish, close it, or leave it alone for 2 minutes.
6. If the agent finished within the 30 second delay, nothing is shown and Mick stays armed for the next run.
7. If you ignored him, Mick remembers for the rest of the day. The next reminder comes sooner (25 minutes later instead of waiting for a fresh 50) and opens with a meaner line. Midnight wipes the slate.
8. If you've been sitting for twice the threshold (100+ minutes), the routine includes a walk.
9. The dropdown shows how long you've been sitting (in Mick's words), and lets you stretch now, snooze, pause, or open settings.

## 6. Architecture

Two pieces: a Claude Code plugin that only records events, and the Mick app that does everything else. There's no sampler process, no lock file, and no Node: the app is a single long-running process that owns all state.

```
Claude Code ──hooks──▶ events.jsonl ──file watch──▶ Mick.app ──▶ reminder panel
                                                       ▲
                               system idle time, sleep/wake
```

### 6.1 Claude Code plugin (hooks only)

Each hook runs one small script, `mick-event.sh <event>`, which appends one compact JSON line to `${MICK_HOME:-$HOME/.mick}/events.jsonl` using `/usr/bin/jq` (ships with macOS since 15; `jq-1.7.1-apple` on macOS 26), then exits 0.

| Claude Code hook | `e` written | Why |
|---|---|---|
| `UserPromptSubmit` | `prompt` | An agent run starts |
| `Stop` | `stop` | The run finished. Doesn't fire on an Esc interrupt |
| `StopFailure` | `stop` | Fires *instead of* `Stop` when the turn ends on an API error (rate limit, overload, auth…) |
| `PermissionRequest` | `wait` | The agent is about to ask for tool permission. Fires immediately |
| `Notification`, matcher `permission_prompt\|elicitation_dialog\|elicitation_url_dialog` | `wait` | Permission prompts `PermissionRequest` doesn't cover (sandbox network requests), and MCP elicitation dialogs |
| `SessionEnd` | `end` | The session is gone |

Notification types left out on purpose:

- `idle_prompt` fires about 60 s after `Stop`, so it adds nothing.
- `agent_needs_input` and `agent_completed` describe *other* background sessions (agent view, agent teams). Treating them as `wait` or `stop` for the reporting session would close the wrong panel.

The `permission_prompt` and elicitation notifications only fire once you haven't typed for about 6 s, and each keystroke defers them. That's why `PermissionRequest` is the main permission signal.

`plugin/hooks/hooks.json` (top-level `hooks` key; exec form, so no `sh -c` in between). Every hook except `SessionEnd` is `"async": true`, so Claude Code never waits on it: async hooks can't block or influence Claude, and since the script prints nothing, nothing reaches Claude's context. `SessionEnd` stays synchronous, because Claude Code kills async hooks at teardown in `-p` mode and all `SessionEnd` hooks share a 1.5 s budget.

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/mick-event.sh", "args": ["prompt"], "async": true }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/mick-event.sh", "args": ["stop"],   "async": true }] }],
    "StopFailure":      [{ "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/mick-event.sh", "args": ["stop"],   "async": true }] }],
    "PermissionRequest":[{ "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/mick-event.sh", "args": ["wait"],   "async": true }] }],
    "Notification":     [{ "matcher": "permission_prompt|elicitation_dialog|elicitation_url_dialog",
                           "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/mick-event.sh", "args": ["wait"],   "async": true }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/mick-event.sh", "args": ["end"] }] }]
  }
}
```

The script (committed executable):

```sh
#!/bin/sh
# mick-event.sh <prompt|stop|wait|end>; hook payload on stdin.
exec >/dev/null 2>/dev/null
d="${MICK_HOME:-$HOME/.mick}"
[ -d "$d" ] || exit 0          # the app creates the directory; no app, no writes
umask 077
"${MICK_JQ:-/usr/bin/jq}" -c --arg e "$1" \
  '{e:$e, t:now, s:.session_id, c:.cwd, n:(.notification_type // null)}' \
  >> "$d/events.jsonl"
exit 0
```

The hook never creates `~/.mick`. The app creates it on first launch, so once the app is uninstalled (and the directory deleted) the hooks are no-ops even if the plugin is still installed. `MICK_JQ` exists only so the hook tests can simulate a missing jq (§16).

Hooks MUST:

- **select only** `session_id`, `cwd` and `notification_type`, plus the event name and a timestamp. Several payloads carry content that is never written anywhere: the prompt text (`prompt` on `UserPromptSubmit`), the agent's last message (`last_assistant_message` on `Stop` and `StopFailure`), and the tool call (`tool_input` on `PermissionRequest`).
- finish quickly. Measured on macOS 26.6: 25–90 ms warm, about 0.9 s on a cold first run. `async` keeps even the cold case off Claude's critical path; the sync `SessionEnd` hook stays well inside its 1.5 s budget.
- always exit 0, even if jq is missing, the payload is malformed or the directory is unwritable
- print nothing to stdout or stderr (a `UserPromptSubmit` hook's stdout would be added to Claude's context)
- never wait on the app. If Mick isn't running, events just accumulate.

Each event is a single short line written with one `write` in append mode, so concurrent hooks from several sessions don't interleave (tested: 200 concurrent writers, 200 intact lines). The file is created with mode `0600`.

Because the hooks are async, a session's events can land slightly out of order, for example a fast run's `stop` before its `prompt`. The app handles this (§6.3).

Hooks run with Claude Code's environment (hooks reference: "Handlers run … with Claude Code's environment"), so `MICK_HOME` set in the shell that launched `claude` reaches them (§12).

The event format is deliberately simple so other agents can be supported later by anything that appends the same line.

Known and accepted: headless runs (`claude -p`, or tools that spawn Claude Code) fire the same hooks and count as agent runs.

### 6.2 Event format

```json
{"e":"prompt","t":1790000000.123,"s":"<session_id>","c":"/Users/.../project","n":null}
```

- `e`: `prompt` | `stop` | `wait` | `end`
- `t`: Unix time in seconds (float), taken when the hook runs
- `s`: session id; `c`: working directory; `n`: `notification_type` for `wait` events from `Notification`, else `null` (diagnostics only)

### 6.3 Mick app

A SwiftUI app running as a menu bar agent (`LSUIElement`, no Dock icon), with the logic in a separate pure Swift package, `MickCore` (§14).

**Event intake**

- On launch, creates `MICK_HOME` (mode `0700`) if it doesn't exist.
- Watches `events.jsonl` for writes and reads new lines from its last offset. A `stop` must be handled fast enough that the panel closes within 2 seconds of the agent finishing.
- Watch mechanics: a vnode source on the file for writes, plus a watch on the directory so the app notices when the file is first created or recreated after rotation. On rename or delete of the watched file, the app reopens `events.jsonl`. If the saved offset is larger than the file (truncated or replaced externally), it resets to 0.
- Rotation: when the file passes 256 KB and everything has been read, the app renames it to `events.jsonl.old`. New hook writes create a fresh `events.jsonl`. After 2 seconds the app reads anything left in `.old` (from a hook that opened it just before the rename), then deletes it.
- App Nap: Apple's App Nap criteria (not frontmost, no recent visible drawing, no activity assertion) fit a windowless accessory app, and napping throttles timers, CPU priority and I/O. The app holds a `ProcessInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason:)` activity while any session is running, a check is scheduled, or a panel is visible or waiting to settle. It ends the activity otherwise, because Apple warns that holding one for long periods hurts energy use. The returned token is retained, since the activity ends if it's deallocated. It does **not** use `.latencyCritical`, which Apple reserves for audio and video recording. (Signals spike: in a 34-minute unattended run neither the copy with the activity nor the one without showed any napping, so the activity stays as a precaution and the real comparison is on the manual checklist.)
- Timers: the show-delay check, the untouched and after-tick timeouts, and the 10-minute cap use a `Timer` with zero tolerance (or a `DispatchSourceTimer` with a small explicit leeway), never `DispatchQueue.main.asyncAfter`. The signals spike measured `asyncAfter` firing about 5% of the delay late (1.5 s on a 30 s delay).
- Backlog on launch: events that arrived while Mick wasn't running update session bookkeeping (running / not running) if they're less than 2 hours old. A backlog `prompt` event never triggers a reminder; only events seen live can.
- Ordering: async hooks can land out of order. An event is applied only if its `t` is newer than the last applied `t` for that session; older ones are dropped. So a `prompt` that lands after its own `stop` doesn't mark the session running again.

**Event handling**

- `prompt`: mark the session running and record the run start. If the trigger conditions pass (§7), schedule a check in `show_delay_seconds` for this session.
- `prompt` for a session that's already marked running (a queued message mid-run, or a new prompt after an Esc interrupt): the run start is reset to this prompt. If a check is scheduled for this session, it's rescheduled to `show_delay_seconds` from now. A visible panel is left alone.
- `stop`: mark the session not running. If the scheduled check belongs to this session, cancel it and hand it off (below). If the visible panel belongs to this session, apply the auto-dismiss rules (§9.2).
- `wait` (the agent is waiting on you: a permission request or an MCP dialog): handled exactly like `stop`. After you approve, the agent carries on with no new event, so Mick treats the rest of that run as not running. That's accepted: the reminder is aimed at the start of a run, not the middle.
- `end`: handled like `stop`, and the session is marked ended. It's kept, not running, until the 2-hour prune, so a late async `prompt` with an older `t` can't bring it back as running.
- Hand-off: when a check is cancelled because its session stopped, and another session is still running, a new check is scheduled for the running session that started most recently, at `max(now, its run_started_at + show_delay_seconds)`. The trigger conditions (§7) are evaluated again.
- An Esc interrupt fires no hook, so the session stays marked running. The show-time input-gap check (§7) and the untouched-panel timeout (§9.2) limit the damage. The next `prompt` for that session resets its run state, and sessions marked running with no event for 2 hours are pruned.

**Sitting timer**

- Polls system idle time every 30 seconds (every 5 seconds during a reminder's follow-up window, §8).
- Idle time >= `break_reset_minutes` (default 5) means you're on a break. On every poll where that's true, `sitting_since` is set to now, so it keeps moving forward for as long as you're away and sitting time restarts from (roughly) the moment you come back.
- Sleep: on wake, if the Mac slept for >= `break_reset_minutes`, reset `sitting_since` to the wake time.
- Quitting and relaunching: `state.json` records `last_active_at = now - idle` (the last time you actually touched the Mac) every poll. On launch, if `now - last_active_at >= break_reset_minutes`, reset `sitting_since` to now.
- Known and accepted: idle time only counts keyboard and mouse input, so watching an agent without touching anything for 5+ minutes counts as a break. People often leave the Mac unlocked while agents run and they're away, which rules out lock state as a better signal.
- Fast user switching: if the session goes inactive (`sessionDidResignActive`) and becomes active again (`sessionDidBecomeActive`) after >= `break_reset_minutes`, reset `sitting_since`.
- **APIs:**
  - Idle time: `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)`, where `~0` means "any input" (`kCGAnyInputEventType` isn't bridged to Swift). It's public and not deprecated (macOS 10.4+), and the `CGEventTypes.h` header documents `kCGAnyInputEventType` as the way to get "the elapsed time since the previous input event". `CGEventType(rawValue: ~0)!` compiles and works under Swift 6.2. Apple doesn't document any permission requirement. Non-Apple sources (ActivityWatch, which relies on it; published research) report it needs no Input Monitoring or Accessibility permission, unlike event taps and `IOHIDManager`. Not IOKit `HIDIdleTime`: its meaning is unpublished and has changed between macOS releases.
  - Sleep/wake and fast user switching: `NSWorkspace.WillSleepMessage`, `DidWakeMessage`, `SessionDidResignActiveMessage` and `SessionDidBecomeActiveMessage` (macOS 26, `NotificationCenter.MainActorMessage`). They're delivered synchronously on whichever thread posts them, and a post from a background thread traps. They're on the main actor only because AppKit posts them from the main thread (signals spike). They must be observed on `NSWorkspace.shared.notificationCenter`; Apple: "If you use a different notification center to register, you won't receive the notification." Form: `NSWorkspace.shared.notificationCenter.addObserver(of: NSWorkspace.shared, for: .willSleep) { _ in … }`. The returned token must be kept.
  - Covered by the spike (§9.3): idle time works with no permission prompt, and sleep/wake messages arrive correctly under strict concurrency.

### 6.4 Menu bar

**Icon states.** An original glyph (a boxing glove), no film imagery.

| State | When |
|---|---|
| Calm | Not armed |
| Armed | Sitting >= threshold and `now >= nag_after` (§7) |
| Glaring | Armed and sitting >= 2× threshold |
| Snoozed | Snoozed |
| Paused | Paused, or inside quiet hours |
| Warning | Hooks not detected yet, or no event received in 7 days |

When several apply, the icon shows the first of: Warning, Paused, Snoozed, Glaring, Armed, Calm.

**Dropdown**

```
  Forty-seven minutes on your can, kid.      ← Mick status line (voice)
  Sitting 47m · reminder at 50m              ← plain detail line
  ─────────────
  Stretch now
  Snooze                    ▸ 30 minutes / 1 hour / 2 hours / Until tomorrow (06:00)
  Pause  (Resume when paused)
  ─────────────
  Settings…
  Quit Mick
```

If hooks aren't detected, a plain line at the top replaces the status: "Claude Code hooks not detected. Set up…", which opens onboarding. After 7 days with no events it reads "No Claude Code events in 7 days. Set up…" instead, so it doesn't claim the hooks were never seen.

"Until tomorrow" snoozes until the next 06:00 local time (so choosing it at 01:00 means 06:00 the same day). "Reminder at" in the detail line is the time you'll be armed: the later of `sitting_since + threshold` and `nag_after`. Once that time has passed, the detail line reads "Sitting 55m · reminder armed". "Stretch now" is disabled while a reminder is scheduled, visible, or waiting to settle.

Resume ends a pause or a snooze. While snoozed, the Snooze submenu also shows "Snoozed until HH:MM" and "Cancel snooze". Snoozing from the menu while a panel is visible settles it as Snoozed, the same as the panel's own Snooze.

Snooze, pause and resume show a line from the `snooze`, `pause` or `resume` pool (§10.2) in the status line for 60 s. Choosing a menu item closes the dropdown, so the line is there when you reopen it. None of them reset the sitting timer. While snoozed, paused or in the warning state, the status line uses the `status_calm` pool, because the armed and glaring lines promise a reminder that won't come.

### 6.5 Settings window

- Sit threshold (default 50 min)
- Show delay (default 30 s)
- Break reset (default 5 min)
- Quiet hours (off, or start/end times; may cross midnight)
- Bell sound when the panel appears (default off; original sound, a boxing-bell style ding)
- Open at login (default on, via `SMAppService.mainApp.register()`, macOS 13+; requires a code-signed app). If `status` is `.requiresApproval`, the toggle shows a plain line pointing to System Settings → General → Login Items. Registration errors (for example `kSMErrorLaunchDeniedByUser`) are shown plainly and logged. "On by default" means it's turned on once, on the launch that creates `~/.mick`, so it never overrides a choice made later in System Settings. A non-default home (tests, simulation) never touches the real login item.
- Uninstall… (§13)

### 6.6 Onboarding

Shown at every launch until hooks are first detected, and from the warning state. It comes to the front only on the launch that creates `~/.mick`, so a login-item launch doesn't take focus:

1. What Mick does, in two sentences, with a Mick line.
2. Install the Claude Code plugin: the two commands, each with a copy button.
3. "Waiting for your first Claude Code prompt…" This turns into a check mark when the first event arrives.
4. Open at login toggle.

## 7. Trigger logic

On a live `prompt` event, schedule a check only if ALL are true:

- `now - sitting_since >= sit_threshold_minutes`
- `now >= nag_after` (set only by an Ignored reminder, §8; `null` passes)
- not snoozed, not paused, outside quiet hours
- no reminder is scheduled, visible, or waiting to settle (globally, across all sessions)

After `show_delay_seconds`, show the panel only if ALL are still true:

- this session is still running and hasn't paused for input since the prompt
- still not snoozed, paused or in quiet hours
- nothing else is visible or waiting to settle
- you're not mid-keystroke: system idle >= 3 s. If not, re-check every second until it is. If 30 s pass without a gap, drop the check with no penalty (Mick stays armed). If the session stops first, the check is cancelled and handed off like any other (§6.3, decision 34).

There is no separate cooldown. After a reminder settles, either `sitting_since` moves to the settle time or `nag_after` is set (§8), and that guarantees spacing between reminders. `sitting_since` always reflects real sitting time; it's never backdated.

## 8. Reminder outcomes and Mick's memory

Each reminder is settled at the later of: the panel closing, or 3 minutes after it was shown. During those 3 minutes Mick polls idle time every 5 seconds and records the longest continuous idle stretch. That's the "did you get up" signal for people who stretch without ticking.

| Outcome | Condition | Effect |
|---|---|---|
| Completed | All items ticked | `sitting_since = settled_at` |
| Partial | At least one item ticked | `sitting_since = settled_at` |
| Stood up | Nothing ticked, but longest idle >= 60 s | `sitting_since = settled_at` |
| Ignored | Nothing ticked and longest idle < 60 s | `sitting_since` unchanged; `nag_after = settled_at + threshold/2` (next reminder in about 25 min); `ignored_today += 1` |
| Snoozed | Snooze chosen from the panel (or the menu while a panel is visible) | Settled immediately, with no idle watch. `sitting_since` unchanged, no counter change. Clears `nag_after` like any non-Ignored outcome. |

- Rows are checked top to bottom; the first match wins. Snoozed is matched first when it applies.
- "Not now" in the panel, and closing it with nothing ticked, are both judged by the table (usually Ignored). Mick lets you skip; he just remembers it.
- Any outcome other than Ignored clears `nag_after`. A real break (§6.3) clears it too, since sitting time then has to reach the full threshold again anyway.
- The 60 s idle signal is deliberately generous: sitting still watching an agent for a minute also counts as Stood up. Mick would rather miss a snub than insult someone who got up.
- The longest idle stretch counts only the part between `shown_at` and the settle time.
- `settled_at` is the scheduled settle time (`max(close, shown + 3 min)`), not when the timer actually fired, so a late timer (for example after sleep) doesn't skew the log or `nag_after`.
- `ignored_today` resets at local midnight. It only affects which lines Mick picks and is never shown as a number in the UI.

**Stretch now** (from the menu) shows the same panel with no session attached, so agent stops don't close it. It closes when all items are ticked, when you close it, 2 minutes after the last tick, or 3 minutes after appearing if untouched. It settles by the same table for timer effects, except that Ignored does nothing (no `nag_after`, no counter). It's logged with `"manual": true`.

## 9. The reminder panel

### 9.1 Behavior

- A small panel anchored under the menu bar icon. It also appears over fullscreen apps.
- **Never takes keyboard focus or activates the app.** Clicking a checkbox must work without stealing focus from whatever you were typing in.
- Positioned under the status item's button: its screen frame is `button.window.convertToScreen(button.convert(button.bounds, to: nil))`. The panel's top edge sits just below it, centered on it, clamped to the screen's visible frame. The status item counts as hidden (notch overflow, auto-hidden menu bar in fullscreen) when its frame is off-screen or empty, when its window's occlusion state lacks `.visible`, or when its center falls outside the screen's `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` (the menu bar either side of the notch). The frame check alone misses notch overflow: the panel spike found an overflowed item reporting a normal, visible, on-screen frame behind the camera housing. When it's hidden, the panel goes top-right of the screen holding the frontmost app's topmost normal window, read from `CGWindowListCopyWindowInfo` (bounds need no permission; only titles do). Without such a window it uses the screen under the mouse, then the first screen.
- Content: the opener line, the checklist (§10), and two buttons: "Not now" and "Snooze ▾". Snooze reveals a row of three buttons (30 min / 1 hour / 2 hours) inside the panel rather than a pop-up menu, so choosing one is a plain click that never takes focus.
- Optional bell sound on appear (off by default).

### 9.2 Lifetime

- Agent stops or pauses for input, nothing ticked → the panel closes within 2 seconds.
- Nothing ticked 3 minutes after it appeared → the panel closes (covers Esc interrupts, which fire no stop event).
- At least one item ticked → the panel stays until all are ticked, you close it, or 2 minutes pass since your last tick.
- All ticked → Mick shows a `done_all` line for about 3 seconds, then the panel closes.
- Some ticked and you click "Not now" → Mick shows a `done_partial` line for about 3 seconds, then the panel closes. A second click closes it at once.
- Unticking every item puts the panel back under the untouched rules: a stop closes it, and it closes 3 minutes after it appeared.
- Hard cap: the panel closes 10 minutes after it appeared, no matter what.

### 9.3 Implementation approach (top implementation risk)

**Don't use SwiftUI `MenuBarExtra` for the panel.** Its initializers take only content, a label and an optional `isInserted` binding, and there's no public API to open its window from code. It also exposes no control over key or activation behavior, which the panel depends on. (Community reports say its `.window` style becomes key when opened; that's untested here and moot either way.) MenuBarExtra isn't used for the dropdown either: the app owns its own `NSStatusItem`, and the dropdown is a normal `NSMenu` on it.

The panel is a custom `NSPanel` subclass in an accessory (`LSUIElement`) app:

- Style mask `[.borderless, .nonactivatingPanel]`
- `canBecomeKey = false`, `canBecomeMain = false`
- `becomesKeyOnlyIfNeeded = true`, `hidesOnDeactivate = false`. The latter must be set explicitly, because Apple documents its NSPanel default as `true`.
- Level `.statusBar` (or `.popUpMenu`, whichever the spike shows works over fullscreen)
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` (tested: accepted at runtime). Never add `.moveToActiveSpace`: combining it with `.canJoinAllSpaces` raises `NSInternalInconsistencyException`. `NSWindow.h` also allows at most one of managed/transient/stationary, one of the cycle options, and one of the full-screen options, or AppKit asserts.
- SwiftUI content in an `NSHostingView` subclass that returns `true` from `acceptsFirstMouse(for:)` and `false` from `needsPanelToBecomeKey`
- Shown with `orderFrontRegardless()`. Never `makeKeyAndOrderFront`, never `NSApp.activate`.

Watch out: most "floating panel" guides tell you to override `canBecomeKey` to `true`. That's for Spotlight-style panels that *want* typing. A key non-activating panel receives keystrokes while the other app still looks frontmost, which is exactly the failure principle 1 forbids.

**The spike (the first thing built, before the rest of the app), on macOS 26, must prove:**

1. While you're typing in Terminal, showing the panel doesn't change `NSWorkspace.frontmostApplication` and loses no keystrokes.
2. A single click on a checkbox-style SwiftUI `Toggle` and on a `.plain` `Button` works with `canBecomeKey = false`, and Terminal keeps keyboard focus after the click. Also check with Full Keyboard Access turned on.
3. The panel appears over a fullscreen app's Space. Try both levels, and confirm the accessory activation policy is what makes it work (compare against a `.regular` build). Spike result so far: for not activating on show, the `.nonactivatingPanel` style mask is what matters, not the policy (a `.regular` build launched from a shell didn't take focus either). `.statusBar` is the provisional level; the fullscreen half is still a manual check.
4. Positioning is right on multiple displays, with the menu bar auto-hidden in fullscreen, and with the status item pushed into notch overflow.
5. Idle time from `CGEventSource` looks right, resets when typing in other apps, and triggers no permission prompt. Test with the app launched from Finder, not from Terminal: a Terminal-launched build can inherit Terminal's Input Monitoring grant and hide a prompt. Confirm Mick doesn't appear under Privacy & Security → Input Monitoring or Accessibility.
6. Sleep/wake messages arrive under Swift 6 strict concurrency (MainActor isolation).
7. With no windows visible for 30+ minutes (App Nap territory), a `stop` still closes the panel within 2 s and the 30 s check fires on time, with the activity assertion held (§6.3). Check without it too, to confirm it's needed.

**Fallbacks if it fails:** if click-without-focus (item 2) can't be made reliable, the panel may take focus *only on click* (the user chose to interact, so that's acceptable), but must still never take focus on appear. If the fullscreen behavior (item 3) fails, a macOS notification becomes the fallback surface in fullscreen only, pulled forward from Later.

## 10. Routines and lines

### 10.1 Routine composition

Every routine starts with a fixed **Stand up** item, followed by moves from `moves.json`. Schema: `{ id, title, instruction, area, seconds }`. The `seconds` values are estimates from the instructions (for example 40 for a both-sides stretch, 120 for the walk); nothing reads them in v1.

- **Normal:** Stand up + 2 moves from different areas.
- **Long sit** (sitting >= 2× threshold when the reminder shows): Stand up + Walk + 1 move.
- **Stretch now** (from the menu): a normal routine. It doesn't count toward today's memory (§8).

Selection:

1. Rotation: pick from moves not yet used in this cycle; when all have been used, start a new cycle.
2. Area rule: the two moves in a routine have different areas, and neither matches an area from the previous routine when an alternative exists. If the rule leaves nothing to pick, relax it: first drop the avoid-the-previous-routine part, then start a new cycle.
3. The walk takes part in the normal rotation too.

Move instructions are plain and exact. The personality lives in the lines around them, not in the instructions.

| # | Title | Instruction | Area |
|---|---|---|---|
| 1 | Back bend | Hands on your lower back, lean back gently. Hold 20s. | back |
| 2 | Forward fold | Knees soft, let your upper body hang toward the floor. Hold 30s. | back |
| 3 | Standing twist | Feet hip-width, arms loose, turn your torso slowly side to side. 10 each way. | back |
| 4 | Hip flexor stretch | Step one foot back, bend the front knee slightly, tuck the hips. 20s each side. | hips |
| 5 | Calf raises | Rise onto your toes, lower slowly. 15 times. | legs |
| 6 | Neck side stretch | Drop one ear toward your shoulder, relax. 15s each side. | neck |
| 7 | Chin tucks | Stand tall, pull your chin straight back, hold 3s. 8 times. | neck |
| 8 | Shoulder rolls | Roll your shoulders backward slowly. 10 times. | shoulders |
| 9 | Chest opener | Clasp your hands behind your back, lift slightly, open the chest. Hold 20s. | chest |
| 10 | Wrist stretch | Arm out, palm up, gently pull your fingers back with the other hand. 15s each side. | wrists |
| 11 | Walk | Walk to the kitchen and back. Refill your water. | walk |

### 10.2 Mick's lines

Stored in `lines.json` as pools, each with enough lines that repeats stay rare (at least 8 per pool for openers, 5 for the rest). Lines rotate within a pool without repeating until the pool is used up.

| Pool | Used when | Examples (original, style guide only) |
|---|---|---|
| `opener` | Normal reminder, nothing ignored today | "On your feet, ya bum. The robot's doin' your job, now you do mine." / "Up. Now. I ain't gonna say it twice." |
| `opener_ignored_1` | 1 ignored today | "You ignored me last time. I noticed. Get up." |
| `opener_ignored_2` | 2 ignored today | "Twice today, kid. TWICE. You got glue on that chair?" |
| `opener_ignored_3` | 3+ ignored today | "I've trained bums with more get-up than you. UP!" |
| `opener_long_sit` | Long-sit routine | "{minutes} minutes? You're growin' roots. Walk." |
| `done_all` | Everything ticked | "That's it. Wasn't so hard, was it?" / "Now you look like a fighter. Sorta." |
| `done_partial` | Closed with some ticked | "Half a job. I'll take it. This time." |
| `snooze` / `pause` / `resume` | Menu or panel actions | "Fine. I'll be here." / "You want quiet? You got it. For now." / "I'm back. Don't make me regret it." (no durations: one snooze pool covers 30 min to tomorrow) |
| `status_calm` / `status_armed` / `status_glaring` | Dropdown status line | "You're fine. For now." / "{minutes} minutes on your can. Next robot run, you're up." / "{hours} in that chair. You're a disgrace to the chair." |
| `onboarding` | First launch | "So you wanna be a contender. Install the thing." |

Opener precedence: if anything was ignored today, the `opener_ignored_*` tier wins. Otherwise a long-sit routine uses `opener_long_sit`. Otherwise `opener`. For a long sit with an ignored tier, the plain detail line under the opener says how long you've been sitting.

Line content follows the rules in §1 (Mick's voice). No line hardcodes a duration, because the threshold is configurable. Lines use placeholders for sitting time, spelled out in words and capitalized at the start of a sentence:

- `{minutes}`: total minutes ("Forty-seven", "A hundred and five")
- `{hours}`: rounded to the nearest half hour ("Two hours", "An hour and a half"). Under 15 minutes it falls back to minutes ("Two minutes"), which only happens with tiny thresholds.
- `{minutes}` renders 0 as "Zero", so right after a break a calm line can read "Zero minutes on your can, kid." That's in character and kept.

The plain detail line and menu labels use digits ("Sitting 47m").

## 11. Config

`~/.mick/config.json`, written by the Settings window (human-readable so it can be edited or read by other tools):

```json
{
  "sit_threshold_minutes": 50,
  "break_reset_minutes": 5,
  "show_delay_seconds": 30,
  "quiet_hours": null,
  "sound": false
}
```

`quiet_hours` is `null` or `{ "start": "HH:MM", "end": "HH:MM" }` in local time, and may cross midnight. Open at login is stored by the system (`SMAppService`), not here. The app watches `config.json` and reloads it when it's edited by hand. Missing config falls back to defaults. Each key is read on its own: a wrong type or an out-of-range value falls back to that key's default (logged), and the other keys are kept. Quiet hours with the same start and end count as off. Changed settings apply from the next reminder; a check that's already scheduled keeps its delay.

## 12. Files

Everything lives under `MICK_HOME` (default `~/.mick`). The app and the hooks both respect it, so tests and simulation run against a temporary directory without touching real state.

`MICK_HOME` is for tests and simulation only. Don't set it in a shell profile: hooks inherit the shell environment, but the app launched from Finder or the login item doesn't, so the two would use different directories.

```
~/.mick/
  events.jsonl     written by hooks, read by the app (§6.1)
  config.json
  state.json
  reminders.jsonl  reminder log (§12.3)
  log.txt          errors and diagnostics, rotated at 1 MB
```

### 12.1 State

`state.json` persists what must survive a relaunch. Written atomically (temp file + rename) by the app only.

```json
{
  "sitting_since": "<ISO>",
  "last_active_at": "<ISO>",
  "last_event_at": "<ISO or null>",
  "snoozed_until": "<ISO or null>",
  "nag_after": "<ISO or null>",
  "paused": false,
  "today": { "date": "2026-09-29", "ignored": 0 },
  "rotation": { "used_move_ids": ["..."], "last_areas": ["back", "shoulders"], "used_line_ids": { "opener": ["..."] } },
  "sessions": { "<session_id>": { "running": true, "run_started_at": "<ISO>", "last_event_at": "<ISO>", "cwd": "...", "ended": false } },
  "events_offset": 0
}
```

Timestamps keep microseconds, so per-session ordering by `t` (§6.3) still holds after a relaunch. Scheduled checks, the visible panel and a pending settlement are in memory only; a relaunch drops them.

### 12.2 Corruption

A corrupted `state.json`, or a `config.json` that isn't valid JSON at launch, is moved aside (`.corrupt-<timestamp>`), replaced with defaults, and logged. If `config.json` becomes invalid while Mick is running (a half-saved hand edit), Mick keeps its current settings until the file is valid again and never moves it aside. A malformed line in `events.jsonl` is skipped and logged.

### 12.3 Reminder log

`reminders.jsonl`, one line per settled reminder. It's for Jose's two-week review, and it's never shown in the UI.

```json
{ "shown_at": "...", "settled_at": "...", "session_id": "...", "cwd": "/Users/.../project", "sitting_minutes": 54, "routine": ["stand", "back-bend", "shoulder-rolls"], "ticked": ["stand", "back-bend"], "max_idle_seconds": 72, "outcome": "partial", "manual": false }
```

`sitting_minutes` is measured when the panel shows. No prompt text or agent output is ever logged, because the hooks never capture it.

## 13. Install and distribution

**v1: local build only.**

1. Run `scripts/install.sh`. It builds Release, signs it with the first Apple Development identity in the keychain (`--identity <SHA-1>` picks another, which is needed when the keychain holds identities from more than one team), enables the hardened runtime, and copies `Mick.app` to `/Applications`. Then open it. The Xcode project itself signs ad hoc by default, because automatic signing fails unattended with identities from several teams. Release builds set `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`, so Xcode doesn't add the debug-only `get-task-allow` entitlement, which would block notarization later.
2. Onboarding shows the plugin install commands. This repo is its own Claude Code marketplace:
   ```
   /plugin marketplace add eltaiguer/mick
   /plugin install mick@mick
   ```
   The install id is the plugin `name`, `@`, and the marketplace `name`, and the `@mick` part is required. `.claude-plugin/marketplace.json` therefore has `"name": "mick"`, an `owner`, and one plugin entry `{ "name": "mick", "source": "./plugin" }`. The source path is relative to the repo root. `claude plugin validate .` must pass for the marketplace, and `claude plugin validate ./plugin` for the plugin.
3. Onboarding confirms when the first hook event arrives.

The app is **not sandboxed**, because it reads `~/.mick` written by the hooks. It's built with the **hardened runtime** so notarization is cheap later.

**Uninstall:** Settings → Uninstall… deletes `~/.mick/`, unregisters the login item, shows the plugin uninstall commands (`/plugin uninstall mick@mick` and `/plugin marketplace remove mick`), and quits. Then drag Mick to the Trash. Nothing else is left behind. If the plugin is left installed, its hooks find no `~/.mick` and do nothing (§6.1).

## 14. Tech choices

- Swift 6.2, SwiftUI, macOS 26 only, Xcode 26.
- The `MickCore` Swift package has two libraries. `MickCore` holds all logic as pure functions over (state, config, event or tick, now), with no UI, file system or clock: trigger decision, outcome settling, sitting-timer resets, routine selection, line selection, quiet hours, midnight rollover, event parsing. `MickIO` is the file, dispatch and log layer (event tailer, state and config persistence, bundled resources, the engine), so intake is testable under `swift test` too. The app is a thin shell that feeds the engine idle readings and system signals, and renders the result.
- Hooks: `/bin/sh` + `/usr/bin/jq`. No other runtime.
- No third-party dependencies.

Suggested repo layout:

```
.claude-plugin/marketplace.json   this repo as a marketplace
plugin/                           the Claude Code plugin (hooks only)
  .claude-plugin/plugin.json
  hooks/hooks.json
  hooks/mick-event.sh
app/
  Mick.xcodeproj
  Mick/                           app target (menu bar, panel, settings, onboarding, smoke check, simulation)
  MickCore/                       Swift package: MickCore (pure logic), MickIO (files, engine), tests
    Sources/MickIO/Resources/     moves.json, lines.json (one copy for the app and swift test)
scripts/                          install.sh, review.sh
spikes/                           panel/ and signals/ (throwaway, each with a VERDICT.md)
tests/                            hooks/, app/, acceptance/, scripts/
docs/acceptance.md                every §15 criterion and how it's verified, plus the manual checklist
```

## 15. Acceptance criteria

- The reminder panel never takes keyboard focus: typing continuously in Terminal while it appears loses no keystrokes.
- Panel checkboxes respond to the first click without activating Mick.
- The panel appears over a fullscreen app.
- With the threshold set to 1 minute, a reminder appears on the next agent run lasting longer than the show delay.
- Agent runs shorter than the show delay never produce a reminder.
- With nothing ticked, the panel closes within 2 seconds of the agent finishing, failing on an API error, or asking for tool permission, including after 30+ minutes with no Mick windows visible (App Nap). For MCP elicitation dialogs, Claude Code itself reports the dialog about 6 s late, so the panel closes within 2 s of that report.
- A run whose `stop` event lands before its `prompt` event (async ordering) leaves the session not running.
- After an Esc interrupt during the show delay, a panel that does appear closes after 3 minutes untouched.
- The panel never appears while you're typing; it waits for a 3 s input gap.
- A reminder that's waiting to settle blocks new reminders: a prompt 1 minute after an auto-dismissed panel never schedules another.
- If the session a check was scheduled for stops early while another session is running, the check is handed to the running session.
- With one item ticked, the panel stays after the agent finishes, and closes 2 minutes after the last tick.
- Three concurrent sessions never produce more than one reminder at once.
- After an Esc interrupt, the session's next prompt behaves normally.
- Being idle for 5+ minutes, sleeping the Mac for 5+ minutes, or having Mick quit for 5+ minutes resets the sitting timer.
- Snooze and pause never reset the sitting timer.
- Coming back from a 40-minute break shows sitting time near zero, not 35 minutes.
- An ignored reminder brings the next one about 25 minutes later with an `opener_ignored_*` line; a completed one waits the full threshold.
- Ignoring a reminder never lowers the displayed sitting time; ignoring repeatedly still reaches the glaring icon and the long-sit routine.
- Nothing ticked but idle >= 60 s counts as Stood up, not Ignored.
- Mick's memory resets at local midnight.
- Sitting for 2× the threshold produces the long-sit routine with a walk.
- No routine contains two moves from the same area.
- Hooks are async (except `SessionEnd`), never print, always exit 0 (including with jq missing or `~/.mick` unwritable), and never write prompt text or agent output.
- Hooks never create `~/.mick`; with the directory absent they write nothing.
- Events written while Mick isn't running never trigger a reminder at launch.
- Corrupted state, config or event lines never crash the app; they're reset or skipped and logged.
- Uninstall leaves nothing behind except the plugin, which onboarding tells you how to remove.

## 16. Test plan

- **Unit tests (`MickCore`)**: trigger decision and re-check (including the input-gap wait and the settle-window block), check hand-off between sessions, same-session re-prompt, outcome settling (all five outcomes), `nag_after` after ignore and its clearing, idle/sleep/relaunch resets (sitting time after a long break), quiet hours across midnight, "until tomorrow" snooze, midnight rollover, Stretch now settling, routine composition (area rule, rotation, long-sit), line pool selection by tier, placeholder rendering, event parsing (malformed lines, unknown notification types), backlog handling, offset reset when the file shrinks.
- **Hook tests**: run `mick-event.sh` with sample payloads against a temporary `MICK_HOME`. Assert the output line only has the allowed fields, nothing goes to stdout or stderr, and no prompt, `last_assistant_message` or `tool_input` text appears in the file. Record warm and cold timings (no hard limit; the hooks are async). Exit must be 0 when `MICK_JQ` points at a missing binary, the payload is malformed, the directory is unwritable, or the directory doesn't exist (in which case nothing is created).
- **Simulation mode**: a debug-build menu (and a `--simulate` launch argument) that uses a temporary `MICK_HOME`, a 1-minute sit threshold and break reset, a 5-second delay, and starts already armed with hooks seen, and replays scripted events for several sessions: a normal run, a short run, an interrupt with no stop, a permission pause mid-reminder, three concurrent sessions, an early stop that hands the check to another session, and a stop that lands before its prompt. It shows the real panel with real panel timings (the Esc scenario takes 3 minutes live). In a normal debug launch the app's own engine still uses `~/.mick`, so a real reminder and a simulated panel can appear together.
- **Manual focus test**: type continuously in Terminal while the simulator triggers the panel, and confirm no keystrokes are lost (acceptance criterion 1).

## 17. Later (not v1)

- Notarized distribution: Developer ID certificate, GitHub Releases, then a Homebrew cask.
- Other agents (Codex, Cursor, etc.) by writing to the same event file.
- An original Mick illustration for the panel.
- Hold timers for timed moves.
- macOS notification-style reminders, as an option for people who hide the menu bar.
- Time-of-day aware routines, informed by two weeks of reminder logs.
- A fallback nudge after very long sitting with no agent runs, if the logs show the gap matters.
- Linux support.
- Public launch: README with the story, demo GIF.

---

## 18. Decision log

| # | Decision | Why |
|---|---|---|
| 1 | Checklist is per reminder: Stand up + 2 moves (Q31a) | Smallest change that fits the core idea, and it lands naturally at 60–90 seconds |
| 2 | Mick remembers today only; no history in the UI (Q32b) | Full Mickey needs a memory, but a daily reset keeps it from becoming a guilt ledger |
| 3 | Hooks write JSON lines to a file with `jq`; the app watches the file | No Node, no socket server, works when the app isn't running, trivially extendable to other agents |
| 4 | Hooks store only session id, cwd, notification type | Prompts and agent replies are in the payloads and must never touch disk |
| 5 | Backlog events never fire a reminder | A stale prompt from before launch isn't a natural pause anymore |
| 6 | Panel with nothing ticked closes when the agent stops (or after 3 min untouched); with ticks it waits (2 min idle, 10 min cap) | Keeps "gets out of the way" without yanking a half-done routine away |
| 7 | Timer effect decided at settle time; Ignored re-arms after half a threshold | Mick should come back sooner if you blew him off, and only then |
| 8 | "Ignored" requires no ticks AND no idle stretch of 60 s | Mick never insults someone who actually got up |
| 9 | "Not now" is allowed but counts; Snooze doesn't count | Skipping is always possible; Mick just notices. Snooze is the explicit "not now, later" |
| 10 | Long sit (2×) = Stand up + Walk + 1 move | Replaces the old walk-only rule within the checklist format |
| 11 | Instructions plain, personality in openers/reactions | Safety and clarity for the moves; variety where it's fun |
| 12 | Insults target sitting only; mild language; never "push through pain" | A stretching app for a public repo |
| 13 | No portrait, original glove icon, original bell sound | Avoid film likeness and imagery |
| 14 | Panel is the only surface in v1; notifications move to Later | One surface to get right; fullscreen is handled by the panel itself (to verify) |
| 15 | No hold timers in v1 | Tick when done; timers are UI work that doesn't change behavior |
| 16 | Idle is polled every 30s (5s during follow-up) | Cheap, and enough resolution for a 5-minute break rule |
| 17 | Quitting Mick for 5+ minutes counts as a break | Consistent with sleep; avoids a reminder right after relaunch |
| 18 | Config in `~/.mick/config.json`, not UserDefaults | Readable, `MICK_HOME`-testable, open to other tools later |
| 19 | Unsandboxed, hardened runtime, local build with Apple Development cert | Needs `~/.mick`; keeps notarization cheap later |
| 20 | "Stretch now" doesn't affect today's memory | It's voluntary; Mick shouldn't count it for or against you |
| 21 | Warning icon after 7 days with no events | Replaces the old self-removal; surfaces a broken plugin instead of silently doing nothing |
| 22 | Own `NSStatusItem` + custom non-activating `NSPanel`; no `MenuBarExtra` | Research: `MenuBarExtra` can't be opened from code and its window takes focus |
| 23 | Idle via `CGEventSource`, not IOKit `HIDIdleTime` | Public, stable, no permission needed per community reports; HIDIdleTime's meaning has changed between releases |
| 24 | Fast user switching for 5+ min counts as a break | Same logic as sleep |
| 25 | Fallbacks if the spike fails: focus-on-click only; notifications in fullscreen only | Keeps principle 1 (never on appear) even in the worst case |
| 26 | Ignore penalty is a separate `nag_after` time; `sitting_since` is never backdated | Backdating made displayed sitting time drop after an ignore and kept repeat ignorers from ever reaching the glaring icon or long-sit walk. `nag_after` is still self-clearing: a real break resets sitting time to below the threshold anyway |
| 27 | Snooze from the panel settles as its own outcome, with no penalty | Snooze is the sanctioned "later"; it shouldn't fall through to Ignored |
| 28 | Ignored-tier openers beat the long-sit opener | Mick bringing up the snub is more in character; sitting time still shows in the detail line |
| 29 | A reminder waiting to settle blocks new triggers | Otherwise a prompt inside the 3-minute settle window re-triggers before `sitting_since` moves |
| 30 | Hooks never create `~/.mick`; the app does | Uninstalling the app makes the hooks inert instead of recreating the directory |
| 31 | Idle break keeps pushing `sitting_since` forward on every poll; `last_active_at = now - idle` | Sitting time restarts when you come back, not when the break began |
| 32 | Hold a `ProcessInfo` activity assertion while anything is live | App Nap would otherwise delay the 2 s close and the show-delay timer |
| 33 | Untouched panel closes after 3 min; show waits for a 3 s input gap | Esc interrupts fire no stop event, and the panel shouldn't appear mid-keystroke |
| 34 | A cancelled check hands off to another running session | One session finishing early shouldn't cost a reminder while another run is underway |
| 35 | Hook is a script (`mick-event.sh`) run in exec form, with a `MICK_JQ` override; Notification uses a matcher | Testable (including missing jq), readable, and irrelevant notifications never hit disk |
| 36 | `completed_today` dropped | Nothing read it, and no scoreboard is a principle |
| 37 | Lines never hardcode durations; `{minutes}`/`{hours}` spelled out | The threshold is configurable |
| 38 | Stretch now: normal timer effects, Ignored has no penalty, logged as manual | Voluntary, so it can help you but never count against you |
| 39 | Headless `claude -p` runs count as agent runs | Accepted; no reliable signal to tell them apart |
| 40 | `PermissionRequest` is the main "waiting on you" signal; the `permission_prompt` notification is a backup | Per the hooks docs, `permission_prompt` only fires after about 6 s without typing; `PermissionRequest` fires immediately |
| 41 | `StopFailure` is treated as `stop` | Per the docs, API errors fire `StopFailure` instead of `Stop`; without it, a rate-limited run would look like it's running forever |
| 42 | `idle_prompt`, `agent_needs_input`, `agent_completed` not subscribed | The first fires after `Stop` and adds nothing; the other two describe other background sessions |
| 43 | All hooks `async: true` except `SessionEnd`; the app orders events by `t` | Measured cold start was about 0.9 s; async makes the hooks invisible to Claude Code. `SessionEnd` stays sync because async hooks are killed at `-p` teardown |
| 44 | Activity assertion uses `.userInitiatedAllowingIdleSystemSleep` only, never `.latencyCritical` | Apple reserves `latencyCritical` for audio and video recording |
| 45 | Install id is `mick@mick` | The docs require `<plugin>@<marketplace>` |
| 46 | A hidden status item is detected by frame, occlusion and the notch's auxiliary areas; the fallback screen comes from the window list | An overflowed item reports a normal visible frame; an accessory app can't query another app's focused window without Accessibility |
| 47 | Reminder timers are zero-tolerance `Timer`s, not `asyncAfter` | `asyncAfter` measured about 5% late |
| 48 | The package splits into pure `MickCore` and `MickIO` | Keeps the logic pure while intake and persistence still run under `swift test` |
| 49 | Ended sessions are kept (not running) until the 2 h prune | A late async prompt could otherwise resurrect them |
| 50 | Icon precedence: Warning, Paused, Snoozed, Glaring, Armed, Calm | The spec gave none; paused has no end time, so it outranks snoozed |
| 51 | Snooze, pause and resume lines come from the pools and show for 60 s | The dropdown closes on click; an interim hardcoded placeholder (including a forbidden duration) was removed after the build |
| 52 | Config is read key by key; an invalid file mid-edit is left alone | Hand edits shouldn't reset every setting or be moved away mid-typing |
| 53 | Open at login is turned on once, when `~/.mick` is created | Doing it every launch would override the person's own choice |
| 54 | Ad hoc signing by default; `scripts/install.sh` signs with Apple Development and drops `get-task-allow` | Two teams in the keychain break automatic signing; the debug entitlement would block notarization |
| 55 | Panel snooze is a row of buttons, not a pop-up menu | A plain click on a non-activating panel is known not to take focus; a menu isn't verified |
| 56 | A stop during the input-gap wait hands the check off | Consistent with decision 34 |

**Status:** v1 is built (issues #1–#13, PRs #14–#26), and decisions 46–56 come from building it. What's left is the manual checklist in `docs/acceptance.md`, then the two-week trial.
