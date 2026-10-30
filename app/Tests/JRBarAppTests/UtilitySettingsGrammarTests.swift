import AppKit
import JRBarCore
import JRBarTestSupport
import Observation
import SwiftUI
import Testing

@testable import JRBarApp

@Suite("Utility settings grammar", .serialized, .temporaryDirectory)
@MainActor
struct UtilitySettingsGrammarTests {
    @Test func everyFeatureRendersItsPurposeAndStatus() async throws {
        let fixture = try SettingsRenderProofTests.fixture()
        defer { fixture.toys.shutdown() }
        let previousHolders = KeepAwakeUtility.shared.proofHolders
        KeepAwakeUtility.shared.proofHolders = []
        defer { KeepAwakeUtility.shared.proofHolders = previousHolders }
        for id in UtilitySettingsRenderProofTests.cards {
            let toy = try #require(fixture.settings.cardToy(id))
            let values = await headings(SettingsFeatureDetail(toy: toy).environment(fixture.settings))
            try requireHeading(values, name: id)
        }
        try requireHeading(await headings(SeasonalSettingsSection(toys: fixture.toys)), name: "seasonal")
        let screenBar = ScreenBarSettingsCard(
            store: fixture.settings,
            device: fixture.settings.deviceEntries.first { $0.kind == "screen_bar" })
        try requireHeading(await headings(screenBar), name: "screen-bar")
        try requireHeading(await headings(ShortcutsPage(store: fixture.settings)), name: "control-center")
    }

    @Test func headerFollowsTheFeatureState() async throws {
        let toy = GrammarToy()
        #expect(await headings(SettingsFeatureDetail(toy: toy)).first?.status == "Off")
        toy.isOn = true
        toy.status = .failed("Could not start")
        #expect(await headings(SettingsFeatureDetail(toy: toy)).first?.status == "Could not start")
        toy.status = .paused("Waiting for permission")
        #expect(await headings(SettingsFeatureDetail(toy: toy)).first?.status == "Waiting for permission")
    }

    @Test func searchOpensEveryNewOptionsGroupWithoutChangingSettings() throws {
        let fixture = try SettingsRenderProofTests.fixture()
        defer { fixture.toys.shutdown() }
        let before = fixture.core.settings?.document
        let entries = fixture.settings.searchEntries.filter(SettingsFeatureOptions.contains)
        #expect(!entries.isEmpty)
        for entry in entries {
            fixture.settings.openFolds.removeAll()
            fixture.settings.reveal(entry)
            let id = entry.card ?? "seasonal"
            #expect(fixture.settings.isFoldOpen(SettingsFeatureOptions.fold(id)), "\(entry.title)")
            #expect(fixture.settings.searchHit == entry)
        }
        #expect(fixture.core.settings?.document == before)
        let rules = try #require(fixture.settings.searchEntries.first { $0.card == "agents" && $0.title == "Alert rules" })
        fixture.settings.reveal(rules)
        for provider in fixture.utilities.agents.alertProviders {
            #expect(fixture.settings.isFoldOpen(SettingsFeatureOptions.agentProvider(provider)))
        }
    }

    @Test func calendarAccessOffDoesNotLeaveSeasonalTouchesWaiting() async throws {
        let fixture = try SettingsRenderProofTests.fixture()
        defer { fixture.toys.shutdown() }
        fixture.toys.seasonal.clock = { Date(timeIntervalSince1970: 1_800_000_000) }
        fixture.toys.state.seasonal.enabled = true
        let values = await headings(SeasonalSettingsSection(toys: fixture.toys))
        #expect(values.first?.status == "On · No occasion today")
    }

    private func requireHeading(_ values: [SettingsFeatureHeadingValue], name: String) throws {
        let heading = try #require(values.first, "No feature header rendered for \(name)")
        #expect(values.count == 1, "Repeated feature header for \(name)")
        #expect(!heading.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!heading.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(name)")
        #expect(!heading.status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(name)")
    }

    private func headings<V: View>(_ view: V) async -> [SettingsFeatureHeadingValue] {
        var values: [SettingsFeatureHeadingValue] = []
        let root = view.onPreferenceChange(SettingsFeatureHeadings.self) { values = $0 }
            .environment(\.renderSnapshot, true).environment(\.ledPreviewsHeld, true)
        let host = NSHostingView(rootView: root)
        let size = NSSize(width: 610, height: 4000)
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        defer {
            window.contentView = nil
            window.close()
        }
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await drainMainQueue()
        }
        return values
    }
}

@MainActor @Observable
private final class GrammarToy: Toy {
    let id = "synthetic"
    let name = "Synthetic utility"
    let blurb = "Configure a synthetic utility."
    let symbol = "gearshape"
    var isOn = false
    var status: ToyStatus = .off
    var controls: AnyView { AnyView(EmptyView()) }
}
