import AppKit
import SwiftUI

/// The tank's window (docs/TOYS.md): titled, resizable, remembers its
/// frame. "Fill screen" turns it borderless across the main screen
/// until Esc; closing it switches the toy off through the store.
@MainActor
final class AquariumWindowController: NSObject, NSWindowDelegate {
    /// The owning toy. The controller keeps it — the window's view
    /// needs it alive — and the cycle breaks when the window closes
    /// (`toy.windowDidClose` drops this controller).
    private let toy: AquariumToy
    private var window: AquariumWindow?
    private var escMonitor: Any?
    private var occlusionObserver: NSObjectProtocol?
    /// While filled, resigning active restores the window — a
    /// screenSaver-level tank would otherwise keep covering the display
    /// after a Cmd-Tab, with its Esc only listening locally.
    private var resignObserver: NSObjectProtocol?

    /// What Fill screen suspended, to put back on Esc.
    private var savedFrame: NSRect?
    private var savedLevel: NSWindow.Level = .normal
    private var savedMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    private(set) var filled = false

    init(toy: AquariumToy) {
        self.toy = toy
        super.init()
    }

    func show(activate: Bool) {
        let window = self.window ?? makeWindow()
        self.window = window
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
        noteOcclusion()
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> AquariumWindow {
        let window = AquariumWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Aquarium"
        window.contentView = NSHostingView(rootView: AquariumView(toy: toy))
        window.minSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("JRBarAquarium")
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteOcclusion() }
            }
        return window
    }

    private func noteOcclusion() {
        guard let window else { return }
        toy.windowOccluded = !window.occlusionState.contains(.visible)
    }

    // MARK: Fill screen

    /// Borderless across the window's own screen (the main screen only
    /// when the window hasn't landed on one yet); Esc puts it back.
    func fillScreen() {
        guard let window, !filled, let screen = window.screen ?? NSScreen.main else { return }
        savedFrame = window.frame
        savedLevel = window.level
        savedMask = window.styleMask
        filled = true
        window.styleMask = [.borderless]
        window.level = .screenSaver
        window.setFrame(screen.frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        installEscMonitor()
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                // The fill only lives while the app is active: a switch
                // away puts the tank back rather than trapping the
                // display under a window that can't take keys elsewhere.
                MainActor.assumeIsolated { self?.restoreScreen() }
            }
        noteOcclusion()
    }

    func restoreScreen() {
        guard let window, filled else { return }
        filled = false
        removeEscMonitor()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        window.styleMask = savedMask
        window.level = savedLevel
        if let savedFrame {
            window.setFrame(savedFrame, display: true)
            self.savedFrame = nil
        }
        window.makeKeyAndOrderFront(nil)
        noteOcclusion()
    }

    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        // The borderless window is keyable, so Esc reaches it like any
        // other key window's events.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.filled, event.window === self.window else { return event }
            if event.keyCode == 53 {
                self.restoreScreen()
                return nil
            }
            return event
        }
    }

    private func removeEscMonitor() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        removeEscMonitor()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        filled = false
        window = nil
        toy.windowDidClose()
    }
}

/// The tank's window. Borderless windows cannot normally take key;
/// this one must, or Esc would never arrive while it fills the screen.
private final class AquariumWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
