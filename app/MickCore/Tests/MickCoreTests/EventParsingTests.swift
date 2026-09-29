import Foundation
import Testing
@testable import MickCore

@Suite struct EventParsingTests {
    @Test func parsesAHookLine() throws {
        let line = #"{"e":"prompt","t":1790000000.123456,"s":"abc","c":"/Users/me/project","n":null}"#
        let event = try EventParser.parse(line).get()
        #expect(event == MickEvent(kind: .prompt, time: 1790000000.123456, sessionID: "abc", cwd: "/Users/me/project", notificationType: nil))
    }

    @Test func parsesEveryKind() throws {
        for kind in MickEvent.Kind.allCases {
            let event = try EventParser.parse(#"{"e":"\#(kind.rawValue)","t":1,"s":"x"}"#).get()
            #expect(event.kind == kind)
        }
    }

    @Test func keepsUnknownNotificationTypes() throws {
        let event = try EventParser.parse(#"{"e":"wait","t":5,"s":"x","c":"/p","n":"some_future_type"}"#).get()
        #expect(event.notificationType == "some_future_type")
    }

    @Test func ignoresExtraFields() throws {
        let event = try EventParser.parse(#"{"e":"stop","t":5,"s":"x","agent":"other","extra":[1,2]}"#).get()
        #expect(event.kind == .stop)
        #expect(event.cwd == nil)
    }

    @Test(arguments: [
        ("", EventParseError.notJSONObject),
        ("not json", .notJSONObject),
        (#"{"e":"prompt","t":1,"s":"x""#, .notJSONObject),  // truncated
        ("[1,2,3]", .notJSONObject),
        ("42", .notJSONObject),
        (#"{"t":1,"s":"x"}"#, .missingField("e")),
        (#"{"e":7,"t":1,"s":"x"}"#, .badField("e")),
        (#"{"e":"start","t":1,"s":"x"}"#, .unknownKind("start")),
        (#"{"e":"prompt","s":"x"}"#, .missingField("t")),
        (#"{"e":"prompt","t":"1","s":"x"}"#, .badField("t")),
        (#"{"e":"prompt","t":true,"s":"x"}"#, .badField("t")),
        (#"{"e":"prompt","t":-5,"s":"x"}"#, .badField("t")),
        (#"{"e":"prompt","t":1}"#, .missingField("s")),
        (#"{"e":"prompt","t":1,"s":null}"#, .missingField("s")),
        (#"{"e":"prompt","t":1,"s":""}"#, .badField("s")),
        (#"{"e":"prompt","t":1,"s":12}"#, .badField("s")),
    ])
    func rejectsMalformedLines(line: String, expected: EventParseError) {
        #expect(EventParser.parse(line) == .failure(expected))
    }

    @Test func splitsOnlyCompleteLines() {
        let data = Data("a\nbb\nccc".utf8)
        let split = EventLines.split(data)
        #expect(split.lines == ["a", "bb"])
        #expect(split.consumed == 5)
    }

    @Test func splitKeepsTheTrailingPartialWhenAsked() {
        let split = EventLines.split(Data("a\nccc".utf8), includeTrailingPartial: true)
        #expect(split.lines == ["a", "ccc"])
        #expect(split.consumed == 5)
    }

    @Test func splitSkipsBlankLinesButConsumesThem() {
        let split = EventLines.split(Data("\n\n  \nx\n".utf8))
        #expect(split.lines == ["x"])
        #expect(split.consumed == 7)
    }

    @Test func splitWithNoNewlineConsumesNothing() {
        let split = EventLines.split(Data(#"{"e":"prompt""#.utf8))
        #expect(split.lines.isEmpty)
        #expect(split.consumed == 0)
    }

    @Test func invalidUTF8BecomesAMalformedLine() {
        var data = Data([0xFF, 0xFE, 0x0A])
        data.append(Data(#"{"e":"stop","t":1,"s":"x"}"#.utf8))
        data.append(0x0A)
        let split = EventLines.split(data)
        #expect(split.lines.count == 2)
        #expect(EventParser.parse(split.lines[0]) == .failure(.notJSONObject))
        #expect((try? EventParser.parse(split.lines[1]).get())?.kind == .stop)
    }
}

@Suite struct MickDateTests {
    @Test func roundTripsWithMicroseconds() throws {
        let date = Date(timeIntervalSince1970: 1790000000.123456)
        let text = MickDate.string(from: date)
        #expect(text == "2026-09-21T14:13:20.123456Z")
        let back = try #require(MickDate.date(from: text))
        #expect(MickDate.micros(back) == MickDate.micros(date))
    }

    @Test func parsesWithoutFractionOrWithOffset() throws {
        #expect(MickDate.date(from: "2026-09-21T14:13:20Z") == Date(timeIntervalSince1970: 1790000000))
        let offset = try #require(MickDate.date(from: "2026-09-21T11:13:20.5-03:00"))
        #expect(offset.timeIntervalSince1970 == 1790000000.5)
        #expect(MickDate.date(from: "yesterday") == nil)
    }

    @Test func roundsUpToTheNextSecond() {
        #expect(MickDate.string(from: Date(timeIntervalSince1970: 1790000000.9999999)) == "2026-09-21T14:13:21.000000Z")
    }

    @Test func localDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Montevideo")!
        // 02:00 UTC on the 22nd is still the 21st in Montevideo (UTC-3).
        #expect(MickDate.localDay(Date(timeIntervalSince1970: 1790042400), calendar: calendar) == "2026-09-21")
    }
}
