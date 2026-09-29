import Foundation

/// Launch arguments of the spike app.
public struct SpikeOptions: Equatable, Sendable {
    /// `.regular` activation policy instead of `.accessory`, for the fullscreen comparison.
    public var regular = false
    public var level: PanelLevel = .statusBar
    /// Show the panel, check focus and first clicks, print a report and quit.
    public var smoke = false
    /// Show the panel this many seconds after launch.
    public var showAfter: Double?
    /// Toggle the panel every this many seconds (for the typing test).
    public var cycle: Double?
    /// Ask for a status item slot near the right edge of the menu bar.
    public var preferRight = false
    /// Also append the focus log to this file.
    public var logPath: String?

    public init() {}

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknown(String)
        case missingValue(String)
        case badValue(String, String)

        public var description: String {
            switch self {
            case .unknown(let a): "unknown argument \(a)"
            case .missingValue(let a): "\(a) needs a value"
            case .badValue(let a, let v): "bad value \(v) for \(a)"
            }
        }
    }

    public static let usage = """
    panel-spike [--regular] [--level statusBar|popUpMenu] [--smoke] [--prefer-right]
                [--show-after SECONDS] [--cycle SECONDS] [--log PATH]
    """

    /// Parses arguments (without the executable path). Ignores the `-NSDocumentRevisionsDebugMode`
    /// style pairs Xcode and LaunchServices may pass.
    public static func parse(_ args: [String]) throws(ParseError) -> SpikeOptions {
        var o = SpikeOptions()
        var it = args.makeIterator()
        func value(_ flag: String) throws(ParseError) -> String {
            guard let v = it.next() else { throw .missingValue(flag) }
            return v
        }
        func seconds(_ flag: String) throws(ParseError) -> Double {
            let v = try value(flag)
            guard let d = Double(v), d > 0 else { throw .badValue(flag, v) }
            return d
        }
        while let a = it.next() {
            switch a {
            case "--regular": o.regular = true
            case "--smoke": o.smoke = true
            case "--prefer-right": o.preferRight = true
            case "--level":
                let v = try value(a)
                guard let l = PanelLevel(rawValue: v) else { throw .badValue(a, v) }
                o.level = l
            case "--show-after": o.showAfter = try seconds(a)
            case "--cycle": o.cycle = try seconds(a)
            case "--log": o.logPath = try value(a)
            default:
                if a.hasPrefix("-NS") || a.hasPrefix("-Apple") || a.hasPrefix("-psn_") {
                    if !a.hasPrefix("-psn_") { _ = it.next() }
                    continue
                }
                throw .unknown(a)
            }
        }
        return o
    }
}
