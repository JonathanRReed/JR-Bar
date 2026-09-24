import AppKit
import SwiftUI

/// The first-run Setup window: a small centred window whose whole
/// content is a Liquid Glass plate hosting the five-step walkthrough.
/// One per app (`shared`); the delegate wires `store`'s model to the
/// live core and presents it when `store.shouldPresentOnLaunch` says so —
/// and again any time Settings asks to run setup again.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    /// The one instance; `SetupWindowController.show()` presents it.
    static let shared = SetupWindowController()
    static let contentSize = NSSize(width: 560, height: 520)

    let store: SetupStore
    private var window: NSWindow?
    /// What waits for the walkthrough to go away (`afterClose`).
    private var afterCloseActions: [@MainActor () -> Void] = []

    init(store: SetupStore = SetupStore()) {
        self.store = store
        super.init()
        // Finish / Open Toys close the window through the store.
        store.onFinished = { [weak self] in self?.close() }
    }

    /// `SetupWindowController.show()` — the call site the launch gate and
    /// the Settings row share.
    static func show() { shared.show() }

    func show() {
        store.present()
        let window = self.window ?? makeWindow()
        self.window = window
        attachContent(to: window)
        WindowFront.bring(window)
    }

    /// Presents and lands on `step` — a lost grant opens on Permissions.
    func show(step: SetupStore.Step) {
        show()
        store.jump(to: step)
    }

    /// The launch-time look for lost grants: named once on the panel and
    /// in Notification Center, with Open Setup landing on Permissions.
    func reviewPermissionHealth(notices: LaunchNotices = .shared, log: @escaping (String) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let lost = await self.store.reviewPermissionHealth()
            guard let text = PermissionHealth.notice(for: lost) else { return }
            log("permissions lost: " + lost.map(\.rawValue).joined(separator: ", "))
            notices.say(.init(key: "permission-health", text: text, actionTitle: "Open Setup") { [weak self] in
                self?.show(step: .permissions)
            })
            notices.deliverBanner("permission-health",
                                  lost.count == 1 ? "JR-Bar lost a permission" : "JR-Bar lost \(lost.count) permissions",
                                  text + " Setup (Settings › General) grants \(lost.count == 1 ? "it" : "them") back.")
        }
    }

    func close() {
        window?.close()
    }

    /// Runs `action` once the walkthrough's window closes, finished or
    /// dismissed, or straight away when it isn't up: the first launch's
    /// panel waits here, so one surface asks for attention at a time.
    func afterClose(_ action: @escaping @MainActor () -> Void) {
        guard isVisible else { action(); return }
        afterCloseActions.append(action)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// The walkthrough's SwiftUI graph lives only while the window is
    /// open (`WindowContentLifecycle`); the step lives in the store.
    /// Internal for the lifecycle test.
    @discardableResult
    func attachContent(to window: NSWindow) -> NSViewController {
        WindowContentLifecycle.attach(to: window, title: "Welcome to JR-Bar") {
            WindowContentLifecycle.glassPlate(around: NSHostingController(rootView: SetupView(store: store)),
                                              size: Self.contentSize)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        attachContent(to: window)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(Self.contentSize)
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier("setup")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow { WindowContentLifecycle.detach(from: closing) }
        store.stopPermissionUpdates()
        WindowContentLifecycle.retractWhenLastWindowCloses()
        let waiting = afterCloseActions
        afterCloseActions = []
        // After the close has finished, like the retraction, so what
        // follows doesn't land under the closing window.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { for action in waiting { action() } }
        }
    }
}
