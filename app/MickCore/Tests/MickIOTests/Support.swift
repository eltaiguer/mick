import Foundation
import Synchronization
import Testing
@testable import MickIO
import MickCore

/// A throwaway MICK_HOME under the system temp directory. Never ~/.mick.
final class TempHome {
    let root: URL
    let home: MickHome

    init(create: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mick-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        home = MickHome(url: root.appendingPathComponent("mick-home", isDirectory: true))
        if create { try home.ensureExists() }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var eventsPath: String { home.events.path }

    func append(_ text: String, to url: URL? = nil) throws {
        let url = url ?? home.events
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func size(_ url: URL? = nil) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: (url ?? home.events).path))?[.size] as? UInt64) ?? 0
    }
}

func line(_ kind: String, _ t: Double, _ s: String = "A") -> String {
    #"{"e":"\#(kind)","t":\#(t),"s":"\#(s)","c":"/tmp/project","n":null}"# + "\n"
}

/// Collects tailer batches from its queue.
final class BatchSink: Sendable {
    private let storage = Mutex<[TailBatch]>([])
    func add(_ batch: TailBatch) { storage.withLock { $0.append(batch) } }
    var batches: [TailBatch] { storage.withLock { $0 } }
    var lines: [String] { batches.flatMap(\.lines) }
    func lines(origin: EventOrigin) -> [String] { batches.filter { $0.origin == origin }.flatMap(\.lines) }
    var lastOffset: UInt64? { batches.last(where: { $0.source == .main })?.offset }
}

/// Polls `condition` every 20 ms until it's true or `timeout` passes.
@discardableResult
func eventually(isolation: isolated (any Actor)? = #isolation, timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

let nowT = Date().timeIntervalSince1970
