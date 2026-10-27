import AppKit
import SwiftUI
import Foundation
import Testing
@testable import JRBarCore
@testable import JRBarApp

@Suite @MainActor
struct MonitorRecoveryFlowTests {
    @Test func connectionStatesAndExistingInspectorNavigation() {
        let core = CoreModel()
        let utility = AgentUtility(core: core)
        var settings = AgentOverviewSettings()
        settings.enabled = true
        utility.settings = { settings }
        core.handle(.connecting(attempt: 2))
        utility.refreshSnapshot()
        #expect(utility.status == .paused("Connecting to monitor"))
        core.handle(.connected)
        utility.refreshSnapshot()
        #expect(utility.status == .paused("Waiting for monitor state"))
        core.apply(.state(CoreState(sessions: [CoreSession(id: "fixture", provider: "codex")])))
        utility.refreshSnapshot()
        #expect(utility.status == .on)
        core.handle(.stateRejected("fixture decode failure"))
        utility.refreshSnapshot()
        #expect(utility.snapshot.connected)
        #expect(!utility.snapshot.live)
        #expect(utility.snapshot.stateRejected == "fixture decode failure")
        #expect(utility.alertProviders.contains("codex"))
        #expect(utility.status == .paused("Monitor update unreadable"))
        let store = OverviewStore(core: core)
        let link = store.links.first { $0.id == "core" }
        #expect(link?.subtitle == "Connected · update unreadable")
        #expect(link?.facts.contains(.init("Update rejected", "fixture decode failure")) == true)
        #expect(store.links.first { $0.id == "node:local" }?.tone != .good)
        var shows = 0
        utility.onOpenMonitorDetails = { store.selectLink("core"); shows += 1 }
        utility.openMonitorDetails()
        #expect(store.selectedLinkID == "core")
        #expect(shows == 1)
        core.apply(.state(CoreState()))
        utility.refreshSnapshot()
        #expect(utility.status == .on)
        #expect(store.links.first { $0.id == "core" }?.tone == .good)
        core.handle(.disconnected(reason: "fixture closed"))
        utility.refreshSnapshot()
        #expect(utility.status == .paused("Monitor not connected"))
        #expect(store.links.first { $0.id == "core" }?.subtitle == "Not connected")
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func recoveryCardRender() throws {
        let core = CoreModel()
        core.handle(.connected)
        core.handle(.stateRejected("fixture decode failure"))
        let panel = PanelStore(core: core)
        let utility = AgentUtility(core: core)
        utility.connectionDescription = { panel.connectionDescription }
        utility.onOpenMonitorDetails = {}
        utility.onOpenOverview = {}
        utility.refreshSnapshot()
        try WindowsRenderProofTests.write("agent-monitor-recovery", size: CGSize(width: 620, height: 420)) {
            AgentUtilityControls(utility: utility).padding()
        }
    }

    @Test func waitingStateAndLegacySnapshotDefaults() {
        let core = CoreModel()
        core.handle(.connected)
        let store = OverviewStore(core: core)
        #expect(store.links.first { $0.id == "core" }?.subtitle == "Connected · waiting for an update")
        #expect(store.links.first { $0.id == "core" }?.tone == .busy)
        var legacy = OverviewLinkage.Snapshot()
        legacy.connected = true
        #expect(OverviewLinkage.links(legacy).first?.tone == .good)
        legacy.usableState = false
        legacy.localSessions = 3
        #expect(OverviewLinkage.links(legacy).first { $0.id == "node:local" }?.subtitle == "3 sessions on record")
    }

    @Test func openingMonitorDetailsRetainsTheTargetThroughWindowPreparation() {
        let core = CoreModel()
        let store = OverviewStore(core: core)
        store.selectedID = "old-selection"
        store.selectedIDs = ["old-selection"]
        store.windowDidOpen(selectingLink: "core")
        defer { store.windowDidClose() }
        #expect(store.windowOpen)
        #expect(store.selectedLinkID == "core")
        #expect(store.selectedLink?.id == "core")
        #expect(store.selectedID == nil)
        #expect(store.selectedIDs.isEmpty)
    }
}
