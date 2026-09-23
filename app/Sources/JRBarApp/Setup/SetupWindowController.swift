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
        // An accessory app is never frontmost on its own; the window
        // needs the app active to draw its controls as key. The same two
        // calls the Settings window uses.
        NSRunningApplication.current.activate()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
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

    var isVisible: Bool { window?.isVisible ?? false }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SetupView(store: store))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to JR-Bar"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(Self.contentSize)
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier("setup")
        // The floating glass card: the window's content IS the plate,
        // with the hosting view inside. The window supplies its own
        // rounding, so the plate's corner radius stays square to it.
        // `JRBAR_PLAIN_MATERIAL` swaps in a plain effect view, as the
        // other glass surfaces do.
        if ProcessInfo.processInfo.environment["JRBAR_PLAIN_MATERIAL"] == nil {
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: Self.contentSize))
            glass.style = .regular
            glass.cornerRadius = 0
            glass.contentView = hosting.view
            window.contentView = glass
        } else {
            let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.contentSize))
            effect.material = .windowBackground
            effect.blendingMode = .behindWindow
            effect.state = .active
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(hosting.view)
            NSLayoutConstraint.activate([
                hosting.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.view.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            window.contentView = effect
        }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        store.stopPermissionUpdates()
        // Back to a pure menu-bar process once the window goes away —
        // the same retraction the Settings window does.
        DispatchQueue.main.async {
            if NSApp.windows.allSatisfy({ !$0.isVisible || $0 is NSPanel }) {
                NSApp.hide(nil)
                NSApp.unhide(nil)
            }
        }
    }
}
