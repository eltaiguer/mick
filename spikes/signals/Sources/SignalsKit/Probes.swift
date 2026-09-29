import Foundation

/// One line of the spike's JSONL results log.
public struct ProbeRecord: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case start, timer, fileWatch, idle, signal, end
    }

    public var kind: Kind
    /// Wall-clock time of the record, seconds since 1970.
    public var t: Double
    /// For `timer`: how late the one-shot timer fired versus its due time.
    /// For `fileWatch`: callback time minus the time the writer stamped in the line.
    public var lateness: Double?
    public var idle: Double?
    public var note: String?

    public init(kind: Kind, t: Double, lateness: Double? = nil, idle: Double? = nil, note: String? = nil) {
        self.kind = kind
        self.t = t
        self.lateness = lateness
        self.idle = idle
        self.note = note
    }
}

/// Appends records to a JSONL file. Main-actor only; the spike does everything on main,
/// the same way the real app will.
@MainActor
public final class ProbeLog {
    private let handle: FileHandle?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public private(set) var records: [ProbeRecord] = []

    public init(url: URL?) {
        if let url {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        } else {
            handle = nil
        }
    }

    public func append(_ record: ProbeRecord) {
        records.append(record)
        guard let handle, var data = try? encoder.encode(record) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }
}

/// Repeatedly schedules a one-shot main-run-loop `Timer` `interval` seconds out and
/// reports how late each one fired. This mirrors Mick's "check in 30 s".
@MainActor
public final class TimerProbe {
    private let interval: TimeInterval
    private let onFire: @MainActor (_ lateness: Double) -> Void
    private var timer: Timer?

    public init(interval: TimeInterval, onFire: @escaping @MainActor (Double) -> Void) {
        self.interval = interval
        self.onFire = onFire
    }

    public func start() { scheduleNext() }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scheduleNext() {
        let due = Date().addingTimeInterval(interval)
        let t = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onFire(Date().timeIntervalSince(due))
                self.scheduleNext()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

/// Watches a file with a vnode dispatch source on the main queue (the mechanism in
/// SPEC.md §6.3) and hands each newly appended line to `onLine`.
@MainActor
public final class FileWatchProbe {
    private let url: URL
    private let onLine: @MainActor (String) -> Void
    private var source: (any DispatchSourceFileSystemObject)?
    private var offset: UInt64 = 0
    private var partial = Data()

    public init(url: URL, onLine: @escaping @MainActor (String) -> Void) {
        self.url = url
        self.onLine = onLine
    }

    public func start() throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        offset = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readNew() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    private func readNew() {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0 }
        try? h.seek(toOffset: offset)
        let data = (try? h.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        partial.append(data)
        while let nl = partial.firstIndex(of: 0x0A) {
            let line = String(decoding: partial[partial.startIndex..<nl], as: UTF8.self)
            partial.removeSubrange(partial.startIndex...nl)
            if !line.isEmpty { onLine(line) }
        }
    }
}
