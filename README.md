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

The full product spec is [SPEC.md](SPEC.md). Status: v1. There's no prebuilt download yet;
you build it from source on your own Mac, which takes about five minutes.

## Requirements

- macOS 26 (Tahoe) and Xcode 26, from the Mac App Store
- [Claude Code](https://claude.com/claude-code)
- A free Apple Development signing certificate. Mick has to be signed for open at login
  to work, and you sign it yourself, so you don't need a paid developer account.

## Install

1. **One-time Xcode setup.** Open Xcode once so it finishes installing its components, then
   point the command line tools at it and accept the license:

   ```sh
   sudo xcode-select -s /Applications/Xcode.app
   sudo xcodebuild -license accept
   ```

2. **Create a signing certificate** if you don't have one. In Xcode, go to Settings →
   Accounts, click + to add your Apple ID, select the team "(Personal Team)", click
   Manage Certificates…, then + → Apple Development. To check that it worked:

   ```sh
   security find-identity -v -p codesigning   # should list an "Apple Development" identity
   ```

3. **Get the code, then build and install Mick:**

   ```sh
   git clone https://github.com/eltaiguer/mick.git
   cd mick
   scripts/install.sh
   ```

   This builds a signed Release build and copies it to `/Applications`. It uses the first
   "Apple Development" identity in your keychain; pass `--identity <SHA-1>` to pick a
   different one. If macOS asks whether `codesign` can use your keychain, click Always Allow.

4. **Open it:** `open /Applications/Mick.app`. Mick lives in the menu bar as a boxing glove
   and has no Dock icon. Onboarding opens on first launch. Open at login is on by default;
   if macOS asks, approve Mick in System Settings → General → Login Items.

5. **Install the Claude Code plugin.** This repo is its own plugin marketplace. In Claude Code:

   ```
   /plugin marketplace add eltaiguer/mick
   /plugin install mick@mick
   ```

   Onboarding shows both commands with copy buttons. Once your first prompt reaches Mick, it
   ticks off "Waiting for your first Claude Code prompt…".

That's it. Work normally. After 50 minutes of sitting the glove turns "armed", and the next
agent run that's still going 30 seconds after you prompt brings Mick out.

## Updating

Quit Mick from its menu (Quit Mick), then:

```sh
cd mick
git pull
scripts/install.sh
open /Applications/Mick.app
```

In Claude Code, `/plugin marketplace update mick` picks up plugin changes.

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

The code is [MIT licensed](LICENSE). The app icon is a still from *Rocky* (1976), and the film
lines belong to their rights holders. They're here as a fan tribute and aren't covered by the
MIT license.
