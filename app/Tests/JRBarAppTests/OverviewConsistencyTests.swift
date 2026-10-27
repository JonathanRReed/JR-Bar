import AppKit
import JRBarCore
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
struct OverviewConsistencyTests {
    @Test func emptyOverviewFitsTheWindow() {
        let core = WindowsRenderProofTests.liveCore(CoreState(sessions: [
            CoreSession(id: "codex:sample", provider: "codex", label: "Sample check", mode: "working"),
        ]))
        let store = OverviewStore(core: core, localName: "Sample Mac")
        store.roster = core.state!.sessions.map { CoreRosterEntry(session: $0) }
        let host = NSHostingView(rootView: OverviewView(store: store).frame(width: 1200))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 760)
        host.layoutSubtreeIfNeeded()
        #expect(store.nobodyWaiting)
        #expect(!host.subviews.isEmpty)
        for child in host.subviews {
            #expect(child.frame.minY >= 0)
            #expect(child.frame.maxY <= host.bounds.maxY)
        }
    }

    @Test func expiredStaleWindowsDoNotCreateColumns() {
        let providers = OverviewConsistencyRenderProofTests.providers
        let names = UsageOverviewTable.windowNames(providers: providers,
            now: OverviewConsistencyRenderProofTests.now, connected: true)
        #expect(names == ["5h", "7d Fable", "Daily"])
        let stale = providers.first { $0.id == "antigravity" }!
        #expect(stale.windows.count == 2, "The provider detail retains the saved windows")
        let namesWhileOffline = UsageOverviewTable.windowNames(providers: providers,
            now: OverviewConsistencyRenderProofTests.now, connected: false)
        #expect(namesWhileOffline == names)
    }

    @Test func providerWordsAndTones() {
        let states: [(String, UsageStatus)] = [
            ("needs_consent", .needsConsent), ("needs_sign_in", .needsSignIn),
            ("disabled", .off), ("stale", .stale),
        ]
        for (raw, status) in states {
            let provider = CoreProviderUsage(id: "codex", state: raw)
            let link = OverviewLinkage.links(.init(providers: [provider])).last!
            #expect(link.subtitle == status.word)
            #expect(link.usageStatus == status)
            #expect(link.color == status.tone.color)
        }
    }

    @Test func canonicalDeviceStateAndNames() {
        let devices = [
            CoreDevice(id: "pro", kind: "pro", name: "Legacy Pro", connected: true, enabled: false),
            CoreDevice(id: "dot", kind: "dot", name: "SidePulse Dot", connected: false),
            CoreDevice(id: "bar", kind: "screen_bar", enabled: true),
        ]
        let links = OverviewLinkage.links(.init(connected: true, devices: devices,
            deck: DeckDevice(name: "Legacy deck", connected: true), deckEnabled: false))
            .filter { $0.group == .devices }
        #expect(links.map(\.title) == ["SidePulse", "PulseDot", "Screen Bar", "Creator Micro 2"])
        #expect(links.map(\.subtitle) == ["Off", "Not connected", "Connected", "Off"])
    }

    @Test func titlebarReservesItsSpace() {
        let controller = OverviewWindowController(store: OverviewStore(core: CoreModel()))
        let window = controller.makeWindow()
        defer { window.close() }
        #expect(!window.isVisible)
        #expect(!window.styleMask.contains(.fullSizeContentView))
        #expect(window.contentLayoutRect.height < window.frame.height)
    }
}
