import AppKit
import Foundation
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

@Suite("Panel render matrix", .serialized)
@MainActor
struct PanelRenderProofTests {
    private typealias Fixture = PanelCompositionTests

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func footerControlsAtBothWidthsAndAppearances() async throws {
        try U5Proof.pinDefaultAccent()
        for state in ["default", "quiet", "clearable", "undo"] {
            let sessions = state == "clearable" ? [Fixture.session("codex:done", provider: "codex", mode: "done")] : []
            let store = Fixture.store(sessions, usage: [Fixture.usage(), Fixture.usage("codex")])
            if state == "quiet" {
                store.core.apply(.state(CoreState(generation: 2, now: Fixture.time, aggregate: CoreAggregate(),
                    usage: CoreUsage(providers: [Fixture.usage(), Fixture.usage("codex")]),
                    focus: CoreFocus(mode: "pause", source: "override", until: Fixture.time + 1800))))
            }
            if state == "undo" {
                store.undoOffer = (batch: "sample-batch", at: store.now.addingTimeInterval(4 - EventPolicy.undoWindow), cleared: 2)
                #expect(store.undoCountdown == "0:04")
            }
            for width: CGFloat in [372, 320] {
                for dark in [false, true] {
                    let panel = PanelView(store: store, panelWidth: width).tint(.blue).accentColor(.blue)
                    try await render(panel, name: "footer-\(state)-\(Int(width))", width: width, dark: dark)
                }
            }
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func panelStatesAtBothWidthsAndAppearances() async throws {
        for state in ["groups", "expanded", "seven-members", "asks", "earlier", "idle", "source-idle",
                      "failure", "missing-recent", "not-found", "elapsed", "empty", "edit", "overflow", "disconnected", "reduced-motion", "short-screen", "find", "undo", "quiet-awake", "missing-root", "retry", "edit-accounts", "motion", "expanded-short-screen", "alerts"] {
            let store = try await fixture(state)
            for width: CGFloat in [PanelView.width, 320] {
                for dark in [false, true] {
                    try await render(PanelView(store: store, panelWidth: width),
                                     name: "panel-\(state)-\(Int(width))", width: width, dark: dark, reduced: store.reduceMotion)
                }
            }
            if state == "expanded-short-screen", let ask = store.visibleAskRows.first?.ask { AskExpansion.shared.collapse(ask) }
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func studioShortcutConflictAndOffSwitch() async throws {
        let suite = ScratchDefaults.suiteName("studio-shortcut-proof")
        defer { ScratchDefaults.remove(suite) }
        let store = SettingsStore(core: CoreModel(), shortcutDefaults: ScratchDefaults.open(suite))
        store.studioHotkeyRegistrationFailed = true
        let center = HotkeyCenter(registrar: HotkeyCenterTests.Recorder())
        for width: CGFloat in [PanelView.width, 320] {
            for dark in [false, true] {
                try await render(ShortcutsPage(store: store, center: center), name: "studio-shortcut-conflict-\(Int(width))", width: width, dark: dark)
            }
        }
    }

    private func fixture(_ name: String) async throws -> PanelStore {
        var root = Fixture.session("claude:root", group: "group", workers: 2)
        let workers = [Fixture.session("codex:child", provider: "codex", group: "group", worker: true),
                       Fixture.session("gemini:child", provider: "gemini", group: "group", worker: true),
                       Fixture.session("factory:child", provider: "factory", mode: "done", group: "group", worker: true)]
        let unlinked = Fixture.session("claude:unlinked", worker: true, unlinked: true)
        let finished = Fixture.session("codex:done", provider: "codex", mode: "done", since: Fixture.time - 300)
        let earlier = Fixture.session("gemini:earlier", provider: "gemini", mode: "done", since: Fixture.time - 700)
        let group = Fixture.group(([root] + workers).map(\.id))
        let store: PanelStore
        switch name {
        case "groups", "expanded", "earlier", "reduced-motion", "find", "undo", "motion":
            store = Fixture.store([root] + workers + [unlinked, finished, earlier], groups: [group],
                                  usage: [Fixture.usage(), Fixture.usage("codex")])
            if name == "expanded" { store.expandedAgentGroups.insert(root.id) }
            if name == "earlier" { store.earlierExpanded = true }
            if name == "find" { store.find(" sample ") }
            if name == "undo" { store.undoOffer = (batch: "sample-batch", at: store.now, cleared: 2) }
            if name == "motion" { store.reduceMotion = false; store.animationsArmed = true; store.expandedAgentGroups.insert(root.id) }
        case "seven-members":
            let six = (0..<6).map { index in
                Fixture.session("worker:\(index)", provider: ["codex", "claude", "factory"][index % 3], group: "group", worker: true)
            }
            root.workers = 6
            store = Fixture.store([root] + six, groups: [Fixture.group(([root] + six).map(\.id))], usage: [Fixture.usage()])
            store.expandedAgentGroups.insert(root.id)
        case "asks":
            let ask = CoreAsk(session: workers[0].id, kind: "permission", openedAt: Fixture.time - 60,
                              summary: "Run the sample tests?", answerable: true, request: "sample-request", preview: "make test")
            var asking = workers[0]
            asking.ask = ask
            asking.mode = "waiting"
            store = Fixture.store([root, asking] + Array(workers.dropFirst()), groups: [group], asks: [ask],
                                  usage: [Fixture.usage("codex")])
            store.expandedAgentGroups.insert(root.id)
        case "idle":
            store = Fixture.store([finished], usage: [Fixture.usage(), Fixture.usage("codex")])
        case "source-idle":
            store = Fixture.store([Fixture.session("claude:active")],
                                  usage: [Fixture.usage("antigravity", availability: "source_idle", action: "Open Antigravity to refresh", actionKind: "open_app")])
        case "failure":
            store = Fixture.store([Fixture.session("claude:active")],
                                  usage: [Fixture.usage("codex", availability: "failing", action: "Sign In…")])
        case "missing-recent":
            store = Fixture.store([Fixture.session("claude:active")], usage: [Fixture.usage("cursor", availability: "missing_recent")])
        case "not-found":
            store = Fixture.store([Fixture.session("claude:active")], usage: [Fixture.usage("kiro", availability: "not_found", action: "Hide", actionKind: "hide")])
        case "elapsed":
            store = Fixture.store([Fixture.session("claude:active")], usage: [Fixture.usage("gemini", elapsed: true)])
        case "empty":
            store = Fixture.store(usage: [Fixture.usage("grok", availability: "absent")])
        case "edit", "edit-accounts":
            store = Fixture.store([Fixture.session("claude:active")], usage: [Fixture.usage(), Fixture.usage("codex")])
            let fixtures = ProviderListStoreTests()
            store.providerList.readRows = {
                var account = try fixtures.row("claude")
                account.instance = "sample-work"
                account.label = "Claude Work"
                var rows = try [fixtures.row(), fixtures.row("codex"), fixtures.row("cursor", hidden: true), fixtures.row("kiro", enabled: false)]
                if name == "edit-accounts" { rows.insert(account, at: 1) }
                return rows
            }
            store.providerList.writePresentation = { fixtures.reply($0) }
            await store.providerList.refresh()
            try await store.providerList.setMenuBarVisible("cursor", false)
            store.editingProviders = true
        case "overflow":
            store = Fixture.store([Fixture.session("claude:active")],
                                  usage: ["claude", "codex", "gemini", "cursor", "antigravity", "grok"].map { Fixture.usage($0) })
        case "alerts":
            let selected = Fixture.session("claude:alerts-selected")
            let watched = Fixture.session("codex:alerts-watched", provider: "codex")
            let quiet = Fixture.session("claude:alerts-quiet", since: Fixture.time - 720)
            store = Fixture.store([selected, watched, quiet], usage: [Fixture.usage()])
            if let row = store.rows.first(where: { $0.id == watched.id }) { store.toggleDoneWatch(row) }
            store.selectedID = selected.id
            store.toast = nil
        case "quiet-awake":
            store = Fixture.store([root], usage: [Fixture.usage()])
            let power = try JSONDecoder().decode(CorePower.self, from: Data(#"{"keep_awake":true,"hold":{"state":"manual","lease":{"kind":"indefinite"}}}"#.utf8))
            store.core.apply(.state(CoreState(generation: 2, now: Fixture.time, aggregate: CoreAggregate(active: 1), sessions: [root], devices: WindowsRenderProofTests.devices,
                usage: CoreUsage(providers: [Fixture.usage()]), power: power, focus: CoreFocus(mode: "pause", source: "override", until: Fixture.time + 1800))))
            store.core.apply(.lights(CoreLights(surfaces: ["hardware": CoreLightSurface(program: LEDPreviewStripTests.sweep, ledCount: 8)])))
        case "missing-root":
            store = Fixture.store(workers, groups: [group], usage: [Fixture.usage()])
        case "retry":
            store = Fixture.store([root], usage: [Fixture.usage("codex", availability: "failing", action: "Retry later")])
        case "expanded-short-screen":
            let ask = CoreAsk(session: "claude:expanded-short-proof", summary: "Run the sample tests?", answerable: true,
                              request: "expanded-short-proof", preview: "make test", detail: CoreAskDetail(command: "make test"))
            store = Fixture.store(asks: [ask], usage: [Fixture.usage(), Fixture.usage("codex")])
            store.screenHeight = 600
            AskExpansion.shared.toggle(ask)
        case "short-screen":
            let asks = (0..<6).map { CoreAsk(session: "claude:ask:\($0)", summary: "Sample request", answerable: true, request: "request-\($0)") }
            let sessions = (0..<8).map { Fixture.session("codex:session:\($0)", provider: "codex") }
            let readings = ["claude", "codex", "gemini", "cursor", "antigravity", "grok"].map { Fixture.usage($0) }
            store = Fixture.store(sessions, asks: asks, usage: readings)
            store.screenHeight = 600
        default:
            store = Fixture.store(usage: [Fixture.usage()])
            store.core.handle(.disconnected(reason: "fixture"))
        }
        return store
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

    private func render<V: View>(_ view: V, name: String, width: CGFloat, dark: Bool, contrast: Bool = false, reduced: Bool = true) async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/jrbar-u2-proof")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let appearanceName: NSAppearance.Name = contrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua)
        let appearance = try #require(NSAppearance(named: appearanceName))
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let staged = view.environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .key)
            .jrbarAccessibility(reduceMotion: reduced)
            .frame(width: width).fixedSize(horizontal: false, vertical: true)
            .background(JRBarTokens.Ink.window)
        let hosting = NSHostingView(rootView: staged)
        hosting.appearance = appearance
        let window = PanelProofWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 100),
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
private final class PanelProofWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
