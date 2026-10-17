import AppKit
import SwiftUI

@MainActor
struct NonblockingSheetWindow: NSViewRepresentable {
    @MainActor private final class Lease {
        let original: Bool
        var owners: Set<ObjectIdentifier> = []

        init(window: NSWindow) { original = window.preventsApplicationTerminationWhenModal }
    }

    // SwiftUI can attach a replacement view before detaching the previous one.
    private static let leases = NSMapTable<NSWindow, Lease>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    func makeNSView(context: Context) -> Anchor { Anchor(frame: .zero) }

    func updateNSView(_ view: Anchor, context: Context) { view.synchronizeWindow() }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.releaseWindow() }

    private static func acquire(_ window: NSWindow, owner: Anchor) {
        let lease = leases.object(forKey: window) ?? Lease(window: window)
        lease.owners.insert(ObjectIdentifier(owner))
        leases.setObject(lease, forKey: window)
        window.preventsApplicationTerminationWhenModal = false
    }

    private static func release(_ window: NSWindow, owner: Anchor) {
        guard let lease = leases.object(forKey: window) else { return }
        lease.owners.remove(ObjectIdentifier(owner))
        guard lease.owners.isEmpty else { return }
        if !window.preventsApplicationTerminationWhenModal {
            window.preventsApplicationTerminationWhenModal = lease.original
        }
        leases.removeObject(forKey: window)
    }

    final class Anchor: NSView {
        private weak var ownedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            synchronizeWindow()
        }

        func synchronizeWindow() {
            guard ownedWindow !== window else { return }
            releaseWindow()
            if let window {
                ownedWindow = window
                NonblockingSheetWindow.acquire(window, owner: self)
            }
        }

        func releaseWindow() {
            guard let ownedWindow else { return }
            self.ownedWindow = nil
            NonblockingSheetWindow.release(ownedWindow, owner: self)
        }
    }
}
