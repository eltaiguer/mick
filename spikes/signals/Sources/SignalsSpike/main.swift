import AppKit
import ApplicationServices
import SignalsKit

// Modes:
//   SignalsSpike                      interactive (e.g. launched from Finder): status item shows live idle time
//   SignalsSpike appnap --results P --watch P [--duration S] [--interval S] [--activity on|off] [--label L]
//   SignalsSpike writer --file P [--interval S] [--duration S]
//   SignalsSpike summarize FILE...

struct Options {
    var mode = "interactive"
    var values: [String: String] = [:]
    var positional: [String] = []

    init(_ args: [String]) {
        var rest = Array(args.dropFirst())
        if let first = rest.first, !first.hasPrefix("-") {
            mode = first
            rest.removeFirst()
        }
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a.hasPrefix("--"), i + 1 < rest.count {
                values[String(a.dropFirst(2))] = rest[i + 1]
                i += 2
            } else if a.hasPrefix("-") {
                // Ignore flags LaunchServices may add (e.g. -NSDocumentRevisionsDebugMode).
                i += 2
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    func double(_ key: String, _ fallback: Double) -> Double { values[key].flatMap(Double.init) ?? fallback }
}

func permissionNote() -> String {
    "listenEventAccess=\(CGPreflightListenEventAccess()) accessibilityTrusted=\(AXIsProcessTrusted()) bundle=\(Bundle.main.bundleIdentifier ?? "none")"
}

@MainActor
final class AppNapRun: NSObject, NSApplicationDelegate {
    let opts: Options
    var log: ProbeLog!
    var timer: TimerProbe!
    var watch: FileWatchProbe!
    var signals: WorkspaceSignals!
    let activity = ActivityHolder()

    init(opts: Options) { self.opts = opts }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let results = opts.values["results"], let watchPath = opts.values["watch"] else {
            FileHandle.standardError.write(Data("appnap needs --results and --watch\n".utf8))
            exit(2)
        }
        let label = opts.values["label"] ?? "run"
        let useActivity = opts.values["activity"] == "on"
        log = ProbeLog(url: URL(fileURLWithPath: results))
        if useActivity { activity.begin() }
        log.append(ProbeRecord(kind: .start, t: Date().timeIntervalSince1970, note: label))
        log.append(ProbeRecord(kind: .idle, t: Date().timeIntervalSince1970, idle: IdleTime.seconds(),
                               note: "activity=\(activity.isHeld) options=\(ActivityPolicy.options.rawValue) " + permissionNote()))

        signals = WorkspaceSignals { [weak self] s in
            self?.log.append(ProbeRecord(kind: .signal, t: Date().timeIntervalSince1970, note: s.rawValue))
        }
        timer = TimerProbe(interval: opts.double("interval", 30)) { [weak self] late in
            self?.log.append(ProbeRecord(kind: .timer, t: Date().timeIntervalSince1970, lateness: late, idle: IdleTime.seconds()))
        }
        timer.start()
        watch = FileWatchProbe(url: URL(fileURLWithPath: watchPath)) { [weak self] line in
            self?.log.append(ProbeRecord(kind: .fileWatch, t: Date().timeIntervalSince1970,
                                         lateness: WriterLine.latency(of: line)))
        }
        do { try watch.start() } catch {
            log.append(ProbeRecord(kind: .end, t: Date().timeIntervalSince1970, note: "watch failed: \(error)"))
            exit(3)
        }
        let duration = opts.double("duration", 33 * 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    func finish() {
        timer.stop()
        watch.stop()
        signals.stop()
        activity.end()
        log.append(ProbeRecord(kind: .end, t: Date().timeIntervalSince1970))
        NSApp.terminate(nil)
    }
}

@MainActor
final class InteractiveRun: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var signals: WorkspaceSignals!
    var log: ProbeLog!
    var ticker: Timer?
    let history = NSMenuItem(title: "No workspace signals yet", action: nil, keyEquivalent: "")
    let perms = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var seen: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mick-signals-spike", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log = ProbeLog(url: dir.appendingPathComponent("interactive-\(Int(Date().timeIntervalSince1970)).jsonl"))
        log.append(ProbeRecord(kind: .start, t: Date().timeIntervalSince1970, note: "interactive " + permissionNote()))

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        perms.title = permissionNote()
        menu.addItem(perms)
        menu.addItem(history)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Log: \(dir.path)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        signals = WorkspaceSignals { [weak self] s in
            guard let self else { return }
            let stamp = Date().formatted(date: .omitted, time: .standard)
            seen.append("\(s.rawValue) \(stamp)")
            history.title = seen.suffix(4).joined(separator: " | ")
            log.append(ProbeRecord(kind: .signal, t: Date().timeIntervalSince1970, idle: IdleTime.seconds(), note: s.rawValue))
        }
        refresh()
        let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { self.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func refresh() {
        let idle = IdleTime.seconds()
        item.button?.title = String(format: "idle %.0fs", idle)
    }
}

let opts = Options(CommandLine.arguments)

switch opts.mode {
case "summarize":
    for path in opts.positional {
        do {
            print(try ProbeSummary.load(URL(fileURLWithPath: path)).text)
            print("")
        } catch {
            FileHandle.standardError.write(Data("\(path): \(error)\n".utf8))
            exit(1)
        }
    }
case "writer":
    guard let file = opts.values["file"] else {
        FileHandle.standardError.write(Data("writer needs --file\n".utf8))
        exit(2)
    }
    let interval = opts.double("interval", 47)
    let end = Date().addingTimeInterval(opts.double("duration", 33 * 60))
    let url = URL(fileURLWithPath: file)
    if !FileManager.default.fileExists(atPath: file) { FileManager.default.createFile(atPath: file, contents: nil) }
    while Date() < end {
        Thread.sleep(forTimeInterval: interval)
        guard let h = try? FileHandle(forWritingTo: url) else { exit(1) }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data((WriterLine.make() + "\n").utf8))
        try? h.close()
    }
case "appnap":
    let app = NSApplication.shared
    let delegate = AppNapRun(opts: opts)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
default:
    let app = NSApplication.shared
    let delegate = InteractiveRun()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
