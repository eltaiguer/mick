import AppKit
import MickCore
import MickIO
import SwiftUI

/// A borderless, non-activating panel that can never become key or main (SPEC §9.3),
/// proven by the panel spike (#1, spikes/panel/VERDICT.md).
///
/// Never show it with `makeKeyAndOrderFront` and never call `NSApp.activate`;
/// use `orderFrontRegardless()`.
final class ReminderPanel: NSPanel {
    /// Exactly the combination from SPEC §9.3. Never add `.moveToActiveSpace`:
    /// combined with `.canJoinAllSpaces` it raises `NSInternalInconsistencyException`.
    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    static let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
    /// `.statusBar`: `.popUpMenu` behaved the same in every automated spike check, so
    /// there's no reason to go higher (spike verdict; fullscreen is a manual check).
    static let windowLevel: NSWindow.Level = .statusBar

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 200), styleMask: Self.styleMask, backing: .buffered, defer: true)
        becomesKeyOnlyIfNeeded = true
        // NSPanel documents its default as `true`; it must be off so the panel stays
        // up while another app is active (which is always).
        hidesOnDeactivate = false
        isFloatingPanel = true
        collectionBehavior = Self.collectionBehavior
        level = Self.windowLevel
        isReleasedWhenClosed = false
        isMovable = false
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Guards against accidental key-window promotion: the panel must never take focus.
    override func makeKey() {}
    override func makeKeyAndOrderFront(_ sender: Any?) {
        orderFrontRegardless()
    }
}

/// Hosting view that takes the first click and never asks the panel to become key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
}

/// What the panel view renders. Mirrors the engine's `Reminder.Panel`.
@MainActor
@Observable
final class ReminderPanelModel {
    var content: ReminderContent = .standard
    var ticked: Set<Int> = []
    var done = false
    /// Frames of the interactive controls, in the hosting view's top-left-origin space
    /// (the smoke check clicks them).
    var controlFrames: [String: CGRect] = [:]
    var onToggle: (Int, Bool) -> Void = { _, _ in }
    var onNotNow: () -> Void = {}

    static func toggleID(_ index: Int) -> String { "toggle.\(index)" }
    static let notNowID = "button.notNow"
}

/// The reminder panel (SPEC §5, §9.1): the opener, the checklist, "Not now" and
/// "Snooze ▾". Snooze is shown but disabled until #10.
struct ReminderPanelView: View {
    @Bindable var model: ReminderPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.done ? model.content.doneLine : model.content.opener)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(model.content.items.enumerated()), id: \.element.id) { index, item in
                    Toggle(isOn: Binding(
                        get: { model.ticked.contains(index) },
                        set: { model.onToggle(index, $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).fontWeight(.medium)
                            if let instruction = item.instruction {
                                Text(instruction)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(model.done)
                    .reportFrame(ReminderPanelModel.toggleID(index), into: model)
                }
            }

            HStack {
                Button("Not now") { model.onNotNow() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .reportFrame(ReminderPanelModel.notNowID, into: model)
                Spacer()
                Button("Snooze ▾") {}
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .disabled(true)
                    .help("Snooze arrives in a later version.")
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
    }
}

private extension View {
    func reportFrame(_ id: String, into model: ReminderPanelModel) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.controlFrames[id] = $0 }
    }
}

/// Shows and hides the reminder panel as the engine's reminder changes (SPEC §9).
/// Holds no lifetime logic: every close rule lives in `MickCore.Reminder`.
@MainActor
final class ReminderPanelController {
    let panel = ReminderPanel()
    let model = ReminderPanelModel()
    let hostingView: FirstClickHostingView<ReminderPanelView>
    private weak var engine: MickEngine?
    private let statusButton: () -> NSStatusBarButton?
    /// Every show, for the smoke check.
    private(set) var showCount = 0

    init(engine: MickEngine, statusButton: @escaping () -> NSStatusBarButton?) {
        self.engine = engine
        self.statusButton = statusButton
        hostingView = FirstClickHostingView(rootView: ReminderPanelView(model: model))
        hostingView.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hostingView
        model.onToggle = { [weak engine] index, on in engine?.setReminderItem(index, ticked: on) }
        model.onNotNow = { [weak engine] in engine?.dismissReminder() }
        engine.onReminder = { [weak self] effects in self?.apply(effects) }
    }

    var isVisible: Bool { panel.isVisible }

    private func apply(_ effects: [Reminder.Effect]) {
        for effect in effects {
            switch effect {
            case .show(let p):
                sync(p)
                show()
            case .updated(let p), .allTicked(let p):
                sync(p)
            case .closed:
                panel.orderOut(nil)
            default:
                break
            }
        }
    }

    private func sync(_ p: Reminder.Panel) {
        model.content = p.content
        model.ticked = p.ticked
        model.done = p.isDone
    }

    /// Only `orderFrontRegardless()`: never `makeKeyAndOrderFront`, never `NSApp.activate`.
    private func show() {
        showCount += 1
        hostingView.layoutSubtreeIfNeeded()
        panel.setContentSize(hostingView.fittingSize)
        panel.setFrame(targetFrame(), display: true)
        panel.orderFrontRegardless()
    }

    func targetFrame() -> CGRect {
        let screens = NSScreen.screens.map(ScreenGeometry.init(screen:))
        guard !screens.isEmpty else { return panel.frame }
        return PanelPlacement.frame(
            panelSize: panel.frame.size,
            anchor: statusItemAnchor(),
            screens: screens,
            fallbackScreen: activeWindowScreenIndex(screens: screens)
        )
    }

    /// The status item button's screen frame (SPEC §9.1), or nil when its window isn't
    /// actually on screen. Notch overflow keeps the window "visible" at a real position
    /// behind the camera housing, so occlusion and the notch areas are checked too
    /// (spike verdict).
    func statusItemAnchor() -> CGRect? {
        guard let button = statusButton(), let window = button.window, window.isVisible else { return nil }
        guard window.occlusionState.contains(.visible) else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// The screen with the frontmost app's frontmost window, from window bounds in the
    /// window list (no Screen Recording or Accessibility needed). Falls back to the
    /// screen under the mouse, then the first screen.
    private func activeWindowScreenIndex(screens: [ScreenGeometry]) -> Int {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let rect = Self.frontmostWindowBounds(ownerPID: pid) {
            let cocoa = PanelPlacement.cocoaRect(fromQuartz: rect, primaryScreenHeight: primaryHeight)
            if let i = PanelPlacement.screenIndex(containingMostOf: cocoa, in: screens) { return i }
        }
        let mouse = NSEvent.mouseLocation
        return screens.firstIndex { $0.frame.contains(mouse) } ?? 0
    }

    private static func frontmostWindowBounds(ownerPID: pid_t) -> CGRect? {
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

    // MARK: - Synthetic clicks (smoke check)

    /// Delivers one mouse-down/up pair to the panel through `sendEvent`, the path a
    /// real click takes after the window server routes it. It doesn't exercise the
    /// window server's click-through decision; only a real click can (spike verdict).
    @discardableResult
    func syntheticClick(control id: String) -> Bool {
        guard let frame = model.controlFrames[id] else { return false }
        let y = hostingView.isFlipped ? frame.midY : hostingView.bounds.height - frame.midY
        let point = hostingView.convert(NSPoint(x: frame.midX, y: y), to: nil)
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

extension ScreenGeometry {
    @MainActor init(screen: NSScreen) {
        self.init(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            menuBarAreasBesideNotch: [screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea].compactMap { $0 }
        )
    }
}
