import AppKit
@testable import JRBarCore
import JRBarUI
import QuartzCore
import ObjectiveC
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("U5 key-window render proofs", .serialized)
@MainActor
struct U5RenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"
    static let stamp = 1_792_947_600.0

    init() throws { try U5Proof.pinDefaultAccent() }

    @Test(.enabled(if: enabled))
    func notchOwnerMatrix() async throws {
        for dark in [false, true] {
            let (toy, owner, monitor) = NotchSurfaceRenderProofTests.makeToy()
            defer { withExtendedLifetime(owner) {} }
            NotchSurfaceRenderProofTests.fill(toy.cardModel, monitor: monitor)
            toy.cardModel.wingHint = true
            defer { NotchSurfaceRenderProofTests.clearTray(toy.cardModel) }
            for page in [NotchCardModel.Page.now, .shelf] {
                toy.cardModel.show(page)
                let card = NotchCardView(model: toy.cardModel, style: .island, width: 400, pinnedLayout: true, stillTurn: 1, stillReduced: true)
                    .padding(.top, 32)
                    .background(.black, in: NotchSilhouette(notchDepth: 32, restingRadius: 8))
                    .padding(.horizontal, 60).padding(.bottom, 24)
                try await U5Proof.render(card, name: page == .now ? "notch-now" : "notch-shelf", width: 520, dark: dark)
            }
            toy.cardModel.pinned = false
            toy.activeCapsule = nil
            try await U5Proof.render(NotchIslandView(toy: toy).frame(width: 300, height: 32).padding(24),
                                     name: "notch-closed", width: 520, dark: dark)
            let ask = try #require(toy.core.asks.first)
            toy.activeCapsule = AlcoveNotice(id: "proof-ask", kind: .ask, title: "Claude · Sample project",
                subtitle: "Run the tests?", provider: "claude", session: ask.session,
                key: "ask", ask: ask, takeover: true)
            try await U5Proof.render(NotchIslandView(toy: toy).frame(width: 400, height: 148).padding(24),
                                     name: "notch-ask", width: 520, dark: dark)
        }
    }

    @Test(.enabled(if: enabled))
    func groupedNotchStates() async throws {
        let ids = ["claude:root", "codex:worker", "factory:worker", "gemini:worker", "claude:worker", "codex:native", "factory:native"]
        let groupValue: JSONValue = .object(["id": .string("fixture-group"), "root_work_key": .string(ids[0]),
            "root_provider": .string("claude"), "members": .array(ids.map(JSONValue.string)), "lineage_evidence": .array([])])
        let group = try JSONDecoder().decode(CoreAgentGroup.self, from: JSONEncoder().encode(groupValue))
        let ask = CoreAsk(session: ids[1], openedAt: Self.stamp - 180, summary: "Run the checks?", answerable: true, request: "fixture")
        var sessions = ids.enumerated().map { index, id in
            CoreSession(id: id, provider: String(id.split(separator: ":")[0]), kind: index == 0 ? "main" : "worker",
                parent: index == 0 ? nil : ids[0], label: index == 0 ? "Sample project" : "Worker \(index)", mode: "working")
        }
        sessions[1].ask = ask
        sessions[2].lifecycle = "failed"
        sessions.append(CoreSession(id: "codex:unlinked", provider: "codex", label: "Unlinked", mode: "working", unlinkedWorker: true))
        for dark in [false, true] {
            let (toy, owner, _) = NotchSurfaceRenderProofTests.makeToy(state: CoreState(sessions: sessions, asks: [ask], agentGroups: [group]))
            defer { withExtendedLifetime(owner) {} }
            toy.cardModel.focus = ScreenBarFocus(style: ProviderStyle.style(for: "claude"), label: "Sample project", word: "Working", clickSession: nil, explanation: nil)
            toy.cardModel.rows = toy.islandSummary.rows
            #expect(toy.cardModel.rows.count == 3)
            #expect(toy.cardModel.rows.contains { $0.workerCount == 6 })
            for expanded in [false, true] {
                let card = NotchCardView(model: toy.cardModel, style: .island, width: 400, pinnedLayout: true, stillTurn: 1, stillReduced: true)
                    .padding(.top, 32).background(.black, in: NotchSilhouette(notchDepth: 32, restingRadius: 8))
                    .padding(24)
                try await U5Proof.render(card, name: expanded ? "notch-group-expanded" : "notch-group-collapsed", width: 500, dark: dark)
            }
        }
    }

    @Test(.enabled(if: enabled))
    func usageMatrix() async throws {
        let savedSelection = UserDefaults.standard.object(forKey: "usageCenter.provider")
        defer {
            if let savedSelection { UserDefaults.standard.set(savedSelection, forKey: "usageCenter.provider") }
            else { UserDefaults.standard.removeObject(forKey: "usageCenter.provider") }
        }
        for dark in [false, true] {
            let states = ["ready", "building", "stale", "failed", "disk_full", "damaged", "over_cap", "disabled", "empty", "no-quota", "scanning", "refreshing"]
            for state in states {
                var provider = CoreProviderUsage(id: "claude", windows: [
                    CoreUsageWindow(name: "5h", usedPct: 42, resetsAt: Self.stamp + 3600),
                    CoreUsageWindow(name: "7d", usedPct: 71, resetsAt: Self.stamp + 86400 * 2),
                ], fidelity: "official", state: "ready", readAt: Self.stamp - 120)
                provider.tokenHistoryState = state
                if state == "no-quota" { provider.windows = []; provider.quotaSource = false }
                let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-u5-proof.sock")
                core.handle(.connected)
                let settings = CoreSettings(document: .object(["token_history_enabled": .bool(state != "disabled"), "usage_graph_days": .number(30)]))
                core.apply(.settings(settings))
                core.apply(.state(CoreState(sessions: [CoreSession(id: "claude:fixture", provider: "claude", label: "Sample project", mode: "working")],
                    usage: CoreUsage(refreshedAt: Self.stamp, providers: [provider]))))
                let store = UsageCenterStore(core: core)
                store.now = Date(timeIntervalSince1970: Self.stamp)
                store.refreshing = state == "refreshing"
                var history = UsageHistory(provider: "claude", range: "30d", days: Self.days,
                    records: state == "empty" ? 0 : 30, partial: state == "scanning", stale: state == "stale")
                if state == "empty" { history.days = [] }
                let fixture = history
                store.readHistory = { _, _ in fixture }
                await store.load(provider: provider)?.value
                try await U5Proof.render(UsageProviderDetail(provider: provider, store: store, showCost: true).padding(24),
                                         name: "usage-" + state, width: 720, dark: dark)
                if state == "ready" {
                    var graph = CoreUsageGraph()
                    graph.days = 30
                    graph.labels = Self.days.map(\.date)
                    graph.periodLabel = "30 days"
                    graph.series = [CoreUsageGraph.Series(providerId: "claude", values: Self.days.map { Double($0.totalTokens) })]
                    store.overviewGraph = graph
                    store.sessionUsage.apply(SessionUsageDocument(sessions: ["claude:fixture": SessionUsage(contextTokens: 65000, contextWindow: 200000)]), asked: ["claude:fixture"])
                    for date in [Self.days.first?.day, Self.days.last?.day].compactMap({ $0 }) {
                        try await U5Proof.render(UsageTokenChart(history: history, range: .month, accent: .blue)
                            .proofSelection(date, cacheVisible: true).padding(24),
                            name: "usage-crosshair-" + (date == Self.days.first?.day ? "left" : "right"), width: 720, dark: dark)
                    }
                    try await U5Proof.render(UsageProviderDetail(provider: provider, store: store, showCost: false).padding(24),
                        name: "usage-cost-off", width: 720, dark: dark)
                    try await U5Proof.render(UsageOverviewTable(store: store, showCost: true, select: { _ in }).padding(24),
                                             name: "usage-overview", width: 850, dark: dark)
                    UserDefaults.standard.set("missing-fixture-provider", forKey: "usageCenter.provider")
                    try await U5Proof.render(UsageCenterView(store: store).frame(height: 720),
                                             name: "usage-window", width: 1000, dark: dark)
                    store.focus(provider: provider.identity)
                    try await U5Proof.render(UsageCenterView(store: store).frame(height: 720),
                                             name: "usage-window-provider", width: 1000, dark: dark)
                    #expect(store.focusProvider == nil)
                }
            }
        }
    }

    static var days: [UsageHistoryDay] {
        (1...30).map { index in
            UsageHistoryDay(date: "2026-10-\(String(format: "%02d", index))", tokensIn: (index % 5 + 1) * 10000,
                tokensOut: (index % 4 + 1) * 3000, cacheRead: index * 12000, costUsd: Double(index) / 4)
        }
    }

    @Test(.enabled(if: enabled))
    func fixStatesMatrix() async throws {
        let now = Date(timeIntervalSince1970: Self.stamp)
        for dark in [false, true] {
            for tokens in [0, 100] {
                let singleton = UsageHistory(provider: "claude", range: "7d", days: [UsageHistoryDay(date: "2026-10-25", tokensIn: tokens)])
                try await U5Proof.render(UsageTokenChart(history: singleton, range: .week, accent: .blue).padding(24),
                    name: "usage-singleton-\(tokens)", width: 720, dark: dark)
            }
            let history = UsageHistory(provider: "claude", range: "30d", days: Self.days, stale: true)
            try await U5Proof.render(UsageTokenChart(history: history, range: .month, accent: .blue)
                .proofSelection(Self.days[12].day, cacheVisible: true).padding(24),
                name: "usage-stale-series", width: 720, dark: dark)
            try await U5Proof.render(UsageTokenChart(history: history, range: .month, accent: .blue, metric: .cost)
                .padding(24), name: "usage-cost", width: 720, dark: dark)
            var graph = CoreUsageGraph()
            graph.labels = Self.days.map(\.date)
            graph.series = ["claude", "codex", "gemini"].enumerated().map { index, provider in
                .init(providerId: provider, values: Self.days.map { Double($0.totalTokens) / Double(index + 1) })
            }
            try await U5Proof.render(UsageOverviewChart(graph: graph, states: ["claude": "ready", "codex": "failed", "gemini": "disk_full"])
                .padding(24), name: "usage-overview-stale", width: 850, dark: dark)
            for mode in ["running", "paused", "done"] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let timers = ShelfTimerModel(storeURL: directory.appendingPathComponent("timers.json"), schedulingEnabled: false, clock: { now })
                let timer = timers.add(label: "Review the final presentation", duration: 125,
                    now: mode == "done" ? now.addingTimeInterval(-130) : now)
                if mode == "paused" { timers.pause(timer) }
                if mode == "done" { timers.sweep() }
                try await U5Proof.render(NotchTimerGlanceRow(timers: timers, style: .island, onOpenShelf: {}, stillDate: now)
                    .padding(16).background(.black), name: "notch-timer-" + mode, width: 400, dark: dark)
            }
            var provider = CoreProviderUsage(id: "claude", windows: [CoreUsageWindow(name: "5h", usedPct: 42)])
            provider.tokenHistoryState = "ready"
            let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-u5-unpriced.sock")
            core.handle(.connected)
            core.apply(.state(CoreState(usage: CoreUsage(providers: [provider]))))
            let store = UsageCenterStore(core: core)
            store.now = now
            store.overviewGraph = graph
            let unpriced = UsageHistory(provider: "claude", range: "7d", days: [UsageHistoryDay(date: "2026-10-25", tokensIn: 1000, cacheRead: 5000)])
            store.readHistory = { _, _ in unpriced }
            await store.load(provider: provider)?.value
            try await U5Proof.render(UsageOverviewTable(store: store, showCost: true, select: { _ in }).padding(24),
                name: "usage-overview-unpriced", width: 850, dark: dark)

            let risky = CoreAsk(session: "claude:risky", summary: "Delete the sample output?", answerable: true, request: "fixture", risk: "destructive")
            let riskyState = CoreState(sessions: [CoreSession(id: "claude:risky", provider: "claude", label: "Sample project", ask: risky)], asks: [risky])
            let (toy, owner, _) = NotchSurfaceRenderProofTests.makeToy(state: riskyState)
            defer { withExtendedLifetime(owner) {} }
            toy.activeCapsule = AlcoveNotice(id: "risky", kind: .ask, title: "Sample project", subtitle: "Delete the sample output?", provider: "claude",
                session: risky.session, key: "risky", ask: risky)
            #expect(toy.engageAskKeyboard())
            try await U5Proof.render(NotchIslandView(toy: toy).frame(width: 400, height: 148).padding(24),
                name: "notch-destructive-keyboard", width: 520, dark: dark)
            try await U5Proof.render(NotchBatteryGlyph(fraction: 0.7, tone: .green, plugged: true, style: .island)
                .padding(24).background(.black), name: "notch-battery-glyph", width: 200, dark: dark)

            let ask = CoreAsk(session: "claude:fixture", summary: "Review plan", detail: CoreAskDetail(plan: "Run the checks"))
            try await U5Proof.render(AskDetailToggle(ask: ask, labelled: true, size: 8.5, tint: .blue).padding(24),
                name: "notch-ask-detail", width: 300, dark: dark)
            try await U5Proof.render(WhatsNewView(entries: WhatsNewCatalog.entries, tryIt: { _ in nil }, onDone: {})
                .proofRefusal("Monitor not connected", entry: "mix"), name: "whats-new-refusal", width: WhatsNewView.width, dark: dark)
        }
    }

    @Test(.enabled(if: enabled))
    func smallMediaGlyphs() async throws {
        for dark in [false, true] {
            let (toy, owner, _) = NotchSurfaceRenderProofTests.makeToy(state: CoreState())
            defer { withExtendedLifetime(owner) {} }
            toy.reduceMotion = { true }
            var media = NotchSurfaceRenderProofTests.media()
            media.artworkData = nil
            toy.noteMedia(media)
            let layout = toy.idleLayout
            let width = 185 + 2 * layout.windowShoulder
            try await U5Proof.render(NotchIslandView(toy: toy).frame(width: width, height: 32).padding(24),
                name: "notch-media-glyph", width: 520, dark: dark)
        }
    }

    @Test(.enabled(if: enabled))
    func welcomeMatrix() async throws {
        for dark in [false, true] {
            var model = SetupModel()
            model.monitorLive = { true }
            model.usageOffers = { [SetupUsageOffer(id: "claude", name: "Claude", question: "Show Claude usage?",
                summary: "JR-Bar asks Anthropic for quota using Claude Code's sign-in.", isOn: false)] }
            model.agents = { [SetupAgent(id: "claude", name: "Claude", detected: true, hookStatus: "ok"),
                              SetupAgent(id: "codex", name: "Codex", detected: true, hookStatus: "missing"),
                              SetupAgent(id: "gemini", name: "Gemini", detected: false, hookStatus: nil)] }
            let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
            for step in SetupStore.Step.allCases {
                #expect(store.step == step)
                if step == .agents { await store.refreshUsageOffers() }
                try await U5Proof.render(SetupView(store: store), name: "setup-" + step.rawValue,
                                         width: SetupWindowController.contentSize.width, dark: dark)
                if step != .done { store.goNext() }
            }
            store.stopPermissionUpdates()
            try await U5Proof.render(ToastView(text: "New provider found: Gemini", action: ("Open Providers", {}), reduced: true).padding(24),
                name: "setup-new-provider", width: 500, dark: dark)
            try await U5Proof.render(WhatsNewView(entries: WhatsNewCatalog.entries, tryIt: { _ in nil }, onDone: {}),
                                     name: "whats-new", width: WhatsNewView.width, dark: dark)
        }
    }
}

@MainActor
enum U5Proof {
    private static var accentPinned = false

    static func pinDefaultAccent() throws {
        guard !accentPinned else { return }
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleAccentColor"] = 4
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let accentMethod = try #require(class_getClassMethod(NSColor.self, #selector(getter: NSColor.controlAccentColor)))
        let blueMethod = try #require(class_getClassMethod(NSColor.self, #selector(NSColor.u5ProofBlueAccent)))
        // Pin the test process before fixtures initialize semantic colours. No preferences are saved.
        method_exchangeImplementations(accentMethod, blueMethod)
        accentPinned = true
    }

    static func render<V: View>(_ view: V, name: String, width: CGFloat, dark: Bool, title: String? = nil) async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/jrbar-u5-proof")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try pinDefaultAccent()
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        NSApplication.shared.setActivationPolicy(.regular)
        let staged = view.tint(.blue).accentColor(.blue).environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .key).environment(\.renderSnapshot, true)
            .jrbarAccessibility(reduceMotion: true).frame(width: width)
            .fixedSize(horizontal: false, vertical: true).background(JRBarTokens.Ink.window)
        let hosting = NSHostingView(rootView: staged)
        hosting.appearance = appearance
        let window = U5ProofWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 100),
                                   styleMask: title == nil ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
        if let title { window.title = title }
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        defer { window.contentView = nil; window.close() }
        try WindowPresenter.renderProofKey(window)
        if !window.isKeyWindow { runUntilKey(window) }
        let initiallyKey = window.isKeyWindow
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        hosting.frame = NSRect(origin: .zero, size: size)
        settle(hosting, window: window)
        CATransaction.flush()
        #expect(window.isKeyWindow, "Render proof must be key: initially=\(initiallyKey), active=\(NSApp.isActive), visible=\(window.isVisible), policy=\(NSApp.activationPolicy().rawValue), processPolicy=\(NSRunningApplication.current.activationPolicy.rawValue), bundle=\(Bundle.main.bundleIdentifier ?? "none")")
        let capturedView = title == nil ? hosting : (hosting.superview ?? hosting)
        let bitmap = try #require(capturedView.bitmapImageRepForCachingDisplay(in: capturedView.bounds))
        capturedView.cacheDisplay(in: capturedView.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }

    private static func settle(_ hosting: NSView, window: NSWindow) {
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        }
    }

    private static func runUntilKey(_ window: NSWindow) {
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
            object: window, queue: nil) { _ in MainActor.assumeIsolated { NSApp.stop(nil) } }
        let loop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated { try? WindowPresenter.renderProofKey(window) }
        }
        let timeout = DispatchWorkItem { @Sendable in
            let mainLoop = CFRunLoopGetMain()
            CFRunLoopPerformBlock(mainLoop, CFRunLoopMode.defaultMode.rawValue) {
                MainActor.assumeIsolated {
                    NSApp.stop(nil)
                    if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                        NSApp.postEvent(wake, atStart: true)
                    }
                }
            }
            CFRunLoopWakeUp(mainLoop)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
        NSApp.run()
        timeout.cancel()
        NotificationCenter.default.removeObserver(observer)
    }
}

@MainActor
private final class U5ProofWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private extension NSColor {
    @objc class func u5ProofBlueAccent() -> NSColor { .systemBlue }
}
