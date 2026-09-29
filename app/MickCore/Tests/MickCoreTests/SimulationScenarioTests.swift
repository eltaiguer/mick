import Foundation
import Testing
@testable import MickCore

/// The scripted scenarios themselves (issue #12): every one the ticket lists exists,
/// and each script says what it claims.
struct SimulationScenarioTests {
    @Test func everyListedScenarioExistsOnce() {
        #expect(SimulationScenario.all.map(\.id) == SimulationScenario.ID.allCases)
        #expect(Set(SimulationScenario.all.map(\.title)).count == SimulationScenario.all.count)
        for s in SimulationScenario.all {
            #expect(!s.expectations.isEmpty, "\(s.id) checks nothing")
            #expect(s.steps.map(\.at) == s.steps.map(\.at).sorted())
            #expect(s.duration > s.steps.last!.at)
        }
    }

    @Test func settingsAreOneMinuteThresholdsAndAFiveSecondDelay() {
        let c = SimulationScenario.config
        #expect(c.sitThresholdMinutes == 1 && c.breakResetMinutes == 1 && c.showDelaySeconds == 5)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let s = SimulationScenario.initialState(now: now)
        #expect(SittingTimer.isArmed(s, config: c, now: now))
        #expect(s.sessions.isEmpty && s.nagAfter == nil && s.snoozedUntil == nil && !s.paused)
    }

    private func events(_ id: SimulationScenario.ID) -> [(at: TimeInterval, kind: MickEvent.Kind, session: String, t: TimeInterval)] {
        SimulationScenario.named(id).steps.compactMap {
            if case .event(let k, let s, let t) = $0.action { ($0.at, k, s, t) } else { nil }
        }
    }

    @Test func outOfOrderWritesTheStopFirstWithTheLaterTime() {
        let e = events(.outOfOrder)
        #expect(e.map(\.kind) == [.stop, .prompt])
        #expect(e[0].at < e[1].at && e[0].t > e[1].t)
        #expect(Set(e.map(\.session)).count == 1)
    }

    @Test func escInterruptNeverStops() {
        let e = events(.escInterrupt)
        #expect(e.map(\.kind) == [.prompt])
        #expect(SimulationScenario.named(.escInterrupt).duration > Reminder.Timings.standard.untouchedClose)
    }

    @Test func permissionPauseWaitsWhileThePanelIsUp() {
        let e = events(.permissionPause)
        #expect(e.map(\.kind) == [.prompt, .wait])
        #expect(e[1].at > Double(SimulationScenario.config.showDelaySeconds))
    }

    @Test func threeSessionsRunConcurrently() {
        let e = events(.threeSessions)
        #expect(Set(e.map(\.session)).count == 3)
        let firstStop = e.first { $0.kind == .stop }!.at
        #expect(e.filter { $0.kind == .prompt && $0.at < firstStop }.map(\.session).count >= 3)
    }

    @Test func handOffStopsTheFirstSessionBeforeItsCheck() {
        let e = events(.handOff)
        let delay = Double(SimulationScenario.config.showDelaySeconds)
        let firstStop = e.first { $0.kind == .stop }!
        #expect(firstStop.session == e[0].session && firstStop.at < e[0].at + delay)
        #expect(e.contains { $0.kind == .prompt && $0.session != firstStop.session && $0.at < firstStop.at })
    }

    @Test func shortRunStopsInsideTheDelay() {
        let e = events(.shortRun)
        #expect(e.map(\.kind) == [.prompt, .stop])
        #expect(e[1].at - e[0].at < Double(SimulationScenario.config.showDelaySeconds))
    }
}
