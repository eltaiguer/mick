import Foundation
import MickCore

/// How a JSON file load went (SPEC §12.2).
public enum LoadOutcome: Equatable, Sendable {
    case loaded
    case missing
    /// Couldn't be decoded; moved aside to this path and replaced with defaults.
    case corrupt(movedTo: URL?)
}

/// Loads and saves Mick's JSON files. Never throws to the caller: a missing file
/// gives defaults, a corrupted one is moved aside to `<name>.corrupt-<timestamp>` and
/// replaced with defaults, and every such case is logged.
public enum JSONFileStore {
    public static func load<T: Decodable>(
        _ type: T.Type, from url: URL, defaults: T, now: Date, log: any MickLogger
    ) -> (value: T, outcome: LoadOutcome) {
        let name = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            log.log("\(name) missing; using defaults")
            return (defaults, .missing)
        } catch {
            log.log("\(name) unreadable (\(error.localizedDescription)); using defaults")
            return (defaults, .corrupt(movedTo: moveAside(url, now: now, log: log)))
        }
        do {
            return (try JSONDecoder.mick().decode(T.self, from: data), .loaded)
        } catch {
            let moved = moveAside(url, now: now, log: log)
            log.log("\(name) corrupted (\(describe(error))); moved to \(moved?.lastPathComponent ?? "nowhere") and replaced with defaults")
            return (defaults, .corrupt(movedTo: moved))
        }
    }

    /// Writes atomically (temp file + rename), mode 0600.
    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder.mick().encode(value) + Data("\n".utf8)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// `state.json.corrupt-20260929T130501Z` (with a counter if that exists already).
    public static func corruptURL(for url: URL, now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: now)
        var candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            n += 1
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)-\(n)")
        }
        return candidate
    }

    private static func moveAside(_ url: URL, now: Date, log: any MickLogger) -> URL? {
        let target = corruptURL(for: url, now: now)
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            log.log("couldn't move \(url.lastPathComponent) aside: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let c): c.debugDescription
        case DecodingError.keyNotFound(let key, _): "missing \(key.stringValue)"
        case DecodingError.typeMismatch(_, let c): "wrong type at \(c.codingPath.map(\.stringValue).joined(separator: "."))"
        case DecodingError.valueNotFound(_, let c): "null at \(c.codingPath.map(\.stringValue).joined(separator: "."))"
        default: String(describing: error)
        }
    }
}
