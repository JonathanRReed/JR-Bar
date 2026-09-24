import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarUI
@testable import JRBarApp
@testable import JRBarCore

/// Render proofs for the windows: the menu-bar panel in its main states
/// (quiet, working, asking, usage-heavy), History, the Usage Center,
/// Effect Studio, the Creator Micro window, What's New, Setup and the
/// Overview's roster, sidebar and inspector — each in light and dark at
/// 2×, so a human can eyeball the whole set side by side. Off by
/// default; set `JRBAR_RENDER_PROOF=1` to write PNGs into
/// `JRBAR_RENDER_PROOF_DIR` (default /tmp/windows-proof).
@Suite("Windows render proof", .serialized)
@MainActor
struct WindowsRenderProofTests {
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1" }

    static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/windows-proof",
            isDirectory: true)
    }

    /// Writes `view` at `size`, once per appearance, over a plate that
    /// stands in for the window's own material.
    static func write<V: View>(_ name: String, size: CGSize, plate: Plate = .window,
                               @ViewBuilder _ view: () -> V) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = view()
        for dark in [false, true] {
            let framed = ZStack {
                plate.color(dark: dark)
                content
            }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.renderSnapshot, true)
            let renderer = ImageRenderer(content: framed)
            renderer.scale = 2
            let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
    }

    /// What sits behind a surface: a titled window's background, or the
    /// glass the panel and the floating cards are made of.
    enum Plate {
        case window
        case glass

        func color(dark: Bool) -> Color {
            switch self {
            case .window: return Color(nsColor: .windowBackgroundColor)
            case .glass: return Color(white: dark ? 0.13 : 0.93)
            }
        }
    }

    // MARK: Fixtures

    static let now = Date()
    static var t: Double { now.timeIntervalSince1970 }

    static func liveCore(_ state: CoreState) -> CoreModel {
        let core = CoreModel()
        core.handle(.connected)
        core.apply(.state(state))
        return core
    }

    static let devices = [
        CoreDevice(id: "pro", kind: "pro", name: "SidePulse Pro", leds: 60, connected: true, brightness: 0.62),
        CoreDevice(id: "dot", kind: "dot", name: "PulseDot", leds: 8, connected: true, brightness: 0.62),
        CoreDevice(id: "bar", kind: "screen_bar", name: "Screen Bar", connected: true, brightness: 0.62),
    ]

    static func usage(heavy: Bool) -> CoreUsage {
        var providers = [
            CoreProviderUsage(id: "claude", windows: [
                CoreUsageWindow(key: "5h", name: "5h", usedPct: 42, resetsAt: t + 3720),
                CoreUsageWindow(key: "7d", name: "7d", usedPct: 18, resetsAt: t + 3 * 86400 + 5 * 3600),
            ], fidelity: "official", state: "ready",
               tokens: CoreUsageTokens(input: 1_240_000, cachedInput: 8_400_000, output: 310_000),
               estimatedCostUSD: 14.2, observedAt: t - 60),
            CoreProviderUsage(id: "codex", windows: [
                CoreUsageWindow(key: "5h", name: "5h", usedPct: heavy ? 86 : 23, resetsAt: t + 7400),
                CoreUsageWindow(key: "7d", name: "7d", usedPct: heavy ? 61 : 12, resetsAt: t + 5 * 86400),
            ], fidelity: "official", state: "ready", observedAt: t - 90),
        ]
        if heavy {
            providers += [
                CoreProviderUsage(id: "gemini", windows: [
                    CoreUsageWindow(key: "daily", name: "Daily", usedPct: 97, resetsAt: t + 5 * 3600),
                ], fidelity: "derived", state: "warning", observedAt: t - 200),
                CoreProviderUsage(id: "cursor", windows: [
                    CoreUsageWindow(key: "monthly", name: "Monthly", usedPct: 33, resetsAt: t + 12 * 86400),
                ], state: "ready"),
                CoreProviderUsage(id: "grok", windows: [], state: "source_not_found", action: "Run grok login"),
                CoreProviderUsage(id: "opencode", windows: [
                    CoreUsageWindow(key: "5h", name: "5h", usedPct: 0, resetsAt: t + 2 * 3600),
                ], state: "ready"),
            ]
        }
        return CoreUsage(refreshedAt: t - 45, providers: providers)
    }

    static func sessions(asking: Bool) -> (sessions: [CoreSession], asks: [CoreAsk]) {
        var sessions = [
            CoreSession(id: "claude:jr-bar", provider: "claude", label: "quality pass", cwd: "/Users/me/src/jr-bar",
                        mode: "working", since: t - 640, workers: 3, tool: "Edit"),
            CoreSession(id: "codex:site", provider: "codex", label: "docs refresh", cwd: "/Users/me/src/site",
                        mode: "working", since: t - 1520, tool: "Bash"),
            CoreSession(id: "gemini:notes", provider: "gemini", label: "release notes", cwd: "/Users/me/src/notes",
                        mode: "done", since: t - 380),
            CoreSession(id: "opencode:ci", provider: "opencode", label: "flaky ci", cwd: "/Users/me/src/api",
                        mode: "failed", since: t - 2200),
        ]
        var asks: [CoreAsk] = []
        if asking {
            let permission = CoreAsk(session: "claude:fix", kind: "permission", openedAt: t - 74,
                                     summary: "Run the test suite before the merge",
                                     answerable: true, request: "r1",
                                     decision: CoreAskDecision(holdUntil: t + 40, always: true),
                                     preview: "npm test -- --runInBand")
            let question = CoreAsk(session: "codex:branch", kind: "question", openedAt: t - 21,
                                   summary: "Which branch should the release notes cover?",
                                   answerable: true, request: "r2",
                                   decision: CoreAskDecision(holdUntil: t + 50, choices: [
                                       CoreAskChoice(question: "Which branch?", options: ["main", "release/0.9"]),
                                   ]))
            asks = [permission, question]
            sessions.insert(CoreSession(id: "claude:fix", provider: "claude", label: "fix-ci",
                                        cwd: "/Users/me/src/jr-bar", mode: "waiting", since: t - 74,
                                        ask: permission), at: 0)
            sessions.insert(CoreSession(id: "codex:branch", provider: "codex", label: "release notes",
                                        cwd: "/Users/me/src/jr-bar", mode: "waiting", since: t - 21,
                                        ask: question), at: 1)
        }
        return (sessions, asks)
    }

    static func panelStore(_ state: CoreState) -> PanelStore {
        let store = PanelStore(core: liveCore(state),
                               draftsDefaults: UserDefaults(suiteName: "jrbar.proof.\(UUID())")!,
                               screenBarShown: true)
        store.now = now
        store.isOpen = true
        store.animationsArmed = false
        store.screenHeight = 1200
        return store
    }

    /// A week of tokens with a busy midweek, for the usage sparklines.
    static func week(_ scale: Double) -> UsageHistory {
        let calendar = Calendar(identifier: .gregorian)
        let shape: [Double] = [0.3, 0.55, 0.9, 0.7, 1.0, 0.2, 0.62]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let days = shape.enumerated().map { index, value in
            let date = calendar.date(byAdding: .day, value: index - 6, to: now)!
            return UsageHistoryDay(date: formatter.string(from: date), tokensIn: Int(value * scale),
                                   tokensOut: Int(value * scale * 0.3), cacheRead: Int(value * scale * 2))
        }
        return UsageHistory(provider: "", range: "7d", days: days, records: 100)
    }

    static func panel(_ store: PanelStore) -> some View {
        PanelView(store: store)
            .clipShape(RoundedRectangle(cornerRadius: PanelController.cornerRadius, style: .continuous))
    }

    static func panelSize(_ store: PanelStore) -> CGSize {
        CGSize(width: PanelView.width, height: CGFloat(store.layout.totalHeight))
    }

    // MARK: Panel

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func panelStates() async throws {
        let quiet = Self.panelStore(CoreState(now: Self.t, devices: Self.devices, usage: Self.usage(heavy: false),
                                              hiddenCount: 3))
        let busy = Self.sessions(asking: false)
        let working = Self.panelStore(CoreState(now: Self.t, aggregate: CoreAggregate(mode: "working", active: 2, ready: 1, failed: 1),
                                                sessions: busy.sessions, devices: Self.devices,
                                                usage: Self.usage(heavy: false)))
        let ask = Self.sessions(asking: true)
        let asking = Self.panelStore(CoreState(now: Self.t, aggregate: CoreAggregate(mode: "waiting", needsYou: 2, active: 2, ready: 1, failed: 1),
                                               sessions: ask.sessions, asks: ask.asks,
                                               devices: Self.devices, usage: Self.usage(heavy: false)))
        let heavy = Self.panelStore(CoreState(now: Self.t, aggregate: CoreAggregate(mode: "working", active: 2),
                                              sessions: Array(busy.sessions.prefix(2)),
                                              devices: Self.devices, usage: Self.usage(heavy: true)))
        let offline = PanelStore(core: CoreModel(), draftsDefaults: UserDefaults(suiteName: "jrbar.proof.\(UUID())")!,
                                 screenBarShown: true)
        offline.now = Self.now
        offline.isOpen = true
        for store in [quiet, working, heavy] {
            store.fetchUsageHistory = { provider, _ in
                Self.week(provider == "claude" ? 4_000_000 : 1_500_000)
            }
            store.refreshSparklines(force: true)
        }
        try await Task.sleep(for: .milliseconds(300))
        for (name, store) in [("quiet", quiet), ("working", working), ("asking", asking),
                              ("usage", heavy), ("offline", offline)] {
            try Self.write("panel-\(name)", size: Self.panelSize(store), plate: .glass) { Self.panel(store) }
        }
    }

    /// The panel as the live check found it: two working sessions, one
    /// with a long title and a worker, their context hairlines; stale
    /// Claude and Grok readings whose sources need a fix; a Usage list
    /// cut half a row in; and an armed closed-lid hold with the lid open.
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func panelLive() async throws {
        let liveSessions = [
            CoreSession(id: "claude:menubar", provider: "claude", label: "Menu bar and icon layout audit",
                        cwd: "/Users/me/Downloads/JR-Bar", mode: "working", since: Self.t - 5, workers: 1),
            CoreSession(id: "codex:inkling", provider: "codex", label: "Improve Inkling suggestions",
                        cwd: "/Users/me/Downloads/inkling", mode: "working", since: Self.t - 15),
        ]
        let liveUsage = CoreUsage(refreshedAt: Self.t - 39, providers: [
            CoreProviderUsage(id: "codex", windows: [
                CoreUsageWindow(key: "7d", name: "7d", usedPct: 75, resetsAt: Self.t + 5 * 86400 + 6 * 3600),
            ], fidelity: "official", state: "ready",
               forecast: CoreUsageForecast(exhaustsAt: Self.t + 11 * 3600 + 59 * 60, pace: "ahead")),
            CoreProviderUsage(id: "claude", windows: [
                CoreUsageWindow(key: "5h", name: "5h", usedPct: 19, resetsAt: Self.t - 37 * 60),
                CoreUsageWindow(key: "7d", name: "7d", usedPct: 19, resetsAt: Self.t + 3 * 86400 + 4 * 3600),
            ], fidelity: "official", state: "stale", action: "Reconnect Claude", reason: "authentication_required"),
            CoreProviderUsage(id: "devin", windows: [
                CoreUsageWindow(key: "7d", name: "7d", usedPct: 100, resetsAt: Self.t + 2 * 86400 + 16 * 3600),
                CoreUsageWindow(key: "daily", name: "Daily", usedPct: 2, resetsAt: Self.t + 16 * 3600 + 24 * 60),
            ], state: "ready"),
            CoreProviderUsage(id: "grok", windows: [
                CoreUsageWindow(key: "credits", name: "Credits", usedPct: 31, resetsAt: Self.t - 3600),
            ], state: "stale", action: "Run grok login"),
            CoreProviderUsage(id: "gemini", windows: [
                CoreUsageWindow(key: "daily", name: "Daily", usedPct: 0, resetsAt: Self.t + 5 * 3600),
            ], state: "ready"),
        ])
        let armedLid = try JSONDecoder().decode(CorePower.self, from: Data(
            #"{"keep_awake":true,"closed_lid":{"policy":"agents","holding":true,"lid_closed":false}}"#.utf8))
        let store = Self.panelStore(CoreState(now: Self.t, aggregate: CoreAggregate(mode: "working", active: 2),
                                              sessions: liveSessions, devices: Self.devices, usage: liveUsage,
                                              power: armedLid, hiddenCount: 2))
        store.sessionUsage.apply(SessionUsageDocument(sessions: [
            "claude:menubar": SessionUsage(provider: "claude", model: "claude-opus-4-5",
                                           contextTokens: 88_000, contextWindow: 200_000),
            "codex:inkling": SessionUsage(provider: "codex", model: "gpt-5.1-codex",
                                          contextTokens: 178_000, contextWindow: 200_000),
        ]), asked: ["claude:menubar", "codex:inkling"])
        store.fetchUsageHistory = { provider, _ in Self.week(provider == "claude" ? 4_000_000 : 1_500_000) }
        store.refreshSparklines(force: true)
        try await Task.sleep(for: .milliseconds(300))
        try Self.write("panel-live", size: Self.panelSize(store), plate: .glass) { Self.panel(store) }
        #expect(store.headerCounts == "2 sessions")
        #expect(store.awakeHold?.symbol == "cup.and.saucer.fill")
    }

    // MARK: The mock daemon

    /// `app/scripts/mock-core.py` on a socket of its own under the temp
    /// directory — never the installed daemon's — paused at timeline step
    /// `startAt`, with history answered whole.
    static func mock(startAt: Int, deck: String = "approved") async throws -> (CoreModel, Process) {
        let socket = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("jrbar-proof-\(UUID().uuidString.prefix(8)).sock")
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/mock-core.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, "--socket", socket, "--step", "600", "--hot-history",
                             "--start-at", "\(startAt)", "--deck", deck]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date(timeIntervalSinceNow: 10)
        while !FileManager.default.fileExists(atPath: socket), Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let core = CoreModel(socketPath: socket)
        core.start()
        try await settle { core.isLive && core.settings != nil }
        return (core, process)
    }

    /// Waits for `condition`, up to ten seconds.
    static func settle(_ condition: () -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: 10)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(150))
    }

    // MARK: History

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func history() async throws {
        let (core, process) = try await Self.mock(startAt: 12)
        defer { process.terminate(); core.stop() }
        let store = HistoryStore(core: core)
        store.windowDidOpen()
        try await Self.settle { !store.rows.isEmpty }
        try Self.write("history", size: CGSize(width: 720, height: 560)) { HistoryView(store: store) }
        store.mode = .events
        try await Self.settle { !store.replay.events.isEmpty }
        try Self.write("history-events", size: CGSize(width: 720, height: 560)) { HistoryView(store: store) }
        store.windowDidClose()
        let empty = HistoryStore(core: CoreModel(socketPath: "/nonexistent.sock"))
        try Self.write("history-offline", size: CGSize(width: 720, height: 420)) { HistoryView(store: empty) }
        // The mock seeds two days, too few for the rhythm; it is drawn
        // again over the weeks a busy Mac loads, and over its first four.
        for (name, reach) in [("history-rhythm", 20), ("history-rhythm-short", 3)] {
            let busy = HistoryStore(core: CoreModel(socketPath: "/nonexistent.sock"))
            busy.now = Self.now
            busy.loadedAt = Self.now
            busy.rows = Self.historyRows(daysBack: reach)
            try Self.write(name, size: CGSize(width: 720, height: 96)) {
                HistoryFilterBar(store: busy).frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// A made-up History: a few rows an hour through each working day,
    /// quieter weekends, the odd failure.
    static func historyRows(daysBack: Int) -> [CoreHistoryRow] {
        let shape = [5, 9, 14, 7, 11, 2, 0, 6, 12, 16, 10, 13, 3, 1, 8, 15, 9, 12, 4, 0, 7]
        let kinds = ["started", "completed", "asked", "answered", "completed"]
        var rows: [CoreHistoryRow] = []
        for back in 0...daysBack {
            let count = shape[back % shape.count] + (back == 0 ? 3 : 0)
            for index in 0..<count {
                let at = t - Double(back) * 86400 - Double(index) * 1500
                let kind = back % 4 == 1 && index == 0 ? "failed" : kinds[index % kinds.count]
                rows.append(CoreHistoryRow(at: at, kind: kind, provider: "claude", session: "claude:s\(back)",
                                           label: "session \(back)"))
            }
        }
        return rows
    }

    // MARK: Usage Center

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func usageCenter() async throws {
        let (core, process) = try await Self.mock(startAt: 6)
        defer { process.terminate(); core.stop() }
        let store = UsageCenterStore(core: core)
        store.windowDidOpen()
        try await Self.settle { !store.providers.isEmpty && store.providers.allSatisfy { store.history(for: $0) != nil } }
        try Self.write("usage-center", size: CGSize(width: 780, height: 1500)) { UsageCenterView(store: store) }
        store.metric = .cost
        try Self.write("usage-center-cost", size: CGSize(width: 780, height: 900)) { UsageCenterView(store: store) }
        store.windowDidClose()
        let offline = UsageCenterStore(core: CoreModel(socketPath: "/nonexistent.sock"))
        try Self.write("usage-center-offline", size: CGSize(width: 760, height: 440)) { UsageCenterView(store: offline) }
    }

    // MARK: Effect Studio

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func effectStudio() async throws {
        let (core, process) = try await Self.mock(startAt: 0)
        defer { process.terminate(); core.stop() }
        let store = EffectStudioStore(core: core)
        store.mode = .effects
        store.windowDidOpen()
        try await Self.settle { store.catalog != nil && store.assignments != nil }
        try Self.write("effects", size: CGSize(width: 1100, height: 720)) {
            HStack(spacing: 0) {
                EffectLibraryPane(store: store).frame(width: 260)
                Divider()
                EffectInspectorPane(store: store).frame(width: 520)
                Divider()
                EffectAssignmentsPane(store: store).frame(width: 318)
            }
        }
        store.mode = .moments
        try Self.write("effects-moments", size: CGSize(width: 1100, height: 720)) { LightMomentsView(store: store) }
        store.windowDidClose()
    }

    // MARK: Creator Micro

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func controlCenter() async throws {
        for (name, deck, step) in [("control-center", "approved", 2), ("control-center-absent", "absent", 0)] {
            let (core, process) = try await Self.mock(startAt: step, deck: deck)
            let store = DeckStore(core: core)
            store.windowDidOpen()
            try await Self.settle { store.deck != nil }
            try Self.write(name, size: CGSize(width: 1000, height: 760)) { ControlCenterView(store: store) }
            store.windowDidClose()
            process.terminate()
            core.stop()
        }
        let offline = DeckStore(core: CoreModel(socketPath: "/nonexistent.sock"))
        try Self.write("control-center-offline", size: CGSize(width: 1000, height: 760)) { ControlCenterView(store: offline) }
    }

    // MARK: What's New and Setup

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func floatingCards() throws {
        try Self.write("whats-new", size: CGSize(width: WhatsNewView.width, height: 780), plate: .glass) {
            WhatsNewView(entries: WhatsNewCatalog.entries, tryIt: { _ in nil }, onDone: {})
                .frame(maxHeight: .infinity, alignment: .top)
        }
        var model = SetupModel()
        model.monitorLive = { true }
        model.agents = {
            [SetupAgent(id: "claude", name: "Claude Code", detected: true, hookStatus: "ok"),
             SetupAgent(id: "codex", name: "Codex", detected: true, hookStatus: "stale"),
             SetupAgent(id: "gemini", name: "Gemini CLI", detected: true, hookStatus: "missing"),
             SetupAgent(id: "opencode", name: "OpenCode", detected: false, hookStatus: nil)]
        }
        model.refreshPermissions = { [.notifications: .granted, .calendar: .granted, .accessibility: .needed,
                                      .screenRecording: .denied] }
        model.act = { _ in }
        model.screenBarShown = { true }
        model.setScreenBar = { _ in }
        model.iconStyle = { StatusIconStyle.agents.rawValue }
        model.setIconStyle = { _ in }
        model.installHooks = { _ in SetupNote("Hooks installed", isError: false) }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        let size = CGSize(width: SetupWindowController.contentSize.width, height: SetupWindowController.contentSize.height)
        for step in 0..<store.stepCount {
            try Self.write("setup-\(step + 1)-\(store.step.rawValue)", size: size, plate: .glass) { SetupView(store: store) }
            store.goNext()
        }
    }

    // MARK: Overview

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func overview() async throws {
        let (core, process) = try await Self.mock(startAt: 3)
        defer { process.terminate(); core.stop() }
        let store = OverviewStore(core: core)
        store.windowDidOpen()
        // The mock keeps no roster: the state's sessions stand in for it.
        store.roster = core.sessions.map { session in
            CoreRosterEntry(session: session, pinned: session.ask != nil,
                            axes: CoreSessionAxes(outcome: session.mode == "failed" ? "failed" : nil,
                                                  review: "unreviewed", freshness: "live"))
        }
        try #require(!store.roster.isEmpty)
        try Self.write("overview-connections", size: CGSize(width: 320, height: 640)) {
            OverviewConnectionsBrowser(store: store)
        }
        if let link = store.links.first {
            try Self.write("overview-link", size: CGSize(width: 320, height: 400)) {
                OverviewConnectionInspector(link: link)
            }
        }
        let asking = store.roster.first { $0.session.ask != nil } ?? store.roster[0]
        store.selectionChanged(to: [asking.id])
        await store.loadTimeline(for: asking.id)
        try await Self.settle { store.timelinePage != nil }
        try Self.write("overview-inspector", size: CGSize(width: 340, height: 900)) {
            OverviewSessionInspector(store: store, entry: asking) { _ in }
        }
        store.filter = OverviewFilter(preset: .all)
        try Self.write("overview-strips", size: CGSize(width: 760, height: 90)) {
            VStack(spacing: 0) {
                OverviewSummaryStrip(store: store)
                OverviewConnectionsStrip(store: store)
                Spacer(minLength: 0)
            }
        }
        store.windowDidClose()
    }
}
