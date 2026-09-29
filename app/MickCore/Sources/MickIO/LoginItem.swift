import Foundation
import MickCore
import Observation
import ServiceManagement

/// The system service behind "Open at login" (SPEC §6.5). The app uses
/// `SystemLoginItem` (`SMAppService.mainApp`); tests, the smoke check and any launch
/// with `MICK_HOME` set use `RecordingLoginItem`, so they never register a real login
/// item (a login item launched by the system wouldn't see `MICK_HOME` anyway, §12).
@MainActor
public protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    /// Opens System Settings → General → Login Items.
    func openSystemSettings()
}

/// `SMAppService.mainApp` (macOS 13+; needs a code-signed app).
@MainActor
public final class SystemLoginItem: LoginItemService {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }

    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }

    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// An in-memory login item that records what was asked of it.
@MainActor
public final class RecordingLoginItem: LoginItemService {
    public var status: LoginItemStatus
    public private(set) var registerCalls = 0
    public private(set) var unregisterCalls = 0
    /// Thrown by the next `register()` / `unregister()`, then cleared.
    public var nextError: (any Error)?
    /// The status `register()` leaves behind (`.requiresApproval` to simulate macOS
    /// asking for approval).
    public var statusAfterRegister: LoginItemStatus = .enabled

    public init(status: LoginItemStatus = .notRegistered) {
        self.status = status
    }

    public func register() throws {
        registerCalls += 1
        if let error = nextError { nextError = nil; throw error }
        status = statusAfterRegister
    }

    public private(set) var openSettingsCalls = 0
    public func openSystemSettings() { openSettingsCalls += 1 }

    public func unregister() throws {
        unregisterCalls += 1
        if let error = nextError { nextError = nil; throw error }
        status = .notRegistered
    }
}

/// The open-at-login toggle's model, shared by Settings and onboarding: the current
/// status, a plain line for approval or a missing item, and the last error, which is
/// also logged.
@MainActor
@Observable
public final class LoginItemController {
    @ObservationIgnored public let service: any LoginItemService
    @ObservationIgnored private let log: any MickLogger
    public private(set) var status: LoginItemStatus
    /// The last registration error, in plain words. Cleared by the next success.
    public private(set) var errorMessage: String?

    public init(service: any LoginItemService, log: any MickLogger) {
        self.service = service
        self.log = log
        self.status = service.status
    }

    public var isOn: Bool { status.isOn }

    /// The plain line under the toggle: the error if there is one, else what the
    /// status needs (approval in System Settings, or a missing item).
    public var note: String? { errorMessage ?? LoginItemNote.line(for: status) }

    /// Whether the note under the toggle should offer to open System Settings.
    public var offersSystemSettings: Bool { status == .requiresApproval || errorMessage?.contains("System Settings") == true }

    public func openSystemSettings() { service.openSystemSettings() }

    /// Re-reads the status (the person may have changed it in System Settings).
    public func refresh() {
        status = service.status
    }

    /// Turns open at login on or off.
    public func setEnabled(_ on: Bool) {
        do {
            if on { try service.register() } else { try service.unregister() }
            errorMessage = nil
            status = service.status
            log.log("open at login \(on ? "on" : "off") (status \(status.rawValue))")
            if status == .requiresApproval { log.log("open at login needs approval in System Settings → General → Login Items") }
        } catch {
            let ns = error as NSError
            let message = LoginItemNote.error(
                turningOn: on, deniedByUser: ns.code == Int(kSMErrorLaunchDeniedByUser),
                code: ns.code, description: ns.localizedDescription)
            errorMessage = message
            status = service.status
            log.log("open at login: \(message) [\(ns.domain) \(ns.code)]")
        }
    }

    /// Open at login is on by default (§6.5): turned on once, on the launch that
    /// created Mick's home. Later launches leave whatever the person chose alone.
    public func applyDefault(firstLaunch: Bool) {
        guard firstLaunch else { return }
        refresh()
        guard !status.isOn else { return }
        log.log("first launch: turning on open at login")
        setEnabled(true)
    }
}
