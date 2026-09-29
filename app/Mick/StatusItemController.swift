import AppKit
import MickCore
import MickIO
import Observation

/// Mick's own status item and dropdown (SPEC §6.4). Re-renders whenever the engine's
/// observed state changes.
@MainActor
final class StatusItemController: NSObject {
    let item: NSStatusItem
    private let engine: MickEngine
    private let onSetUp: () -> Void
    private(set) var icon: MenuBarIcon?

    init(engine: MickEngine, onSetUp: @escaping () -> Void) {
        self.engine = engine
        self.onSetUp = onSetUp
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
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
        let icon = MenuBarIcon.current(hooks: engine.hooks)
        if icon != self.icon {
            self.icon = icon
            item.button?.image = GloveIcon.image(for: icon)
            item.button?.toolTip = icon == .warning ? "Mick: Claude Code hooks not detected" : "Mick"
        }
        item.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let line = engine.hooks.menuLine {
            // Plain voice for problems (§1): the instruction comes first.
            let setUp = NSMenuItem(title: line, action: #selector(setUp), keyEquivalent: "")
            setUp.target = self
            menu.addItem(setUp)
        } else {
            // Placeholder until the sitting timer (#5) and Mick's voice (#9) land.
            let running = SessionBook.running(in: engine.state).count
            let status = NSMenuItem(title: "Mick's in your corner.", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            let detail = NSMenuItem(title: running == 1 ? "1 Claude Code session running" : "\(running) Claude Code sessions running", action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Mick", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// The first menu item's title (the smoke check reads it).
    var topLine: String? { item.menu?.items.first?.title }

    @objc private func setUp() { onSetUp() }
    @objc private func quit() { NSApp.terminate(nil) }
}
