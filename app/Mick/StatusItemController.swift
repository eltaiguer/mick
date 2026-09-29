import AppKit
import MickCore
import MickIO
import Observation

/// Mick's own status item and dropdown (SPEC §6.4). Re-renders whenever the engine's
/// observed state changes (at least every idle poll), and rebuilds the dropdown each
/// time it opens so the sitting time is current.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    let item: NSStatusItem
    private let engine: MickEngine
    private let onSetUp: () -> Void
    private let menu = NSMenu()
    private(set) var icon: MenuBarIcon?
    /// Items added above Quit each time the menu is rebuilt (the debug Simulate menu).
    var extraMenuItems: (() -> [NSMenuItem])? {
        didSet { populate(menu) }
    }

    init(engine: MickEngine, onSetUp: @escaping () -> Void) {
        self.engine = engine
        self.onSetUp = onSetUp
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        observe()
    }

    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.observe() }
            }
        }
    }

    private func render() {
        let icon = engine.icon
        if icon != self.icon {
            self.icon = icon
            item.button?.image = GloveIcon.image(for: icon)
            item.button?.toolTip = GloveIcon.description(for: icon)
        }
        populate(menu)
    }

    // Rebuilding in place (not replacing item.menu) keeps an open menu intact.
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let line = engine.hooks.menuLine {
            // Plain voice for problems (§1): the instruction comes first.
            let setUp = NSMenuItem(title: line, action: #selector(setUp), keyEquivalent: "")
            setUp.target = self
            menu.addItem(setUp)
        } else {
            // A snooze/pause/resume line shows briefly (§6.4); otherwise a placeholder
            // until Mick's voice (#9) lands.
            let status = NSMenuItem(title: engine.noticeLine ?? "Mick's in your corner.", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }
        let detail = NSMenuItem(title: engine.sittingDetail, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
        menu.addItem(.separator())

        // Disabled while a reminder is scheduled, visible or settling (§6.4).
        let stretch = NSMenuItem(title: Self.stretchNowTitle, action: #selector(stretchNow), keyEquivalent: "")
        stretch.target = self
        stretch.isEnabled = engine.canStretchNow
        menu.addItem(stretch)

        let snooze = NSMenuItem(title: Self.snoozeTitle, action: nil, keyEquivalent: "")
        let options = NSMenu(title: Self.snoozeTitle)
        options.autoenablesItems = false
        for option in SnoozeOption.allCases {
            let item = NSMenuItem(title: option.label, action: #selector(snoozeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            options.addItem(item)
        }
        if engine.isSnoozed, let until = engine.state.snoozedUntil {
            options.addItem(.separator())
            let note = NSMenuItem(title: "Snoozed until \(until.formatted(date: .omitted, time: .shortened))", action: nil, keyEquivalent: "")
            note.isEnabled = false
            options.addItem(note)
            let cancel = NSMenuItem(title: Self.cancelSnoozeTitle, action: #selector(resume), keyEquivalent: "")
            cancel.target = self
            options.addItem(cancel)
        }
        snooze.submenu = options
        menu.addItem(snooze)

        let pause = engine.isPaused
            ? NSMenuItem(title: Self.resumeTitle, action: #selector(resume), keyEquivalent: "")
            : NSMenuItem(title: Self.pauseTitle, action: #selector(pause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)

        menu.addItem(.separator())
        if let extra = extraMenuItems?(), !extra.isEmpty {
            extra.forEach(menu.addItem)
            menu.addItem(.separator())
        }
        let quit = NSMenuItem(title: "Quit Mick", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// The first menu item's title (the smoke check reads it).
    var topLine: String? { item.menu?.items.first?.title }
    /// The plain detail line's title.
    var detailLine: String? { item.menu?.items.dropFirst().first?.title }

    static let stretchNowTitle = "Stretch now"
    static let snoozeTitle = "Snooze"
    static let pauseTitle = "Pause"
    static let resumeTitle = "Resume"
    static let cancelSnoozeTitle = "Cancel snooze"

    /// The top-level item with this title, from a fresh rebuild (the smoke check drives
    /// the menu through it).
    func menuItem(_ title: String) -> NSMenuItem? {
        populate(menu)
        return menu.items.first { $0.title == title }
    }

    /// Fires an enabled menu item's action, the way choosing it does.
    @discardableResult
    func choose(_ item: NSMenuItem) -> Bool {
        guard item.isEnabled, let menu = item.menu else { return false }
        let index = menu.index(of: item)
        guard index >= 0 else { return false }
        menu.performActionForItem(at: index)
        return true
    }

    @objc private func stretchNow() { engine.stretchNow() }
    @objc private func snoozeChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = SnoozeOption(rawValue: raw) else { return }
        engine.snooze(option)
    }
    @objc private func pause() { engine.pause() }
    @objc private func resume() { engine.resume() }
    @objc private func setUp() { onSetUp() }
    @objc private func quit() { NSApp.terminate(nil) }
}
