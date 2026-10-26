import AppKit
import JRBarCore
import QuartzCore
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Settings navigation release", .serialized)
struct SettingsNavigationReleaseTests {
    private final class WeakView {
        weak var value: NSView?
        init(_ value: NSView) { self.value = value }
    }

    private final class WeakObject {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }

    private struct Graph {
        let hosts: [WeakView]
        let storage: [WeakObject]
    }

    private func navigationStorage(in value: Any, depth: Int = 0,
                                   visited: inout Set<ObjectIdentifier>) -> [WeakObject] {
        guard depth < 8 else { return [] }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .class {
            let object = value as AnyObject
            guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            if String(reflecting: type(of: value)).contains("RevealInteractionContainerStorage") {
                return [WeakObject(object)]
            }
        }
        return mirror.children.flatMap { navigationStorage(in: $0.value, depth: depth + 1, visited: &visited) }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func graph(in window: NSWindow) -> Graph {
        let views = descendants(window.contentView!)
        let hosts = views.filter { String(reflecting: type(of: $0)).contains("NSHostingView") }.map(WeakView.init)
        var visited = Set<ObjectIdentifier>()
        let storage = views.flatMap { view in
            Mirror(reflecting: view).children
                .filter { $0.label == "revealInteractionBridge" }
                .flatMap { navigationStorage(in: $0.value, visited: &visited) }
        }
        return Graph(hosts: hosts, storage: storage)
    }

    @Test func nativeCloseReleasesRealSettingsHostingGraph() async throws {
        try await closeReleasesRealSettings(keyed: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func nativeKeyWindowReleasesRealSettingsHostingGraph() async throws {
        try await closeReleasesRealSettings(keyed: true)
    }

    private func closeReleasesRealSettings(keyed: Bool) async throws {
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        if keyed { app.setActivationPolicy(.regular) }
        defer { if keyed { app.setActivationPolicy(previousPolicy) } }
        let store = SettingsStore(core: CoreModel())
        store.page = .general
        store.launchAtLoginStatus = { false }
        let controller = SettingsWindowController(store: store)
        let origin: CGFloat = keyed ? -20000 : 0
        let window = NavigationProofWindow(contentRect: NSRect(x: origin, y: origin, width: 820, height: 620),
                                           styleMask: SettingsWindowController.windowStyle, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = controller
        defer { if window.contentViewController != nil { window.close() } }
        weak var root: NSViewController?
        autoreleasepool {
            let host = controller.attachSettingsContent(to: window)
            root = host
            host.view.layoutSubtreeIfNeeded()
            window.recalculateKeyViewLoop()
            if let sidebar = descendants(host.view).first(where: { $0 is NSTableView }) {
                window.makeFirstResponder(sidebar)
            }
        }
        await drainMainQueue()
        flushWindowUpdates()
        if keyed { try await renderOffscreen(window) }
        let captured = autoreleasepool { graph(in: window) }
        print("Current Settings: page=general, hosts=\(captured.hosts.count), legacyStorage=\(captured.storage.count), key=\(window.isKeyWindow)")
        #expect(captured.hosts.count > 1, "the real Settings split view builds navigation columns")
        autoreleasepool { window.close() }
        await drainMainQueue()
        flushWindowUpdates()
        #expect(root == nil)
        #expect(captured.hosts.allSatisfy { $0.value == nil },
                "surviving Settings hosts: \(captured.hosts.compactMap { $0.value }.map { String(reflecting: type(of: $0)) })")
        #expect(captured.storage.allSatisfy { $0.value == nil })
    }

    private struct LegacyGroupedForm: View {
        var body: some View {
            NavigationSplitView {
                List { Text("Synthetic sidebar") }
            } detail: {
                Form {
                    Section("Synthetic group") {
                        Toggle("Synthetic switch", isOn: .constant(false)).help("Synthetic switch help")
                        TextField("Synthetic field", text: .constant("Synthetic value")).help("Synthetic field help")
                    }
                }
                .formStyle(.grouped)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func legacyGroupedFormReleasesActualRevealStorageAfterNativeClose() async throws {
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        defer { app.setActivationPolicy(previousPolicy) }
        let window = NavigationProofWindow(contentRect: NSRect(x: -20000, y: -20000, width: 820, height: 620),
                                           styleMask: SettingsWindowController.windowStyle, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let delegate = NavigationCloseDelegate()
        window.delegate = delegate
        defer {
            if window.contentViewController != nil { window.close() }
            withExtendedLifetime(delegate) {}
        }
        weak var root: NSViewController?
        autoreleasepool {
            let attached = WindowContentLifecycle.attach(to: window, title: "Synthetic legacy form") {
                SettingsHostingController(rootView: AnyView(CheckedContent(content: LegacyGroupedForm())))
            }
            root = attached
            attached.view.layoutSubtreeIfNeeded()
            window.recalculateKeyViewLoop()
        }
        try await renderOffscreen(window)
        let captured = autoreleasepool { graph(in: window) }
        print("Legacy grouped Form: hosts=\(captured.hosts.count), actualRevealStorage=\(captured.storage.count), key=\(window.isKeyWindow)")
        #expect(captured.hosts.count > 1)
        #expect(!captured.storage.isEmpty, "the legacy fixture must create actual SwiftUI reveal storage")
        autoreleasepool { window.close() }
        await drainMainQueue()
        flushWindowUpdates()
        #expect(root == nil)
        #expect(captured.hosts.allSatisfy { $0.value == nil })
        #expect(captured.storage.allSatisfy { $0.value == nil })
    }

    private func renderOffscreen(_ window: NSWindow) async throws {
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        try WindowPresenter.renderProofKey(window)
        if !window.isKeyWindow { FoundationRenderProofTests.runUntilKey(window) }
        #expect(window.isKeyWindow, "the offscreen native proof must become key")
        autoreleasepool {
            let content = window.contentView!
            content.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
            }
        }
        await drainMainQueue()
        flushWindowUpdates()
    }

    private func flushWindowUpdates() {
        for _ in 0..<6 {
            autoreleasepool {
                CATransaction.flush()
                let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue,
                                                                  false, CFIndex.max) { _, _ in
                    CFRunLoopStop(CFRunLoopGetMain())
                }
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)
                CFRunLoopRunInMode(.defaultMode, 1, false)
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .defaultMode)
            }
        }
    }
}

@MainActor
private final class NavigationProofWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class NavigationCloseDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { WindowContentLifecycle.detach(from: window) }
    }
}
