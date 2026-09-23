import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import JRBarCore
import SwiftUI

/// The tank outside its window (docs/TOYS.md), in two opt-in forms:
///
/// - **Live wallpaper** — on a chosen display the tank sits just above
///   the desktop, behind every window and click-through, and stays up
///   when you switch apps. What SereneScreen is bought for, and what
///   Tiny Aquarium's desktop mode never managed on macOS.
/// - **Screensaver** — after N idle minutes the tank fills every free
///   screen until the next touch. The display often stays lit through
///   long agent runs (keep-display-awake), so the lit screen can show
///   the actual fleet working. Idle time is read, never faked: no
///   synthetic input, no permission.
@MainActor
final class AquariumAmbientController {
    private weak var toy: AquariumToy?
    private var wallpaper: AquariumAmbientPanel?
    private var wallpaperName: String?
    private var savers: [AquariumAmbientPanel] = []
    /// When the screensaver went up — any input after this puts it away.
    private var shownAt: Date?
    /// Armed once the idle clock has been seen under the threshold: a
    /// real touch since the last showing. A saver put away by a lock or
    /// a sleeping display stays away until someone is back, instead of
    /// popping up again five seconds later over the same idle stretch.
    private var armed = false
    private var idleTimer: Timer?
    private var watchTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    init(toy: AquariumToy) {
        self.toy = toy
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismissSaver()
                self?.sync()
            }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissSaver() }
            })
        }
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: FoldSessionState.lockedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissSaver() }
        })
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        idleTimer?.invalidate()
        watchTimer?.invalidate()
    }

    private var settings: AquariumSettings { toy?.store?.state.aquarium ?? AquariumSettings() }

    /// Makes the panels and the idle poll match the settings.
    func sync() {
        syncWallpaper()
        if settings.idleFillMinutes > 0 {
            if idleTimer == nil {
                // A slow look at the idle clock: minutes matter, not
                // seconds, and the read is one call.
                let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkIdle() }
                }
                RunLoop.main.add(timer, forMode: .common)
                idleTimer = timer
            }
        } else {
            idleTimer?.invalidate()
            idleTimer = nil
            dismissSaver()
        }
    }

    // MARK: Live wallpaper

    private func syncWallpaper() {
        let name = settings.ambientDisplay
        guard let toy, let name,
              let screen = NSScreen.screens.first(where: { $0.localizedName == name }) else {
            wallpaper?.orderOut(nil)
            wallpaper = nil
            wallpaperName = nil
            return
        }
        if let wallpaper, wallpaperName == name {
            wallpaper.setFrame(screen.frame, display: true)
            return
        }
        wallpaper?.orderOut(nil)
        let panel = AquariumAmbientPanel(screen: screen, toy: toy, mode: .wallpaper)
        panel.orderFrontRegardless()
        wallpaper = panel
        wallpaperName = name
    }

    // MARK: Screensaver

    /// Seconds since the last real input of any kind, session-wide.
    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                eventType: CGEventType(rawValue: ~0)!)
    }

    private func checkIdle() {
        guard savers.isEmpty, let toy else { return }
        let minutes = settings.idleFillMinutes
        let idle = Self.idleSeconds()
        guard AquariumScreensaver.isIdle(idleSeconds: idle, minutes: minutes) else {
            armed = true
            return
        }
        guard armed else { return }
        // The idle clock says yes; only now pay for the window list and
        // the power assertions.
        let screens = ConfettiToy.screensWithoutFullscreenApps().compactMap { $0 }
        let ok = AquariumScreensaver.shouldShow(
            idleSeconds: idle, minutes: minutes,
            locked: FoldSessionState.current().locked,
            someoneWatching: AquariumScreensaver.someoneIsWatching(),
            freeScreens: screens.count)
        guard ok else { return }
        // The live-wallpaper display keeps its wallpaper; every other
        // free screen gets the tank.
        savers = screens.filter { $0.localizedName != wallpaperName }.map {
            let panel = AquariumAmbientPanel(screen: $0, toy: toy, mode: .screensaver)
            panel.onTouch = { [weak self] in self?.dismissSaver() }
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.animator().alphaValue = 1
            return panel
        }
        guard !savers.isEmpty else { return }
        armed = false
        shownAt = Date()
        let watch = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchForInput() }
        }
        RunLoop.main.add(watch, forMode: .common)
        watchTimer = watch
    }

    /// Up: any key, click or move since it showed puts it away. The idle
    /// clock resets on input we never see — that is the whole trick.
    private func watchForInput() {
        guard let shownAt else { return }
        if AquariumScreensaver.inputSinceShowing(idleSeconds: Self.idleSeconds(),
                                                 shownFor: Date().timeIntervalSince(shownAt)) {
            dismissSaver()
        }
    }

    func dismissSaver() {
        watchTimer?.invalidate()
        watchTimer = nil
        shownAt = nil
        for panel in savers { panel.orderOut(nil) }
        savers = []
    }

    /// Everything down — the toy's owner is going away.
    func tearDown() {
        dismissSaver()
        idleTimer?.invalidate()
        idleTimer = nil
        wallpaper?.orderOut(nil)
        wallpaper = nil
        wallpaperName = nil
    }
}

/// The screensaver's rules, pure so they can be pinned.
enum AquariumScreensaver {
    /// The idle clock alone: at or past the chosen minutes. Cheap, so it
    /// runs every poll; the room is only read once this says yes.
    static func isIdle(idleSeconds: Double, minutes: Int) -> Bool {
        minutes > 0 && idleSeconds.isFinite && idleSeconds >= Double(minutes) * 60
    }

    /// Only the screensaver's own switch, the idle clock and the room
    /// decide: never over a lock screen, never while someone else holds
    /// the display awake to watch something, never on a screen a
    /// fullscreen app owns.
    static func shouldShow(idleSeconds: Double, minutes: Int, locked: Bool,
                           someoneWatching: Bool, freeScreens: Int) -> Bool {
        isIdle(idleSeconds: idleSeconds, minutes: minutes)
            && !locked && !someoneWatching && freeScreens > 0
    }

    /// The idle clock ran on from when the tank went up unless something
    /// touched the Mac: an idle time shorter than the time it's been up
    /// means input landed since. A quarter second of slack covers the
    /// poll's own timing.
    static func inputSinceShowing(idleSeconds: Double, shownFor: Double) -> Bool {
        idleSeconds + 0.25 < shownFor
    }

    /// One power assertion as the system lists it.
    struct Assertion: Equatable {
        var pid: Int32
        var process: String
        var type: String
    }

    /// Someone is watching something: another process holds the display
    /// awake on purpose (a video, a call, a presentation). `caffeinate`
    /// is not watching — it's JR-Bar's own keep-awake, the very reason
    /// the display is lit — and neither are we.
    static func isWatching(_ assertions: [Assertion], ownPID: Int32) -> Bool {
        assertions.contains {
            $0.pid != ownPID && $0.type == "PreventUserIdleDisplaySleep"
                && $0.process.lowercased() != "caffeinate"
        }
    }

    /// The live read of the system's assertions.
    static func someoneIsWatching() -> Bool {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byProcess = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return false }
        var list: [Assertion] = []
        for (pid, assertions) in byProcess {
            for assertion in assertions {
                list.append(Assertion(
                    pid: pid.int32Value,
                    process: assertion["Process Name"] as? String ?? "",
                    type: assertion[kIOPMAssertionTypeKey as String] as? String ?? ""))
            }
        }
        return isWatching(list, ownPID: ProcessInfo.processInfo.processIdentifier)
    }
}

/// The live wallpaper's picker, pure so it can be pinned.
enum AquariumWallpaper {
    /// Each connected display once — two of the same monitor share a
    /// name, and the picker's rows need distinct tags — plus the saved
    /// one while it's unplugged, so the picker never shows a blank
    /// selection and replugging brings the tank straight back.
    static func displayChoices(connected: [String], saved: String?) -> [String] {
        var seen = Set<String>()
        var names = connected.filter { seen.insert($0).inserted }
        if let saved, !seen.contains(saved) { names.append(saved) }
        return names
    }
}

/// The tank as scenery, plus the screensaver's quiet clock — the
/// SereneScreen touch: a lit screen you can still read the time off.
struct AquariumSceneryView: View {
    let toy: AquariumToy
    /// Screensaver panels may wear the clock; the wallpaper never does.
    let clock: Bool

    /// A screensaver panel, with the card's clock switch on.
    static func wearsClock(panel clock: Bool, settings: AquariumSettings?) -> Bool {
        clock && (settings?.saverClock ?? true)
    }

    var body: some View {
        AquariumView(toy: toy, ambient: true)
            .overlay(alignment: .bottomLeading) {
                if Self.wearsClock(panel: clock, settings: toy.store?.state.aquarium) {
                    TimelineView(.everyMinute) { context in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.date, format: .dateTime.hour().minute())
                                .font(.system(size: 46, weight: .ultraLight, design: .rounded))
                                .monospacedDigit()
                            Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                                .font(.system(size: 14, weight: .regular, design: .rounded))
                        }
                        .foregroundStyle(.white.opacity(0.58))
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                        .padding(48)
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

/// One screen's worth of scenery tank: borderless, never key, sharing
/// nothing with screen capture. The wallpaper sits a level above the
/// desktop icons, behind every window and click-through; the
/// screensaver sits over everything and takes the first click only to
/// go away, so the click never lands on something you can't see.
@MainActor
final class AquariumAmbientPanel: NSPanel {
    enum Mode { case wallpaper, screensaver }

    var onTouch: (@MainActor () -> Void)?

    init(screen: NSScreen, toy: AquariumToy, mode: Mode) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        let host = TouchView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let hosting = NSHostingView(rootView: AquariumSceneryView(
            toy: toy, clock: mode == .screensaver))
        hosting.frame = host.bounds
        hosting.autoresizingMask = [.width, .height]
        host.addSubview(hosting)
        host.onTouch = { [weak self] in self?.onTouch?() }
        contentView = host
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        sharingType = .none
        switch mode {
        case .wallpaper:
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            ignoresMouseEvents = true
            collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        case .screensaver:
            level = .screenSaver
            ignoresMouseEvents = false
            collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        }
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Swallows the click that wakes the screensaver.
    private final class TouchView: NSView {
        var onTouch: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            frame.contains(point) ? self : nil
        }
        override func mouseDown(with event: NSEvent) { onTouch?() }
        override func rightMouseDown(with event: NSEvent) { onTouch?() }
        override func scrollWheel(with event: NSEvent) { onTouch?() }
    }
}
