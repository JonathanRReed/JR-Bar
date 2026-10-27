import AppKit
import JRBarCore
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Usage polish", .serialized)
@MainActor
struct UsagePolishTests {
    static let now = 1_800_000_000.0

    static var provider: CoreProviderUsage {
        CoreProviderUsage(id: "claude", windows: [
            CoreUsageWindow(name: "5h", usedPct: 42, resetsAt: now + 3900),
            CoreUsageWindow(name: "7d", usedPct: 18, resetsAt: now + 86400),
        ], state: "ready", creditsRemaining: 0.4, readAt: now - 97)
    }

    @Test func overviewButtonSpeaksItsFigures() throws {
        let row = UsageOverviewProviderRow(provider: Self.provider, name: "Claude", now: Self.now,
            connected: true, windowNames: ["5h", "7d"], columnWidth: 76, snapshotReceivedAt: Self.now,
            today: UsageHistoryDay(date: "2027-01-15", tokensIn: 1000, tokensOut: 234, costUsd: 0.12),
            showCost: true, select: {})
        let host = NSHostingView(rootView: row.frame(width: 500))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        #expect(PolishRound2Tests.buttonLabels(host).contains("Claude"))
        let values = PolishRound2Tests.elements(host).compactMap {
            PolishRound2Tests.accessibilityValue($0, "accessibilityValue") as? String
        }
        #expect(values.contains(row.spokenValue))
        #expect(row.spokenValue.contains("5-hour. 42 percent used. Resets in 65 minutes"))
        #expect(row.spokenValue.contains("7-day. 18 percent used"))
        #expect(row.spokenValue.contains("Today's tokens including cache reads: 1234"))
        #expect(row.spokenValue.contains("Estimated cost: $0.12"))
    }

    @Test func emptyOffStaleAndResetReadingsHaveSpokenStates() {
        let empty = CoreProviderUsage(id: "grok", state: "ready")
        let emptyRow = UsageGaugeRow(provider: empty, name: "Grok", now: Self.now,
            style: .compact, windowNames: ["5h", "7d"])
        #expect(emptyRow.accessibilityValue == "No reading")
        var off = Self.provider
        off.reason = CoreProviderUsage.usageOffReason
        #expect(UsageGaugeRow(provider: off, name: "Claude", now: Self.now).accessibilityValue == "Off")
        var stale = Self.provider
        stale.state = "stale"
        let staleRow = UsageGaugeRow(provider: stale, name: "Claude", now: Self.now, snapshotReceivedAt: Self.now)
        #expect(staleRow.accessibilityValue.contains("Stale"))
        #expect(staleRow.accessibilityValue.contains("Read 1 minute ago"))
        let expired = CoreUsageWindow(name: "5h", usedPct: 42, resetsAt: Self.now - 60)
        let reading = UsageGaugeReading(window: expired, provider: stale, now: Self.now)
        #expect(reading.percentUsed == nil)
        #expect(reading.accessibilityLabel.contains("Reset 1 minute ago"))
        #expect(!reading.accessibilityLabel.contains("42 percent"))
    }

    @Test(arguments: ["Grok", "Grok · Team account"])
    func emptyCompactRowFitsThePanelHeight(_ name: String) {
        var provider = CoreProviderUsage(id: "grok", state: "ready")
        provider.incident = "Sample service delay"
        let gauge = UsageGaugeRow(provider: provider, name: name, now: Self.now,
            style: .compact, windowNames: ["5h", "7d"], onOpen: {})
        #expect(gauge.accessibilityValue.contains("Sample service delay"))
        let host = NSHostingView(rootView: UsageGaugeRow(provider: provider, name: name, now: Self.now,
            style: .compact, windowNames: ["5h", "7d"], onOpen: {}).frame(width: 320))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height <= 44)
    }

    @Test func invalidResetsHaveNoSpokenDate() {
        for reset in [0.0, -1, .infinity, .nan, Date.distantFuture.timeIntervalSince1970 + 1] {
            let window = CoreUsageWindow(name: "5h", usedPct: 42, resetsAt: reset)
            let reading = UsageGaugeReading(window: window, provider: Self.provider, now: Self.now)
            #expect(!reading.accessibilityLabel.contains("Reset "))
            #expect(!reading.accessibilityLabel.contains("Resets in"))
        }
    }

    @Test func detailWindowButtonsSpeakResetUnits() {
        let host = NSHostingView(rootView: UsageGaugeRow(provider: Self.provider, name: "Claude",
            now: Self.now, style: .detail, onInspect: { _ in }).frame(width: 600))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let labels = PolishRound2Tests.buttonLabels(host)
        #expect(labels.contains { $0.contains("5-hour. 42 percent used. Resets in 65 minutes") })
        #expect(labels.contains { $0.contains("7-day. 18 percent used") })
    }

    @Test func unknownPaceHasOneSummaryAndNoBadge() {
        let core = WindowsRenderProofTests.liveCore(CoreState(usage: CoreUsage(providers: [Self.provider])))
        let store = UsageCenterStore(core: core)
        store.now = Date(timeIntervalSince1970: Self.now)
        let detail = UsageProviderDetail(provider: Self.provider, store: store, showCost: false)
        let inspection = detail.inspection(for: Self.provider.windows[0])
        #expect(!inspection.showsVerdict)
        #expect(inspection.summaryText.contains("42% used"))
        #expect(inspection.summaryText.contains("Resets "))
    }

    @Test func readingAgesAndRunLengthsHoldWholeMinutes() {
        #expect(UsageGaugeReading.age(provider: Self.provider, now: Self.now, snapshotReceivedAt: Self.now) == "Read 1m ago")
        #expect(UsageGaugeReading.age(provider: Self.provider, now: Self.now + 20, snapshotReceivedAt: Self.now) == "Read 1m ago")
        #expect(HistoryStore.duration(59) == "59s")
        #expect(HistoryStore.duration(95) == "1m")
        #expect(HistoryStore.duration(3600) == "1h 00m")
        #expect(HistoryStore.duration(.infinity) == nil)
    }

    @Test(arguments: [0.4, 1.0, 1.5, 10.0])
    func creditBalancesKeepTheirUnit(_ balance: Double) {
        var provider = Self.provider
        provider.creditsRemaining = balance
        let facts = UsageProviderFacts(provider: provider, history: nil, providers: [], isLive: true,
            now: Date(timeIntervalSince1970: Self.now))
        let expected: String
        switch balance {
        case 0.4: expected = "0.4 credits available"
        case 1: expected = "1 credit available"
        case 1.5: expected = "1.5 credits available"
        default: expected = "10 credits available"
        }
        #expect(facts.credits == expected)
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func renderProofs() async throws {
        try U5Proof.pinDefaultAccent()
        var account = Self.provider
        account.id = "codex"
        account.windows = [account.windows[0]]
        account.incident = "Sample service delay"
        var empty = CoreProviderUsage(id: "grok", state: "ready")
        empty.availability = "absent"
        let providers = [Self.provider, account, empty]
        let session = CoreSession(id: "codex:sample", provider: "codex", label: "Sample task", mode: "working")
        let core = WindowsRenderProofTests.liveCore(CoreState(now: Self.now, sessions: [session],
            usage: CoreUsage(refreshedAt: Self.now, providers: providers)))
        let usage = UsageCenterStore(core: core)
        usage.now = Date(timeIntervalSince1970: Self.now)
        usage.readProviderRows = { [] }
        var expired = Self.provider
        expired.state = "stale"
        expired.action = "Retry"
        expired.windows[0].resetsAt = Self.now - 60
        let expiredInspection = UsageWindowInspection(provider: expired, window: expired.windows[0],
            forecast: usage.forecast(for: expired, window: expired.windows[0]), isLive: true, now: usage.now)
        let overview = OverviewStore(core: core, localName: "Sample Mac")
        overview.roster = [CoreRosterEntry(session: session)]
        overview.filter = OverviewFilter(preset: .working)
        overview.selectedID = session.id
        overview.selectedIDs = [session.id]
        let settings = try SettingsRenderProofTests.fixture()
        defer { settings.toys.shutdown() }
        let programs = StudioWorkspaceRenderProofTests.Programs.synthetic()
        let studio = EffectStudioStore(core: core)
        studio.covered = true
        studio.lightsStudio.requestPlan = { programs.plan }
        studio.lightsStudio.requestPreview = { scenario, mode in
            try #require(programs.previews["\(scenario)|\(mode)"])
        }
        await studio.lightsStudio.refreshPlan()
        await studio.lightsStudio.refreshPreviews()
        let deck = DeckStore(core: core)
        deck.reduceMotion = true
        let slot = DeckSlot(index: 0, session: session.id, label: "Sample task", provider: "codex",
                            state: .active, navigable: true)
        let finish = try EffectStudioMomentsTests.finishDocument()
        for dark in [false, true] {
            for width in [CGFloat(320), CGFloat(372)] {
                try await U5Proof.render(VStack(spacing: 12) {
                    UsageGaugeHeader(windowNames: ["5h", "7d"])
                    UsageGaugeRow(provider: Self.provider, name: "Claude", now: Self.now, style: .compact,
                        windowNames: ["5h", "7d"])
                    UsageGaugeRow(provider: account, name: "Codex · Team account", now: Self.now, style: .compact,
                        windowNames: ["5h", "7d"])
                    UsageGaugeRow(provider: empty, name: "Grok", now: Self.now, style: .compact,
                        windowNames: ["5h", "7d"], includeAbsent: true)
                }, name: "p3-usage-\(Int(width))", width: width, dark: dark)
            }
            try await U5Proof.render(UsageProviderDetail(provider: Self.provider, store: usage, showCost: true)
                .padding(20), name: "p3-usage-detail", width: 700, dark: dark)
            try await U5Proof.render(UsageForecastSummary(inspection: expiredInspection).padding(20),
                name: "p3-window-summary-stale", width: 440, dark: dark)
            try await U5Proof.render(UsageOverviewTable(store: usage, showCost: false, select: { _ in })
                .padding(20), name: "p3-usage-overview", width: 1000, dark: dark)
            try await U5Proof.render(VStack(alignment: .leading, spacing: 20) {
                SettingsPageNotice(store: settings.settings, page: .agents)
                SettingsProvidersPage(store: settings.settings)
                SettingToggle(settings.settings, "Sub-agent asks", subtitle: SubagentAsksCopy.subtitle,
                    path: "subagent_asks_alert")
            }.padding(20), name: "p3-providers-offline", width: 600, dark: dark)
            try await U5Proof.render(ScreenBarSettingsCard(store: settings.settings, device: nil).padding(20),
                name: "p3-screenbar-settings", width: 600, dark: dark)
            try await U5Proof.render(MenuBarUtilityControls(utility: settings.utilities.menuBar, showAdvanced: true).padding(20),
                name: "p3-menubar-settings", width: 600, dark: dark)
            try await U5Proof.render(StudioMixPage(store: studio).frame(height: 900),
                name: "p3-studio", width: 850, dark: dark)
            try await U5Proof.render(VStack(alignment: .leading, spacing: 20) {
                PaletteEditor(colors: ["#1288FF"], maximum: 4, allowEmpty: true, onChange: { _ in })
                KeyCap(store: deck, slot: slot)
                BankPager(store: deck)
                FinishMomentsSection(store: studio, seed: finish)
            }.padding(20), name: "p3-keyboard-controls", width: 760, dark: dark)
            try await U5Proof.render(OverviewView(store: overview).frame(height: 800),
                name: "p3-overview", width: 1400, dark: dark)
            try await U5Proof.render(OverviewSessionInspector(store: overview,
                entry: CoreRosterEntry(session: session), reply: { _ in }).padding(20),
                name: "p3-overview-inspector", width: 440, dark: dark)
            try Self.toolbarProof(store: usage, selection: "overview", dark: dark)
            try Self.toolbarProof(store: usage, selection: Self.provider.identity, dark: dark)
            let history = HistoryStore(core: core, schedulingEnabled: false)
            history.now = usage.now
            history.loadedAt = history.now
            history.rows = [
                CoreHistoryRow(at: Self.now - 60, kind: "completed", provider: "claude",
                    session: "claude:sample-short", label: "Short task", duration: 95),
                CoreHistoryRow(at: Self.now - 1800, kind: "completed", provider: "codex",
                    session: "codex:sample-long", label: "Long task", duration: 3600),
            ]
            try await U5Proof.render(HistoryView(store: history).frame(height: 560),
                name: "p3-history", width: 800, dark: dark)
        }
    }

    private static func toolbarProof(store: UsageCenterStore, selection: String, dark: Bool) throws {
        let suite = ScratchDefaults.suiteName("usage-polish-toolbar")
        let defaults = ScratchDefaults.open(suite)
        defer { ScratchDefaults.remove(suite) }
        defaults.set(selection, forKey: "usageCenter.provider")
        defaults.set(false, forKey: "usageCenter.showCost")
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 980, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        WindowContentLifecycle.attach(to: window, title: "Usage Center") {
            WindowContentLifecycle.hosting(UsageCenterView(store: store).defaultAppStorage(defaults)
                .tint(.blue).accentColor(.blue).environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.controlActiveState, .key).background(JRBarTokens.Ink.window)
                .environment(\.renderSnapshot, true).jrbarAccessibility(reduceMotion: true))
        }
        window.toolbarStyle = .unified
        defer { WindowContentLifecycle.detach(from: window); window.close() }
        let frame = try #require(window.contentView?.superview)
        for _ in 0..<6 {
            frame.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        #expect(window.toolbar != nil)
        #expect(!window.isVisible)
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let page = selection == "overview" ? "overview" : "provider"
        let name = "p3-toolbar-\(page)-\(dark ? "dark" : "light").png"
        try png.write(to: ProofRender.directory.appendingPathComponent(name))
    }

}
