import AppKit

/// Every explicit permission action uses this decision and these effects.
/// Tests supply all effects, including activation, so they never reach TCC.
@MainActor
struct PermissionRequest {
    @TaskLocal static var override: (@MainActor @Sendable (SetupPermission, PermissionRequest) -> PermissionRequest)?

    static let didChange = Notification.Name("JRBarPermissionChanged")

    var status: () async -> SetupPermissionStatus
    var prompt: (() async -> Void)?
    var settingsURL: URL
    var activate: () -> Void
    var openSettings: (URL) -> Void
    var explainFullAccess: () -> Void
    var refresh: () -> Void

    @discardableResult
    func perform() async -> SetupPermissionStatus {
        let current = await status()
        var result = current
        switch current {
        case .granted:
            break
        case .needed:
            if let prompt {
                activate()
                await prompt()
                result = await status()
            } else {
                openSettings(settingsURL)
            }
        case .writeOnly:
            activate()
            explainFullAccess()
            openSettings(settingsURL)
        case .denied, .restricted, .unknown, .unavailable:
            openSettings(settingsURL)
        }
        refresh()
        return result
    }

    static func live(permission: SetupPermission,
                     status: @escaping () async -> SetupPermissionStatus,
                     prompt: (() async -> Void)? = nil,
                     settingsURL: URL) -> Self {
        let request = Self(status: status, prompt: prompt, settingsURL: settingsURL,
             activate: { WindowFront.requestActivation() },
             openSettings: { SetupModel.openSettingsPane($0) },
             explainFullAccess: {
                 let alert = fullAccessAlert(for: permission)
                 _ = WindowPresenter.automatic.runModal(alert)
             },
             refresh: { refresh(permission) })
        return override?(permission, request) ?? request
    }

    static func fullAccessAlert(for permission: SetupPermission) -> NSAlert {
        let alert = NSAlert()
        let content = permission == .calendar ? "events" : "reminders"
        alert.messageText = "Full \(permission.title) access is needed"
        alert.informativeText = "Choose Full Access for JR-Bar in System Settings to read \(content). Write-only access cannot show them."
        alert.addButton(withTitle: "Open Settings")
        return alert
    }

    static func refresh(_ permission: SetupPermission, reader: ShelfCalendarReader = .shared,
                        center: NotificationCenter = .default) {
        reader.invalidate()
        reader.notifications.post(name: ShelfCalendarReader.didChange, object: reader)
        center.post(name: didChange, object: permission)
    }
}
