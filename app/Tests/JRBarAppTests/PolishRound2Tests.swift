import AppKit
@testable import JRBarCore
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite(.serialized)
struct PolishRound2Tests {
    nonisolated static let providerIDs = Array(Set(ProviderUsageRoadmap.entries.map(\.registeredProviderID) + SettingsKey.providers + ["kimi", "kilo", "openai-api", "t3code", "mystery"])).sorted()
    nonisolated static let windowNames = ["5h", "7d", "7d Fable", "Daily", "Credits", "Gemini Weekly", "Gemini 5-Pro (High)", "Claude + Fable (Thinking)", "Gemini 4 Argon"]

    static func provider(_ id: String, windows: [CoreUsageWindow] = [], availability: String) -> CoreProviderUsage {
        var provider = CoreProviderUsage(id: id, windows: windows)
        provider.availability = availability
        return provider
    }

    static func accessibilityValue(_ element: NSObject, _ key: String) -> Any? {
        let selector = NSSelectorFromString(key)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }

    static func elements(_ root: Any) -> [NSObject] {
        guard let element = root as? NSObject else { return [] }
        let children = accessibilityValue(element, "accessibilityChildren") as? [Any] ?? []
        return [element] + children.flatMap(elements)
    }

    static func buttonLabels(_ host: NSView) -> [String] {
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = application.accessibilityAttributeValue(attribute)
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        return elements(host).filter { accessibilityValue($0, "accessibilityRole") as? String == "AXButton" }
            .compactMap { accessibilityValue($0, "accessibilityLabel") as? String }
    }

    @Test("every catalogue provider keeps a visible identity and named button, including absent providers",
          arguments: providerIDs)
    func providerIdentity(_ id: String) throws {
        let name = ProviderPalette.displayName(for: id)
        for availability in ["absent", "ready", "not_found"] {
            let provider = Self.provider(id, availability: availability)
            let host = NSHostingView(rootView: UsageOverviewProviderRow(provider: provider, name: name, now: 0,
                connected: true, windowNames: [], columnWidth: 64, snapshotReceivedAt: nil, select: {})
                .frame(width: 360))
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height >= 36, "The identity occupies a row for \(id), \(availability)")
            let labels = Self.buttonLabels(host)
            #expect(labels.contains(name), "\(id), \(availability): \(labels)")
            if availability == "absent" {
                let renderer = ImageRenderer(content: host.rootView.background(Color.white).environment(\.colorScheme, .light))
                let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
                var inks = Set<Int>()
                for y in 12..<24 {
                    for x in 16..<28 {
                        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        inks.insert(Int((color.redComponent + color.greenComponent + color.blueComponent) * 100))
                    }
                }
                #expect(inks.count > 2, "\(id) draws a mark inside its tile, including fallback marks")
            }
        }
    }

    @Test("the longest quota window names fit their Overview columns")
    func fullWindowNames() {
        let width = UsageOverviewHeader.columnWidth(for: Self.windowNames)
        for name in Self.windowNames {
            let lines = UsageOverviewHeader.titleLines(for: name)
            #expect(lines.count <= 2)
            #expect(lines.joined(separator: " ") == name + " used")
            let host = NSHostingView(rootView: Text(lines.joined(separator: "\n")).font(JRBarTokens.TypeStyle.caption.font).fixedSize())
            #expect(host.fittingSize.width <= width)
        }
        #expect(UsageOverviewHeader.columnWidth(for: ["5h", "7d"]) == UsageGaugeRow.columnWidth)
        #expect(ScreenBarFullScreen.allCases.allSatisfy { $0.title.count <= 12 })
    }

    @Test("flattened toy groups expose controls without another expansion")
    func flatControls() {
        let host = NSHostingView(rootView: DisclosureGroup("Adjust") { Button("Amount") {} }
            .disclosureGroupStyle(SettingsDisclosureStyle(flattened: true)).frame(width: 360))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let labels = Self.buttonLabels(host)
        #expect(labels.contains("Amount"))
        #expect(!labels.contains("Adjust"))
    }

    @Test("switching providers starts at the header after scrolling Overview")
    func switchingProviderResetsScroll() async throws {
        let suite = "jrbar-polish-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("overview", forKey: "usageCenter.provider")
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-polish.sock")
        core.handle(.connected)
        let providers = Self.providerIDs.map { Self.provider($0, availability: "absent") }
        core.apply(.state(CoreState(usage: CoreUsage(providers: providers))))
        let store = UsageCenterStore(core: core)
        store.readProviderRows = { [] }
        let host = NSHostingView(rootView: UsageCenterView(store: store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 980, height: 720),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func settle() async {
            for _ in 0..<12 { host.layoutSubtreeIfNeeded(); await drainMainQueue() }
        }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        await settle()
        let overview = try #require(scrollViews(host).first { $0.bounds.width > 500 && $0.hasVerticalScroller })
        overview.contentView.scroll(to: NSPoint(x: 0, y: 400))
        overview.reflectScrolledClipView(overview.contentView)
        #expect(overview.contentView.bounds.minY >= 300)
        store.focus(provider: "codex")
        await settle()
        let detail = try #require(scrollViews(host).first { $0.bounds.width > 500 && $0.hasVerticalScroller })
        #expect(detail.contentView.bounds.minY <= 1)
        #expect(store.focusProvider == nil)
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func identityProofs() throws {
        for start in stride(from: 0, to: Self.providerIDs.count, by: 24) {
            let ids = Array(Self.providerIDs[start..<min(start + 24, Self.providerIDs.count)])
            try WindowsRenderProofTests.write("round2-provider-catalogue-\(start / 24)", size: CGSize(width: 520, height: 100)) {
                VStack(spacing: JRBarTokens.Space.xs) {
                    ForEach(ids, id: \.self) { id in
                        UsageOverviewProviderRow(provider: Self.provider(id, availability: "absent"),
                            name: ProviderPalette.displayName(for: id), now: 0, connected: true,
                            windowNames: [], columnWidth: 64, snapshotReceivedAt: nil, select: {})
                    }
                }.padding(JRBarTokens.Space.md)
            }
        }
        try WindowsRenderProofTests.write("round2-window-headers", size: CGSize(width: 600, height: 200)) {
            VStack(spacing: JRBarTokens.Space.md) {
                ForEach(Self.windowNames, id: \.self) { name in
                    UsageOverviewHeader(windowNames: [name]).frame(width: 320)
                }
            }.padding(JRBarTokens.Space.md)
        }
    }
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func overviewProofs() throws {
        let suite = "jrbar-overview-proof-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("overview", forKey: "usageCenter.provider")
        let ids = ["codex", "claude", "cursor", "devin", "grok", "gemini", "antigravity", "opencode", "factory", "openai-api", "kimi", "kilo", "kiro"]
        let providers = ids.enumerated().map { index, id in
            Self.provider(id, windows: [CoreUsageWindow(name: Self.windowNames[index % Self.windowNames.count], usedPct: 42)],
                              availability: ["cursor", "kiro"].contains(id) ? "absent" : "ready")
        }
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-overview-proof.sock")
        core.handle(.connected)
        core.apply(.state(CoreState(usage: CoreUsage(providers: providers))))
        let store = UsageCenterStore(core: core)
        try WindowsRenderProofTests.write("round2-overview", size: CGSize(width: 980, height: 720)) {
            UsageCenterView(store: store).defaultAppStorage(defaults)
        }
        try WindowsRenderProofTests.write("round2-overview-table", size: CGSize(width: 1500, height: 900)) {
            UsageOverviewTable(store: store, showCost: true, select: { _ in }).padding(JRBarTokens.Space.xl)
        }
    }

}

extension PolishRound2Tests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func normalUsageWindowProofs() async throws {
        let suite = "jrbar-normal-usage-proof-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ids = ["codex", "claude", "cursor", "devin", "grok", "gemini", "antigravity", "opencode", "factory", "openai-api", "kimi", "kilo", "kiro"]
        for dark in [false, true] {
            defaults.set("overview", forKey: "usageCenter.provider")
            let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-normal-usage-proof.sock")
            core.handle(.connected)
            let providers = ids.map { id in
                Self.provider(id, windows: id == "codex" ? [CoreUsageWindow(name: "5h", usedPct: 42)] : [],
                              availability: ["cursor", "kiro"].contains(id) ? "absent" : "ready")
            }
            core.apply(.state(CoreState(usage: CoreUsage(providers: providers))))
            let store = UsageCenterStore(core: core)
            store.readProviderRows = { [] }
            let size = NSSize(width: 980, height: 720)
            let window = PolishRound2ProofWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.toolbarStyle = .unified
            window.toolbar = NSToolbar(identifier: "round2-usage-proof")
            let controller = WindowContentLifecycle.attach(to: window, title: "Usage Center", subtitle: "JR-Bar") {
                WindowContentLifecycle.hosting(UsageCenterView(store: store).defaultAppStorage(defaults)
                    .environment(\.colorScheme, dark ? .dark : .light))
            }
            defer { WindowContentLifecycle.detach(from: window); window.close() }
            window.setContentSize(size)
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            try WindowPresenter.renderProofKey(window)
            let host = controller.view
            func settle() async {
                for _ in 0..<12 { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); await drainMainQueue() }
            }
            func capture(_ name: String) throws {
                let frame = try #require(window.contentView?.superview)
                let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: WindowsRenderProofTests.directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            await settle()
            #expect(window.isKeyWindow)
            try capture("round2-usage-normal")
            let scroll = try #require(scrollViews(host).first { $0.bounds.width > 500 && $0.hasVerticalScroller })
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
            scroll.reflectScrolledClipView(scroll.contentView)
            await settle()
            try capture("round2-switch-before")
            store.focus(provider: "codex")
            await settle()
            try capture("round2-switch-after")
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func focusRuleProofs() throws {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-focus-rule-proof.sock")
        core.handle(.connected)
        core.apply(.settings(CoreSettings(document: .object(["focus_dim_rules": .object([:]), "screen_bar_show_in_full_screen": .bool(true)]))))
        let store = SettingsStore(core: core)
        try WindowsRenderProofTests.write("round2-focus-rules", size: CGSize(width: 549, height: 260)) {
            SettingsGroup {
                FocusRuleRow(store: store, focusID: "do-not-disturb", name: "Do Not Disturb")
                FocusRuleRow(store: store, focusID: "work", name: "Work")
                FocusRuleRow(store: store, focusID: "personal", name: "Personal")
            }.padding(JRBarTokens.Space.xl).controlSize(.small)
        }
        try WindowsRenderProofTests.write("round2-screen-bar-settings", size: CGSize(width: 549, height: 400)) {
            ScreenBarSettingsCard(store: store, device: nil)
                .padding(JRBarTokens.Space.xl).controlSize(.small)
                .disclosureGroupStyle(SettingsDisclosureStyle())
        }
    }
}

extension PolishRound2Tests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func historyFixtureProofs() throws {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-history-polish-proof.sock")
        core.handle(.connected)
        let store = HistoryStore(core: core, schedulingEnabled: false)
        store.now = WindowsRenderProofTests.now
        store.loadedAt = store.now
        store.rows = WindowsRenderProofTests.historyRows(daysBack: 20)
        try WindowsRenderProofTests.write("round2-history", size: CGSize(width: 720, height: 560)) { HistoryView(store: store) }
        store.mode = .events
        store.replay.events = [
            CoreEvent(id: "fixture-1", kind: "session_started", session: "claude:fixture", label: "Sample task", at: store.now.timeIntervalSince1970 - 30),
            CoreEvent(id: "fixture-2", kind: "session_completed", session: "claude:fixture", label: "Sample task", at: store.now.timeIntervalSince1970),
        ]
        try WindowsRenderProofTests.write("round2-history-events", size: CGSize(width: 720, height: 560)) { HistoryView(store: store) }
    }
}

@MainActor
private final class PolishRound2ProofWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
