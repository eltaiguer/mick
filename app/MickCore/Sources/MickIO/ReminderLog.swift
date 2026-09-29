import Foundation
import MickCore

/// `reminders.jsonl` (SPEC §12.3): one line appended per settled reminder. Never read
/// by the app and never shown in the UI.
public struct ReminderLog: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Appends one record as a single JSON line. Creates the file (mode 0600) if needed.
    public func append(_ record: ReminderRecord) throws {
        let data = Data((try record.jsonLine() + "\n").utf8)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
