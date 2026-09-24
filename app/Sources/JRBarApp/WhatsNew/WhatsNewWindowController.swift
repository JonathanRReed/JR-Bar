import AppKit
import JRBarCore
import SwiftUI

/// The What's New window: a small glass card, a sibling of Setup's, that
/// lists what this release brings with a Try it for each thing a click
/// can show. It comes up on its own once per release (`arm(core:)`,
/// gated by `WhatsNewGate`), and on request from `jrbar://window/whats-new`,
/// the menus and the palette. Closing it by any route stamps the release
/// as seen.
@MainActor
final class WhatsNewWindowController: NSObject, NSWindowDelegate {
    /// Runs a Try it: the router, which does exactly what a link would.
    var run: @MainActor (AppCommand) -> AppCommandRouter.Outcome = { AppCommandRouter.shared.perform($0) }
    /// Stamps the release as seen (`setup.json`'s `whatsNewSeen`).
    var markSeen: @MainActor (_ release: String) -> Void = { _ in }

    private var window: NSWindow?
    /// The launch's one automatic showing is waiting for its moment.
    private(set) var isArmed = false
    private var armedCore: CoreModel?
    /// What wakes the wait: workspace and lock notifications.
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var settle: DispatchWorkItem?

    var isVisible: Bool { window?.isVisible ?? false }

    /// Opened by hand — a menu, a link, the palette: in front and key,
    /// like any window.
    func show() {
        disarm()
        let window = self.window ?? makeWindow()
        self.window = window
        attachContent(to: window)
        NSRunningApplication.current.activate()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// On its own: in front of whatever is up, without taking the app
    /// active. A click makes it key.
    private func present() {
        let window = self.window ?? makeWindow()
        self.window = window
        attachContent(to: window)
        window.center()
        window.orderFrontRegardless()
    }

    /// Internal for the tests: a Try it's refusal, or nil once it ran.
    func tryIt(_ command: AppCommand) -> String? {
        if case .refused(let why) = run(command) { return why }
        return nil
    }

    /// The card's SwiftUI graph lives only while the window is open
    /// (`WindowContentLifecycle`). Internal for the lifecycle test.
    @discardableResult
    func attachContent(to window: NSWindow) -> NSViewController {
        WindowContentLifecycle.attach(to: window, title: "What's New in JR-Bar") {
            let hosting = NSHostingController(rootView: WhatsNewView(
                entries: WhatsNewCatalog.entries,
                tryIt: { [weak self] command in self?.tryIt(command) },
                onDone: { [weak window] in window?.performClose(nil) }))
            hosting.sizingOptions = []
            return WindowContentLifecycle.glassPlate(around: hosting, size: Self.contentSize(of: hosting))
        }
    }

    /// The card is as tall as its rows: the view fixes its width and
    /// SwiftUI says the height it needs.
    static func contentSize(of hosting: NSHostingController<WhatsNewView>) -> NSSize {
        let fitting = hosting.sizeThatFits(in: NSSize(width: WhatsNewView.width, height: 2000))
        return NSSize(width: WhatsNewView.width, height: max(320, fitting.height.rounded(.up)))
    }

    private func makeWindow() -> NSWindow {
        let window = WhatsNewWindow(
            contentRect: NSRect(x: 0, y: 0, width: WhatsNewView.width, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        let content = attachContent(to: window)
        window.setContentSize(content.view.frame.size)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier("jrbar.whats-new")
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow { WindowContentLifecycle.detach(from: closing) }
        disarm()
        // Any route counts — Done, the close button, Esc, ⌘W: it was seen.
        markSeen(WhatsNewCatalog.releaseID)
        WindowContentLifecycle.retractWhenLastWindowCloses()
    }

    // MARK: The automatic showing

    /// Waits for the launch's moment (`WhatsNewGate.isRight`) and shows
    /// the window once. The delegate arms it only when the gate says
    /// this launch owes it. Every fact the moment depends on wakes the
    /// wait: the monitor going live, an unlock, a Space or app change.
    func arm(core: CoreModel) {
        guard !isArmed else { return }
        isArmed = true
        armedCore = core
        observeLive(core)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.momentMayHaveCome() }
            }
            observers.append((workspace, token))
        }
        let distributed = DistributedNotificationCenter.default()
        let unlocked = distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.momentMayHaveCome() }
        }
        observers.append((distributed, unlocked))
        momentMayHaveCome()
    }

    private func disarm() {
        isArmed = false
        armedCore = nil
        settle?.cancel()
        settle = nil
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []
    }

    private func observeLive(_ core: CoreModel) {
        withObservationTracking {
            _ = core.isLive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isArmed, let core = self.armedCore else { return }
                self.momentMayHaveCome()
                self.observeLive(core)
            }
        }
    }

    /// A moment that looks right is given a breath to settle — the first
    /// state lands, a Space finishes sliding — and looked at again
    /// before the window comes up.
    private func momentMayHaveCome() {
        guard isArmed, settle == nil, let core = armedCore,
              WhatsNewGate.isRight(Self.moment(core: core)) else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settle = nil
                guard self.isArmed, let core = self.armedCore else { return }
                guard WhatsNewGate.isRight(Self.moment(core: core)) else { return }
                self.disarm()
                self.present()
            }
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// The live facts: the core's connection, the session's lock flag,
    /// and whether the app in front fills the screen the window would
    /// open on.
    private static func moment(core: CoreModel) -> WhatsNewGate.Moment {
        var fullScreen = false
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           let screen = NSScreen.main {
            fullScreen = ScreenBarController.windowFillsScreen(pid: front.processIdentifier, screen: screen)
        }
        return WhatsNewGate.Moment(coreLive: core.isLive, locked: MenuBarStateRunner.screenIsLocked(),
                                   fullScreenInFront: fullScreen)
    }
}

/// Esc closes the card, as it does a sheet.
final class WhatsNewWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
