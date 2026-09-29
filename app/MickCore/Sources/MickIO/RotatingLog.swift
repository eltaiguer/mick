import Foundation
import Synchronization

/// Where Mick writes diagnostics. Safe to call from any thread.
public protocol MickLogger: Sendable {
    func log(_ message: String)
}

/// `log.txt` (SPEC §12): one timestamped line per message, rotated to `log.txt.old`
/// when it passes the size limit (1 MB), so it never grows without bound.
public final class RotatingLog: MickLogger {
    public let url: URL
    public let limitBytes: UInt64
    private let echoToStderr: Bool
    private let lock = Mutex(())

    public init(url: URL, limitBytes: UInt64 = 1024 * 1024, echoToStderr: Bool = false) {
        self.url = url
        self.limitBytes = limitBytes
        self.echoToStderr = echoToStderr
    }

    public var rotatedURL: URL { url.appendingPathExtension("old") }

    public func log(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        if echoToStderr { FileHandle.standardError.write(Data(line.utf8)) }
        lock.withLock { _ in
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size >= limitBytes {
                try? fm.removeItem(at: rotatedURL)
                try? fm.moveItem(at: url, to: rotatedURL)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}

/// Collects messages in memory (tests).
public final class MemoryLog: MickLogger {
    private let storage = Mutex<[String]>([])
    public init() {}
    public func log(_ message: String) { storage.withLock { $0.append(message) } }
    public var messages: [String] { storage.withLock { $0 } }
}
