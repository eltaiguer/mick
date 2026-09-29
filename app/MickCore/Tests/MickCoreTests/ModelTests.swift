import Foundation
import Testing
@testable import MickCore

@Suite struct EventFilePolicyTests {
    @Test func keepsTheSavedOffsetWhenTheFileIsLongEnough() {
        #expect(EventFilePolicy.startOffset(saved: 100, fileSize: 100) == 100)
        #expect(EventFilePolicy.startOffset(saved: 100, fileSize: 500) == 100)
    }

    @Test func resetsTheOffsetWhenTheFileShrank() {
        #expect(EventFilePolicy.startOffset(saved: 500, fileSize: 100) == 0)
        #expect(EventFilePolicy.startOffset(saved: 1, fileSize: 0) == 0)
    }

    @Test func rotatesOnlyPast256KBAndFullyRead() {
        let limit = EventFilePolicy.rotateBytes
        #expect(limit == 262_144)
        #expect(!EventFilePolicy.shouldRotate(fileSize: limit, offset: limit))
        #expect(EventFilePolicy.shouldRotate(fileSize: limit + 1, offset: limit + 1))
        #expect(!EventFilePolicy.shouldRotate(fileSize: limit + 100, offset: limit + 50))
    }
}

@Suite struct HooksStatusTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func notDetectedUntilAnEventArrives() {
        let status = HooksStatus.evaluate(lastEventAt: nil, now: now)
        #expect(status == .notDetected)
        #expect(status.showsWarning)
        #expect(!status.everDetected)
        #expect(status.menuLine == "Claude Code hooks not detected. Set up…")
        #expect(MenuBarIcon.current(hooks: status) == .warning)
    }

    @Test func detectedClearsTheWarning() {
        let status = HooksStatus.evaluate(lastEventAt: now.addingTimeInterval(-60), now: now)
        #expect(status == .detected(lastEventAt: now.addingTimeInterval(-60)))
        #expect(!status.showsWarning)
        #expect(status.everDetected)
        #expect(status.menuLine == nil)
        #expect(MenuBarIcon.current(hooks: status) == .calm)
    }

    @Test func staleAfterSevenDays() {
        let justUnder = HooksStatus.evaluate(lastEventAt: now.addingTimeInterval(-7 * 86400 + 1), now: now)
        #expect(!justUnder.showsWarning)
        let stale = HooksStatus.evaluate(lastEventAt: now.addingTimeInterval(-7 * 86400), now: now)
        #expect(stale == .stale(lastEventAt: now.addingTimeInterval(-7 * 86400)))
        #expect(stale.showsWarning)
        #expect(stale.everDetected)
        #expect(stale.menuLine != nil)
        #expect(MenuBarIcon.current(hooks: stale) == .warning)
    }
}

@Suite struct ConfigTests {
    @Test func defaultsMatchTheSpec() throws {
        let json = String(decoding: try JSONEncoder.mick().encode(MickConfig.defaults), as: UTF8.self)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        #expect(object["sit_threshold_minutes"] as? Int == 50)
        #expect(object["break_reset_minutes"] as? Int == 5)
        #expect(object["show_delay_seconds"] as? Int == 30)
        #expect(object["quiet_hours"] is NSNull)
        #expect(object["sound"] as? Bool == false)
    }

    @Test func missingKeysTakeDefaults() throws {
        let config = try JSONDecoder.mick().decode(MickConfig.self, from: Data(#"{"sit_threshold_minutes": 1}"#.utf8))
        #expect(config == MickConfig(sitThresholdMinutes: 1))
        #expect(try JSONDecoder.mick().decode(MickConfig.self, from: Data("{}".utf8)) == .defaults)
    }

    @Test func quietHoursRoundTrip() throws {
        let config = MickConfig(quietHours: QuietHours(start: "22:30", end: "07:00"))
        let back = try JSONDecoder.mick().decode(MickConfig.self, from: JSONEncoder.mick().encode(config))
        #expect(back == config)
    }

    @Test func wrongTypesFailToDecode() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder.mick().decode(MickConfig.self, from: Data(#"{"sound": "yes"}"#.utf8))
        }
    }

    @Test func outOfRangeValuesFallBackToDefaults() {
        let (fixed, problems) = MickConfig(
            sitThresholdMinutes: 0, breakResetMinutes: -1, showDelaySeconds: 99999,
            quietHours: QuietHours(start: "25:00", end: "7")
        ).validated()
        #expect(fixed == .defaults)
        #expect(problems.count == 4)
        #expect(MickConfig(sitThresholdMinutes: 1).validated().problems.isEmpty)
    }

    @Test func quietHoursParsing() {
        #expect(QuietHours.minutes("00:00") == 0)
        #expect(QuietHours.minutes("23:59") == 1439)
        #expect(QuietHours.minutes("24:00") == nil)
        #expect(QuietHours.minutes("7:00") == nil)
        #expect(QuietHours.minutes("ab:cd") == nil)
    }
}

@Suite struct StateTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func encodesTheSpecFieldNames() throws {
        var state = MickState.defaults(now: now)
        state.sessions["s1"] = .init(running: true, runStartedAt: now, lastEventAt: now, cwd: "/p")
        state.eventsOffset = 42
        let object = try JSONSerialization.jsonObject(with: JSONEncoder.mick().encode(state)) as! [String: Any]
        #expect(Set(object.keys) == [
            "sitting_since", "last_active_at", "last_event_at", "snoozed_until", "nag_after",
            "paused", "today", "rotation", "sessions", "events_offset",
        ])
        #expect(object["sitting_since"] as? String == "2026-09-21T14:13:20.000000Z")
        #expect(object["last_event_at"] is NSNull)
        #expect(object["events_offset"] as? Int == 42)
        let session = (object["sessions"] as! [String: Any])["s1"] as! [String: Any]
        #expect(Set(session.keys) == ["running", "run_started_at", "last_event_at", "cwd"])
        let rotation = object["rotation"] as! [String: Any]
        #expect(Set(rotation.keys) == ["used_move_ids", "last_areas", "used_line_ids"])
        #expect(Set((object["today"] as! [String: Any]).keys) == ["date", "ignored"])
    }

    @Test func roundTrips() throws {
        var state = MickState.defaults(now: now)
        state.lastEventAt = now.addingTimeInterval(0.123456)
        state.sessions["s1"] = .init(running: false, runStartedAt: nil, lastEventAt: now, cwd: nil, ended: true)
        state.rotation.usedLineIDs["opener"] = ["o1"]
        let back = try JSONDecoder.mick().decode(MickState.self, from: JSONEncoder.mick().encode(state))
        #expect(back == state)
    }

    @Test func missingKeysTakeDefaults() throws {
        let state = try JSONDecoder.mick().decode(MickState.self, from: Data(#"{"events_offset": 7, "paused": true}"#.utf8))
        #expect(state.eventsOffset == 7)
        #expect(state.paused)
        #expect(state.sessions.isEmpty)
        #expect(state.lastEventAt == nil)
    }

    @Test func badValuesFailToDecode() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder.mick().decode(MickState.self, from: Data(#"{"sitting_since": "not a date"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder.mick().decode(MickState.self, from: Data(#"{"events_offset": -1}"#.utf8))
        }
    }
}
