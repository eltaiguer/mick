import Testing
@testable import PanelSpikeKit

@Suite struct SpikeOptionsTests {
    @Test func defaultsAreAccessoryAtStatusBarLevel() throws {
        let o = try SpikeOptions.parse([])
        #expect(o.regular == false)
        #expect(o.level == .statusBar)
        #expect(o.smoke == false)
    }

    @Test func parsesEverything() throws {
        let o = try SpikeOptions.parse(["--regular", "--level", "popUpMenu", "--smoke", "--show-after", "3", "--cycle", "5", "--log", "/tmp/x.log", "--prefer-right"])
        #expect(o.preferRight)
        #expect(o.regular)
        #expect(o.level == .popUpMenu)
        #expect(o.smoke)
        #expect(o.showAfter == 3)
        #expect(o.cycle == 5)
        #expect(o.logPath == "/tmp/x.log")
    }

    @Test func ignoresSystemArguments() throws {
        let o = try SpikeOptions.parse(["-NSDocumentRevisionsDebugMode", "YES", "-psn_0_12345", "--smoke"])
        #expect(o.smoke)
    }

    @Test func rejectsBadInput() {
        #expect(throws: SpikeOptions.ParseError.unknown("--nope")) { try SpikeOptions.parse(["--nope"]) }
        #expect(throws: SpikeOptions.ParseError.missingValue("--level")) { try SpikeOptions.parse(["--level"]) }
        #expect(throws: SpikeOptions.ParseError.badValue("--level", "floating")) { try SpikeOptions.parse(["--level", "floating"]) }
        #expect(throws: SpikeOptions.ParseError.badValue("--cycle", "0")) { try SpikeOptions.parse(["--cycle", "0"]) }
    }
}
