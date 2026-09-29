import AppKit
import MickCore
import MickIO
import SwiftUI

/// The two plugin install commands (SPEC §13).
enum PluginCommands {
    static let addMarketplace = "/plugin marketplace add eltaiguer/mick"
    static let install = "/plugin install mick@mick"
    static let all = [addMarketplace, install]
    /// Shown after Uninstall… (§13).
    static let uninstall = "/plugin uninstall mick@mick"
    static let removeMarketplace = "/plugin marketplace remove mick"
}

/// A command in monospace with a Copy button.
struct CommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .accessibilityLabel("Copy \(command)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Onboarding (SPEC §6.6): what Mick does, the plugin install commands with copy
/// buttons, a line that turns into a check mark when the first event arrives, and the
/// open-at-login toggle.
struct OnboardingView: View {
    let engine: MickEngine
    let loginItem: LoginItemController
    /// Mick's line, from the `onboarding` pool (§10.2).
    var line: String = "So you wanna be a contender. Install the damn thing."
    var onDone: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Meet Mick").font(.title2.bold())
                Text("Mick keeps track of how long you've been sitting. When it's been too long and you hand work to Claude Code, he drops down from the menu bar with a one-minute stretch routine, then gets out of the way.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("“\(line)”")
                    .italic()
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Install the Claude Code plugin").font(.headline)
                Text("Run these two commands inside Claude Code:")
                    .foregroundStyle(.secondary)
                ForEach(PluginCommands.all, id: \.self) { command in
                    CommandRow(command: command)
                }
            }

            status
                .accessibilityElement(children: .combine)

            LoginItemToggle(controller: loginItem)

            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    @ViewBuilder private var status: some View {
        switch OnboardingStatus(engine.hooks) {
        case .waiting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(OnboardingStatus.waiting.text)
            }
        case .connected:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(OnboardingStatus.connected.text)
            }
        case .stale:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(OnboardingStatus.stale.text)
            }
        }
    }
}

/// The status line at the bottom of onboarding.
enum OnboardingStatus: Equatable {
    case waiting, connected, stale

    init(_ hooks: HooksStatus) {
        switch hooks {
        case .notDetected: self = .waiting
        case .detected: self = .connected
        case .stale: self = .stale
        }
    }

    var text: String {
        switch self {
        case .waiting: "Waiting for your first Claude Code prompt…"
        case .connected: "Got your first Claude Code prompt. The plugin works."
        case .stale: "No Claude Code events in 7 days. Check the plugin is still installed, then send a prompt."
        }
    }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let engine: MickEngine
    private let loginItem: LoginItemController
    private var window: NSWindow?

    init(engine: MickEngine, loginItem: LoginItemController) {
        self.engine = engine
        self.loginItem = loginItem
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Shows onboarding. `activate` is for when the person asked for it from the menu;
    /// at launch the app is already frontmost if they opened it.
    func show(activate: Bool) {
        let window = self.window ?? makeWindow()
        self.window = window
        if activate { NSApp.activate() }
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let view = OnboardingView(engine: engine, loginItem: loginItem, line: engine.onboardingLine()) { [weak self] in self?.close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Mick"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}
