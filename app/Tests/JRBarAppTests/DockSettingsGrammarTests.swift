import Foundation
import JRBarCore
import Testing

@testable import JRBarApp

@Suite("Dock settings grammar", .serialized, .temporaryDirectory)
@MainActor
struct DockSettingsGrammarTests {
    @Test func searchingEveryDockRowPreservesItsSettings() throws {
        let fixture = try SettingsRenderProofTests.fixture()
        defer { fixture.toys.shutdown() }
        let before = fixture.utilities.state.dock
        let entries = fixture.settings.searchEntries.filter { $0.card == "dock" }
        #expect(entries.count == ToySearchCatalog.rows["dock"]!.count + 1)
        for entry in entries {
            fixture.settings.openFolds.removeAll()
            fixture.settings.reveal(entry)
            #expect(fixture.settings.subpage == "dock")
            #expect(fixture.settings.searchHit == entry)
            #expect(fixture.settings.isFoldOpen(SettingsFeatureOptions.fold("dock"))
                    == SettingsFeatureOptions.contains(entry))
            #expect(fixture.utilities.state.dock == before)
        }
    }

    @Test func statusKeepsPermissionAndProviderStates() {
        let utility = DockUtility()
        var saved = DockSettings()
        utility.settings = { saved }
        #expect(utility.settingsStatus == "Off · Medium widgets")
        saved.enabled = true
        #expect(utility.settingsStatus.contains("Needs Accessibility"))
        utility.enhance.accessibilityTrusted = true
        #expect(utility.settingsStatus == "Starting · Medium widgets")
        saved.enhance.hoverPreviews = false
        saved.enhance.windowSwitcher = false
        saved.enhance.appSwitcher = false
        #expect(utility.settingsStatus.contains("Previews and switcher are off"))
        saved.enhance.previewSize = .large
        #expect(utility.settingsStatus.hasSuffix("Large widgets"))
        #expect(DockUtility.settingsStatus(settings: saved, status: .external("Synthetic provider"))
                == "Synthetic provider · Large widgets")
        #expect(DockUtility.settingsStatus(settings: saved, status: .failed("Could not start"))
                == "Could not start · Large widgets")
        saved.enhance.hoverPreviews = true
        #expect(DockUtility.settingsStatus(settings: saved, status: .on) == "Previews on · Large widgets")
        saved.enhance.hoverPreviews = false
        #expect(DockUtility.settingsStatus(settings: saved, status: .on) == "Previews off · Large widgets")
    }

    @Test func widgetAccessUsesTheSharedPermissionAction() async {
        let cases: [(access: DockWidgetAccess, permission: SetupPermission)] = [
            (.calendar, .calendar), (.reminders, .reminders), (.music, .automation),
        ]
        for item in cases {
            var effects: [String] = []
            let factory: @MainActor @Sendable (SetupPermission, PermissionRequest) -> PermissionRequest = { permission, original in
                #expect(permission == item.permission)
                return PermissionRequest(
                    status: { .needed }, prompt: { effects.append("prompt") }, settingsURL: original.settingsURL,
                    activate: { effects.append("activate") }, openSettings: { _ in effects.append("settings") },
                    explainFullAccess: {}, refresh: { effects.append("refresh") })
            }
            await PermissionRequest.$override.withValue(factory) { await item.access.request() }
            #expect(effects == ["activate", "prompt", "refresh"])
        }
        #expect(DockWidgetAccess.music.text(for: .denied) == "Needs Automation")
        #expect(DockWidgetAccess.music.text(for: .granted) == "Access allowed")
        #expect(DockWidgetAccess.music.text(for: .unavailable).contains("Open Music first"))
    }
}
