import AppKit
import SwiftUI

/// What the focus probe saw around one show or click.
public struct FocusSnapshot: Equatable, Sendable, CustomStringConvertible {
    public var frontmostBundleID: String?
    public var frontmostPID: pid_t?
    public var appIsActive: Bool
    public var panelIsKey: Bool
    public var panelIsVisible: Bool
    public var keyWindowExists: Bool

    public var description: String {
        "frontmost=\(frontmostBundleID ?? "nil")(\(frontmostPID.map(String.init) ?? "-")) appActive=\(appIsActive) panelKey=\(panelIsKey) panelVisible=\(panelIsVisible) appHasKeyWindow=\(keyWindowExists)"
    }
}

/// Owns the panel, places it under the status item and shows it without focus.
@MainActor
public final class PanelController {
    public let panel: ReminderPanel
    public let model: SpikeModel
    public let hostingView: FirstClickHostingView<SpikeContentView>
    public weak var statusButton: NSStatusBarButton?

    public init(level: PanelLevel, model: SpikeModel = SpikeModel()) {
        self.model = model
        panel = ReminderPanel(level: level)
        hostingView = FirstClickHostingView(rootView: SpikeContentView(model: model))
        hostingView.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hostingView
    }

    public func snapshot() -> FocusSnapshot {
        let front = NSWorkspace.shared.frontmostApplication
        return FocusSnapshot(
            frontmostBundleID: front?.bundleIdentifier,
            frontmostPID: front?.processIdentifier,
            appIsActive: NSApp.isActive,
            panelIsKey: panel.isKeyWindow,
            panelIsVisible: panel.isVisible,
            keyWindowExists: NSApp.keyWindow != nil
        )
    }

    /// Shows the panel. Only `orderFrontRegardless()`: never `makeKeyAndOrderFront`,
    /// never `NSApp.activate`.
    public func show() {
        panel.setContentSize(hostingView.fittingSize)
        panel.layoutIfNeeded()
        panel.setFrame(targetFrame(), display: true)
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel.orderOut(nil)
    }

    public func targetFrame() -> CGRect {
        let screens = NSScreen.screens.map(ScreenGeometry.init(screen:))
        guard !screens.isEmpty else { return panel.frame }
        return PanelPlacement.frame(
            panelSize: panel.frame.size,
            anchor: statusItemAnchor(),
            screens: screens,
            fallbackScreen: activeWindowScreenIndex(screens: screens)
        )
    }

    /// Raw facts about the status item's button window, for the focus log.
    public func statusItemDiagnostics() -> String {
        guard let button = statusButton else { return "no status button" }
        guard let window = button.window else { return "button has no window" }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        return "buttonRect=\(rect) windowVisible=\(window.isVisible) occlusionVisible=\(window.occlusionState.contains(.visible)) windowFrame=\(window.frame)"
    }

    /// The status item button's screen frame (SPEC §9.1), or nil when its window
    /// isn't actually on screen (notch overflow, menu bar auto-hidden).
    public func statusItemAnchor() -> CGRect? {
        guard let button = statusButton, let window = button.window, window.isVisible else { return nil }
        guard window.occlusionState.contains(.visible) else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// The screen with the frontmost app's frontmost window. Uses window bounds from
    /// the window list, which need no Screen Recording or Accessibility permission
    /// (only window titles do). Falls back to the screen under the mouse, then 0.
    public func activeWindowScreenIndex(screens: [ScreenGeometry]) -> Int {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let rect = Self.frontmostWindowBounds(ownerPID: pid) {
            let cocoa = PanelPlacement.cocoaRect(fromQuartz: rect, primaryScreenHeight: primaryHeight)
            if let i = PanelPlacement.screenIndex(containingMostOf: cocoa, in: screens) { return i }
        }
        let mouse = NSEvent.mouseLocation
        return screens.firstIndex { $0.frame.contains(mouse) } ?? 0
    }

    /// Bounds (Quartz coordinates) of the topmost normal-layer on-screen window owned by `ownerPID`.
    public static func frontmostWindowBounds(ownerPID: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for info in list {  // front to back
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == ownerPID,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict),
                  rect.width > 1, rect.height > 1 else { continue }
            return rect
        }
        return nil
    }

    // MARK: - Synthetic clicks (tests and --smoke)

    /// Center of a control, in the panel's window coordinates (bottom-left origin).
    public func windowPoint(forControl id: String) -> NSPoint? {
        guard let frame = model.controlFrames[id] else { return nil }
        // SwiftUI's global space has a top-left origin; NSHostingView may or may not be flipped.
        let y = hostingView.isFlipped ? frame.midY : hostingView.bounds.height - frame.midY
        return hostingView.convert(NSPoint(x: frame.midX, y: y), to: nil)
    }

    /// Delivers one mouse-down/up pair straight to the panel through `sendEvent`,
    /// the path a real click takes after the window server routes it. It exercises
    /// the panel's own first-mouse and key handling, not the window server's
    /// click-through decision, which only a real click can check.
    @discardableResult
    public func syntheticClick(control id: String) -> Bool {
        guard let point = windowPoint(forControl: id) else { return false }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            )
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
        panel.sendEvent(down)
        panel.sendEvent(up)
        return true
    }
}

public extension ScreenGeometry {
    @MainActor init(screen: NSScreen) {
        self.init(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            menuBarAreasBesideNotch: [screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea].compactMap { $0 }
        )
    }
}
