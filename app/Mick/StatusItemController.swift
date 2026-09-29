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
            // Placeholder until Mick's voice (#9) lands.
            let status = NSMenuItem(title: "Mick's in your corner.", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }
        let detail = NSMenuItem(title: engine.sittingDetail, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Mick", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// The first menu item's title (the smoke check reads it).
    var topLine: String? { item.menu?.items.first?.title }
    /// The plain detail line's title.
    var detailLine: String? { item.menu?.items.dropFirst().first?.title }

    @objc private func setUp() { onSetUp() }
    @objc private func quit() { NSApp.terminate(nil) }
}
