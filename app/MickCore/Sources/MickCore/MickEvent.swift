import Foundation

/// One line of `events.jsonl` (SPEC §6.2):
/// `{"e":"prompt","t":1790000000.123,"s":"<session_id>","c":"/path","n":null}`
public struct MickEvent: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case prompt, stop, wait, end
    }

    public var kind: Kind
    /// Unix time in seconds, taken when the hook ran.
    public var time: Double
    public var sessionID: String
    public var cwd: String?
    /// `notification_type` for `wait` events from `Notification`. Diagnostics only:
    /// unknown values are kept, never rejected.
    public var notificationType: String?

    public init(kind: Kind, time: Double, sessionID: String, cwd: String? = nil, notificationType: String? = nil) {
        self.kind = kind
        self.time = time
        self.sessionID = sessionID
        self.cwd = cwd
        self.notificationType = notificationType
    }

    public var date: Date { Date(timeIntervalSince1970: time) }
}

public enum EventParseError: Error, Equatable, Sendable, CustomStringConvertible {
    case notJSONObject
    case unknownKind(String)
    case missingField(String)
    case badField(String)

    public var description: String {
        switch self {
        case .notJSONObject: "not a JSON object"
        case .unknownKind(let e): "unknown event \"\(e)\""
        case .missingField(let f): "missing field \"\(f)\""
        case .badField(let f): "bad value for \"\(f)\""
        }
    }
}

public enum EventParser {
    /// Parses one line. Extra fields are ignored so other agents can add their own.
    public static func parse(_ line: some StringProtocol) -> Result<MickEvent, EventParseError> {
        guard let data = String(line).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let dict = object as? [String: Any] else {
            return .failure(.notJSONObject)
        }
        guard let rawKind = dict["e"] else { return .failure(.missingField("e")) }
        guard let kindText = rawKind as? String else { return .failure(.badField("e")) }
        guard let kind = MickEvent.Kind(rawValue: kindText) else { return .failure(.unknownKind(kindText)) }

        guard let rawTime = dict["t"] else { return .failure(.missingField("t")) }
        // JSONSerialization gives NSNumber; reject booleans, which also bridge to NSNumber.
        guard let number = rawTime as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue > 0 else {
            return .failure(.badField("t"))
        }

        guard let rawSession = dict["s"], !(rawSession is NSNull) else { return .failure(.missingField("s")) }
        guard let session = rawSession as? String, !session.isEmpty else { return .failure(.badField("s")) }

        let cwd = dict["c"] as? String
        let notification = dict["n"] as? String
        return .success(MickEvent(kind: kind, time: number.doubleValue, sessionID: session, cwd: cwd, notificationType: notification))
    }
}

/// Splits raw bytes read from the events file into complete lines.
///
/// Only bytes up to and including the last newline are consumed; a trailing partial
/// line stays in the file for the next read (a hook write is a single `write`, but the
/// app can still read between two hooks' writes landing in the page cache).
public enum EventLines {
    public struct Split: Equatable, Sendable {
        public var lines: [String]
        /// Bytes consumed from the start of the chunk (through the last newline).
        public var consumed: Int
    }

    public static func split(_ chunk: Data, includeTrailingPartial: Bool = false) -> Split {
        let newline = UInt8(ascii: "\n")
        var lines: [String] = []
        var start = chunk.startIndex
        var consumedEnd = chunk.startIndex
        var i = chunk.startIndex
        while i < chunk.endIndex {
            if chunk[i] == newline {
                appendLine(chunk[start..<i], to: &lines)
                start = chunk.index(after: i)
                consumedEnd = start
            }
            i = chunk.index(after: i)
        }
        if includeTrailingPartial, start < chunk.endIndex {
            appendLine(chunk[start..<chunk.endIndex], to: &lines)
            consumedEnd = chunk.endIndex
        }
        return Split(lines: lines, consumed: chunk.distance(from: chunk.startIndex, to: consumedEnd))
    }

    private static func appendLine(_ bytes: Data, to lines: inout [String]) {
        // Invalid UTF-8 still becomes a (malformed) line so it's skipped and logged, not lost silently.
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { lines.append(text) }
    }
}
