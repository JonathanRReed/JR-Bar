import AppKit
import JRBarUI
import SwiftUI

enum DockWidgetAccess {
    case calendar, reminders, mail, music

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .mail: "Mail"
        case .music: "Music"
        }
    }

    var neededText: String {
        switch self {
        case .calendar: "Needs Calendar access"
        case .reminders: "Needs Reminders access"
        case .mail, .music: "Needs Automation"
        }
    }

    private var bundleID: String { self == .mail ? "com.apple.mail" : "com.apple.Music" }

    @MainActor func status() async -> SetupPermissionStatus {
        switch self {
        case .calendar: return SetupModel.calendarStatus()
        case .reminders: return SetupModel.reminderStatus()
        case .mail, .music:
            let target = bundleID
            let answer = await Task.detached { AutomationPermission.target(target, ask: false) }.value
            return SetupModel.automationStatus(answer)
        }
    }

    @MainActor func request() async {
        switch self {
        case .calendar: await SetupModel.requestCalendar()
        case .reminders: await SetupModel.requestReminders()
        case .mail, .music:
            let target = bundleID
            await PermissionRequest.live(permission: .automation, status: { await status() }, prompt: {
                _ = await Task.detached { AutomationPermission.target(target, ask: true) }.value
            }, settingsURL: AutomationPermission.settingsURL).perform()
        }
    }

    func text(for status: SetupPermissionStatus) -> String {
        if status == .granted { return "Access allowed" }
        if status == .unavailable {
            if self == .mail || self == .music { return "\(neededText) · Open \(title) first" }
            return "\(title) access unavailable"
        }
        return neededText
    }
}

/// Checks access only for an opted-in widget. Only Allow can request it.
struct DockWidgetPermission: View {
    let access: DockWidgetAccess
    @ViewState private var status: SetupPermissionStatus = .needed
    @ViewState private var requesting = false
    @ViewState private var revision = 0
    @Environment(\.renderSnapshot) private var renderSnapshot

    var body: some View {
        HStack(spacing: JRBarTokens.Space.sm) {
            Text(access.text(for: status)).jrbarType(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: JRBarTokens.Space.sm)
            if status != .granted {
                Button("Allow") {
                    requesting = true
                    _ = Task {
                        defer { requesting = false }
                        guard !renderSnapshot else { return }
                        await access.request()
                        status = await access.status()
                    }
                }
                .controlSize(.small).disabled(requesting)
                .accessibilityLabel("Allow \(access.title) access")
            }
        }
        .task(id: revision) {
            guard !renderSnapshot else { return }
            status = await access.status()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            revision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: PermissionRequest.didChange)) { _ in
            revision += 1
        }
    }
}
