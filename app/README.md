# Mick app

- `Mick.xcodeproj`: the menu bar app (`LSUIElement`, own `NSStatusItem`, no `MenuBarExtra`).
  Sources live in `Mick/`, a folder-synchronized group, so new files there are picked up
  without editing the project file.
- `MickCore/`: a Swift package with two libraries.
  - `MickCore`: pure logic and data types. No file system and no clock (everything
    takes `now`): event parsing, ordering, backlog, session bookkeeping, events-file
    offset and rotation decisions, the hooks warning state, and the `state.json` and
    `config.json` models.
  - `MickIO`: the Foundation layer around it. Mick's home directory, loading files with
    defaults and moving corrupted ones aside, the rotating `log.txt`, the `events.jsonl`
    tailer, and `MickEngine`, the one object that owns state and that the app observes.

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

## Tests

```sh
(cd app/MickCore && swift test)   # unit and file-system tests, temporary MICK_HOME only
tests/app/smoke.sh                # builds the app and runs its --smoke self-check (needs a GUI session)
tests/hooks/test-hooks.sh         # the plugin's hook script
```

`Mick --smoke [--smoke-hook plugin/hooks/mick-event.sh]` runs inside the real app: it
checks the accessory policy, status item, menu, files and onboarding, then (with
`--smoke-hook`) fires a real hook event and checks that the warning clears and onboarding
shows its check mark within 2 s. It refuses to run without `MICK_HOME`.
