import AppKit
import SwiftUI

/// The window level the panel uses. The spike compares both (SPEC §9.3, item 3).
public enum PanelLevel: String, CaseIterable, Sendable {
    case statusBar
    case popUpMenu

    public var windowLevel: NSWindow.Level {
        switch self {
        case .statusBar: .statusBar
        case .popUpMenu: .popUpMenu
        }
    }
}

/// A borderless, non-activating panel that can never become key or main (SPEC §9.3).
///
/// Never show it with `makeKeyAndOrderFront` and never call `NSApp.activate`;
/// use `orderFrontRegardless()`.
public final class ReminderPanel: NSPanel {
    /// Exactly the combination from SPEC §9.3. Never add `.moveToActiveSpace`:
    /// combined with `.canJoinAllSpaces` it raises `NSInternalInconsistencyException`.
    public static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]

    public static let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]

    public init(contentRect: NSRect = NSRect(x: 0, y: 0, width: 300, height: 200), level: PanelLevel) {
        super.init(contentRect: contentRect, styleMask: Self.styleMask, backing: .buffered, defer: true)
        becomesKeyOnlyIfNeeded = true
        // NSPanel documents its default as `true`; it must be off so the panel
        // stays up while another app is active (which is always).
        hidesOnDeactivate = false
        isFloatingPanel = true
        collectionBehavior = Self.collectionBehavior
        self.level = level.windowLevel
        isReleasedWhenClosed = false
        isMovable = false
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        animationBehavior = .none
    }

    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }

    public func setLevel(_ level: PanelLevel) {
        self.level = level.windowLevel
    }

    /// Guard against accidental key-window promotion: the panel must never take focus.
    override public func makeKey() {}
    override public func makeKeyAndOrderFront(_ sender: Any?) {
        orderFrontRegardless()
    }
}

/// Hosting view that takes the first click and never asks the panel to become key.
public final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override public var needsPanelToBecomeKey: Bool { false }
}
