import AppKit
import Carbon
import Foundation
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@Suite("Panel composition", .serialized)
@MainActor
struct PanelCompositionTests {
    static let time: Double = 1_790_000_000

    static func session(_ id: String, provider: String = "claude", mode: String = "working",
                        since: Double = time - 120, group: String? = nil, worker: Bool = false,
                        unlinked: Bool = false, workers: Int = 0, ask: CoreAsk? = nil) -> CoreSession {
        CoreSession(id: id, provider: provider, kind: worker ? "worker" : "session",
                    label: worker ? "Review tests" : "Sample project", cwd: "/tmp/sample/project",
                    mode: mode, lifecycle: mode == "done" ? "completed" : nil, since: since, ask: ask, workers: workers, groupId: group, unlinkedWorker: unlinked)
    }

    static func store(_ sessions: [CoreSession] = [], groups: [CoreAgentGroup] = [],
                      asks: [CoreAsk] = [], usage: [CoreProviderUsage] = []) -> PanelStore {
        let core = CoreModel(socketPath: "/tmp/jrbar-u2-unused.sock")
        core.handle(.connected)
        let aggregate = CoreAggregate(mode: "working", needsYou: asks.count,
                                      active: sessions.filter { $0.mode == "working" }.count,
                                      ready: sessions.filter { $0.mode == "done" }.count)
        core.apply(.state(CoreState(now: time, aggregate: aggregate, sessions: sessions, asks: asks,
                                   usage: CoreUsage(providers: usage), agentGroups: groups)))
        let store = PanelStore(core: core, draftsDefaults: ScratchDefaults.open(ScratchDefaults.suiteName("u2")), screenBarShown: false)
        store.now = Date(timeIntervalSince1970: time)
        store.isOpen = true
        store.reduceMotion = true
        store.screenHeight = 1000
        return store
    }

    static func group(_ members: [String], root: String = "claude:root") -> CoreAgentGroup {
        CoreAgentGroup(id: "group", rootWorkKey: root, rootProvider: "claude", members: members, lineageEvidence: [])
    }

    static func usage(_ id: String = "claude", availability: String = "available", action: String? = nil,
                      actionKind: String? = nil, elapsed: Bool = false) -> CoreProviderUsage {
        var usage = CoreProviderUsage(id: id, windows: [
            CoreUsageWindow(name: "5h", usedPct: 42, resetsAt: time + (elapsed ? -60 : 2400)),
            CoreUsageWindow(name: "7d", usedPct: 18, resetsAt: time + 86_400),
        ], state: "ready", action: action)
        usage.availability = availability
        usage.lastGoodAgeSeconds = 2460
        usage.actionKind = actionKind
        switch availability {
        case "failing": usage.statusText = "Sign-in rejected"
        case "source_idle": usage.statusText = "Quota service is not running"
        case "not_found", "missing_recent": usage.statusText = "Not found on this Mac"
        default: break
        }
        return usage
    }

    @Test func publishedMembershipGroupsAcrossProvidersAndAsksStayIndividual() {
        let ask = CoreAsk(session: "codex:child", summary: "Run the sample tests?", answerable: true)
        let sessions = [Self.session("claude:root", group: "group", workers: 2),
                        Self.session("gemini:child", provider: "gemini", group: "group", worker: true),
                        Self.session("codex:child", provider: "codex", mode: "waiting", group: "group", worker: true, ask: ask),
                        Self.session("factory:unlinked", provider: "factory", worker: true, unlinked: true)]
        let store = Self.store(sessions, groups: [Self.group(Array(sessions.prefix(3)).map(\.id))], asks: [ask])
        #expect(store.panelAgents.count == 2)
        #expect(store.panelAgents.first { $0.id == "claude:root" }?.members.map(\.id) == ["gemini:child"])
        #expect(store.panelAgents.first { $0.id == "claude:root" }?.workerCount == 2)
        #expect(store.visibleAskRows.map(\.id) == ["codex:child"])
        #expect(store.panelAgents.first { $0.id == "factory:unlinked" }?.unlinked == true)
        #expect(store.panelSelectableRows.map(\.id) == ["codex:child", "claude:root", "factory:unlinked"])
        store.expandedAgentGroups.insert("claude:root")
        #expect(store.panelSelectableRows.map(\.id).contains("gemini:child"))
    }

    @Test func aSharedFolderDoesNotCreateAGroup() {
        let store = Self.store([Self.session("claude:a"), Self.session("codex:b", provider: "codex")])
        #expect(store.panelAgents.count == 2)
        #expect(store.panelAgents.allSatisfy { $0.members.isEmpty })
    }

    @Test func completionsFoldAtTenMinutesAndKeepWorkingMembersVisible() {
        let root = Self.session("claude:root", mode: "done", since: Self.time - 599)
        let store = Self.store([root])
        #expect(store.currentPanelAgents.count == 1)
        store.now = store.now.addingTimeInterval(1)
        #expect(store.currentPanelAgents.isEmpty)
        #expect(store.earlierPanelAgents.count == 1)
        #expect(store.panelSelectableRows.isEmpty)
        store.earlierExpanded = true
        #expect(store.panelSelectableRows.map(\.id) == [root.id])
        let grouped = Self.store([Self.session("claude:root", mode: "done", since: Self.time - 700, group: "group"),
                                  Self.session("codex:child", provider: "codex", group: "group", worker: true)],
                                 groups: [Self.group(["claude:root", "codex:child"])])
        #expect(grouped.currentPanelAgents.count == 1)
        #expect(grouped.panelHasRunningAgents)
    }

    @Test func quotaStatesStayVisibleAndExpiredWindowsHaveNoCurrentPercent() {
        let readings = [Self.usage(), Self.usage("antigravity", availability: "source_idle", action: "Open", actionKind: "open_app"),
                        Self.usage("codex", availability: "failing", action: "Sign In…"),
                        Self.usage("gemini", elapsed: true), Self.usage("cursor", availability: "missing_recent"),
                        Self.usage("kiro", availability: "not_found", action: "Hide", actionKind: "hide"),
                        Self.usage("grok", availability: "absent")]
        let store = Self.store(usage: readings)
        #expect(store.panelUsage.count == 6)
        #expect(store.panelWindowNames == ["5h", "7d"])
        let reading = UsageGaugeReading(window: readings[3].windows[0], provider: readings[3], now: Self.time)
        #expect(reading.elapsed && reading.percentUsed == nil)
        #expect(!store.panelHasRunningAgents)
        let composition = PanelComposition(store: store)
        #expect(composition.usageLimit >= 1 && composition.usageLimit <= 4)
        #expect(store.panelUsage.count > composition.usageLimit)
    }

    @Test func aShortScreenKeepsWholeUsageRowsAndTheFooter() {
        let asks = (0..<6).map { CoreAsk(session: "claude:ask:\($0)", summary: "Sample request", answerable: true, request: "request-\($0)") }
        let sessions = (0..<8).map { Self.session("codex:session:\($0)", provider: "codex") }
        let readings = ["claude", "codex", "gemini", "cursor", "antigravity", "grok"].map { Self.usage($0) }
        let store = Self.store(sessions, asks: asks, usage: readings)
        store.screenHeight = 600
        let composition = PanelComposition(store: store)
        #expect(composition.totalHeight <= 588)
        #expect(composition.usageLimit >= 1)
        #expect(composition.asksHeight >= CGFloat(PanelLayout.askRowHeight))
        #expect(composition.agentsHeight >= PanelComposition.rowHeight)
        #expect(composition.asksHeight.truncatingRemainder(dividingBy: CGFloat(PanelLayout.askRowHeight)) == 0)
    }

    @Test func anExpandedFirstAskKeepsItsWholeCardAndTheFooterOnAShortScreen() {
        let ask = CoreAsk(session: "claude:expanded-short", summary: "Sample request", answerable: true,
                          request: "expanded-short-test", detail: CoreAskDetail(command: "make test"))
        let store = Self.store(asks: [ask], usage: [Self.usage(), Self.usage("codex")])
        store.screenHeight = 600
        AskExpansion.shared.toggle(ask)
        defer { AskExpansion.shared.collapse(ask) }
        let composition = PanelComposition(store: store)
        #expect(composition.totalHeight <= 588)
        #expect(composition.askDetailHeight >= 24)
        #expect(composition.asksHeight == CGFloat(PanelLayout.askRowHeight) + composition.askDetailHeight)
    }

    @Test func editsSaveTheSharedOrderAndPanelVisibilityLeavesTrackOn() async throws {
        let store = Self.store(usage: [Self.usage(), Self.usage("codex")])
        let fixtures = ProviderListStoreTests()
        store.providerList.readRows = { try [fixtures.row(), fixtures.row("codex")] }
        await store.providerList.refresh()
        store.providerList.writePresentation = { fixtures.reply($0) }
        store.providerList.writePanel = { row, visible in
            var saved = row
            saved.options["panel_hidden"] = visible ? "false" : "true"
            return saved
        }
        await store.movePanelProvider("codex", before: "claude")
        #expect(store.panelUsage.map(\.id) == ["codex", "claude"])
        #expect(store.providerList.preferences.order == ["codex", "claude"])
        let row = try #require(store.providerList.providers.first { $0.id == "codex" })
        try await store.providerList.setPanelVisible(row, false)
        #expect(store.panelUsage.map(\.id) == ["claude"])
        #expect(store.providerList.isTracked("codex"))
        #expect(store.providerList.showsInMenuBar("codex"))
    }

    @Test func hideSnapshotWinsOverAnOlderProviderListRow() async throws {
        var reading = Self.usage("kiro", availability: "not_found", action: "Hide", actionKind: "hide")
        let store = Self.store(usage: [reading])
        let fixtures = ProviderListStoreTests()
        store.providerList.readRows = { try [fixtures.row("kiro")] }
        await store.providerList.refresh()
        #expect(store.panelUsage.map(\.id) == ["kiro"])
        reading.panelVisible = false
        store.core.apply(.state(CoreState(generation: 2, usage: CoreUsage(providers: [reading]))))
        #expect(store.providerList.showsInPanel(store.providerList.providers[0]))
        #expect(store.panelUsage.isEmpty)
        #expect(store.providerList.isTracked("kiro"))
    }

    @Test func retryUsesTheProviderScopeAcceptedByTheDaemon() async throws {
        let store = Self.store()
        let requests = TestEvents<[String]>()
        store.requestUsageRefresh = { providers in
            requests.send(providers)
            return CoreReply(id: "retry", ok: true)
        }
        var reading = Self.usage("codex", availability: "failing", action: "Retry")
        reading.instance = "sample-account"
        store.panelUsageAction(reading)
        let requested = try await requests.next()
        #expect(requested == ["codex"])
    }

    @Test func disconnectedPanelKeepsItsLastGoodUsage() {
        let store = Self.store(usage: [Self.usage()])
        store.core.handle(.disconnected(reason: "fixture"))
        #expect(store.panelUsage.map(\.id) == ["claude"])
        #expect(!store.isLive)
        let usage = store.panelUsage[0]
        let reading = UsageGaugeReading(window: usage.windows[0], provider: usage, now: Self.time, connected: false)
        #expect(reading.stale && reading.percentUsed == 42)
    }

    @Test func footerFitsTheNarrowPanel() {
        let store = Self.store()
        let width = NSHostingView(rootView: PanelActionsFooter(store: store)).fittingSize.width
        #expect(width <= 320)
    }

    @Test func shortcutsUseTheExistingRegistryAndReportConflicts() async throws {
        #expect(PanelHotkey.panelDefault.displayString == "⌥⌘J")
        #expect(PanelHotkey.studioDefault.displayString == "⌥⌘L")
        #expect(PanelHotkey.panelDefault.problem == nil && PanelHotkey.studioDefault.problem == nil)
        let recorder = HotkeyCenterTests.Recorder()
        let center = HotkeyCenter(registrar: recorder)
        let hotkey = PanelHotkey(id: PanelHotkey.studioID, title: "Open Studio", defaultChord: PanelHotkey.studioDefault, center: center)
        hotkey.chordSource = { PanelHotkey.studioDefault }
        var opens = 0
        hotkey.onPress = { opens += 1 }
        hotkey.setEnabled(true)
        let registration = try #require(recorder.registered.first)
        recorder.onHotKey?(registration.id)
        await drainMainQueue()
        #expect(opens == 1)
        hotkey.unregister()
        center.register("occupied", title: "Other action", chord: PanelHotkey.studioDefault) {}
        hotkey.setEnabled(true)
        #expect(hotkey.registrationFailed)
        #expect(center.owner(of: PanelHotkey.studioDefault)?.id == "occupied")
    }

    @Test func keyboardExpandsGroupsAndReachesEarlierWithMotionAllowed() {
        let root = Self.session("claude:root", group: "group", workers: 1)
        let child = Self.session("codex:child", provider: "codex", group: "group", worker: true)
        let earlier = Self.session("claude:old", mode: "done", since: Self.time - 700)
        let store = Self.store([root, child, earlier], groups: [Self.group([root.id, child.id])])
        store.reduceMotion = false
        store.moveSelection(by: 1)
        #expect(store.selectedID == root.id)
        #expect(store.handleDisclosureKey(124))
        #expect(store.expandedAgentGroups.contains(root.id))
        store.moveSelection(by: 1)
        #expect(store.selectedID == child.id)
        store.moveSelection(by: 1)
        #expect(store.selectedID == PanelStore.earlierSelectionID)
        #expect(store.handleDisclosureKey(124))
        store.moveSelection(by: 1)
        #expect(store.selectedID == earlier.id)
        store.moveSelection(by: -1)
        #expect(store.handleDisclosureKey(123))
        #expect(!store.earlierExpanded)
        store.selectedID = root.id
        #expect(store.handleDisclosureKey(123))
        #expect(!store.expandedAgentGroups.contains(root.id))
    }

    @Test func aMissingRootAndAnUnpublishedGroupKeepWorkersClickable() {
        let child = Self.session("codex:child", provider: "codex", group: "group", worker: true)
        let plain = Self.session("claude:plain", worker: true)
        let store = Self.store([child, plain], groups: [Self.group(["claude:missing", child.id])])
        #expect(Set(store.panelAgents.map(\.id)) == Set([child.id, plain.id]))
        #expect(store.panelAgents.allSatisfy { $0.members.isEmpty })
        #expect(store.panelSelectableRows.count == 2)
    }

    @Test func groupsUseThePublishedLiveWorkerCount() throws {
        let root = Self.session("claude:root", group: "group", workers: 1)
        let child = Self.session("codex:done", provider: "codex", mode: "done", group: "group", worker: true)
        let store = Self.store([root, child], groups: [Self.group([root.id, child.id, "codex:gone"])])
        let group = try #require(store.panelAgents.first)
        #expect(group.workerCount == 1)
        #expect(group.displayMembers.map(\.id) == [root.id, child.id])
    }

    @Test func findTrimsTheSameQueryForAgentsAndAsks() {
        let ask = CoreAsk(session: "codex:ask", summary: "Sample request", answerable: true)
        let store = Self.store([Self.session("claude:root")], asks: [ask])
        store.find("  sample  ")
        #expect(store.visibleAskRows.count == 1)
        #expect(store.panelAgents.count == 1)
        #expect(store.findSummary == "“sample” · 2 of 2")
    }

    @Test func anAskingLeadCountsOnceInFindResults() {
        let ask = CoreAsk(session: "claude:root", summary: "Sample request", answerable: true)
        let root = Self.session("claude:root", mode: "waiting", group: "group", workers: 1, ask: ask)
        let child = Self.session("codex:child", provider: "codex", group: "group", worker: true)
        let store = Self.store([root, child], groups: [Self.group([root.id, child.id])], asks: [ask])
        store.find(" sample ")
        #expect(store.findSummary == "“sample” · 2 of 2")
        #expect(Set(store.panelSelectionIDs).count == store.panelSelectionIDs.count)
        store.find("request")
        #expect(store.findSummary == "“request” · 1 of 2")
    }

    @Test func movingInBothDirectionsKeepsProvidersOutsideThePanelOrder() async throws {
        let store = Self.store(usage: [Self.usage(), Self.usage("codex"), Self.usage("kiro", availability: "absent")])
        let fixtures = ProviderListStoreTests()
        store.providerList.readRows = { try [fixtures.row(), fixtures.row("codex"), fixtures.row("kiro")] }
        store.providerList.writePresentation = { fixtures.reply($0) }
        await store.providerList.refresh()
        let row = try #require(store.panelEditProviders.first { $0.id == "claude" })
        await store.shiftPanelProvider(row, by: 1)
        #expect(store.providerList.preferences.order == ["codex", "claude", "kiro"])
        await store.shiftPanelProvider(row, by: -1)
        #expect(store.providerList.preferences.order == ["claude", "codex", "kiro"])
    }

    @Test func editCapacityUsesWholeFortyFourPointRows() async throws {
        let store = Self.store()
        let fixtures = ProviderListStoreTests()
        store.providerList.readRows = { try [fixtures.row(), fixtures.row("codex"), fixtures.row("gemini"), fixtures.row("kiro")] }
        await store.providerList.refresh()
        store.editingProviders = true
        store.screenHeight = 600
        let composition = PanelComposition(store: store)
        #expect(composition.usageLimit == 4)
        #expect(composition.totalHeight <= 588)
    }

    @Test func headerNamesEveryStateBesideTheAgentsTitle() {
        let store = Self.store()
        store.core.apply(.state(CoreState(generation: 2, aggregate: CoreAggregate(needsYou: 1, active: 2, ready: 1))))
        #expect(store.headerCounts == "2 working · 1 asking · 1 done")
    }

    @Test func sectionOrderStaysFixedUntilTheNextOpen() {
        let store = Self.store([Self.session("claude:root")])
        store.providerList.readRows = { [] }
        store.panelDidOpen()
        defer { store.panelDidClose() }
        store.core.apply(.state(CoreState(generation: 2, usage: CoreUsage(providers: [Self.usage()]))))
        #expect(!store.panelHasRunningAgents)
        #expect(store.panelAgentsFirst == true)
    }

    @Test func motionUsesApprovedDurations() {
        #expect(PanelMotion.unfoldDuration == 0.14)
        #expect(PanelMotion.reducedDuration == 0.08)
        #expect(PanelMotion.contents(reduced: true) == nil)
    }
}
