# Mick

A macOS menu bar corner man for the agent era.

When you've been sitting too long and you hand work to a Claude Code agent, Mick drops a
small panel under the menu bar with a stand-up-and-stretch routine and a line from a gruff
old boxing trainer. He only shows up when an agent run has just started, never while
you're typing, and the panel never takes keyboard focus. When the agent finishes and you
haven't started, he gets out of the way.

Fair warning: Mick swears, insults you, and occasionally quotes the films. The moves are
general suggestions, not medical advice; skip anything that hurts.

Everything stays on your Mac: no accounts, no network, no telemetry. The Claude Code
plugin records only an event name, a timestamp, the session id, the working directory and
the notification type. Prompts and agent output are never read or stored.

The full product spec is [SPEC.md](SPEC.md). Status: v1, built from source for personal use.

## Requirements

- macOS 26 and Xcode 26
- Claude Code
- An Apple Development signing certificate (free with an Apple ID: Xcode → Settings →
  Accounts → Manage Certificates). Open at login needs a signed app.

## Install

1. Build Mick, signed with your Apple Development certificate and the hardened runtime,
   and copy it to `/Applications`:

   ```sh
   scripts/install.sh
   ```

   It picks the first "Apple Development" identity in your keychain; pass
   `--identity <SHA-1>` to choose one (`security find-identity -v -p codesigning` lists
   them). Quit Mick first if you're updating it.

2. Open it: `open /Applications/Mick.app`. Mick lives in the menu bar (a boxing glove)
   and has no Dock icon. Onboarding opens on first launch. Open at login is on by default;
   if macOS asks, approve Mick in System Settings → General → Login Items.

3. Install the Claude Code plugin. This repo is its own plugin marketplace. In Claude Code:

   ```
   /plugin marketplace add eltaiguer/mick
   /plugin install mick@mick
   ```

   Onboarding shows both commands with copy buttons, and ticks "Waiting for your first
   Claude Code prompt…" once the first event arrives.

That's it. Work normally. After 50 minutes of sitting the glove turns "armed", and the next
agent run that's still going 30 seconds after you prompt brings Mick out.

## Using it

- **The panel**: tick items as you do them. "Not now" skips (Mick remembers, for today).
  "Snooze ▾" puts him off for 30 minutes to 2 hours with no hard feelings.
- **The menu**: how long you've been sitting, Stretch now, Snooze, Pause, Settings.
- **Settings**: sit threshold, show delay, break reset, quiet hours, the bell, open at login.
  They're saved in `~/.mick/config.json`, which you can also edit by hand.

Mick keeps its files in `~/.mick` (`MICK_HOME` overrides it, for tests and simulation only;
don't set it in your shell profile).

## The two-week review

Every settled reminder adds one line to `~/.mick/reminders.jsonl` (when it showed, how long
you'd been sitting, the routine, what you ticked, and how it ended). It's never shown in the
app. To summarize it:

```sh
scripts/review.sh
```

The goal: most shown reminders end as Completed, Partial or Stood up, not Ignored.

## Uninstall

Settings → Uninstall… deletes `~/.mick`, removes the login item, shows the plugin uninstall
command, and quits. Then drag Mick to the Trash and, in Claude Code:

```
/plugin uninstall mick@mick
```

If you leave the plugin installed, its hooks find no `~/.mick` and do nothing.

## Development

Build, simulation mode and the test suites are described in [app/README.md](app/README.md).
The acceptance criteria and how each is verified are in
[docs/acceptance.md](docs/acceptance.md). The short version:

```sh
(cd app/MickCore && swift test)   # logic, engine and acceptance tests
tests/hooks/test-hooks.sh          # the plugin hook
tests/app/smoke.sh                 # the built app's self-check (GUI session)
tests/app/simulate.sh              # simulation scenarios in the real app (~4 min)
tests/app/release-check.sh         # the signed build scripts/install.sh makes
tests/acceptance/check-matrix.sh   # docs/acceptance.md covers every §15 criterion
tests/scripts/test-review.sh       # scripts/review.sh
```

MIT licensed. Mick's lines are original writing, in the spirit of a certain trainer; no
film quotes, stills, likeness or artwork.
