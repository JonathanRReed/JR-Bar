import AppKit
import SwiftUI

/// The tank's window (docs/TOYS.md): resizable, remembers its frame, the
/// water running edge to edge under a clear title bar with only the
/// traffic lights floating over it. "Fill screen" turns it borderless
/// across the main screen until Esc; closing it switches the toy off
/// through the store.
@MainActor
final class AquariumWindowController: NSObject, NSWindowDelegate {
    /// The owning toy. The controller keeps it — the window's view
    /// needs it alive — and the cycle breaks when the window closes
    /// (`toy.windowDidClose` drops this controller).
    private let toy: AquariumToy
    private var window: NSWindow?
    private let notificationCenter: NotificationCenter
    private let bringWindow: @MainActor (NSWindow) -> Void
    private let screenFrame: @MainActor (NSWindow) -> NSRect?
    private let visibleFrames: @MainActor () -> [NSRect]
    private var escMonitor: Any?
    private var occlusionObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    /// While filled, resigning active restores the window — a
    /// screenSaver-level tank would otherwise keep covering the display
    /// after a Cmd-Tab, with its Esc only listening locally.
    private var resignObserver: NSObjectProtocol?
    private var mainWindowObserver: NSObjectProtocol?

    /// What Fill screen suspended, to put back on Esc.
    private var savedFrame: NSRect?
    private var savedLevel: NSWindow.Level = .normal
    private var savedMask: NSWindow.StyleMask = AquariumWindowController.styleMask

    /// The window's own look: titled for its traffic lights and its
    /// resize edges, the content under the title bar.
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable,
                                                .fullSizeContentView]
    private(set) var filled = false

    init(toy: AquariumToy, window: NSWindow? = nil, notificationCenter: NotificationCenter = .default,
         bring: @escaping @MainActor (NSWindow) -> Void = { WindowFront.bring($0) },
         screenFrame: @escaping @MainActor (NSWindow) -> NSRect? = { ($0.screen ?? NSScreen.main)?.frame },
         visibleFrames: @escaping @MainActor () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) }) {
        self.toy = toy
        self.window = window
        self.notificationCenter = notificationCenter
        self.bringWindow = bring
        self.screenFrame = screenFrame
        self.visibleFrames = visibleFrames
        super.init()
        if let window { observeWindow(window) }
    }

    func show(activate: Bool) {
        let window = self.window ?? makeWindow()
        self.window = window
        // `jrbar://aquarium` from Terminal or a Quicklink arrives while
        // another app has the screen: the tank comes in front of it
        // (`WindowFront`). Left on at quit, it comes back at launch
        // without taking focus.
        if activate {
            bringWindow(window)
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
            styleMask: Self.styleMask,
            backing: .buffered,
            defer: false)
        window.title = "Aquarium"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The deep water, so a resize or the first frame never flashes
        // the system's grey.
        window.backgroundColor = NSColor(srgbRed: 0.02, green: 0.07, blue: 0.25, alpha: 1)
        window.contentView = NSHostingView(rootView: AquariumView(toy: toy))
        window.minSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("JRBarAquarium")
        observeWindow(window)
        return window
    }

    private func observeWindow(_ window: NSWindow) {
        window.delegate = self
        occlusionObserver = notificationCenter.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteOcclusion() }
            }
        screenObserver = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenParametersChanged() }
            }
    }

    private func screenParametersChanged() {
        guard filled, let window, let frame = screenFrame(window) else { return }
        window.setFrame(frame, display: true)
        noteOcclusion()
    }

    private func noteOcclusion() {
        guard let window else { return }
        toy.windowOccluded = !window.occlusionState.contains(.visible)
    }

    // MARK: Fill screen

    /// Borderless across the window's own screen (the main screen only
    /// when the window hasn't landed on one yet); Esc puts it back.
    func fillScreen() {
        guard let window, !filled, let frame = screenFrame(window) else { return }
        savedFrame = window.frame
        savedLevel = window.level
        savedMask = window.styleMask
        filled = true
        window.styleMask = [.borderless]
        window.level = .screenSaver
        window.setFrame(frame, display: true)
        installEscMonitor()
        resignObserver = notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                // The fill only lives while the app is active: a switch
                // away puts the tank back rather than trapping the
                // display under a window that can't take keys elsewhere.
                MainActor.assumeIsolated { self?.restoreScreen() }
            }
        mainWindowObserver = notificationCenter.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let other = note.object as? NSWindow else { return }
                let identity = ObjectIdentifier(other)
                MainActor.assumeIsolated {
                    guard let self, let window = self.window,
                          identity != ObjectIdentifier(window) else { return }
                    self.restoreScreen(keepFocus: false)
                }
            }
        bringWindow(window)
        noteOcclusion()
    }

    func restoreScreen(keepFocus: Bool = true) {
        guard let window, filled else { return }
        let restoreFocus = keepFocus && NSApp.isActive && window.isKeyWindow
        filled = false
        removeEscMonitor()
        removeFillObservers()
        window.styleMask = savedMask
        window.level = savedLevel
        if let savedFrame {
            let frame = Self.restoreFrame(savedFrame, visibleScreens: visibleFrames())
            window.setFrame(frame, display: true)
            self.savedFrame = nil
        }
        if restoreFocus { window.makeKeyAndOrderFront(nil) }
        noteOcclusion()
    }

    private func removeFillObservers() {
        if let resignObserver {
            notificationCenter.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        if let mainWindowObserver {
            notificationCenter.removeObserver(mainWindowObserver)
            self.mainWindowObserver = nil
        }
    }

    /// Keep the saved position while enough title bar remains usable to drag it.
    static func restoreFrame(_ frame: NSRect, visibleScreens: [NSRect]) -> NSRect {
        let titleHeight = min(28, frame.height)
        let titleBar = NSRect(x: frame.minX, y: frame.maxY - titleHeight,
                             width: frame.width, height: titleHeight)
        let draggableWidth = min(120, frame.width)
        guard !visibleScreens.contains(where: {
                  let visibleTitle = $0.intersection(titleBar)
                  return visibleTitle.width >= draggableWidth && visibleTitle.height >= titleHeight
              }),
              let screen = visibleScreens.min(by: {
                  hypot($0.midX - frame.midX, $0.midY - frame.midY)
                      < hypot($1.midX - frame.midX, $1.midY - frame.midY)
              }) else { return frame }
        let size = NSSize(width: min(frame.width, screen.width), height: min(frame.height, screen.height))
        return NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                      width: size.width, height: size.height)
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
        removeFillObservers()
        if let occlusionObserver {
            notificationCenter.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let screenObserver {
            notificationCenter.removeObserver(screenObserver)
            self.screenObserver = nil
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
