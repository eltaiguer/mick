import AppKit
import Foundation
import Testing
@testable import SignalsKit

/// Waits on the main actor until `condition` holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite struct IdleTimeTests {
    @Test func anyInputEventTypeBridges() {
        // kCGAnyInputEventType is ~0; the spec builds it with CGEventType(rawValue: ~0)!.
        #expect(IdleTime.anyInputEventType != nil)
        #expect(IdleTime.anyInputEventType?.rawValue == ~0)
    }

    @Test func readsAFiniteNonNegativeValue() {
        let idle = IdleTime.seconds()
        #expect(idle.isFinite)
        #expect(idle >= 0)
    }

    @Test func readsDoNotRequireInputMonitoringOrAccessibility() {
        // Reading idle time must work whether or not this process has either grant.
        // (Under Terminal it may inherit a grant, so this only proves "works without
        // crashing or blocking"; the no-prompt check from Finder is manual.)
        let start = ContinuousClock.now
        for _ in 0..<100 { _ = IdleTime.seconds() }
        #expect(ContinuousClock.now - start < .seconds(1))
    }
}

@Suite struct ActivityPolicyTests {
    @Test func usesUserInitiatedAllowingIdleSystemSleep() {
        #expect(ActivityPolicy.options == .userInitiatedAllowingIdleSystemSleep)
        #expect(ActivityPolicy.options.contains(.userInitiatedAllowingIdleSystemSleep))
    }

    @Test func neverLatencyCritical() {
        #expect(!ActivityPolicy.options.contains(.latencyCritical))
    }

    @Test func allowsIdleSystemSleep() {
        #expect(!ActivityPolicy.options.contains(.idleSystemSleepDisabled))
    }

    @MainActor @Test func holderRetainsAndEndsToken() {
        let holder = ActivityHolder()
        #expect(!holder.isHeld)
        holder.begin()
        #expect(holder.isHeld)
        holder.begin() // idempotent
        #expect(holder.isHeld)
        holder.end()
        #expect(!holder.isHeld)
    }
}

@MainActor @Suite(.serialized) struct WorkspaceSignalsTests {
    /// Posts the typed main-actor message, the way `NotificationCenter.post(_:subject:)` would.
    func postTyped(_ signal: WorkspaceSignal, on center: NotificationCenter) {
        let ws = NSWorkspace.shared
        switch signal {
        case .willSleep: center.post(NSWorkspace.WillSleepMessage(), subject: ws)
        case .didWake: center.post(NSWorkspace.DidWakeMessage(), subject: ws)
        case .sessionDidResignActive: center.post(NSWorkspace.SessionDidResignActiveMessage(), subject: ws)
        case .sessionDidBecomeActive: center.post(NSWorkspace.SessionDidBecomeActiveMessage(), subject: ws)
        }
    }

    @Test(arguments: WorkspaceSignal.allCases)
    func typedMessageArrivesOnMainActor(_ signal: WorkspaceSignal) async {
        var got: [WorkspaceSignal] = []
        var onMain = true
        let observer = WorkspaceSignals { s in
            onMain = onMain && Thread.isMainThread
            got.append(s)
        }
        postTyped(signal, on: NSWorkspace.shared.notificationCenter)
        #expect(await eventually { got == [signal] })
        #expect(onMain)
        observer.stop()
    }

    /// The system posts the legacy `Notification`; the typed message must bridge from it.
    @Test(arguments: WorkspaceSignal.allCases)
    func legacyNotificationBridgesToTypedMessage(_ signal: WorkspaceSignal) async {
        var got: [WorkspaceSignal] = []
        let observer = WorkspaceSignals { got.append($0) }
        NSWorkspace.shared.notificationCenter.post(name: signal.notificationName, object: NSWorkspace.shared)
        #expect(await eventually { got == [signal] })
        observer.stop()
    }

    /// Delivery is synchronous on the posting thread: the typed observer does not hop
    /// to the main actor. A post from a background thread therefore traps instead of
    /// being delivered. AppKit posts workspace notifications on the main thread, which
    /// is what makes the `MainActorMessage` contract hold (real sleep/wake is a manual check).
    @Test func backgroundPostTrapsRatherThanHopping() async {
        await #expect(processExitsWith: .failure) {
            let observer = await MainActor.run { WorkspaceSignals { _ in } }
            let name = WorkspaceSignal.didWake.notificationName
            await Task.detached {
                NSWorkspace.shared.notificationCenter.post(name: name, object: NSWorkspace.shared)
            }.value
            await MainActor.run { observer.stop() }
        }
    }

    /// Apple: observers on a different center don't receive workspace notifications.
    @Test func otherCenterDoesNotReceive() async {
        var got: [WorkspaceSignal] = []
        let observer = WorkspaceSignals(center: .default) { got.append($0) }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        postTyped(.willSleep, on: NSWorkspace.shared.notificationCenter)
        #expect(await eventually(timeout: .milliseconds(300)) { !got.isEmpty } == false)
        observer.stop()
    }

    @Test func stopEndsDelivery() async {
        var got: [WorkspaceSignal] = []
        let observer = WorkspaceSignals { got.append($0) }
        observer.stop()
        postTyped(.didWake, on: NSWorkspace.shared.notificationCenter)
        #expect(await eventually(timeout: .milliseconds(300)) { !got.isEmpty } == false)
    }

    @Test func releasingTheObserverEndsDelivery() async {
        var got: [WorkspaceSignal] = []
        var observer: WorkspaceSignals? = WorkspaceSignals { got.append($0) }
        _ = observer
        observer = nil
        postTyped(.didWake, on: NSWorkspace.shared.notificationCenter)
        #expect(await eventually(timeout: .milliseconds(300)) { !got.isEmpty } == false)
    }
}

@MainActor @Suite struct ProbeTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("signals-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func timerProbeFiresOnTime() async {
        var lateness: [Double] = []
        let probe = TimerProbe(interval: 0.1) { lateness.append($0) }
        probe.start()
        #expect(await eventually { lateness.count >= 3 })
        probe.stop()
        #expect(lateness.allSatisfy { $0 >= 0 && $0 < 0.5 })
    }

    @Test func fileWatchSeesAppendedLinesQuickly() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("watch.txt")
        var latencies: [Double] = []
        let probe = FileWatchProbe(url: url) { line in
            if let l = WriterLine.latency(of: line) { latencies.append(l) }
        }
        try probe.start()
        for _ in 0..<3 {
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            try h.write(contentsOf: Data((WriterLine.make() + "\n").utf8))
            try h.close()
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await eventually { latencies.count == 3 })
        probe.stop()
        #expect(latencies.allSatisfy { $0 >= 0 && $0 < 2 })
    }

    @Test func fileWatchHandlesPartialLinesAndTruncation() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("watch.txt")
        try Data("old\n".utf8).write(to: url)
        var lines: [String] = []
        let probe = FileWatchProbe(url: url) { lines.append($0) }
        try probe.start()
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data("ab".utf8))
        try await Task.sleep(for: .milliseconds(100))
        try h.write(contentsOf: Data("c\n".utf8))
        #expect(await eventually { lines == ["abc"] })
        // Truncate, then write: offset resets to 0.
        try h.truncate(atOffset: 0)
        try h.seek(toOffset: 0)
        try h.write(contentsOf: Data("new\n".utf8))
        try h.close()
        #expect(await eventually { lines == ["abc", "new"] })
        probe.stop()
    }

    @Test func logWritesJSONLAndSummaryReadsIt() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("r.jsonl")
        let log = ProbeLog(url: url)
        log.append(ProbeRecord(kind: .start, t: 0, note: "x"))
        log.append(ProbeRecord(kind: .timer, t: 30, lateness: 0.2))
        log.append(ProbeRecord(kind: .timer, t: 60, lateness: 1.5))
        log.append(ProbeRecord(kind: .fileWatch, t: 70, lateness: 0.01))
        log.append(ProbeRecord(kind: .fileWatch, t: 80, lateness: 3))
        log.append(ProbeRecord(kind: .signal, t: 90, note: "didWake"))
        log.append(ProbeRecord(kind: .end, t: 120))
        let s = try ProbeSummary.load(url)
        #expect(s.label == "x")
        #expect(s.durationSeconds == 120)
        #expect(s.timerFires == 2)
        #expect(s.timerMaxLateness == 1.5)
        #expect(s.timerLateOver1s == 1)
        #expect(s.fileWatchCallbacks == 2)
        #expect(s.fileWatchOver2s == 1)
        #expect(s.signals == ["didWake"])
    }

    @Test func writerLineRoundTrips() {
        let now = Date()
        let line = WriterLine.make(at: now.addingTimeInterval(-1))
        let l = WriterLine.latency(of: line, receivedAt: now)
        #expect(l != nil)
        #expect(abs((l ?? 0) - 1) < 0.001)
        #expect(WriterLine.latency(of: "garbage") == nil)
    }
}
