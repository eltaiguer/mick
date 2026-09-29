import Foundation
import Testing
@testable import MickIO
import MickCore

@Suite struct MickHomeTests {
    @Test func resolvesMickHomeOrTheDefault() {
        let user = URL(fileURLWithPath: "/Users/someone")
        #expect(MickHome.resolve(environment: [:], homeDirectory: user).url.path == "/Users/someone/.mick")
        #expect(MickHome.resolve(environment: ["MICK_HOME": ""], homeDirectory: user).url.path == "/Users/someone/.mick")
        #expect(MickHome.resolve(environment: ["MICK_HOME": "/tmp/x"], homeDirectory: user).url.path == "/tmp/x")
    }

    @Test func createsTheDirectoryWithMode0700() throws {
        let temp = try TempHome(create: false)
        #expect(try temp.home.ensureExists())
        let mode = try FileManager.default.attributesOfItem(atPath: temp.home.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(try temp.home.ensureExists() == false)
    }

    @Test func refusesAFileInTheWay() throws {
        let temp = try TempHome(create: false)
        FileManager.default.createFile(atPath: temp.home.url.path, contents: Data())
        #expect(throws: (any Error).self) { try temp.home.ensureExists() }
    }
}

@Suite struct JSONFileStoreTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func missingFileGivesDefaults() throws {
        let temp = try TempHome()
        let log = MemoryLog()
        let (config, outcome) = JSONFileStore.load(MickConfig.self, from: temp.home.config, defaults: .defaults, now: now, log: log)
        #expect(config == .defaults)
        #expect(outcome == .missing)
        #expect(log.messages.contains { $0.contains("config.json missing") })
    }

    @Test(arguments: ["{not json", "", "[]", #"{"sit_threshold_minutes": "fifty"}"#])
    func corruptConfigIsMovedAside(content: String) throws {
        let temp = try TempHome()
        try Data(content.utf8).write(to: temp.home.config)
        let log = MemoryLog()
        let (config, outcome) = JSONFileStore.load(MickConfig.self, from: temp.home.config, defaults: .defaults, now: now, log: log)
        #expect(config == .defaults)
        guard case .corrupt(let moved?) = outcome else { Issue.record("expected corrupt, got \(outcome)"); return }
        #expect(moved.lastPathComponent == "config.json.corrupt-20260921T141320Z")
        #expect(try Data(contentsOf: moved) == Data(content.utf8))
        #expect(!FileManager.default.fileExists(atPath: temp.home.config.path))
        #expect(log.messages.contains { $0.contains("config.json corrupted") })
    }

    @Test func corruptStateIsMovedAsideTwiceWithoutClobbering() throws {
        let temp = try TempHome()
        let log = MemoryLog()
        for _ in 0..<2 {
            try Data("garbage".utf8).write(to: temp.home.state)
            _ = JSONFileStore.load(MickState.self, from: temp.home.state, defaults: .defaults(now: now), now: now, log: log)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: temp.home.url.path).sorted()
        #expect(names == ["state.json.corrupt-20260921T141320Z", "state.json.corrupt-20260921T141320Z-2"])
    }

    @Test func savesAtomicallyWithMode0600AndReadsBack() throws {
        let temp = try TempHome()
        var state = MickState.defaults(now: now)
        state.eventsOffset = 99
        try JSONFileStore.save(state, to: temp.home.state)
        let mode = try FileManager.default.attributesOfItem(atPath: temp.home.state.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let (back, outcome) = JSONFileStore.load(MickState.self, from: temp.home.state, defaults: .defaults(now: now), now: now, log: MemoryLog())
        #expect(outcome == .loaded)
        #expect(back == state)
        // Only the file itself: no temp file left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.home.url.path) == ["state.json"])
    }
}

@Suite struct RotatingLogTests {
    @Test func appendsTimestampedLines() throws {
        let temp = try TempHome()
        let log = RotatingLog(url: temp.home.log)
        log.log("one")
        log.log("two")
        let text = try String(contentsOf: temp.home.log, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix(" one"))
        #expect(lines[1].hasSuffix(" two"))
    }

    @Test func rotatesAtTheLimit() throws {
        let temp = try TempHome()
        let log = RotatingLog(url: temp.home.log, limitBytes: 200)
        for i in 0..<20 { log.log("message number \(i) with some padding") }
        let size = try FileManager.default.attributesOfItem(atPath: temp.home.log.path)[.size] as! UInt64
        #expect(size < 200 + 100)
        #expect(FileManager.default.fileExists(atPath: log.rotatedURL.path))
        let current = try String(contentsOf: temp.home.log, encoding: .utf8)
        #expect(current.contains("message number 19"))
    }

    @Test func defaultLimitIsOneMegabyte() throws {
        #expect(RotatingLog(url: URL(fileURLWithPath: "/dev/null")).limitBytes == 1_048_576)
    }
}
