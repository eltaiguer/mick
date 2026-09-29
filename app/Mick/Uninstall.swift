import AppKit
import MickCore
import MickIO
import SwiftUI

/// Settings → Uninstall… (SPEC §13): confirm, then delete Mick's home, unregister the
/// login item, show the plugin uninstall command, and quit.
@MainActor
enum UninstallConfirmation {
    static let title = "Uninstall Mick?"

    static func message(home: MickHome) -> String {
        "This deletes Mick's folder (\(home.url.path)) with your settings, today's memory and the reminder log, turns off open at login, and quits Mick. The Claude Code plugin stays installed until you remove it; Mick shows you the command next."
    }

    /// Asks first; runs `onConfirm` only if the person chose Uninstall.
    static func ask(home: MickHome, attachedTo window: NSWindow?, onConfirm: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message(home: home)
        let uninstall = alert.addButton(withTitle: "Uninstall")
        uninstall.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { onConfirm() }
        }
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { handle(response) } }
        } else {
            NSApp.activate()
            handle(alert.runModal())
        }
    }
}

/// What's shown once Mick's folder is gone: the plugin commands, then Quit.
struct UninstalledView: View {
    /// The commands the window shows, in order: remove the plugin, then the marketplace.
    static let commands = [PluginCommands.uninstall, PluginCommands.removeMarketplace]

    let result: MickEngine.UninstallResult
    let home: MickHome
    var onQuit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(result.removedHome ? "Mick's packed up" : "Mick couldn't finish uninstalling").font(.title2.bold())
                Text(result.removedHome
                     ? "Mick's folder is deleted and he won't open at login."
                     : result.problems.contains(where: { $0.hasPrefix("Refused") })
                        ? "Nothing was deleted."
                        : "Mick's folder at \(home.url.path) is still there. Delete it in Finder.")
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(result.problems, id: \.self) { problem in
                    Text(problem).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Remove the Claude Code plugin").font(.headline)
                Text("Its hooks do nothing without Mick's folder. To remove it, run this inside Claude Code:")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                CommandRow(command: Self.commands[0])
                Text("And to forget the marketplace too:")
                    .foregroundStyle(.secondary)
                CommandRow(command: Self.commands[1])
            }

            Text("Then drag Mick to the Trash. Nothing else is left behind.")
                .fixedSize(horizontal: false, vertical: true)
            Text("“That's the bell, kid. Stay loose.”")
                .italic()
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Quit Mick", action: onQuit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// The last window Mick shows. Quitting (or closing it) ends the app.
@MainActor
final class UninstalledWindowController: NSObject, NSWindowDelegate {
    let result: MickEngine.UninstallResult
    private(set) var window: NSWindow!
    private let onQuit: () -> Void

    init(result: MickEngine.UninstallResult, home: MickHome, onQuit: @escaping () -> Void) {
        self.result = result
        self.onQuit = onQuit
        super.init()
        let view = UninstalledView(result: result, home: home) { [weak self] in self?.quit() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Mick is uninstalled"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
    }

    var isVisible: Bool { window.isVisible }

    func show(activate: Bool) {
        if activate {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    private var quitting = false

    func quit() {
        guard !quitting else { return }
        quitting = true
        onQuit()
    }

    func windowWillClose(_ notification: Notification) { quit() }
}
