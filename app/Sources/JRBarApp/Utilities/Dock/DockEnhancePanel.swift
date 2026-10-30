import JRBarUI
import AppKit
import JRBarCore
import Observation
import QuartzCore
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The click handlers a `DockPreviewView` calls — a shared box so the
/// panel can be built before the controller's closures land, without
/// rebuilding the hosting tree.
@MainActor
@Observable
final class DockPreviewActions {
    @ObservationIgnored private weak var content: DockPreviewContent?
    @ObservationIgnored var isActive: @MainActor () -> Bool = { true }

    init(content: DockPreviewContent) {
        self.content = content
    }

    /// Gestures and context menus can outlive the row they captured.
    /// Resolve its stamped ID before calling any window action, and use
    /// the current row's state rather than the old rendering snapshot.
    private func currentWindow(_ snapshot: DockPreviewWindow) -> DockPreviewWindow? {
        guard isActive() else { return nil }
        return content?.windows.first { $0.id == snapshot.id }
    }

    func performWindowAction(
        _ snapshot: DockPreviewWindow,
        _ action: (@MainActor (DockPreviewWindow) -> Void)?
    ) {
        guard let current = currentWindow(snapshot) else { return }
        action?(current)
    }

    func performWindowAction<Value>(
        _ snapshot: DockPreviewWindow, value: Value,
        _ action: (@MainActor (DockPreviewWindow, Value) -> Void)?
    ) {
        guard let current = currentWindow(snapshot) else { return }
        action?(current, value)
    }

    func calendarDay(_ day: Date, clickCount: Int) {
        if clickCount == 2 { onCalendarDateOpen?(day) }
        else if clickCount == 1 { onCalendarDay?(day) }
    }

    /// A window card's click — the controller raises it.
    var onPick: (@MainActor (DockPreviewWindow) -> Void)?
    /// A window card's ⌥-click — raise it and keep the panel up, so a
    /// set of windows can be compared or raised in one hover.
    var onPickKeepOpen: (@MainActor (DockPreviewWindow) -> Void)?

    /// A card's click, read with the modifiers held at the time: ⌥ keeps
    /// the panel (DockDoor's keep-open-after-activating), plain closes it.
    func pick(_ snapshot: DockPreviewWindow, flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        performWindowAction(snapshot, DockEnhanceMath.keepsPanelOpen(flags) ? onPickKeepOpen : onPick)
    }
    /// The card's × — close that window.
    var onClose: (@MainActor (DockPreviewWindow) -> Void)?
    /// The card's – — minimize, or bring a minimized window back.
    var onMinimize: (@MainActor (DockPreviewWindow) -> Void)?
    /// The card's fullscreen verb — toggle the window's own
    /// `AXFullScreen`.
    var onFullScreen: (@MainActor (DockPreviewWindow) -> Void)?
    /// The context menu's tile — snap the window into a half or
    /// quarter of the screen, DockDoor's snap verbs.
    var onTile: (@MainActor (DockPreviewWindow, DockTile) -> Void)?
    /// The header's "New" — the app's own New Window menu item.
    var onNewWindow: (@MainActor () -> Void)?
    /// The header's "Quit".
    var onQuitApp: (@MainActor () -> Void)?
    /// The header's "Hide".
    var onHideApp: (@MainActor () -> Void)?
    /// DockDoor's minimise-all — every open window to the Dock.
    var onMinimizeAll: (@MainActor () -> Void)?
    /// Close-all — every window closes, the app stays running.
    var onCloseAll: (@MainActor () -> Void)?
    /// A folder pop's click — open the entry, or the header's "Open"
    /// for the folder itself.
    var onOpen: (@MainActor (URL) -> Void)?
    /// Aero shake on a card — minimise the app's other windows.
    var onShake: (@MainActor (DockPreviewWindow) -> Void)?
    /// A vertical flick on a card — down minimises, up restores.
    var onSwipeMinimize: (@MainActor (DockPreviewWindow, Bool) -> Void)?
    /// The player row's transport — previous, play/pause, next.
    var onMediaCommand: (@MainActor (MediaRemoteBridge.Command) -> Void)?
    /// The player row's scrubber — seek to a playhead in seconds.
    var onMusicAllow: (@MainActor () -> Void)?
    var onMusicOpen: (@MainActor () -> Void)?
    var onPreviewSize: (@MainActor (DockPreviewSize?) -> Void)?
    var onMediaSeek: (@MainActor (Double) -> Void)?
    /// The synced lyrics the notch Shelf already holds for the playing
    /// track — read, never fetched: nil unless the Shelf has them.
    @ObservationIgnored var lyrics: @MainActor () -> SyncedLyrics? = { nil }
    var onMailAuth: (@MainActor () -> Void)?
    var onMailSettings: (@MainActor () -> Void)?
    var onMailOpen: (@MainActor () -> Void)?
    var onMailNew: (@MainActor () -> Void)?
    var onMailMessage: (@MainActor (DockMailMessage) -> Void)?
    var onMailReply: (@MainActor (DockMailMessage) -> Void)?
    /// Calendar access uses Setup's existing permission action.
    var onRemindersAuth: (@MainActor () -> Void)?
    var onReminderComplete: (@MainActor (ShelfRemindersModel.Entry) -> Void)?
    var onReminderAdd: (@MainActor (String) -> Bool)?
    var onRemindersOpen: (@MainActor () -> Void)?
    var onShortcutRun: (@MainActor (String) -> Void)?
    var onShortcutOpen: (@MainActor (String) -> Void)?
    var onShortcutsOpen: (@MainActor () -> Void)?
    var onShortcutNew: (@MainActor () -> Void)?
    var onMessagesOpen: (@MainActor () -> Void)?
    var onMessageNew: (@MainActor () -> Void)?
    var onCalendarAuth: (@MainActor () -> Void)?
    var onCalendarView: (@MainActor (DockCalendarView) -> Void)?
    var onCalendarDay: (@MainActor (Date) -> Void)?
    var onCalendarDateOpen: (@MainActor (Date) -> Void)?
    var onCalendarMonth: (@MainActor (Date) -> Void)?
    var onCalendarEvent: (@MainActor (ShelfCalendarModel.Event) -> Void)?
    var onCalendarOpen: (@MainActor () -> Void)?
    var onNativeWindowsChange: (@MainActor () -> Void)?
    /// The calendar row's "Join" — opens the meeting link.
    var onCalendarJoin: (@MainActor (URL?) -> Void)?
    /// A document card dropped on another app's preview — the
    /// controller opens the file in the previewed app, DockDoor's
    /// drag-between-previews handoff. False means the drop fell
    /// through (a non-document, or an app that can't take it).
    var onDocumentDrop: (@MainActor (URL) -> Bool)?
    /// An ask row's answer came back from the shared desk — the panel
    /// refits around the line that now stands where its buttons were.
    var onAnswered: (@MainActor () -> Void)?
    /// The context menu's Move To — the window to another display.
    var onMoveToDisplay: (@MainActor (DockPreviewWindow, CGDirectDisplayID) -> Void)?
    /// The pointer landed on a card — the controller re-takes its still
    /// when the cached one has aged past a glance, or plays it live.
    var onHoverCard: (@MainActor (DockPreviewWindow) -> Void)?
    /// The pointer left a card — a live card stops streaming.
    var onHoverCardEnd: (@MainActor (DockPreviewWindow) -> Void)?
    /// The header's "Never Preview <App>" — the app joins the card's
    /// exclusion list from where it bothered you.
    var onExcludeApp: (@MainActor () -> Void)?
    /// "Send to Shelf" — the file joins the notch Shelf's tray. nil (no
    /// Shelf wired) hides the verb.
    var onSendToShelf: (@MainActor (URL) -> Void)?
    /// "Show in Finder" — the file's folder opens with it selected.
    var onReveal: (@MainActor (URL) -> Void)?
    /// A folder chip's click — browse into it in place.
    var onDrillFolder: (@MainActor (URL) -> Void)?
    /// The drilled pop's chevron — one folder back up.
    var onFolderBack: (@MainActor () -> Void)?
    var onRetryFolder: (@MainActor () -> Void)?
}

/// The Macs' displays as the Move To menu names them, and the screen
/// geometry the Dock's watcher and switcher share: AX frames and CG
/// bounds live in Quartz space, y down from the primary display's top.
@MainActor
enum DockDisplays {
    struct Display { let id: CGDirectDisplayID; let name: String; let screen: NSScreen }

    static func all() -> [Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return Display(id: CGDirectDisplayID(number.uint32Value), name: screen.localizedName, screen: screen)
        }
    }

    /// Every display but the one holding `frame`'s centre (Quartz) —
    /// empty on a one-screen desk, so the menu never offers a no-op.
    static func others(than frame: CGRect?) -> [Display] {
        let displays = all()
        guard displays.count > 1 else { return [] }
        guard let frame else { return displays }
        let centre = CGPoint(x: frame.midX, y: primaryHeight() - frame.midY)
        return displays.filter { !$0.screen.frame.contains(centre) }
    }

    /// The primary screen's height — the one holding the global origin,
    /// whose top edge Quartz's y counts down from.
    static func primaryHeight() -> CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?
            .frame.height ?? 0
    }

    /// The pointer's screen in Quartz space — "only this display" for
    /// the switcher and the previews.
    static func pointerDisplayQuartz() -> CGRect? {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) else { return nil }
        let f = screen.frame
        return CGRect(x: f.minX, y: primaryHeight() - f.maxY, width: f.width, height: f.height)
    }
}

/// The Enhance preview's window: a borderless, nonactivating glass
/// panel (it floats, so the material rule allows glass) off Apple's
/// Dock, all-spaces like the Dock. It rides above the Dock while it
/// covers the Dock's name bubble, just under it otherwise (see
/// `level(coversLabel:)`). The controller positions it; the view reads
/// `DockPreviewContent`, so late thumbnails re-render without a
/// re-present.
@MainActor
final class DockPreviewPanel: NSPanel {
    let actions: DockPreviewActions

    private let hosting: NSHostingView<DockPreviewView>
    private let viewport: NSScrollView
    private let glass: NSGlassEffectView
    private let container: NSView

    init(content: DockPreviewContent) {
        actions = DockPreviewActions(content: content)
        hosting = NSHostingView(rootView: DockPreviewView(content: content, actions: actions))
        // Keep the content at its natural size. On a small display the
        // viewport scrolls, so minimum widths never hide controls.
        hosting.sizingOptions = [.intrinsicContentSize]
        let radius = content.hasNativeCard ? JRBarTokens.Radius.panel : content.metrics.panelRadius
        glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 240, height: 96))
        glass.cornerRadius = radius
        glass.style = .regular
        viewport = NSScrollView(frame: glass.bounds)
        viewport.drawsBackground = false
        viewport.borderType = .noBorder
        viewport.hasHorizontalScroller = true
        viewport.hasVerticalScroller = true
        viewport.autohidesScrollers = true
        viewport.scrollerStyle = .overlay
        viewport.documentView = hosting
        viewport.autoresizingMask = [.width, .height]
        glass.contentView = viewport
        container = GlassBackdrop.rounded(glass, cornerRadius: radius)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 96),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = container
        actions.isActive = { [weak self] in self?.isVisible == true }
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .transient, .fullScreenAuxiliary, .ignoresCycle]
        // The cards' hover verbs (× and –) need mouse-moved events, which
        // a non-key panel does not get unless it asks.
        acceptsMouseMovedEvents = true
        title = "JR-Bar Dock Preview"
        level = Self.level(coversLabel: false)
        // Out of screen recordings and window captures — and out of its
        // own app's window list, so hovering JR-Bar's tile never
        // previews the preview. JRBAR_CAPTURE_CARD is the dev escape.
        if ProcessInfo.processInfo.environment["JRBAR_CAPTURE_CARD"] == nil {
            sharingType = .none
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The panel's level. Covering the Dock's name bubble, it rides at
    /// the status-bar level, over the Dock's own window (the bubble is
    /// drawn inside it) — DockDoor's "above app labels"; the controller
    /// then keeps it clear of a magnified icon's reach. Otherwise it sits
    /// just under the Dock: above every app window, while a magnified
    /// icon swelling into its band still draws over it and takes its
    /// click (one level over the Dock made the upper half of every
    /// magnified icon dead).
    static func level(coversLabel: Bool) -> NSWindow.Level {
        coversLabel ? .statusBar : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
    }

    /// The level for `placement`: over the Dock while it covers the name
    /// bubble, under it otherwise. The show, the re-anchor and the refit
    /// all call it, so a cover flipped while the panel is up lands on
    /// the next move rather than the next hover.
    func hold(_ placement: DockPlacement) {
        let wanted = Self.level(coversLabel: placement.coversLabel)
        if level != wanted { level = wanted }
    }

    /// Mail stays private even under the development capture override.
    func protectMail(_ isMail: Bool) {
        sharingType = isMail || ProcessInfo.processInfo.environment["JRBAR_CAPTURE_CARD"] == nil ? .none : .readOnly
    }

    /// The glass takes the spacing's corner — concentric with the card
    /// plates at the spacing's inset — and the window re-reads the
    /// rounded shadow. Called on every show.
    func apply(_ metrics: DockPreviewMetrics) {
        let native = hosting.rootView.content.hasNativeCard
        let radius = native ? JRBarTokens.Radius.panel : metrics.panelRadius
        glass.cornerRadius = radius
        container.layer?.cornerRadius = radius
        invalidateShadow()
    }

    /// Measure natural content against the room on the anchor's display.
    /// Warm-up callers use a fixed budget without consulting a display.
    func fittingSize(maximumSize: CGSize = CGSize(width: 720, height: 900)) -> CGSize {
        hosting.invalidateIntrinsicContentSize()
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.intrinsicContentSize
        let natural = CGSize(width: max(1, fit.width), height: max(1, fit.height))
        let sizeLimit = hosting.rootView.content.previewSize.maximumHeight
        let heightLimit = min(sizeLimit, max(1, maximumSize.height))
        let size = CGSize(width: min(natural.width, max(1, maximumSize.width)),
                          height: min(natural.height, heightLimit))
        let wasAtTop = hosting.isFlipped
            ? viewport.contentView.bounds.minY <= 1
            : viewport.contentView.bounds.maxY >= hosting.frame.height - 1
        hosting.setFrameSize(natural)
        viewport.setFrameSize(size)
        if wasAtTop {
            let top = hosting.isFlipped ? 0 : max(0, natural.height - size.height)
            let point = CGPoint(x: viewport.contentView.bounds.minX, y: top)
            viewport.contentView.scroll(to: point)
            viewport.reflectScrolledClipView(viewport.contentView)
        }
        return size
    }

    /// A newly summoned app starts at its header, even if the previous
    /// preview was scrolled to its last window.
    func resetScrollPosition() {
        let top = hosting.isFlipped ? 0 : max(0, hosting.frame.height - viewport.contentSize.height)
        viewport.contentView.scroll(to: CGPoint(x: 0, y: top))
        viewport.reflectScrolledClipView(viewport.contentView)
    }

    /// Show at `target`, animating a short springy drift up off the
    /// dock — a 220 ms ease with a hint of overshoot, under the 250 ms
    /// cap, so the panel visibly tracks which icon summoned it. The
    /// drift and the level come from `placement`: covering the name
    /// bubble, the glass never drifts across the icon under the pointer.
    /// A retarget while visible just slides to the new anchor; dismiss
    /// stays instant (a leave means leave), and Reduce Motion snaps.
    func present(frame target: CGRect, dockedAt edge: DockEdge, placement: DockPlacement) {
        hold(placement)
        if isVisible, alphaValue > 0.5 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(target, display: true)
            }
            WindowPresenter.automatic.order(self)
            return
        }
        let drift = placement.openingDrift
        var start = target
        switch edge {
        case .bottom: start.origin.y -= drift
        case .left: start.origin.x -= drift
        case .right: start.origin.x += drift
        }
        setFrame(start, display: false)
        alphaValue = 0
        WindowPresenter.automatic.order(self)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0.03 : 0.22
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.25, 1.3, 0.4, 1)
            animator().alphaValue = 1
            animator().setFrame(target, display: true)
        }
    }

    static func resizedFrame(_ prior: CGRect, size: CGSize, edge: DockEdge) -> CGRect {
        let origin: CGPoint
        switch edge {
        case .bottom: origin = CGPoint(x: prior.midX - size.width / 2, y: prior.minY)
        case .left: origin = CGPoint(x: prior.minX, y: prior.midY - size.height / 2)
        case .right: origin = CGPoint(x: prior.maxX - size.width, y: prior.midY - size.height / 2)
        }
        return CGRect(origin: origin, size: size)
    }

    func resize(to frame: CGRect, animated: Bool) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated && !reduced else { setFrame(frame, display: true); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = JRBarTokens.Motion.rowChange.duration
            animator().setFrame(frame, display: true)
        }
    }

    /// Instant — a leave means leave.
    func dismiss() {
        alphaValue = 0
        orderOut(nil)
    }
}

/// A one-line glass toast just above a Dock tile — what an invisible
/// gesture did ("Quit Safari", "Force quit Xcode") or why it waited
/// ("Claude is working here — ⌘-right-click again to quit"). It never
/// takes a click or focus, and fades on its own.
@MainActor
final class DockToastPanel: NSPanel {
    @MainActor @Observable final class Model { var text = "" }
    private let model = Model()
    private let hosting: NSHostingView<DockToastView>
    private var fadeWork: DispatchWorkItem?

    init() {
        hosting = NSHostingView(rootView: DockToastView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 160, height: 30))
        glass.cornerRadius = 12
        glass.style = .regular
        hosting.frame = glass.bounds
        hosting.autoresizingMask = [.width, .height]
        glass.contentView = hosting
        super.init(contentRect: NSRect(x: 0, y: 0, width: 160, height: 30),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = GlassBackdrop.rounded(glass, cornerRadius: 12)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .transient, .fullScreenAuxiliary, .ignoresCycle]
        level = DockPreviewPanel.level(coversLabel: false)
        title = "JR-Bar Dock Toast"
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show `text` over `tile` (AppKit space) off the Dock's `edge`,
    /// for `duration`, then fade. It sits where a preview would — the
    /// card's distance from the Dock, over or clear of the name bubble
    /// of the tile titled `title`, at the preview's level for that.
    func show(_ text: String, over tile: CGRect, edge: DockEdge, screen: CGRect,
              placement: DockPlacement, title: String, duration: TimeInterval = 1.4) {
        model.text = text
        hosting.invalidateIntrinsicContentSize()
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.intrinsicContentSize
        let size = CGSize(width: min(max(fit.width, 80), 420), height: max(fit.height, 28))
        level = DockPreviewPanel.level(coversLabel: placement.coversLabel)
        setFrame(placement.frame(anchor: tile, edge: edge, size: size, screen: screen, title: title),
                 display: true)
        fadeWork?.cancel()
        alphaValue = 1
        WindowPresenter.automatic.order(self)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
                    self.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated { self?.orderOut(nil) }
                })
            }
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

struct DockToastView: View {
    let model: DockToastPanel.Model

    var body: some View {
        Text(model.text)
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
    }
}

/// The panel's body: the app's header and its verbs, any agent waiting
/// in it, the player or calendar glance, then the window cards — each
/// window's own still when Screen Recording granted one, the app's icon
/// otherwise — with close, minimize and full screen on hover. Clicks
/// report through `actions`.
struct DockPreviewView: View {
    let content: DockPreviewContent
    let actions: DockPreviewActions
    /// A document card held over the panel — the highlight ring.
    @ViewState private var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The spacing the panel was shown at: its inset from the glass
    /// edge, the air between sections, and the corners — the cards'
    /// plates sit concentric inside the glass at this inset.
    private var metrics: DockPreviewMetrics { content.metrics }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
            if !content.hasNativeCard { header }
            if let note = content.headerNote {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, content.hasNativeCard ? content.previewSize.widgetPadding : 2)
                    .frame(width: content.hasNativeCard ? content.previewSize.contentWidth : nil, alignment: .leading)
            }
            if let failure = content.actionFailure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(DockChrome.caution)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, content.hasNativeCard ? content.previewSize.widgetPadding : 2)
                    .frame(width: content.hasNativeCard ? content.previewSize.contentWidth : nil, alignment: .leading)
                    .help(failure)
            }
            if !content.askRows.isEmpty {
                VStack(spacing: 6) {
                    ForEach(content.askRows) { mark in
                        DockAskRow(mark: mark, actions: actions, metrics: metrics)
                    }
                }
            }
            if content.mediaPending, content.windows.isEmpty, !content.hasNativeCard {
                Text("Loading playback…").jrbarType(.callout).foregroundStyle(.secondary)
            }
            if content.musicPlayerEnabled {
                rule
                if let music = content.music {
                    DockMusicCard(player: music, actions: actions)
                } else {
                    DockWidget(title: "Music", symbol: "music.note") {
                        Text("Loading Music…").jrbarType(.callout).foregroundStyle(.secondary)
                    }
                }
            } else if let media = content.media {
                rule
                DockMediaRow(media: media, actions: actions, appName: content.appName)
            }
            if let state = content.mailState {
                rule
                DockMailCard(state: state, now: content.mailNow, actions: actions)
            }
            if let state = content.calendarState {
                rule
                DockCalendarCard(state: state, now: content.calendarNow, actions: actions,
                                 isCalendarApp: content.bundleID == DockEnhanceMath.calendarBundleID,
                                 view: content.calendarView, month: content.calendarMonth,
                                 listDay: content.calendarListDay,
                                 selectedDay: Binding(get: { content.calendarSelectedDay },
                                                      set: { content.calendarSelectedDay = $0 }))
            }
            if let state = content.remindersState {
                rule
                DockRemindersCard(state: state, now: content.remindersNow,
                                  writeNotice: content.remindersWriteNotice, actions: actions)
            }
            if let state = content.shortcutsState {
                rule
                DockShortcutsCard(state: state, runs: content.shortcutRuns, actions: actions)
            }
            if let state = content.messagesState {
                rule
                DockMessagesCard(state: state, actions: actions)
            }
            if content.folderURL != nil {
                rule
                folder
            } else if !content.windows.isEmpty {
                rule
                windowSection.frame(width: content.hasNativeCard ? content.previewSize.contentWidth : nil)
            }
        }
        .environment(\.dockPreviewSize, content.previewSize)
        .padding(content.hasNativeCard ? 0 : metrics.panelInset)
        .contextMenu {
            if content.bundleID != nil {
                ForEach(DockPreviewSize.allCases, id: \.self) { size in
                    Button { actions.onPreviewSize?(size) } label: {
                        if size == content.previewSize { Label(size.title, systemImage: "checkmark") }
                        else { Text(size.title) }
                    }
                }
                Button("Use Default Size") { actions.onPreviewSize?(nil) }
            }
        }
        .animation(reduceMotion ? nil : JRBarTokens.Motion.rowChange.animation, value: content.previewSize)
        // The card→Dock-tile handoff's other half: a document card
        // dropped on this preview opens the file in the previewed app —
        // DockDoor's drag between previews. Folder previews and bare
        // tiles have no app to hand the file to, so they never claim it.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard content.bundleID != nil, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in _ = actions.onDocumentDrop?(url) }
            }
            return true
        }
        .overlay {
            if dropTargeted, content.bundleID != nil {
                RoundedRectangle(cornerRadius: metrics.panelRadius - 4, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var windowSection: some View {
        if content.hasNativeCard {
            Button {
                content.selectedWindowID = nil
                content.nativeWindowsExpanded.toggle()
                actions.onNativeWindowsChange?()
            } label: {
                Label("Windows (\(content.windows.count))",
                      systemImage: content.showsWindows ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(DockCapsuleButtonStyle())
            .accessibilityValue(content.showsWindows ? "Expanded" : "Collapsed")
        }
        if content.showsWindows { windows }
    }

    /// The hairline between sections — at the tighter scales the air
    /// alone separates them.
    @ViewBuilder
    private var rule: some View {
        if metrics.showsRule && !content.hasNativeCard { DockPanelRule() }
    }

    // MARK: Header

    private var header: some View {
        Group {
            if content.mailState != nil {
                HStack(spacing: 10) {
                    headerIcon
                    headerWords
                }
            } else if cardStripWidth >= wideHeaderMinimum {
                HStack(spacing: 10) {
                    headerBack
                    headerIcon
                    headerWords
                    Spacer(minLength: 12)
                    verbs
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        headerBack
                        headerIcon
                        headerWords
                    }
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ViewThatFits(in: .horizontal) {
                            verbs
                            VStack(alignment: .center, spacing: 4) {
                                HStack(spacing: 6) { leadingVerbs }
                                HStack(spacing: 6) { trailingVerbs }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(width: Self.stripWidth(cards: cardStripWidth, nativeCard: content.hasNativeCard, size: content.previewSize))
    }

    @ViewBuilder
    private var headerBack: some View {
        if !content.folderTrail.isEmpty {
            DockRoundVerb(symbol: "chevron.left", label: backLabel, size: metrics.verbDisc) {
                actions.onFolderBack?()
            }
        }
    }

    @ViewBuilder
    private var headerIcon: some View {
        if let icon = content.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: metrics.headerIcon, height: metrics.headerIcon)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .overlay(alignment: .topTrailing) {
                    if let badge = content.badge {
                        DockBadgePill(text: badge)
                            .fixedSize(horizontal: content.mailState != nil, vertical: true)
                            .offset(x: 7, y: -6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let agent = content.appAgents.first {
                        DockAgentDot(mark: agent, size: 9)
                            .offset(x: 3, y: 3)
                    }
                }
        }
    }

    private var headerWords: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(appTitle.base)
                    .jrbarType(content.previewSize.headerType)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let channel = appTitle.channel {
                    Text(channel)
                        .jrbarType(.caption).fontWeight(.semibold)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }
            Text(subtitle)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .contextMenu {
            if content.bundleID != nil, content.folderURL == nil {
                Button("Never Preview \(content.appName)") { actions.onExcludeApp?() }
            }
        }
    }

    /// The header's verbs as quiet glass discs — least to most final,
    /// Quit at the edge — each taking its traffic-light colour only
    /// under the pointer, so five of them never read as a row of alarms.
    @ViewBuilder
    private var verbs: some View {
        if let shown = content.folderShown {
            DockRoundVerb(symbol: "folder", tint: .accentColor,
                          label: "Open \(shown.lastPathComponent) in Finder", size: metrics.verbDisc) {
                actions.onOpen?(shown)
            }
        } else if content.isRunning {
            HStack(spacing: 6) {
                leadingVerbs
                trailingVerbs
            }
        }
    }

    @ViewBuilder
    private var leadingVerbs: some View {
        if content.isRunning {
            DockRoundVerb(symbol: "plus", tint: DockChrome.go,
                          label: "New window in \(content.appName)", size: metrics.verbDisc) {
                actions.onNewWindow?()
            }
            DockRoundVerb(symbol: "eye.slash", tint: DockChrome.caution,
                          label: "Hide \(content.appName) (⌘H)", size: metrics.verbDisc) {
                actions.onHideApp?()
            }
            if content.windows.contains(where: { !$0.minimized }), content.windows.count > 1 {
                DockRoundVerb(symbol: "minus", tint: DockChrome.caution,
                              label: "Minimise every \(content.appName) window",
                              size: metrics.verbDisc) {
                    actions.onMinimizeAll?()
                }
            }
        }
    }

    @ViewBuilder
    private var trailingVerbs: some View {
        if content.isRunning {
            if content.windows.count > 1 {
                DockRoundVerb(symbol: "xmark", tint: DockChrome.stop,
                              label: "Close every \(content.appName) window (app stays running)",
                              size: metrics.verbDisc) {
                    actions.onCloseAll?()
                }
            }
            DockRoundVerb(symbol: content.stillRunning ? "bolt.horizontal.fill" : "power",
                          tint: DockChrome.stop, label: quitLabel, size: metrics.verbDisc,
                          lit: content.stillRunning) {
                actions.onQuitApp?()
            }
        }
    }

    private var quitLabel: String {
        content.stillRunning ? "Force quit \(content.appName)" : "Quit \(content.appName)"
    }

    /// Enough room for the one-row header. Narrow card strips keep their
    /// own width and put the controls below the name instead.
    private var wideHeaderMinimum: CGFloat {
        var titleWidth: CGFloat = 72
        if let channel = appTitle.channel {
            let font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
            let badge = (channel as NSString).size(withAttributes: [.font: font]).width
            titleWidth += badge + 18
        }
        return headerChromeWidth + titleWidth
    }

    /// Native widgets keep their width when their window strip is expanded.
    static func stripWidth(cards: CGFloat, nativeCard: Bool, size: DockPreviewSize = .medium) -> CGFloat {
        nativeCard ? size.contentWidth : cards
    }

    private var cardStripWidth: CGFloat {
        if content.hasNativeCard || content.compact || content.windows.isEmpty {
            return content.previewSize.contentWidth
        }
        let cards = content.windows.map { max(cardSize($0).width, DockPreviewCard.minColumn)
            + 2 * metrics.cardPad }
        return cards.reduce(0, +) + CGFloat(max(0, cards.count - 1)) * metrics.cardSpacing
    }

    private var headerChromeWidth: CGFloat {
        var width: CGFloat = 12
        if !content.folderTrail.isEmpty { width += metrics.verbDisc + 10 }
        if content.icon != nil { width += metrics.headerIcon + 10 }
        let count: Int
        if content.folderShown != nil {
            count = 1
        } else if content.isRunning {
            count = 3
                + (content.windows.count > 1 ? 1 : 0)
                + (content.windows.count > 1 && content.windows.contains { !$0.minimized } ? 1 : 0)
        } else {
            count = 0
        }
        if count > 0 {
            width += CGFloat(count) * metrics.verbDisc + CGFloat(count - 1) * 6
        }
        return width
    }

    /// The folder the pop is showing, by name.
    private var folderName: String? { content.folderShown?.lastPathComponent }

    private var backLabel: String {
        "Back to \(content.folderTrail.dropLast().last?.lastPathComponent ?? content.appName)"
    }

    // MARK: Windows

    @ViewBuilder
    private var windows: some View {
        if content.compact {
            DockPreviewCompactList(windows: content.windows, agents: content.agents,
                                   selectedWindowID: content.selectedWindowID,
                                   armedWindowID: content.armedWindowID,
                                   armedNote: content.armedNote, rowPad: metrics.listPadH,
                                   actions: actions)
        } else {
            // A strip that fits centres in the panel — one card
            // left-anchored with dead glass beside it reads as a
            // second, empty slot. ViewThatFits alone only centres
            // inside its own content-hugging bounds; the spacers
            // are what hand it the row's full width. An
            // overflowing set falls through to the scroll and
            // the spacers collapse to nothing.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: metrics.cardSpacing) { cards }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: metrics.cardSpacing) { cards }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The window cards — shared between the centred-when-fits strip and
    /// the scrolling one, so both draw the same row.
    @ViewBuilder
    private var cards: some View {
        let captions = captionLines
        ForEach(content.windows) { window in
            DockPreviewCard(window: window, icon: content.icon,
                            size: cardSize(window),
                            fillsStill: content.hugWindows,
                            selected: window.id == content.selectedWindowID,
                            showsTitle: showsTitle(window),
                            captionLines: captions,
                            agent: content.agents[window.id],
                            armedNote: content.armedWindowID == window.id ? content.armedNote : nil,
                            pulsed: content.pulsedWindowIDs.contains(window.id),
                            metrics: metrics,
                            actions: actions)
        }
    }

    /// A card's still box: 16:10, or the window's own shape when the
    /// cards hug their windows.
    private func cardSize(_ window: DockPreviewWindow) -> CGSize {
        guard content.hugWindows else { return DockEnhanceMath.cardSize(size: content.previewSize) }
        return DockEnhanceMath.cardSize(size: content.previewSize, aspect: DockEnhanceMath.aspect(of: window))
    }

    /// A card whose title is just the app name again — "Claude" under a
    /// header that already says Claude — reads as a second label, not a
    /// caption. The Dock's own bubble makes three.
    private func showsTitle(_ window: DockPreviewWindow) -> Bool {
        window.title != content.appName && window.title != appTitle.base
    }

    /// The caption rows the strip reserves under every still — the most
    /// any card needs — so the stills line up along one top edge and
    /// one bottom edge whatever each card has to say.
    private var captionLines: Int {
        content.windows.map { window in
            let armed = content.armedWindowID == window.id && content.armedNote != nil
            if armed { return 2 }
            let title = showsTitle(window) ? 1 : 0
            return title + (content.agents[window.id] == nil ? 0 : 1)
        }.max() ?? 0
    }

    // MARK: Folder

    @ViewBuilder
    private var folder: some View {
        switch content.folderState {
        case .loading:
            HStack(spacing: 8) {
                DelayedWait(since: content.folderLoadStarted)
                Text("Loading…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        case .denied:
            DockFolderNotice(symbol: "lock.fill", tint: DockChrome.caution,
                             title: "No access to \(folderName ?? "this folder")",
                             detail: "Allow Files & Folders for JR-Bar to list it here.") {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                        actions.onOpen?(url)
                    }
                }
                .buttonStyle(DockCapsuleButtonStyle(prominent: true))
                .help("Grant folder access in Privacy & Security")
                if let retry = actions.onRetryFolder {
                    Button("Retry", action: retry)
                        .buttonStyle(DockCapsuleButtonStyle(prominent: false))
                }
            }
        case .failed:
            DockFolderNotice(symbol: "exclamationmark.triangle.fill", tint: DockChrome.caution,
                             title: "Couldn't read this folder",
                             detail: "The folder may have moved, or its drive may be unavailable.") {
                if let retry = actions.onRetryFolder {
                    Button("Retry", action: retry)
                        .buttonStyle(DockCapsuleButtonStyle(prominent: true))
                        .accessibilityLabel("Retry loading \(folderName ?? "this folder")")
                }
            }
        case .ready:
            if content.folderEntries.isEmpty {
                DockFolderNotice(symbol: "tray", tint: .secondary,
                                 title: "Nothing in \(folderName ?? "here")",
                                 detail: "Files you save here show up in this pop.") { EmptyView() }
            } else {
                // Apple's Grid stack: five across, four rows before it
                // scrolls; a folder chip browses in.
                let grid = DockEnhanceMath.folderGrid(count: content.folderEntries.count)
                let gap = DockFolderChip.gap(metrics)
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(DockFolderChip.width), spacing: gap),
                                             count: grid.columns),
                              spacing: gap) {
                        ForEach(content.folderEntries, id: \.url) { entry in
                            DockFolderChip(entry: entry, actions: actions)
                        }
                    }
                }
                .frame(width: CGFloat(grid.columns) * (DockFolderChip.width + gap),
                       height: CGFloat(grid.rows) * (DockFolderChip.height + gap))
            }
        }
    }

    // MARK: Words

    /// The header's name: the product name with any release-channel tag
    /// split into its own chip, so "T3 Code (Nightly)" lays out as slim
    /// as "T3 Code" — the tag still shows, just not on the title line.
    private var appTitle: (base: String, channel: String?) {
        // A drilled pop names the folder it shows.
        if !content.folderTrail.isEmpty, let shown = content.folderShown {
            return (shown.lastPathComponent, nil)
        }
        return AppNameChannel.split(content.appName)
    }

    static func folderSubtitle(state: DockFolderState, count: Int) -> String {
        switch state {
        case .loading: return "Folder"
        case .denied: return "No access"
        case .failed: return "Read failed"
        case .ready: return count == 1 ? "1 item" : "\(count) items"
        }
    }

    private var subtitle: String {
        if let state = content.mailState { return state.subtitle(now: content.mailNow) }
        if let summary = content.nativeAppSubtitle { return summary }
        if content.folderURL != nil {
            return Self.folderSubtitle(state: content.folderState, count: content.folderEntries.count)
        }
        // A minimized-window tile whose owner didn't resolve still
        // carries its one card — "Not running" would misname it.
        if !content.isRunning {
            return content.windows.isEmpty ? "Not running" : "Minimized window"
        }
        let minimized = content.windows.filter(\.minimized).count
        let windows: String
        switch content.windows.count {
        case 0: windows = "No open windows"
        case 1: windows = minimized == 1 ? "1 window, minimized" : "1 window"
        default:
            windows = minimized > 0
                ? "\(content.windows.count) windows, \(minimized) minimized"
                : "\(content.windows.count) windows"
        }
        // "3 windows · 1 agent waiting" — the header answers which
        // terminal wants you before any card is read.
        guard let agents = DockAgentMatch.headerSummary(content.appAgents) else { return windows }
        return "\(windows) · \(agents)"
    }
}

/// One window's card: the still (or the app's icon), the title, what an
/// agent in it is doing, and the verbs that appear on hover — × closes,
/// – minimizes or restores, the arrows toggle full screen. The face is
/// the raise target.
struct DockPreviewCard: View {
    let window: DockPreviewWindow
    let icon: NSImage?
    let size: CGSize
    /// The still fills its box (cropped at the edges) rather than fitting
    /// inside it — for a box already cut to the window's shape.
    var fillsStill = false
    var selected = false
    /// nil-equivalent title rows are suppressed — the header already
    /// names the app, and the Dock's own bubble does too.
    var showsTitle = true
    /// The caption rows the strip reserves under every still, so a card
    /// with less to say keeps its still in line with the rest.
    var captionLines = 2
    /// The agent session this window hosts — its mark, its ring when it
    /// waits on you, and what it is doing under the title.
    var agent: DockAgentMark? = nil
    /// A guarded close's first press: the still rings in the agent's
    /// colour and this line replaces the captions until it lapses.
    var armedNote: String? = nil
    /// A shake or flick just moved this window — the card dips a beat.
    var pulsed = false
    /// The plate's reach past the still, its corner (concentric with the
    /// still inside it), and the air between still and caption.
    var metrics = DockPreviewMetrics.standard
    /// The hover face drawn without a pointer — the verbs and the lit
    /// plate — for the render proofs.
    var hoverShown = false
    let actions: DockPreviewActions
    @ViewState private var hovering = false
    @ViewState private var shake = DockEnhanceMath.ShakeDetector()
    /// One caption row's height.
    static let captionRow: CGFloat = 14
    /// The narrowest a card's plate and caption get: a portrait window's
    /// still is narrower, and centres in this column so its title still
    /// reads as words.
    static let minColumn: CGFloat = 96

    /// The caption's width, which the plate takes: the still's, or the
    /// minimum column when the still is narrower.
    private var columnWidth: CGFloat { max(size.width, Self.minColumn) }

    private var showsHover: Bool { hovering || hoverShown }

    /// The hover verbs: × closes, – minimizes or restores, the arrows
    /// toggle full screen when the window can.
    @ViewBuilder
    private var verbs: some View {
        DockRoundVerb(symbol: "xmark", tint: DockChrome.stop, label: "Close window",
                      size: 20, onStill: true) {
            actions.performWindowAction(window, actions.onClose)
        }
        DockRoundVerb(symbol: window.minimized ? "arrow.up.left.and.arrow.down.right" : "minus",
                      tint: DockChrome.caution,
                      label: window.minimized ? "Bring back" : "Minimize",
                      size: 20, onStill: true) {
            actions.performWindowAction(window, actions.onMinimize)
        }
        if let fullScreen = window.fullScreen {
            DockRoundVerb(symbol: fullScreen ? "arrow.down.left.and.arrow.up.right"
                                             : "arrow.up.right.and.arrow.down.left",
                          tint: DockChrome.go,
                          label: fullScreen ? "Leave full screen" : "Full screen",
                          size: 20, onStill: true) {
                actions.performWindowAction(window, actions.onFullScreen)
            }
        }
    }

    var body: some View {
        VStack(spacing: metrics.captionGap) {
            ZStack(alignment: .topLeading) {
                Button { actions.pick(window) } label: {
                    face
                }
                .buttonStyle(.plain)
                // A window that declares AXDocument is a drag source:
                // dropping the card on another app's Dock tile is the
                // system's own "open this file in that app".
                .draggableIfPresent(window.documentURL)
                // Middle-click the card closes the window — the
                // DockDoor verb a trackpad can't gesture.
                .overlay(MiddleClickCatcher { actions.performWindowAction(window, actions.onClose) })
                // A trackpad flick down on the card minimises it; up
                // restores — the strip's own horizontal scroll falls
                // through, the catcher only claims vertical flicks.
                .overlay(SwipeCatcher { flick in
                    actions.performWindowAction(window, value: flick == .down, actions.onSwipeMinimize)
                })
                // Right-click — DockDoor's action menu: the verbs the
                // hover pills offer plus the tile grid.
                .contextMenu { menu }
                if showsHover {
                    // A still too narrow for the row (a portrait window's
                    // card) stacks the verbs down its edge instead.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) { verbs }
                        VStack(spacing: 5) { verbs }
                    }
                    .padding(6)
                    .transition(.opacity)
                }
            }
            // Pinned to the still: the hover verbs never widen the card,
            // so pointing at it can't reflow the strip under the pointer.
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                if let agent {
                    DockAgentDot(mark: agent, size: 10)
                        .shadow(color: .black.opacity(0.35), radius: 1.5)
                        .padding(7)
                        .allowsHitTesting(false)
                }
            }
            if captionLines > 0 {
                captions
                    .frame(width: columnWidth, height: CGFloat(captionLines) * Self.captionRow, alignment: .top)
            }
        }
        .padding(metrics.cardPad)
        .background(plate)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            actions.performWindowAction(window, inside ? actions.onHoverCard : actions.onHoverCardEnd)
        }
        // Aero shake lives on continuous hover — a non-activating panel
        // still gets tracking-area events while the pointer rests.
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                if shake.note(x: point.x, now: CACurrentMediaTime()) {
                    actions.performWindowAction(window, actions.onShake)
                }
            case .ended:
                shake.reset()
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .opacity(pulsed ? 0.45 : 1)
        .animation(.easeOut(duration: 0.18), value: pulsed)
        .help(window.title)
    }

    /// The keyboard's pick wears the accent; the pointer's a quiet plate.
    @ViewBuilder
    private var plate: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.plateRadius, style: .continuous)
        if selected {
            shape.fill(Color.accentColor.opacity(0.16))
                .overlay(shape.strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1))
        } else if showsHover {
            shape.fill(DockChrome.plateHover)
        }
    }

    /// A waiting agent's still is ringed in its provider's colour; a
    /// guarded close's first press thickens the ring.
    private var ring: Color? {
        guard let agent, agent.isWaiting || armedNote != nil else { return nil }
        return agent.accent
    }

    @ViewBuilder
    private var face: some View {
        Group {
            if let thumbnail = window.thumbnail {
                DockStill(image: thumbnail, ring: ring, ringWidth: armedNote != nil ? 3 : 2, fill: fillsStill)
                    .opacity(window.minimized ? 0.55 : 1)
                    .overlay(alignment: .bottomLeading) {
                        if window.minimized { DockMinimizedMark().padding(6) }
                    }
            } else {
                DockStillPlaceholder(icon: icon, minimized: window.minimized, ring: ring)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var captions: some View {
        VStack(spacing: 1) {
            if let armedNote {
                Text(armedNote)
                    .jrbarType(.caption).fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            } else {
                // A minimized window says so on its face — the corner
                // mark on a still, the word on the icon — not here too.
                if showsTitle {
                    Text(window.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(height: Self.captionRow)
                }
                if let agent {
                    // What the agent in this window is doing — the fact the
                    // panel's row would show, one quiet line.
                    Text(agent.statusLine)
                        .jrbarType(.caption).fontWeight(agent.isWaiting ? .semibold : .regular)
                        .foregroundStyle(agent.isWaiting ? AnyShapeStyle(agent.accent) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: Self.captionRow)
                }
            }
        }
        .frame(maxWidth: columnWidth)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Raise") { actions.performWindowAction(window, actions.onPick) }
        Button("Raise, Keep Preview") { actions.performWindowAction(window, actions.onPickKeepOpen) }
        Divider()
        Button(window.minimized ? "Bring Back" : "Minimize") {
            actions.performWindowAction(window, actions.onMinimize)
        }
        if window.fullScreen != nil {
            Button(window.fullScreen == true ? "Leave Full Screen" : "Full Screen") {
                actions.performWindowAction(window, actions.onFullScreen)
            }
        }
        Divider()
        Menu("Tile To") {
            ForEach(DockTile.allCases.filter { $0 != .center && $0 != .fill }, id: \.rawValue) { tile in
                Button(tile.title) { actions.performWindowAction(window, value: tile, actions.onTile) }
            }
            Divider()
            Button(DockTile.center.title) { actions.performWindowAction(window, value: DockTile.center, actions.onTile) }
            Button(DockTile.fill.title) { actions.performWindowAction(window, value: DockTile.fill, actions.onTile) }
        }
        // The other monitors, by name — the display half of
        // DockDoor's move-between-Spaces, no private Space API.
        let others = DockDisplays.others(than: window.frame)
        if !others.isEmpty {
            Menu("Move To") {
                ForEach(others, id: \.id) { display in
                    Button(display.name) {
                        actions.performWindowAction(window, value: display.id, actions.onMoveToDisplay)
                    }
                }
            }
        }
        if let document = window.documentURL, let send = actions.onSendToShelf {
            Divider()
            Button("Send Document to Shelf") { send(document) }
        }
        Divider()
        Button("Close Window") { actions.performWindowAction(window, actions.onClose) }
    }
}

/// The past-`compactListLimit` face: one dense row per window — title,
/// minimized mark, what an agent in it is doing, the same hover verbs
/// as a card — instead of thumbnails a many-windowed app would only
/// smear. Compact also means no captures: nothing here ever flashes the
/// recording dot.
struct DockPreviewCompactList: View {
    let windows: [DockPreviewWindow]
    var agents: [Int: DockAgentMark] = [:]
    /// The keyboard-walked row.
    var selectedWindowID: Int? = nil
    var armedWindowID: Int? = nil
    var armedNote: String? = nil
    /// A row's padding across — the spacing's `listPadH`.
    var rowPad: CGFloat = DockPreviewMetrics.standard.listPadH
    @Environment(\.dockPreviewSize) private var previewSize
    let actions: DockPreviewActions

    var body: some View {
        // The leading columns are the list's, not each row's: a row with
        // no mark or no state glyph still keeps the space, so every title
        // starts on the same line.
        let columns = DockCompactColumns.of(windows, agents: agents)
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: previewSize.rowSpacing) {
                ForEach(windows) { window in
                    DockPreviewCompactRow(window: window, agent: agents[window.id],
                                          selected: window.id == selectedWindowID,
                                          armedNote: armedWindowID == window.id ? armedNote : nil,
                                          columns: columns, pad: rowPad, actions: actions)
                }
            }
        }
        // The list takes the panel's width — an ask row above it can be
        // wider than the rows need — and never less than a row's own.
        .frame(width: previewSize.contentWidth)
        .frame(height: min(CGFloat(windows.count) * (previewSize.rowHeight + previewSize.rowSpacing), previewSize.maximumCardHeight))
    }

    /// Nine rows and half the tenth: a longer list shows it scrolls.
    static let maxHeight: CGFloat = 276
}

/// One chip in a folder pop: the file's Quick Look face (its type icon
/// until one lands) over the name — a click opens the file, a folder
/// browses in place. The plate only shows under the pointer, so a full
/// grid reads as files, not as a wall of buttons.
private struct DockFolderChip: View {
    let entry: DockFolderEntry
    let actions: DockPreviewActions
    /// The chip's box — the grid lays out on it.
    static let width: CGFloat = 92
    static let height: CGFloat = 72
    /// Chip to chip: the cards' spacing, so the grid tightens with the
    /// strip.
    static func gap(_ metrics: DockPreviewMetrics) -> CGFloat { metrics.cardSpacing }
    @ViewState private var hovering = false
    /// The file's Quick Look thumbnail once it lands — a screenshot or
    /// a PDF reads at a glance instead of as one more document icon.
    @ViewState private var thumbnail: NSImage?

    var body: some View {
        Button {
            // A folder browses in place; ⌘-click (or a file) opens it.
            if entry.isDirectory, !NSEvent.modifierFlags.contains(.command) {
                actions.onDrillFolder?(entry.url)
            } else {
                actions.onOpen?(entry.url)
            }
        } label: {
            VStack(spacing: 5) {
                face
                    .frame(width: 40, height: 40)
                Text(entry.name)
                    .jrbarType(.caption).fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 4)
            }
            .frame(width: Self.width, height: Self.height)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(hovering ? DockChrome.plateHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.isDirectory ? "\(entry.name), folder" : entry.name)
        .accessibilityHint(entry.isDirectory ? "Browse this folder. Command-click opens it in Finder." : "Open this file.")
        // DockDoor's Folder Pop drag-out: the chip carries its own
        // file URL — dropping it on Finder or another app's tile is
        // the system's copy/move, never ours. The chip snapshot is the
        // drag preview. The click still opens; a drag only arms once
        // the press moves.
        .draggable(entry.url)
        // The chip's verbs past the click: reveal it, or stage it on the
        // notch Shelf for the next drag — one app owns both surfaces.
        .contextMenu {
            Button("Open") { actions.onOpen?(entry.url) }
            Button("Show in Finder") { actions.onReveal?(entry.url) }
            if let send = actions.onSendToShelf {
                Divider()
                Button("Send to Shelf") { send(entry.url) }
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(entry.url.path)
        .task(id: entry.url) {
            thumbnail = nil
            guard !entry.isDirectory else { return }
            let image = await DockFolderThumbs.thumbnail(for: entry.url)
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }

    /// A Quick Look face is a picture of the file — it gets a still's
    /// corners and rim; a type icon is already its own shape.
    @ViewBuilder
    private var face: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(DockChrome.hairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        } else {
            Image(nsImage: entry.icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        }
    }
}

/// A folder pop with nothing to grid — loading aside: why, in a line,
/// and the one thing that fixes it.
private struct DockFolderNotice<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 2)
        .frame(minWidth: 320)
    }
}

/// Quick Look thumbnails for Folder Pop chips — the Shelf tray's
/// generator path, asked off the main thread, one ask per file and
/// remembered for a few minutes so a second hover never regenerates.
/// A file Quick Look can't draw keeps its type icon.
@MainActor
enum DockFolderThumbs {
    private static var cache: [String: (image: NSImage, at: Date)] = [:]
    static let lifetime: TimeInterval = 300
    static let cacheCap = 240

    static func thumbnail(for url: URL) async -> NSImage? {
        let now = Date()
        if let hit = cache[url.path], now.timeIntervalSince(hit.at) < lifetime { return hit.image }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = await generate(url, scale: scale) else { return nil }
        if cache.count >= cacheCap {
            cache = cache.filter { now.timeIntervalSince($0.value.at) < lifetime }
            if cache.count >= cacheCap { cache.removeAll() }
        }
        cache[url.path] = (image, now)
        return image
    }

    /// The generator's callback, read on its own queue — the
    /// representation isn't Sendable, the image is.
    nonisolated private static func generate(_ url: URL, scale: CGFloat) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: 34, height: 34), scale: scale,
                representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
    }
}

/// `draggable` only when a payload exists — a document-less card must
/// not eat the press that raises its window.
extension View {
    @ViewBuilder
    func draggableIfPresent(_ url: URL?) -> some View {
        if let url {
            self.draggable(url)
        } else {
            self
        }
    }
}

/// Middle-click, which SwiftUI has no gesture for: a bare NSView that
/// reports `otherMouseDown` on button 2 and otherwise lets every event
/// fall through to the card under it.
struct MiddleClickCatcher: NSViewRepresentable {
    var onMiddleClick: () -> Void

    func makeNSView(context: Context) -> MiddleClickView {
        let view = MiddleClickView()
        view.onMiddleClick = onMiddleClick
        return view
    }

    func updateNSView(_ view: MiddleClickView, context: Context) {
        view.onMiddleClick = onMiddleClick
    }
}

final class MiddleClickView: NSView {
    var onMiddleClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Claim the hit only while the event being dispatched is the
        // middle button — every other click and hover falls through to
        // the card face under us.
        guard let event = NSApp.currentEvent,
              event.type == .otherMouseDown || event.type == .otherMouseUp,
              event.buttonNumber == 2 else { return nil }
        return self
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onMiddleClick?() }
    }
}

/// A vertical trackpad flick on a card, which SwiftUI can't see: the
/// overlay claims only scroll events that are more vertical than
/// horizontal — the strip's horizontal scroll and every click pass
/// straight through to the card. Momentum coasts don't count; only a
/// real gesture's phases do.
struct SwipeCatcher: NSViewRepresentable {
    var onFlick: (DockEnhanceMath.SwipeAccumulator.Flick) -> Void

    func makeNSView(context: Context) -> SwipeCatcherView {
        let view = SwipeCatcherView()
        view.onFlick = onFlick
        return view
    }

    func updateNSView(_ view: SwipeCatcherView, context: Context) {
        view.onFlick = onFlick
    }
}

final class SwipeCatcherView: NSView {
    var onFlick: ((DockEnhanceMath.SwipeAccumulator.Flick) -> Void)?
    private var accumulator = DockEnhanceMath.SwipeAccumulator()

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .scrollWheel,
              event.momentumPhase == [],
              abs(event.deltaY) > abs(event.deltaX) else { return nil }
        return self
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase == [] else { return }
        if let flick = accumulator.note(
            deltaY: event.deltaY,
            inverted: event.isDirectionInvertedFromDevice,
            now: event.timestamp) {
            onFlick?(flick)
        }
    }
}

/// Which leading columns the compact list reserves — the agent's mark
/// and the minimized / full-screen glyph. Every row keeps a column any
/// row needs, so the titles line up.
struct DockCompactColumns: Equatable {
    var mark = false
    var state = false

    static func of(_ windows: [DockPreviewWindow], agents: [Int: DockAgentMark]) -> DockCompactColumns {
        DockCompactColumns(mark: windows.contains { agents[$0.id] != nil },
                           state: windows.contains { $0.minimized || $0.fullScreen == true })
    }
}

/// One row of the compact list — click raises, hover shows the verbs.
private struct DockPreviewCompactRow: View {
    /// A row's narrowest — the list never squeezes a title below it.
    let window: DockPreviewWindow
    var agent: DockAgentMark? = nil
    var selected = false
    var armedNote: String? = nil
    var columns = DockCompactColumns()
    var pad: CGFloat = DockPreviewMetrics.standard.listPadH
    @Environment(\.dockPreviewSize) private var previewSize
    let actions: DockPreviewActions
    @ViewState private var hovering = false

    var body: some View {
        Button { actions.pick(window) } label: {
            HStack(spacing: 8) {
                // A clear slot, not a Group: a Group hands its frame to
                // each child, so an empty one would take no room at all.
                if columns.mark {
                    Color.clear
                        .frame(width: 8, height: 8)
                        .overlay {
                            if let agent { DockAgentDot(mark: agent, size: 8) }
                        }
                }
                if columns.state {
                    Color.clear
                        .frame(width: 11, height: 11)
                        .overlay {
                            if window.minimized {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                            } else if window.fullScreen == true {
                                Image(systemName: "arrow.up.right.and.arrow.down.left")
                            }
                        }
                        .jrbarType(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                Text(armedNote ?? window.title)
                    .font(.system(size: 12.5, weight: armedNote == nil ? .regular : .semibold))
                    .foregroundStyle(window.minimized && armedNote == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 10)
                if hovering {
                    HStack(spacing: 4) {
                        DockRoundVerb(symbol: "xmark", tint: DockChrome.stop, label: "Close window", size: 20) {
                            actions.performWindowAction(window, actions.onClose)
                        }
                        DockRoundVerb(symbol: window.minimized ? "arrow.up.left.and.arrow.down.right" : "minus",
                                      tint: DockChrome.caution,
                                      label: window.minimized ? "Bring back" : "Minimize", size: 20) {
                            actions.performWindowAction(window, actions.onMinimize)
                        }
                        if let fullScreen = window.fullScreen {
                            DockRoundVerb(symbol: fullScreen ? "arrow.down.left.and.arrow.up.right"
                                                             : "arrow.up.right.and.arrow.down.left",
                                          tint: DockChrome.go,
                                          label: fullScreen ? "Leave full screen" : "Full screen", size: 20) {
                                actions.performWindowAction(window, actions.onFullScreen)
                            }
                        }
                    }
                    .transition(.opacity)
                } else if armedNote == nil, let agent {
                    // What the agent in this window is doing, where the
                    // verbs stand on hover.
                    Text(agent.statusLine)
                        .font(.system(size: 11, weight: agent.isWaiting ? .semibold : .regular))
                        .foregroundStyle(agent.isWaiting ? AnyShapeStyle(agent.accent) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .frame(maxWidth: 130, alignment: .trailing)
                }
            }
            .padding(.horizontal, pad)
            .frame(maxWidth: .infinity)
            .frame(height: previewSize.rowHeight)
            .background(plate)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(MiddleClickCatcher { actions.performWindowAction(window, actions.onClose) })
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(window.title)
    }

    @ViewBuilder
    private var plate: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if selected {
            shape.fill(Color.accentColor.opacity(0.18))
        } else if hovering {
            shape.fill(DockChrome.plateHover)
        } else if armedNote != nil, let agent {
            shape.fill(agent.accent.opacity(0.14))
        }
    }
}

/// What the Dock's ask row puts where the verbs go, read off the ask
/// and the desk alone so it can be checked without drawing anything.
enum DockAskVerbSet: Equatable {
    /// The desk's last line, a sent answer or its refusal.
    case note(String)
    /// JR-Bar already answered this ask: the row says so in the panel's
    /// words and draws no verb, not even a disabled one.
    case decided(line: String)
    /// A held question: Deny and its options.
    case choices
    /// Deny, Always Allow where offered, Approve.
    case verdicts
    /// The ask cannot be answered from JR-Bar (a view-only agent, a host
    /// that cannot prove its focused tab, or a typed reply): the row says
    /// where to answer it and draws no verb, not even a disabled one.
    case elsewhere
    /// No ask or no desk: nothing to draw.
    case none

    /// The desk's line about the last answer comes first; then, whatever
    /// else the ask says, the decided line for an answered one; then a
    /// held question's options; then the verdicts. With no desk there is
    /// nothing to answer through, so nothing is drawn.
    static func resolve(ask: CoreAsk?, hasDesk: Bool, note: String?) -> DockAskVerbSet {
        if let note { return .note(note) }
        if let line = ask?.decidedLine { return .decided(line: line) }
        guard let ask, hasDesk else { return .none }
        if AskVerbs.chooses(ask) { return .choices }
        return ask.canAnswer && !ask.wantsTextReply ? .verdicts : .elsewhere
    }
}

/// A waiting agent this app hosts, answerable from the Dock: the
/// provider's tile, the session and what it asks — what it would run,
/// and the red mark when that is destructive — then Deny / Approve.
/// Where the hook holds the ask, Always Allow sits between them, and a
/// held question offers its options instead of Approve. Every verb goes
/// through the shared answer desk the panel and the notch answer
/// through, so one pending set dims every copy of the buttons and the
/// line under the ask is the desk's. Where the daemon says the ask can't
/// be answered from outside, the row says where to answer it and draws no
/// verb; once answered, the row shows the daemon's verdict instead of
/// guessing success. An ask JR-Bar already answered draws no verb at all,
/// not even a disabled one: the row says the agent is being waited for.
/// With no desk published the row draws no verbs.
private struct DockAskRow: View {
    let mark: DockAgentMark
    let actions: DockPreviewActions
    var metrics = DockPreviewMetrics.standard

    /// The mark's ask with its session filled in, for the desk.
    private var ask: CoreAsk? {
        mark.ask.map { ask in
            var ask = ask
            if ask.session == nil { ask.session = mark.sessionID }
            return ask
        }
    }

    private var destructive: Bool { ask?.isDestructive == true }

    var body: some View {
        let desk = AskAnswerDesk.shared
        let busy = desk?.isPending(mark.sessionID) ?? false
        HStack(spacing: 10) {
            ProviderTile(style: ProviderStyle.style(for: mark.provider), size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(mark.label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    if destructive {
                        AskRiskMark(size: 10)
                    }
                }
                Text(mark.statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let preview = ask?.previewLine {
                    AskPreviewLine(text: preview, size: 10,
                                   tint: destructive ? Tone.failure.color.opacity(0.9) : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.06)))
                }
            }
            .frame(maxWidth: 280, alignment: .leading)
            Spacer(minLength: 10)
            HStack(spacing: 6) {
                verbs(desk: desk, busy: busy)
            }
        }
        .padding(.horizontal, metrics.rowPadH)
        .padding(.vertical, metrics.rowPadV)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(mark.accent.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(mark.accent.opacity(destructive ? 0 : 0.28), lineWidth: 1))
        .overlay {
            if destructive {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Tone.failure.color.opacity(0.55), lineWidth: 1)
            }
        }
        .help("\(mark.providerName) · \(mark.label)\n\(mark.cwd ?? "")")
    }

    @ViewBuilder
    private func verbs(desk: AskAnswerDesk?, busy: Bool) -> some View {
        let plan = DockAskVerbSet.resolve(ask: ask, hasDesk: desk != nil,
                                          note: desk?.note(for: mark.sessionID)?.text)
        switch plan {
        case .note(let line), .decided(let line):
            // The desk's line about the last answer, or the words for an
            // ask JR-Bar already answered: a line where the verbs were,
            // never a disabled button pointing at another window.
            Text(line)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .choices:
            if let ask, let desk {
                Button("Deny") { answer(ask, .deny, on: desk) }
                    .buttonStyle(DockCapsuleButtonStyle())
                    .disabled(busy)
                DockAskChoices(ask: ask, desk: desk, accent: mark.accent, busy: busy)
            }
        case .elsewhere:
            Text(AskAnswerHost.line(host: nil))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .verdicts:
            if let ask, let desk {
                Button("Deny") { answer(ask, .deny, on: desk) }
                    .buttonStyle(DockCapsuleButtonStyle())
                    .disabled(busy)
                if AskVerbs.alwaysAllows(ask) {
                    Button("Always Allow") { answer(ask, .always, on: desk) }
                        .buttonStyle(DockCapsuleButtonStyle())
                        .disabled(busy)
                        .help("Approve, and let \(mark.providerName) remember the rule it offered")
                }
                Button("Approve") { answer(ask, .approve, on: desk) }
                    .buttonStyle(DockCapsuleButtonStyle(prominent: true, tint: mark.accent))
                    .disabled(busy)
                    .help("Approve — \(mark.providerName) carries on")
            }
        case .none:
            EmptyView()
        }
    }

    /// One click's verdict, through the desk; once it has answered, the
    /// panel refits around the desk's line.
    private func answer(_ ask: CoreAsk, _ verdict: AskVerdict, on desk: AskAnswerDesk) {
        Task {
            await desk.answer(ask, verdict)
            actions.onAnswered?()
        }
    }
}

/// A held question's options on the Dock's ask row: a button each for
/// one short single-pick question — a click is the answer — else one
/// menu that holds them, with Send once each question has a pick.
private struct DockAskChoices: View {
    let ask: CoreAsk
    let desk: AskAnswerDesk
    let accent: Color
    let busy: Bool

    private var choices: [CoreAskChoice] { ask.decision?.choices ?? [] }

    var body: some View {
        switch AskChoiceLayout.layout(choices) {
        case .buttons(let labels):
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                option(label)
                    .buttonStyle(DockCapsuleButtonStyle(prominent: index == 0, tint: accent))
            }
        case .menu:
            let picks = desk.picks(for: ask)
            Menu(AskChoiceLayout.menuTitle(choices, picks: picks)) {
                AskChoiceMenuItems(choices: choices, picks: picks,
                                   pick: { desk.pick($0, in: $1, of: ask) },
                                   send: { Task { await desk.sendPicks(for: ask) } })
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(busy)
            if picks.isComplete(choices), choices.count > 1 || choices.first?.multi == true {
                Button("Send") { Task { await desk.sendPicks(for: ask) } }
                    .buttonStyle(DockCapsuleButtonStyle(prominent: true, tint: accent))
                    .disabled(busy)
            }
        }
    }

    private func option(_ label: String) -> some View {
        Button(label) {
            if let choice = choices.first { desk.pick(label, in: choice, of: ask) }
        }
        .disabled(busy)
        .help("Answer “\(label)”")
    }
}

/// The player tile's Now Playing row — DockDoor's media widget: the
/// artwork, the title over the artist, and the transport the shared
/// MediaRemote feed sends for real.
struct DockMediaRow: View {
    @Environment(\.dockPreviewSize) private var previewSize
    let media: AlcoveMedia
    let actions: DockPreviewActions
    var appName = "Now playing"

    var body: some View {
        DockWidget(title: appName, symbol: "music.note", fillsSize: previewSize == .small) {
            if previewSize == .small {
                artwork.overlay(alignment: .bottom) {
                    HStack {
                        Text(media.title).jrbarType(.headline).lineLimit(2)
                        playButton
                    }
                    .padding(JRBarTokens.Space.sm)
                    .background(.regularMaterial)
                }
            } else if previewSize == .medium {
                HStack(spacing: JRBarTokens.Space.md) {
                    artwork.frame(width: previewSize.artwork, height: previewSize.artwork)
                    VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
                        words
                        progress
                        transport
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            } else {
                VStack(spacing: JRBarTokens.Space.sm) {
                    artwork.frame(width: previewSize.artwork, height: previewSize.artwork)
                    words
                    progress
                    transport
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var artwork: some View {
        GeometryReader { geometry in
            Group {
                if let data = media.artworkData, let image = ArtworkThumbCache.shared.image(for: data) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.primary.opacity(0.06))
                        .overlay { Image(systemName: "music.note").jrbarType(.title).foregroundStyle(.secondary) }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
    }

    private var words: some View {
        VStack(alignment: previewSize == .large ? .center : .leading, spacing: 0) {
            Text(media.title).jrbarType(.title3).lineLimit(2)
            if let artist = media.artist { Text(artist).foregroundStyle(.secondary).lineLimit(1) }
            if previewSize == .large, let album = media.album { Text(album).jrbarType(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    @ViewBuilder private var progress: some View {
        if let duration = media.duration, duration > 0, media.elapsed != nil {
            DockMediaScrubber(media: media, duration: duration, showsTimes: previewSize == .large) { actions.onMediaSeek?($0) }
        }
    }

    private var playButton: some View {
        DockTransportButton(symbol: media.playing ? "pause.fill" : "play.fill", label: media.playing ? "Pause" : "Play", size: 16) {
            actions.onMediaCommand?(.togglePlayPause)
        }
    }

    private var transport: some View {
        HStack(spacing: JRBarTokens.Space.sm) {
            DockTransportButton(symbol: "backward.fill", label: "Previous track") { actions.onMediaCommand?(.previousTrack) }
            playButton
            DockTransportButton(symbol: "forward.fill", label: "Next track") { actions.onMediaCommand?(.nextTrack) }
        }
    }
}

/// A transport glyph with a round plate under the pointer.
private struct DockTransportButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 12
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(hovering ? DockChrome.plateHover : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The player row's playhead: elapsed, a thin continuous track, the
/// length. A click or drag on the track seeks there. The playhead
/// advances between feed pushes from the sampled elapsed + timestamp —
/// once a second while playing; a paused one only re-reads its feed.
private struct DockMediaScrubber: View {
    let media: AlcoveMedia
    let duration: Double
    var showsTimes = true
    let onSeek: (Double) -> Void
    @ViewState private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: media.playing ? 1 : 60)) { context in
            let elapsed = media.liveElapsed(at: context.date) ?? 0
            let fraction = dragFraction ?? min(1, max(0, elapsed / duration))
            HStack(spacing: 8) {
                if showsTimes {
                    Text(DockEnhanceMath.clock(dragFraction.map { $0 * duration } ?? elapsed))
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 34, alignment: .leading)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(Color.primary.opacity(0.7))
                            .frame(width: max(4, geo.size.width * fraction))
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFraction = min(1, max(0, value.location.x / max(1, geo.size.width)))
                        }
                        .onEnded { value in
                            let f = min(1, max(0, value.location.x / max(1, geo.size.width)))
                            dragFraction = nil
                            onSeek(f * duration)
                        })
                }
                .frame(height: 12)
                if showsTimes {
                    Text(DockEnhanceMath.clock(duration))
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 34, alignment: .trailing)
                }
            }
            .jrbarType(.caption).fontWeight(.medium).monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .help("Drag to seek")
    }
}
