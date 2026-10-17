import AppKit
import JRBarCore
import OSLog
import SwiftUI

/// The full-bar underlay `MenuBarSettings` drives beyond the boundary.
///
/// JR-Bar has exactly one status item, the icon (`StatusItemController`).
/// Nothing here creates another, and nothing here writes a Control Center
/// preference.

/// A tint sheet drawn under the whole menu bar row — Ice's "menu bar
/// appearance" — one panel per screen, below the items so the bar's
/// translucency shows it through. The bar backdrop is opaque on some
/// macOS builds; there the panels simply read as nothing, which is
/// the honest failure.
@MainActor
final class MenuBarUnderlay {
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var observers: [NSObjectProtocol] = []
    private var appearance = MenuBarCoverAppearance()

    /// Show or restyle the sheets. Called from `syncExtras` — a
    /// settings change lands on the next reconcile.
    func show(appearance: MenuBarCoverAppearance) {
        self.appearance = appearance
        var live: Set<CGDirectDisplayID> = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.uint32Value
            live.insert(id)
            let depth = max(NSStatusBar.system.thickness,
                            ScreenBarGeometry.notchDepth(of: screen))
            let frame = NSRect(x: screen.frame.minX,
                               y: screen.frame.maxY - depth,
                               width: screen.frame.width, height: depth)
            let panel = panels[id] ?? makePanel(id: id)
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            (panel.contentView as? MenuBarCoverView)?.apply(
                MenuBarCoverAppearance(material: appearance.material,
                                       tintHex: appearance.tintHex,
                                       tintOpacity: appearance.tintOpacity,
                                       roundness: 0, separator: false))
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        for (id, panel) in panels where !live.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
        if observers.isEmpty {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.show(appearance: self.appearance)
                }
            })
        }
    }

    func hide() {
        for (_, panel) in panels { panel.orderOut(nil) }
        panels = [:]
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    isolated deinit { hide() }

    private func makePanel(id: CGDirectDisplayID) -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // Below the items — the bar's own translucency carries the
        // tint through. One level under `statusBar` keeps it clear of
        // every status item window without touching the desktop.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]
        if ProcessInfo.processInfo.environment["JRBAR_CAPTURE_CARD"] == nil {
            panel.sharingType = .none
        }
        let view = MenuBarCoverView()
        panel.contentView = view
        panel.title = "JR-Bar Menu Bar Underlay \(id)"
        panels[id] = panel
        return panel
    }
}
