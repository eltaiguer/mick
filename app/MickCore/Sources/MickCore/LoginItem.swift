import Foundation

/// The open-at-login item's status, mirroring `SMAppService.Status` (SPEC §6.5). Open at
/// login is stored by the system, not in `config.json` (§11).
public enum LoginItemStatus: String, Equatable, Sendable, CaseIterable {
    case enabled
    case notRegistered
    /// Registered, but the person has to allow it in System Settings.
    case requiresApproval
    /// The system can't find the app's login item (for example a copy that isn't signed).
    case notFound

    /// Whether the toggle shows as on. Waiting for approval counts as on: Mick asked,
    /// and the plain line under the toggle explains what's left.
    public var isOn: Bool { self == .enabled || self == .requiresApproval }
}

/// What the Settings window and onboarding show under the open-at-login toggle.
/// Plain voice (§1): problems get instructions, not jokes.
public enum LoginItemNote {
    public static let requiresApproval =
        "macOS needs your OK: open System Settings → General → Login Items and allow Mick."
    public static let notFound =
        "macOS can't find Mick's login item. Build Mick signed, copy it to Applications and open it from there."

    /// The line for a status, or nil when there's nothing to say.
    public static func line(for status: LoginItemStatus) -> String? {
        switch status {
        case .enabled, .notRegistered: nil
        case .requiresApproval: requiresApproval
        case .notFound: notFound
        }
    }

    /// A registration or unregistration error, shown plainly and logged.
    /// `deniedByUser` is ServiceManagement's `kSMErrorLaunchDeniedByUser`.
    public static func error(turningOn: Bool, deniedByUser: Bool, code: Int, description: String) -> String {
        if turningOn, deniedByUser {
            return "Couldn't turn on open at login: it's turned off for Mick in System Settings → General → Login Items. Turn it on there."
        }
        return "Couldn't turn \(turningOn ? "on" : "off") open at login: \(description) (error \(code))."
    }
}
