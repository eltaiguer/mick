import AppKit
import MickCore
import MickIO
import SwiftUI

/// Every change the Settings window makes goes through here: into the engine, which
/// validates it and writes `config.json` (SPEC §6.5, §11). The smoke check drives the
/// same calls.
@MainActor
struct SettingsEditor {
    let engine: MickEngine

    func set<T>(_ key: WritableKeyPath<MickConfig, T>, _ value: T) {
        var config = engine.config
        config[keyPath: key] = value
        engine.updateConfig(config)
    }

    func binding<T>(_ key: WritableKeyPath<MickConfig, T>) -> Binding<T> {
        Binding(get: { engine.config[keyPath: key] }, set: { set(key, $0) })
    }

    /// A number kept inside `range` (typing 0 minutes gives the minimum, not the default).
    func binding(_ key: WritableKeyPath<MickConfig, Int>, in range: ClosedRange<Int>) -> Binding<Int> {
        Binding(get: { engine.config[keyPath: key] }, set: { set(key, min(max($0, range.lowerBound), range.upperBound)) })
    }

    func setQuietHours(_ on: Bool) {
        set(\.quietHours, on ? (engine.config.quietHours ?? .suggested) : nil)
    }

    /// One end of the quiet hours as a time of day today (for a `DatePicker`).
    func quietTime(_ key: WritableKeyPath<QuietHours, String>) -> Binding<Date> {
        Binding(
            get: {
                let text = engine.config.quietHours?[keyPath: key] ?? QuietHours.suggested[keyPath: key]
                let minutes = QuietHours.minutes(text) ?? 0
                let midnight = Calendar.current.startOfDay(for: Date())
                return Calendar.current.date(byAdding: .minute, value: minutes, to: midnight) ?? midnight
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                var quiet = engine.config.quietHours ?? .suggested
                quiet[keyPath: key] = QuietHours.string(minutes: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
                set(\.quietHours, quiet)
            }
        )
    }
}

/// The Settings window's content (SPEC §6.5). Reads straight from the engine, so a
/// hand edit to `config.json` shows up here as soon as Mick picks it up.
struct SettingsView: View {
    let engine: MickEngine
    let loginItem: LoginItemController
    var onPlayBell: () -> Void = {}
    var onUninstall: () -> Void = {}

    private var editor: SettingsEditor { SettingsEditor(engine: engine) }

    var body: some View {
        Form {
            Section {
                numberRow("Sit threshold", unit: "min", key: \.sitThresholdMinutes, range: MickConfig.sitThresholdRange, step: 5,
                          help: "How long you sit before Mick's ready to step in.")
                numberRow("Show delay", unit: "s", key: \.showDelaySeconds, range: MickConfig.showDelayRange, step: 5,
                          help: "How long an agent run has to go before the panel appears.")
                numberRow("Break reset", unit: "min", key: \.breakResetMinutes, range: MickConfig.breakResetRange, step: 1,
                          help: "Away from the keyboard this long counts as a break.")
            } header: {
                Text("Reminders")
            }

            Section {
                Toggle("Quiet hours", isOn: Binding(get: { engine.config.quietHours != nil }, set: { editor.setQuietHours($0) }))
                if engine.config.quietHours != nil {
                    DatePicker("From", selection: editor.quietTime(\.start), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: editor.quietTime(\.end), displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("Quiet hours")
            } footer: {
                Text("No reminders in this window. It can run past midnight.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Toggle("Ring the bell when Mick shows up", isOn: editor.binding(\.sound))
                    Spacer()
                    Button("Play", action: onPlayBell)
                        .accessibilityLabel("Play the bell")
                }
                LoginItemToggle(controller: loginItem)
            } header: {
                Text("General")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Uninstall Mick")
                        Text("Deletes Mick's folder, turns off open at login and quits.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Uninstall…", role: .destructive, action: onUninstall)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func numberRow(_ title: String, unit: String, key: WritableKeyPath<MickConfig, Int>, range: ClosedRange<Int>, step: Int, help: String) -> some View {
        let value = editor.binding(key, in: range)
        return LabeledContent {
            HStack(spacing: 6) {
                TextField(title, value: value, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Text(unit).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                Stepper(title, value: value, in: range, step: step).labelsHidden()
            }
        } label: {
            Text(title)
            Text(help)
        }
    }
}

/// The open-at-login toggle, with its plain line (approval needed, or an error). Used
/// by Settings and onboarding.
struct LoginItemToggle: View {
    let controller: LoginItemController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Open at login", isOn: Binding(get: { controller.isOn }, set: { controller.setEnabled($0) }))
            if let note = controller.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if controller.offersSystemSettings {
                    Button("Open Login Items Settings") { controller.openSystemSettings() }
                }
            }
        }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let engine: MickEngine
    private let loginItem: LoginItemController
    private let onPlayBell: () -> Void
    private let onUninstall: () -> Void
    private(set) var window: NSWindow?

    init(engine: MickEngine, loginItem: LoginItemController, onPlayBell: @escaping () -> Void, onUninstall: @escaping () -> Void) {
        self.engine = engine
        self.loginItem = loginItem
        self.onPlayBell = onPlayBell
        self.onUninstall = onUninstall
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Shows the window. `activate` brings Mick forward (the person chose Settings…);
    /// the smoke check passes false so unattended runs never take focus.
    func show(activate: Bool) {
        loginItem.refresh()  // it may have been changed in System Settings
        let window = self.window ?? makeWindow()
        self.window = window
        if activate {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let view = SettingsView(engine: engine, loginItem: loginItem, onPlayBell: onPlayBell, onUninstall: onUninstall)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Mick Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}
