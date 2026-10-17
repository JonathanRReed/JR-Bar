import ServiceManagement
import SwiftUI

enum LoginItemState: Equatable, Sendable {
    case enabled, requiresApproval, notRegistered, notFound, unknown

    nonisolated init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered: self = .notRegistered
        case .notFound: self = .notFound
        @unknown default: self = .unknown
        }
    }

    var isEnabled: Bool { self == .enabled }
    var isRequested: Bool { self == .enabled || self == .requiresApproval }

    var subtitle: String {
        switch self {
        case .enabled: return "Starts JR-Bar when you log in."
        case .requiresApproval: return "Waiting for approval in System Settings › General › Login Items. Turn this off to cancel the request."
        case .notRegistered: return "JR-Bar does not start when you log in."
        case .notFound: return "macOS could not find this login item. Open the installed JR-Bar app and try again."
        case .unknown: return "Could not confirm the login item state."
        }
    }
}

struct LoginItemRow: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Toggle(isOn: Binding(get: { store.loginItemState.isRequested }, set: { store.setLaunchAtLogin($0) })) {
            SettingLabel(title: "Launch at login", subtitle: store.launchAtLoginSubtitle)
        }
        .disabled(store.launchAtLoginBusy)
        .settingRowStyle()
    }
}
