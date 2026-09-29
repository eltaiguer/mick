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

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknown(String)
        case missingValue(String)

        var description: String {
            switch self {
            case .unknown(let a): "unknown argument \(a)"
            case .missingValue(let a): "\(a) needs a value"
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
