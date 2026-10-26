import AppKit
import JRBarCore
import QuartzCore
import SwiftUI
import Testing
@testable import JRBarUI
@testable import JRBarApp

@Suite("UI foundation render proofs", .serialized)
@MainActor
struct FoundationRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"
    let now = 1_767_272_400.0
    let locale = Locale(identifier: "en_US")
    let zone = TimeZone(secondsFromGMT: 0)!

    private func usage(_ id: String = "claude", values: [Double?] = [42, 18], names: [String] = ["5h", "7d"],
                       availability: String? = nil, status: String? = nil, age: Double? = nil,
                       action: String? = nil, quotaSource: Bool = true, off: Bool = false) -> CoreProviderUsage {
        let windows = zip(names, values).enumerated().map { index, pair in
            CoreUsageWindow(name: pair.0, usedPct: pair.1, resetsAt: now + (index == 0 ? 2520 : 86400))
        }
        var row = CoreProviderUsage(id: id, windows: windows, state: age == nil ? "ready" : "stale",
                                    action: action, reason: off ? CoreProviderUsage.usageOffReason : nil, quotaSource: quotaSource)
        row.availability = availability
        row.statusText = status
        row.lastGoodAgeSeconds = age
        return row
    }

    private func row(_ provider: CoreProviderUsage, name: String? = nil, connected: Bool = true,
                     columns: [String]? = nil, style: UsageGaugeRow.Style = .compact) -> some View {
        UsageGaugeRow(provider: provider, name: name ?? ProviderPalette.displayName(for: provider.id), now: now,
                      connected: connected, style: style, windowNames: columns, snapshotReceivedAt: now,
                      locale: locale, timeZone: zone, pace: ["5h": 52, "7d": 38, "7d Opus": 60, "Monthly": 72],
                      onAction: provider.action == nil ? nil : {}, onRetry: provider.availability == "failing" ? {} : nil)
    }

    @Test(.enabled(if: enabled)) func usageAtPanelAndDrawerWidths() async throws {
        for dark in [false, true] {
            for width in [280.0, 320.0] {
                let view = VStack(spacing: 2) {
                    UsageGaugeHeader(windowNames: ["7d", "5h"])
                    row(usage())
                    row(usage("codex", values: [99.6], names: ["5h"]), name: "Codex · Team workspace", columns: ["5h", "7d"])
                    row(usage("gemini", values: [0, 100]), columns: ["5h", "7d"])
                    row(usage("cursor", values: [142, nil]), columns: ["5h", "7d"])
                    row(usage("antigravity", availability: "missing_recent", status: "Open Antigravity to refresh", age: 2460, action: "Open Antigravity"))
                    row(usage(availability: "failing", status: "Your authentication token expired while reading the account quota", age: 10800, action: "Reconnect Claude"))
                    row(usage("codex", availability: "source_idle", status: "Waiting for a recent session", age: 259200))
                    row(usage(age: 59))
                    row(usage(), connected: false)
                    row(usage("pi", quotaSource: false))
                    row(usage("grok", values: [], names: []))
                    row(usage("kiro", availability: "not_found", status: "Not found on this Mac"))
                    row(usage("codex", status: "Usage is off", action: "Turn on usage", off: true))
                    row(expired())
                    row(sameDayReset())
                    row(usage(values: [42], names: ["5h"]))
                    row(usage(values: [42, 12, 8, 70], names: ["5h", "7d", "7d Opus", "Monthly"]))
                }
                try await render(view, name: "usage-\(Int(width))", width: width, dark: dark)
            }
            let detail = VStack(spacing: 8) {
                row(usage("codex", values: [42, 99.6, 18], names: ["5h", "7d Opus", "Monthly"]), name: "Codex · Team workspace", style: .detail)
                row(usage(age: 10800), style: .detail)
                row(expired(), style: .detail)
                row(usage(values: [nil], names: ["Monthly"]), style: .detail)
            }
            try await render(detail, name: "detail-cells", width: 600, dark: dark)
            let cells = VStack(spacing: 12) {
                row(usage(values: [42], names: ["5h"]), style: .detail)
                row(usage(values: [99.6], names: ["7d Opus"]), style: .detail)
                row(expired(), style: .detail)
            }
            try await render(cells, name: "detail-cell-260", width: 260, dark: dark)
        }
    }

    private func sameDayReset() -> CoreProviderUsage {
        var provider = usage(values: [42], names: ["5h"])
        provider.windows[0].resetsAt = now + 6000
        return provider
    }

    private func expired() -> CoreProviderUsage {
        var provider = usage(values: [nil, 88])
        provider.windows[0].resetsAt = now - 120
        return provider
    }

    @Test(.enabled(if: enabled)) func providerTilesOnEverySurface() async throws {
        let providers = ProviderPalette.hexes.keys.sorted() + ["unknown"]
        for dark in [false, true] {
            for surface in ["normal", "dim", "black", "override", "glass"] {
                let sheet = VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(surface); Spacer(); Text("16 / 20 / 28 / 40") }
                    ForEach(providers, id: \.self) { provider in
                        HStack(spacing: 16) {
                            Text(ProviderPalette.displayName(for: provider)).frame(width: 100, alignment: .leading)
                            ForEach([16, 20, 28, 40], id: \.self) { size in
                                ProviderLogoTile(provider: provider, size: CGFloat(size),
                                                 accent: surface == "override" ? .purple : nil,
                                                 dim: surface == "dim", surface: surface == "black" ? .black : surface == "glass" ? (dark ? .darkGlass : .lightGlass) : nil)
                                    .frame(width: 44, height: 44)
                            }
                        }
                    }
                }
                .font(JRBarTokens.TypeStyle.caption.font)
                .foregroundStyle(surface == "black" ? .white : JRBarTokens.Ink.label)
                .padding(12)
                .background {
                    if surface == "black" { Color.black }
                    else if surface == "glass" { Rectangle().fill(.regularMaterial) }
                    else { JRBarTokens.Ink.content }
                }
                try await render(sheet, name: "logos-\(surface)", width: 376, dark: dark)
            }
        }
    }

    @Test(.enabled(if: enabled)) func bannersSettingsAndGroups() async throws {
        for dark in [false, true] {
            for width in [280.0, 320.0] {
                try await render(components, name: "components-\(Int(width))", width: width, dark: dark)
            }
            try await render(components.tint(.orange), name: "accent-override", width: 320, dark: dark)
            try await render(interactionRows, name: "hover-focus", width: 320, dark: dark)
            try await render(components.jrbarAccessibility(increaseContrast: true), name: "increase-contrast", width: 320, dark: dark, contrast: true)
            try await render(components.jrbarAccessibility(reduceMotion: true, reduceTransparency: true),
                             name: "reduce-transparency-motion", width: 320, dark: dark)
        }
    }


    private var interactionRows: some View {
        let hovered = AgentGroupRow(provider: "claude", name: "Claude", workerCount: 3, expanded: .constant(false)) { EmptyView() }.proofInteraction(hovered: true)
        let focused = AgentGroupRow(provider: "codex", name: "Codex", workerCount: 1, expanded: .constant(false)) { EmptyView() }.proofInteraction(focused: true)
        return VStack(spacing: 8) { hovered; focused }.padding(8)
    }

    private var components: some View {
        VStack(spacing: 12) {
            StatusBanner("Quota could not refresh", kind: .failure,
                         detail: "Your last reading stays visible until the source reconnects.") { Button("Retry") {} }
            StatusBanner("Usage is off", detail: "Turn it on to read account quotas.")
            StatusBanner("Claude needs you", kind: .attention) { Button("Open") {} }
            SettingsGroup {
                SettingsRow("Track Claude") { Toggle("Track Claude", isOn: .constant(true)).labelsHidden().toggleStyle(.switch) }
                SettingsRow("Read usage", subtitle: "Account quota and reset times") { Toggle("Read usage", isOn: .constant(false)).labelsHidden().toggleStyle(.switch) }
                SettingsRow("Show in menu bar") { Toggle("Show in menu bar", isOn: .constant(true)).labelsHidden().toggleStyle(.switch).disabled(true) }
                SettingsNavigationRow("Provider accounts", subtitle: "Claude, Codex and Gemini") {}
            }
            HStack(spacing: 16) { ForEach(StateDot.State.allCases, id: \.self) { StateDot($0) } }
            AgentGroupRow(provider: "claude", name: "Claude", project: "A very long project name for layout verification",
                          subtitle: "Reviewing the account settings", elapsed: "2:41", state: .working,
                          workerCount: 3, expanded: .constant(false)) { EmptyView() }
            AgentGroupRow(provider: "codex", name: "Codex", project: "Sample workspace", subtitle: "Building the shared components",
                          elapsed: "4:02", state: .asking, memberMarks: ["claude", "gemini", "codex"],
                          workerCount: 3, expanded: .constant(true)) {
                AgentMemberRow(provider: "claude", name: "Claude", role: "Reviewer", elapsed: "1:10", state: .done)
                AgentMemberRow(provider: "gemini", name: "Gemini", role: "Search", state: .working)
                AgentMemberRow(provider: "codex", name: "Codex", role: "Tests", state: .failed, isLast: true)
            }
            AgentGroupRow(provider: "gemini", name: "Gemini", workerCount: 1, expanded: .constant(false)) { EmptyView() }
            AgentGroupRow(provider: "codex", name: "Codex", workerCount: 1, unlinked: true, expanded: .constant(false)) { EmptyView() }
        }
        .padding(8)
    }

    private func runUntilKey(_ window: NSWindow) {
        // Swift Testing runs tasks without NSApplication's event loop. AppKit
        // completes the key-window request only while that loop is running.
        let notification = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil
        ) { _ in MainActor.assumeIsolated { NSApp.stop(nil) } }
        let loop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated { try? WindowPresenter.renderProofKey(window) }
        }
        let timeout = DispatchWorkItem { @Sendable in
            let mainLoop = CFRunLoopGetMain()
            CFRunLoopPerformBlock(mainLoop, CFRunLoopMode.defaultMode.rawValue) {
                MainActor.assumeIsolated {
                    NSApp.stop(nil)
                    // An application-defined wake-up carries no mouse or keyboard input.
                    let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                        subtype: 0, data1: 0, data2: 0)
                    if let wake { NSApp.postEvent(wake, atStart: true) }
                }
            }
            CFRunLoopWakeUp(mainLoop)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
        NSApp.run()
        timeout.cancel()
        NotificationCenter.default.removeObserver(notification)
    }

    private func render<V: View>(_ view: V, name: String, width: CGFloat, dark: Bool, contrast: Bool = false) async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/jrbar-u1-proof")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let appearanceName: NSAppearance.Name = contrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua)
        let appearance = try #require(NSAppearance(named: appearanceName))
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let staged = view.environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .key)
            .jrbarAccessibility(reduceMotion: true)
            .frame(width: width).fixedSize(horizontal: false, vertical: true)
            .background(JRBarTokens.Ink.window)
        let hosting = NSHostingView(rootView: staged)
        hosting.appearance = appearance
        let window = FoundationProofWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 100),
                                           styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        try WindowPresenter.renderProofKey(window)
        defer { window.close() }
        if !window.isKeyWindow { runUntilKey(window) }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        #expect(abs(size.width - width) < 1)
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        await Task.yield()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        #expect(window.isKeyWindow, "Accent proof must be a key window")
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
}

@MainActor
private final class FoundationProofWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
