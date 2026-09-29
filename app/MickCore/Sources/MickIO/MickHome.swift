import Foundation
import MickCore

/// Mick's home directory (SPEC §12): `$MICK_HOME`, else `~/.mick`.
public struct MickHome: Sendable, Equatable {
    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    /// Resolves `MICK_HOME` (when set and non-empty) or `~/.mick`.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> MickHome {
        if let custom = environment["MICK_HOME"], !custom.isEmpty {
            return MickHome(url: URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true))
        }
        return MickHome(url: homeDirectory.appendingPathComponent(".mick", isDirectory: true))
    }

    public var events: URL { url.appendingPathComponent(EventFilePolicy.fileName) }
    public var rotatedEvents: URL { url.appendingPathComponent(EventFilePolicy.rotatedFileName) }
    public var config: URL { url.appendingPathComponent("config.json") }
    public var state: URL { url.appendingPathComponent("state.json") }
    public var reminders: URL { url.appendingPathComponent("reminders.jsonl") }
    public var log: URL { url.appendingPathComponent("log.txt") }

    /// Creates the directory with mode 0700 if it doesn't exist (§6.3). Returns true
    /// if it was created now (a first launch).
    @discardableResult
    public func ensureExists() throws -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
            }
            return false
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // createDirectory applies the umask to intermediate and final directories; set it explicitly.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return true
    }
}
