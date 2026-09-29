import AppKit
import Testing
@testable import PanelSpikeKit

/// Panel invariants from SPEC §9.3 and a live show/click in this (accessory) process.
/// These need a logged-in GUI session (window server), not a human.
@MainActor
@Suite(.serialized) struct ReminderPanelTests {
    init() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
    }

    @Test func styleMaskIsBorderlessNonActivating() {
        let panel = ReminderPanel(level: .statusBar)
        // `.borderless` is the empty mask, so equality is the real check.
        #expect(panel.styleMask == [.borderless, .nonactivatingPanel])
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.styleMask.contains(.titled))
        #expect(ReminderPanel.styleMask == [.borderless, .nonactivatingPanel])
    }

    @Test func neverKeyNeverMain() {
        let panel = ReminderPanel(level: .statusBar)
        #expect(panel.canBecomeKey == false)
        #expect(panel.canBecomeMain == false)
        #expect(panel.becomesKeyOnlyIfNeeded == true)
        #expect(panel.hidesOnDeactivate == false)
    }

    @Test func collectionBehaviorIsExactlyTheSpecCombination() {
        let panel = ReminderPanel(level: .statusBar)
        #expect(panel.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle])
        #expect(!panel.collectionBehavior.contains(.moveToActiveSpace))
        // NSWindow.h: at most one of managed/transient/stationary.
        #expect(!panel.collectionBehavior.contains(.managed))
        #expect(!panel.collectionBehavior.contains(.transient))
        // At most one cycle option and one full-screen option.
        #expect(!panel.collectionBehavior.contains(.participatesInCycle))
        #expect(!panel.collectionBehavior.contains(.fullScreenPrimary))
        #expect(!panel.collectionBehavior.contains(.fullScreenNone))
    }

    @Test(arguments: PanelLevel.allCases) func levels(level: PanelLevel) {
        let panel = ReminderPanel(level: level)
        #expect(panel.level == level.windowLevel)
        let other: PanelLevel = level == .statusBar ? .popUpMenu : .statusBar
        panel.setLevel(other)
        #expect(panel.level == other.windowLevel)
    }

    @Test func hostingViewTakesFirstMouseWithoutKey() {
        let controller = PanelController(level: .statusBar)
        #expect(controller.hostingView.acceptsFirstMouse(for: nil) == true)
        #expect(controller.hostingView.needsPanelToBecomeKey == false)
        #expect(controller.panel.contentView === controller.hostingView)
    }

    @Test func makeKeyCallsCannotMakeItKey() {
        let controller = PanelController(level: .statusBar)
        controller.panel.makeKeyAndOrderFront(nil)
        controller.panel.makeKey()
        #expect(controller.panel.isKeyWindow == false)
        #expect(NSApp.keyWindow !== controller.panel)
        controller.hide()
    }

    @Test func showingDoesNotTakeFocusOrChangeFrontmost() async throws {
        let controller = PanelController(level: .statusBar)
        let before = controller.snapshot()
        controller.show()
        try await Task.sleep(for: .milliseconds(300))
        let after = controller.snapshot()
        defer { controller.hide() }

        #expect(after.panelIsVisible)
        #expect(after.panelIsKey == false)
        #expect(after.appIsActive == false)
        #expect(after.keyWindowExists == false)
        #expect(after.frontmostPID == before.frontmostPID, "showing changed the frontmost app: \(before) -> \(after)")
        #expect(after.frontmostPID != ProcessInfo.processInfo.processIdentifier)
    }

    @Test func showingAtPopUpMenuLevelDoesNotTakeFocus() async throws {
        let controller = PanelController(level: .popUpMenu)
        let before = controller.snapshot()
        controller.show()
        try await Task.sleep(for: .milliseconds(300))
        let after = controller.snapshot()
        defer { controller.hide() }
        #expect(after.panelIsVisible)
        #expect(after.panelIsKey == false)
        #expect(after.appIsActive == false)
        #expect(after.frontmostPID == before.frontmostPID)
    }

    @Test func shownPanelIsOnScreenAtItsLevel() async throws {
        let controller = PanelController(level: .statusBar)
        controller.show()
        try await Task.sleep(for: .milliseconds(300))
        defer { controller.hide() }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let mine = list.first { ($0[kCGWindowNumber as String] as? Int) == controller.panel.windowNumber }
        #expect(mine != nil, "panel not in the on-screen window list")
        #expect((mine?[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)))
        // Without a status item it falls back to the top-right of a screen.
        let visible = NSScreen.screens.map(\.visibleFrame)
        #expect(visible.contains { $0.contains(controller.panel.frame) })
    }

    @Test func singleClickTogglesCheckboxAndTapsPlainButtonsWithoutFocus() async throws {
        let controller = PanelController(level: .statusBar)
        var interactions: [String] = []
        controller.model.onInteraction = { interactions.append($0) }
        let before = controller.snapshot()
        controller.show()
        try await Task.sleep(for: .milliseconds(300))
        defer { controller.hide() }

        let toggle = SpikeModel.toggleID(0)
        #expect(controller.model.controlFrames[toggle] != nil, "control frames not reported")

        #expect(controller.syntheticClick(control: toggle))
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.model.checked[0] == true, "first click did not tick the checkbox")
        #expect(controller.model.checked[1] == false)

        #expect(controller.syntheticClick(control: SpikeModel.toggleID(2)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.model.checked[2] == true)

        #expect(controller.syntheticClick(control: SpikeModel.notNowID))
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.model.notNowTaps == 1, "first click did not trigger the plain button")

        #expect(controller.syntheticClick(control: SpikeModel.snoozeID))
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.model.snoozeTaps == 1)

        // A second click unticks: exactly one toggle per click.
        #expect(controller.syntheticClick(control: toggle))
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.model.checked[0] == false)

        let after = controller.snapshot()
        #expect(after.panelIsKey == false)
        #expect(after.appIsActive == false)
        #expect(after.keyWindowExists == false)
        #expect(after.frontmostPID == before.frontmostPID)
        #expect(interactions.count == 5)
    }
}
