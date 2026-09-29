// swift-tools-version: 6.2
import PackageDescription

// MickCore: all of Mick's logic, with no UI (SPEC §14).
// - MickCore: pure logic and data types (event parsing, ordering, backlog, sessions,
//   state and config models). No file system and no clock: everything takes `now`.
// - MickIO: the thin Foundation layer around it (Mick's home directory, state and
//   config files, the rotating log, and the events.jsonl tailer). It lives here rather
//   than in the app target so it runs under `swift test` against a temporary MICK_HOME.
let package = Package(
    name: "MickCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MickCore", targets: ["MickCore"]),
        .library(name: "MickIO", targets: ["MickIO"]),
    ],
    targets: [
        .target(name: "MickCore"),
        // moves.json and lines.json ship here so the app and `swift test` read the same file.
        .target(name: "MickIO", dependencies: ["MickCore"], resources: [.copy("Resources/moves.json"), .copy("Resources/lines.json")]),
        .testTarget(name: "MickCoreTests", dependencies: ["MickCore"]),
        .testTarget(name: "MickIOTests", dependencies: ["MickIO", "MickCore"]),
    ],
    swiftLanguageModes: [.v6]
)
