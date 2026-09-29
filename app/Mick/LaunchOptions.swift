import Foundation
import MickCore

/// Command-line arguments: the self-check, and simulation mode in debug builds.
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
    /// scenario end to end with real hook events (`show-stop`, `short-run`, `tick-stays`,
    /// `panel-snooze`, `stretch-now`, `menu-controls`). The caller prepares an armed
    /// state and a short show delay in `MICK_HOME`.
    var smokeReminder: SmokeReminder?

#if DEBUG
    /// `--simulate [SCENARIO|all]` (debug builds only; SPEC §16): run against a fresh
    /// temporary Mick home with simulation settings, and play one scenario (or all of
    /// them in order) at launch. Without a scenario, it just starts in simulation mode;
    /// the Simulate menu plays scenarios in every debug build.
    var simulate: Simulate?
    /// `--simulate-idle SECONDS`: report this fixed system idle time to simulation runs
    /// instead of the real one (unattended checks; a person should use the real one).
    var simulateIdle: Double?
    /// `--simulate-exit`: quit when the scenarios are done, with status 0 if every
    /// check passed and 1 otherwise.
    var simulateExit = false
    /// `--simulate-via-menu`: start the scenario by choosing it in the status item's
    /// Simulate menu, the way a person does (unattended check of the menu wiring).
    var simulateViaMenu = false

    enum Simulate: Equatable {
        case menuOnly
        case scenarios([SimulationScenario.ID])
    }
#endif

    enum SmokeReminder: String, CaseIterable {
        case showStop = "show-stop"
        case shortRun = "short-run"
        case tickStays = "tick-stays"
        /// Snooze ▾ → 1 hour on the panel settles it as Snoozed.
        case panelSnooze = "panel-snooze"
        /// Stretch now from the menu: a manual panel agent stops don't close.
        case stretchNow = "stretch-now"
        /// Pause, resume and snooze from the menu. Ends paused, so a relaunch can
        /// check the pause persisted.
        case menuControls = "menu-controls"
    }

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknown(String)
        case missingValue(String)
        case badValue(String)
        case conflict(String)

        var description: String {
            switch self {
            case .conflict(let a): a
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
#if DEBUG
            case "--simulate":
                if i + 1 < args.count, !args[i + 1].hasPrefix("-") {
                    let value = args[i + 1]
                    if value == "all" {
                        options.simulate = .scenarios(SimulationScenario.ID.allCases)
                    } else if let id = SimulationScenario.ID(rawValue: value) {
                        options.simulate = .scenarios([id])
                    } else {
                        throw ParseError.badValue(arg)
                    }
                    i += 1
                } else {
                    options.simulate = .menuOnly
                }
            case "--simulate-idle":
                guard i + 1 < args.count else { throw ParseError.missingValue(arg) }
                guard let seconds = Double(args[i + 1]), seconds.isFinite, seconds >= 0 else { throw ParseError.badValue(arg) }
                options.simulateIdle = seconds
                i += 1
            case "--simulate-exit":
                options.simulateExit = true
            case "--simulate-via-menu":
                options.simulateViaMenu = true
#endif
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
#if DEBUG
        if options.smoke, options.simulate != nil { throw ParseError.conflict("--smoke and --simulate can't be combined") }
        if options.simulate == nil, options.simulateIdle != nil || options.simulateExit || options.simulateViaMenu {
            throw ParseError.conflict("--simulate-idle, --simulate-exit and --simulate-via-menu need --simulate")
        }
        if options.simulate == .menuOnly, options.simulateExit || options.simulateViaMenu {
            throw ParseError.conflict("--simulate-exit and --simulate-via-menu need a scenario (--simulate SCENARIO)")
        }
        if options.simulateViaMenu, case .scenarios(let ids)? = options.simulate, ids.count != 1 {
            throw ParseError.conflict("--simulate-via-menu plays one scenario")
        }
#endif
        return options
    }
}
