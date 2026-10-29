import EventKit
import Foundation
import Testing
@testable import JRBarApp

@MainActor
@Suite("Permission actions use the same status decision", .serialized)
struct PermissionRequestTests {
    nonisolated static let permissions: [SetupPermission] = [
        .calendar, .reminders, .camera, .location, .focusStatus,
        .bluetooth, .automation, .audioCapture,
    ]
    nonisolated static let statuses: [SetupPermissionStatus] = [
        .needed, .denied, .restricted, .writeOnly, .granted, .unknown,
    ]

    nonisolated static let panes: [SetupPermission: URL] = [
        .calendar: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!,
        .reminders: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!,
        .camera: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!,
        .location: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!,
        .focusStatus: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Focus")!,
        .bluetooth: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!,
        .automation: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!,
        .audioCapture: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!,
    ]

    nonisolated static func settingsURL(for permission: SetupPermission) -> URL { panes[permission]! }

    enum Surface: String, CaseIterable, Sendable {
        case setup, settings, notch, dock, shelf

        @MainActor
        func press(_ permission: SetupPermission) async {
            // Setup and Settings dispatch a row's permission. Feature actions
            // use the same entry points as the notch, Dock and shelf buttons.
            switch self {
            case .setup, .settings:
                var model = SetupModel()
                model.refreshPermissions = { [permission: .needed] }
                model.act = { await SetupModel.act(on: $0) }
                let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
                await store.refreshPermissions()
                await store.act(on: permission).value
            case .notch, .dock, .shelf:
                switch permission {
                case .calendar: await SetupModel.requestCalendar()
                case .reminders: await SetupModel.requestReminders()
                case .camera: await SetupModel.requestCamera()
                case .location: await SetupModel.requestLocation()
                case .focusStatus: await SetupModel.requestFocusStatus()
                case .bluetooth: await SetupModel.requestBluetooth()
                case .automation: await SetupModel.requestAutomation()
                case .audioCapture: await SetupModel.requestAudioCapture()
                default: Issue.record("unexpected permission")
                }
            }
        }
    }

    @Test(arguments: permissions, statuses)
    func actionMatrix(permission: SetupPermission, status: SetupPermissionStatus) async {
        var effects: [String] = []
        let pane = Self.settingsURL(for: permission)
        let request = PermissionRequest(
            status: { status }, prompt: { effects.append("prompt") }, settingsURL: pane,
            activate: { effects.append("activate") },
            openSettings: { effects.append($0.absoluteString) },
            explainFullAccess: { effects.append("full access needed") },
            refresh: { effects.append("refresh") })
        await request.perform()
        switch status {
        case .needed:
            #expect(effects == ["activate", "prompt", "refresh"])
        case .writeOnly:
            #expect(effects == ["activate", "full access needed", pane.absoluteString, "refresh"])
        case .granted:
            #expect(effects == ["refresh"])
        default:
            #expect(effects == [pane.absoluteString, "refresh"])
        }
    }

    @Test(arguments: Surface.allCases, permissions)
    func surfaceMatrix(surface: Surface, permission: SetupPermission) async {
        for status in Self.statuses {
            var effects: [String] = []
            let factory: @MainActor @Sendable (SetupPermission, PermissionRequest) -> PermissionRequest = { requested, original in
                #expect(requested == permission)
                #expect(original.settingsURL == Self.settingsURL(for: permission))
                return PermissionRequest(
                    status: { status }, prompt: { effects.append("prompt") },
                    settingsURL: original.settingsURL, activate: { effects.append("activate") },
                    openSettings: { effects.append($0.absoluteString) },
                    explainFullAccess: { effects.append("full access needed") },
                    refresh: { effects.append("refresh") })
            }
            await PermissionRequest.$override.withValue(factory) { await surface.press(permission) }
            #expect(effects.last == "refresh")
            if status == .needed { #expect(effects == ["activate", "prompt", "refresh"]) }
            if status == .granted { #expect(effects == ["refresh"]) }
            if status == .writeOnly { #expect(effects.contains("full access needed")) }
            if status == .denied || status == .restricted || status == .unknown || status == .writeOnly {
                #expect(effects.contains(Self.settingsURL(for: permission).absoluteString))
                #expect(!effects.contains("prompt"))
            }
        }
    }

    @Test func eventKitStatusKeepsWriteOnlyAndRestrictionDistinct() {
        #expect(SetupModel.eventKitStatus(.notDetermined) == .needed)
        #expect(SetupModel.eventKitStatus(.denied) == .denied)
        #expect(SetupModel.eventKitStatus(.restricted) == .restricted)
        #expect(SetupModel.eventKitStatus(.writeOnly) == .writeOnly)
        #expect(SetupModel.eventKitStatus(.fullAccess) == .granted)
        #expect(SetupPermission.calendar.action(for: .writeOnly)?.title == "Allow Full Access…")
        #expect(SetupPermission.calendar.action(for: .restricted)?.opensSettings == true)
    }

    @Test("a service without a standalone prompt always has a pane action")
    func noPublicPrompt() async {
        var opened: [URL] = []
        var refreshes = 0
        let pane = SetupModel.audioCaptureSettingsURL
        let request = PermissionRequest(status: { .needed }, settingsURL: pane,
                                        activate: { Issue.record("must not activate without a prompt") },
                                        openSettings: { opened.append($0) }, explainFullAccess: {},
                                        refresh: { refreshes += 1 })
        await request.perform()
        #expect(opened == [pane])
        #expect(refreshes == 1)
    }
}
