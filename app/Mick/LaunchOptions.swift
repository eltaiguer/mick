import Foundation

/// Command-line arguments. Only the self-check uses any today.
struct LaunchOptions: Equatable {
    /// `--smoke`: launch, check the shell end to end against `$MICK_HOME`, print
    /// PASS/FAIL lines and quit. Refuses to run without `MICK_HOME`, so it can never
    /// touch `~/.mick`.
    var smoke = false
    /// `--smoke-hook PATH`: the plugin's `mick-event.sh`, run by the smoke check to
    /// produce a real hook event.
    var smokeHook: String?
    /// `--smoke-idle SECONDS`: with `--smoke`, report this fixed system idle time
    /// instead of the real one, so sitting-timer checks don't depend on whether
    /// someone is using the Mac.
    var smokeIdle: Double?
    /// `--smoke-reminder SCENARIO`: with `--smoke` and `--smoke-hook`, run one reminder
    /// scenario end to end with real hook events (`show-stop`, `short-run`, `tick-stays`).
    /// The caller prepares an armed state and a short show delay in `MICK_HOME`.
    var smokeReminder: SmokeReminder?

    enum SmokeReminder: String, CaseIterable {
        case showStop = "show-stop"
        case shortRun = "short-run"
        case tickStays = "tick-stays"
    }

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknown(String)
        case missingValue(String)
        case badValue(String)

        var description: String {
            switch self {
            case .unknown(let a): "unknown argument \(a)"
            case .missingValue(let a): "\(a) needs a value"
            case .badValue(let a): "bad value for \(a)"
            }
        }
    }

    static func parse(_ args: [String]) throws -> LaunchOptions {
        var options = LaunchOptions()
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--smoke":
                options.smoke = true
            case "--smoke-hook":
                guard i + 1 < args.count else { throw ParseError.missingValue(arg) }
                options.smokeHook = args[i + 1]
                i += 1
            case "--smoke-reminder":
                guard i + 1 < args.count else { throw ParseError.missingValue(arg) }
                guard let scenario = SmokeReminder(rawValue: args[i + 1]) else { throw ParseError.badValue(arg) }
                options.smokeReminder = scenario
                i += 1
            case "--smoke-idle":
                guard i + 1 < args.count else { throw ParseError.missingValue(arg) }
                guard let seconds = Double(args[i + 1]), seconds.isFinite, seconds >= 0 else { throw ParseError.badValue(arg) }
                options.smokeIdle = seconds
                i += 1
            default:
                // AppKit/Xcode pass things like `-NSDocumentRevisionsDebugMode YES`.
                if arg.hasPrefix("-") && !arg.hasPrefix("--") {
                    if i + 1 < args.count, !args[i + 1].hasPrefix("-") { i += 1 }
                } else {
                    throw ParseError.unknown(arg)
                }
            }
            i += 1
        }
        return options
    }
}
