import Foundation
import Testing
@testable import MickCore

/// Hand-edited config.json (§11), the open-at-login lines (§6.5) and the bell.
@Suite struct ConfigFileTests {
    private func parse(_ json: String) -> ConfigFile.Parsed { ConfigFile.parse(Data(json.utf8)) }

    private func config(_ json: String) -> (MickConfig, [String]) {
        guard case .config(let c, let problems) = parse(json) else {
            Issue.record("expected a config for \(json)")
            return (.defaults, [])
        }
        return (c, problems)
    }

    @Test func readsEveryKey() {
        let (c, problems) = config(#"{"sit_threshold_minutes": 40, "break_reset_minutes": 7, "show_delay_seconds": 12, "quiet_hours": {"start": "22:30", "end": "07:00"}, "sound": true}"#)
        #expect(c == MickConfig(sitThresholdMinutes: 40, breakResetMinutes: 7, showDelaySeconds: 12,
                                quietHours: QuietHours(start: "22:30", end: "07:00"), sound: true))
        #expect(problems.isEmpty)
    }

    @Test func whatMickWritesReadsBack() throws {
        let original = MickConfig(sitThresholdMinutes: 25, quietHours: QuietHours(start: "12:00", end: "13:00"), sound: true)
        let data = try JSONEncoder.mick().encode(original)
        #expect(ConfigFile.parse(data) == .config(original, problems: []))
        // Human-readable: pretty printed with one key per line.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\n  \"sit_threshold_minutes\" : 25"))
    }

    @Test func missingKeysTakeDefaults() {
        #expect(config("{}").0 == .defaults)
        #expect(config(#"{"sound": true}"#).0 == MickConfig(sound: true))
    }

    @Test func aWrongTypeOnlyCostsThatValue() {
        let (c, problems) = config(#"{"sit_threshold_minutes": "fifty", "sound": true, "show_delay_seconds": 10}"#)
        #expect(c == MickConfig(showDelaySeconds: 10, sound: true))
        #expect(problems.count == 1)
        #expect(problems[0].contains("sit_threshold_minutes"))

        let (c2, p2) = config(#"{"sound": "yes", "break_reset_minutes": true, "show_delay_seconds": 2.5, "quiet_hours": "22:00-07:00"}"#)
        #expect(c2 == .defaults)
        #expect(p2.count == 4)
    }

    @Test func outOfRangeValuesFallBackAndAreReported() {
        let (c, problems) = config(#"{"sit_threshold_minutes": 0, "break_reset_minutes": 99999, "show_delay_seconds": -1, "quiet_hours": {"start": "25:00", "end": "07:00"}}"#)
        #expect(c == .defaults)
        #expect(problems.count == 4)
    }

    @Test func wholeFloatsAndNullQuietHoursAreFine() {
        let (c, problems) = config(#"{"sit_threshold_minutes": 30.0, "quiet_hours": null}"#)
        #expect(c == MickConfig(sitThresholdMinutes: 30))
        #expect(problems.isEmpty)
    }

    @Test func unknownKeysAreIgnored() {
        #expect(config(#"{"colour": "red", "sound": true}"#) == (MickConfig(sound: true), []))
    }

    @Test func notJSONIsUnreadable() {
        #expect(parse(#"{"sit_threshold_minutes": 5"#) == .unreadable("not valid JSON"))
        #expect(parse("") == .unreadable("not valid JSON"))
        #expect(parse("[1, 2]") == .unreadable("not a JSON object"))
    }

    @Test func quietHoursStrings() {
        #expect(QuietHours.string(minutes: 0) == "00:00")
        #expect(QuietHours.string(minutes: 22 * 60 + 5) == "22:05")
        #expect(QuietHours.string(minutes: 1440 + 61) == "01:01")
        #expect(QuietHours.string(minutes: -1) == "23:59")
        for m in stride(from: 0, to: 1440, by: 7) {
            #expect(QuietHours.minutes(QuietHours.string(minutes: m)) == m)
        }
        #expect(QuietHours.suggested.isValid)
    }

    @Test func settingsRangesMatchValidation() {
        for v in [MickConfig.sitThresholdRange.lowerBound, MickConfig.sitThresholdRange.upperBound] {
            #expect(MickConfig(sitThresholdMinutes: v).validated().problems.isEmpty)
        }
        #expect(!MickConfig(sitThresholdMinutes: MickConfig.sitThresholdRange.upperBound + 1).validated().problems.isEmpty)
        #expect(MickConfig(showDelaySeconds: MickConfig.showDelayRange.lowerBound).validated().problems.isEmpty)
        #expect(!MickConfig(showDelaySeconds: MickConfig.showDelayRange.upperBound + 1).validated().problems.isEmpty)
        #expect(!MickConfig(breakResetMinutes: MickConfig.breakResetRange.lowerBound - 1).validated().problems.isEmpty)
    }
}

@Suite struct LoginItemNoteTests {
    @Test func toggleState() {
        #expect(LoginItemStatus.enabled.isOn)
        #expect(LoginItemStatus.requiresApproval.isOn)
        #expect(!LoginItemStatus.notRegistered.isOn)
        #expect(!LoginItemStatus.notFound.isOn)
    }

    @Test func requiresApprovalPointsToLoginItems() {
        let line = LoginItemNote.line(for: .requiresApproval)
        #expect(line?.contains("System Settings → General → Login Items") == true)
        #expect(LoginItemNote.line(for: .enabled) == nil)
        #expect(LoginItemNote.line(for: .notRegistered) == nil)
        #expect(LoginItemNote.line(for: .notFound) != nil)
    }

    @Test func errorsArePlain() {
        let denied = LoginItemNote.error(turningOn: true, deniedByUser: true, code: 11, description: "Operation not permitted")
        #expect(denied.contains("System Settings → General → Login Items"))
        let other = LoginItemNote.error(turningOn: false, deniedByUser: false, code: 3, description: "Invalid signature")
        #expect(other == "Couldn't turn off open at login: Invalid signature (error 3).")
    }
}

@Suite struct BellSoundTests {
    @Test func isAValidWAV() {
        let wav = BellSound.wav()
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        let sampleCount = Int(BellSound.duration * Double(BellSound.sampleRate))
        #expect(wav.count == 44 + sampleCount * 2)
        func u32(_ at: Int) -> UInt32 { wav[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        #expect(u32(4) == UInt32(wav.count - 8))
        #expect(u32(24) == UInt32(BellSound.sampleRate))
        #expect(u32(40) == UInt32(sampleCount * 2))
    }

    @Test func dingsAndDecays() {
        let s = BellSound.samples()
        let peak = s.map(abs).max() ?? 0
        #expect(abs(peak - BellSound.peak) < 1e-9)  // loud enough, never clips
        func rms(_ range: Range<Double>) -> Double {
            let a = Int(range.lowerBound * Double(BellSound.sampleRate)), b = Int(range.upperBound * Double(BellSound.sampleRate))
            return (s[a..<b].reduce(0) { $0 + $1 * $1 } / Double(b - a)).squareRoot()
        }
        #expect(rms(0.0..<0.1) > 0.1)
        #expect(rms(0.0..<0.1) > 3 * rms(0.8..<0.9))  // it rings out
        #expect(abs(s.last ?? 1) < 0.001)  // fades to silence, no click at the end
        #expect(BellSound.samples() == s)  // the same ding every time
    }
}
