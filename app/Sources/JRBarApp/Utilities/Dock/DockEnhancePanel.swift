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
    var onMediaSeek: (@MainActor (Double) -> Void)?
    /// The synced lyrics the notch Shelf already holds for the playing
    /// track — read, never fetched: nil unless the Shelf has them.
    @ObservationIgnored var lyrics: @MainActor () -> SyncedLyrics? = { nil }
    /// The calendar row's "Show events" — asks for the grant.
    var onCalendarAuth: (@MainActor () -> Void)?
    /// The calendar row's "Join" — opens the meeting link.
    var onCalendarJoin: (@MainActor (URL?) -> Void)?
    /// A document card dropped on another app's preview — the
    /// controller opens the file in the previewed app, DockDoor's
    /// drag-between-previews handoff. False means the drop fell
    /// through (a non-document, or an app that can't take it).
    var onDocumentDrop: (@MainActor (URL) -> Bool)?
    /// An ask row's Approve (true) / Deny (false).
    var onAnswer: (@MainActor (CoreAsk, Bool) -> Void)?
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
}

/// The Macs' displays as the Move To menu names them.
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
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                             ?? NSScreen.screens.first)?.frame.height ?? 0
        let centre = CGPoint(x: frame.midX, y: primaryHeight - frame.midY)
        return displays.filter { !$0.screen.frame.contains(centre) }
    }
}

/// The Enhance preview's window: a borderless, nonactivating glass
/// panel (it floats, so the material rule allows glass) just above
/// Apple's Dock — dock-window level + 1 so a magnified icon can't
/// cover it — all-spaces like the Dock. The controller positions it;
/// the view reads `DockPreviewContent`, so late thumbnails re-render
/// without a re-present.
@MainActor
final class DockPreviewPanel: NSPanel {
    let actions: DockPreviewActions
    static let cornerRadius: CGFloat = 16

    private let hosting: NSHostingView<DockPreviewView>

    init(content: DockPreviewContent) {
        actions = DockPreviewActions(content: content)
        hosting = NSHostingView(rootView: DockPreviewView(content: content, actions: actions))
        // The panel is sized from the content's intrinsic size and the
        // hosting view fills the glass — a hosting view left at its
        // initial frame drew the content in the panel's bottom-left
        // corner, which read as "the preview is off-centre".
        hosting.sizingOptions = [.intrinsicContentSize]
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 240, height: 96))
        glass.cornerRadius = Self.cornerRadius
        glass.style = .regular
        hosting.frame = glass.bounds
        hosting.autoresizingMask = [.width, .height]
        glass.contentView = hosting
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 96),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = GlassBackdrop.rounded(glass, cornerRadius: Self.cornerRadius)
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
        // Just under the Dock's own level: above every app window, but
        // a magnified icon that swells into the panel's band still
        // draws over it and still takes its click. One level over the
        // Dock made the upper half of every magnified icon dead.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        // Out of screen recordings and window captures — and out of its
        // own app's window list, so hovering JR-Bar's tile never
        // previews the preview. JRBAR_CAPTURE_CARD is the dev escape.
        if ProcessInfo.processInfo.environment["JRBAR_CAPTURE_CARD"] == nil {
            sharingType = .none
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The size the content wants, clamped so a many-windowed app
    /// can't sprawl the panel across the screen.
    func fittingSize() -> CGSize {
        hosting.invalidateIntrinsicContentSize()
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.intrinsicContentSize
        let limit = (NSScreen.main?.frame.width ?? 1200) - 40
        return CGSize(width: min(fit.width, min(720, limit)), height: fit.height)
    }

    /// Show at `target`, animating a short springy drift up off the
    /// dock — a 220 ms ease with a hint of overshoot, under the 250 ms
    /// cap, so the panel visibly tracks which icon summoned it. A
    /// retarget while visible just slides to the new anchor; dismiss
    /// stays instant (a leave means leave), and Reduce Motion snaps.
    func present(frame target: CGRect, dockedAt edge: DockEdge) {
        if isVisible, alphaValue > 0.5 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(target, display: true)
            }
            orderFrontRegardless()
            return
        }
        let drift: CGFloat = 10
        var start = target
        switch edge {
        case .bottom: start.origin.y -= drift
        case .left: start.origin.x -= drift
        case .right: start.origin.x += drift
        }
        setFrame(start, display: false)
        alphaValue = 0
        orderFrontRegardless()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0.03 : 0.22
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.25, 1.3, 0.4, 1)
            animator().alphaValue = 1
            animator().setFrame(target, display: true)
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
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        title = "JR-Bar Dock Toast"
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show `text` over `tile` (AppKit space) off the Dock's `edge`,
    /// for `duration`, then fade.
    func show(_ text: String, over tile: CGRect, edge: DockEdge, screen: CGRect,
              duration: TimeInterval = 1.4) {
        model.text = text
        hosting.invalidateIntrinsicContentSize()
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.intrinsicContentSize
        let size = CGSize(width: min(max(fit.width, 80), 420), height: max(fit.height, 28))
        setFrame(DockEnhanceMath.panelFrame(anchor: tile, edge: edge, size: size,
                                            screen: screen, gap: 10), display: true)
        fadeWork?.cancel()
        alphaValue = 1
        orderFrontRegardless()
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
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }
}

/// The panel's body: app header with its verbs, then the window cards
/// — thumbnail when Screen Recording granted one, the app icon
/// otherwise — each with hover-revealed close and minimize buttons.
/// Clicks report through `actions`.
struct DockPreviewView: View {
    let content: DockPreviewContent
    let actions: DockPreviewActions
    /// A document card held over the panel — the highlight ring.
    @ViewState private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !content.folderTrail.isEmpty {
                    Button { actions.onFolderBack?() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Back to \(content.folderTrail.dropLast().last?.lastPathComponent ?? content.appName)")
                    .accessibilityLabel("Back")
                }
                if let icon = content.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 26, height: 26)
                        .overlay(alignment: .topTrailing) {
                            // The Dock tile's own badge, on the icon the
                            // way the tile draws it — unread counts,
                            // alert dots, the works.
                            if let badge = content.badge {
                                Text(badge)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.red, in: Capsule())
                                    .offset(x: 7, y: -5)
                            }
                        }
                        // Beside the Dock's badge, the agent's: the most
                        // urgent session this app hosts, as a mark.
                        .overlay(alignment: .bottomTrailing) {
                            if let agent = content.appAgents.first {
                                DockAgentDot(mark: agent, size: 8)
                                    .offset(x: 3, y: 3)
                            }
                        }
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(appTitle.base)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let channel = appTitle.channel {
                            Text(channel)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 240, alignment: .leading)
                // Exclude an app from where it bothers you — the card's
                // list, one right-click nearer.
                .contextMenu {
                    if content.bundleID != nil, content.folderURL == nil {
                        Button("Never Preview \(content.appName)") { actions.onExcludeApp?() }
                    }
                }
                Spacer(minLength: 8)
                // DockDoor's compact header: traffic-light circles, not
                // spelled-out buttons — the row reclaims ~110pt of width.
                if let shown = content.folderShown {
                    headerVerb("folder", tint: .accentColor,
                               label: "Open \(shown.lastPathComponent) in Finder") {
                        actions.onOpen?(shown)
                    }
                } else if content.isRunning {
                    HStack(spacing: 4) {
                        headerVerb(content.stillRunning ? "bolt.horizontal.fill" : "power",
                                   tint: Color(red: 0.93, green: 0.34, blue: 0.32),
                                   label: content.stillRunning ? "Force quit \(content.appName)"
                                                               : "Quit \(content.appName)") {
                            actions.onQuitApp?()
                        }
                        if content.windows.contains(where: { !$0.minimized }), content.windows.count > 1 {
                            headerVerb("minus", tint: Color(red: 0.96, green: 0.73, blue: 0.20),
                                       label: "Minimise every \(content.appName) window") {
                                actions.onMinimizeAll?()
                            }
                        }
                        if content.windows.count > 1 {
                            headerVerb("xmark", tint: Color(red: 0.93, green: 0.34, blue: 0.32),
                                       label: "Close every \(content.appName) window (app stays running)") {
                                actions.onCloseAll?()
                            }
                        }
                        headerVerb("eye.slash", tint: Color(red: 0.96, green: 0.73, blue: 0.20),
                                   label: "Hide \(content.appName) (⌘H)") {
                            actions.onHideApp?()
                        }
                        headerVerb("plus", tint: Color(red: 0.36, green: 0.78, blue: 0.36),
                                   label: "New window in \(content.appName)") {
                            actions.onNewWindow?()
                        }
                    }
                }
            }
            if let note = content.headerNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !content.askRows.isEmpty {
                Divider()
                ForEach(content.askRows) { mark in
                    DockAskRow(mark: mark, note: content.askNotes[mark.sessionID],
                               answering: content.answering.contains(mark.sessionID),
                               actions: actions)
                }
            }
            if let media = content.media {
                Divider()
                DockMediaRow(media: media, actions: actions)
            }
            if !content.calendarEvents.isEmpty || content.calendarNeedsAuth {
                Divider()
                DockCalendarRow(events: content.calendarEvents,
                                freeUntil: content.calendarFreeUntil,
                                needsAuth: content.calendarNeedsAuth,
                                actions: actions)
            }
            if content.folderURL != nil {
                Divider()
                switch content.folderState {
                case .loading:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                case .denied:
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                        Text("No access to this folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                                actions.onOpen?(url)
                            }
                        }
                        .controlSize(.small)
                        .help("Grant folder access in Privacy & Security")
                    }
                    .padding(.vertical, 4)
                case .failed:
                    Text("Couldn't read this folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                case .ready:
                    if content.folderEntries.isEmpty {
                        Text("Empty")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        // Apple's Grid stack: five across, four rows
                        // before it scrolls; a folder chip browses in.
                        let grid = DockEnhanceMath.folderGrid(count: content.folderEntries.count)
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(DockFolderChip.width), spacing: 8),
                                                     count: grid.columns),
                                      spacing: 8) {
                                ForEach(content.folderEntries) { entry in
                                    DockFolderChip(entry: entry, actions: actions)
                                }
                            }
                            .padding(2)
                        }
                        .frame(width: CGFloat(grid.columns) * (DockFolderChip.width + 8) + 4,
                               height: CGFloat(grid.rows) * (DockFolderChip.height + 8) + 4)
                    }
                }
            } else if !content.windows.isEmpty {
                Divider()
                if content.compact {
                    DockPreviewCompactList(windows: content.windows, agents: content.agents,
                                           armedWindowID: content.armedWindowID,
                                           armedNote: content.armedNote, actions: actions)
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
                            HStack(spacing: 8) { cards }
                                .padding(2)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) { cards }
                                    .padding(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(8)
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
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The window cards — shared between the centred-when-fits strip and
    /// the scrolling one, so both draw the same row.
    @ViewBuilder
    private var cards: some View {
        ForEach(content.windows) { window in
            DockPreviewCard(window: window, icon: content.icon,
                            size: DockEnhanceMath.cardSize(large: content.largeCards),
                            selected: window.id == content.selectedWindowID,
                            // A card whose title is just the app name again
                            // — "Claude" under a header that already says
                            // Claude — reads as a second label, not a
                            // caption. The Dock's own bubble makes three.
                            showsTitle: window.title != content.appName
                                && window.title != appTitle.base,
                            agent: content.agents[window.id],
                            armedNote: content.armedWindowID == window.id ? content.armedNote : nil,
                            pulsed: content.pulsedWindowIDs.contains(window.id),
                            actions: actions)
        }
    }

    /// A header verb drawn as a macOS traffic light — a tinted circle
    /// with a glyph, like DockDoor's compact header controls. The disc
    /// itself is 13pt; the button keeps an 18pt hit area so the smaller
    /// face never costs the click. The label carries both the tooltip
    /// and the accessibility name since the button has no text.
    private func headerVerb(_ symbol: String, tint: Color, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(tint)
                .frame(width: 13, height: 13)
                .overlay {
                    Image(systemName: symbol)
                        // scaledToFit, not a font size: a 7pt symbol
                        // rides its text baseline and floats off the
                        // disc's centre; a resizable glyph centres in
                        // the box it is given.
                        .resizable()
                        .scaledToFit()
                        .frame(width: 7, height: 7)
                        .foregroundStyle(.white)
                }
                .frame(width: 18, height: 18)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

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

    private var subtitle: String {
        if content.folderURL != nil {
            switch content.folderState {
            case .loading: return "Folder"
            case .denied: return "No access"
            case .failed: return "Folder"
            case .ready:
                return content.folderEntries.count == 1 ? "1 item" : "\(content.folderEntries.count) items"
            }
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

/// One window's card: the thumbnail (or the icon), the title, and the
/// verbs that appear on hover — × closes, – minimizes or restores.
/// The face is the raise target.
struct DockPreviewCard: View {
    let window: DockPreviewWindow
    let icon: NSImage?
    let size: CGSize
    var selected = false
    /// nil-equivalent title rows are suppressed — the header already
    /// names the app, and the Dock's own bubble does too.
    var showsTitle = true
    /// The agent session this window hosts — its mark, its ring when it
    /// waits on you, and what it is doing under the title.
    var agent: DockAgentMark? = nil
    /// A guarded close's first press: the card rings in the agent's
    /// colour and this line replaces the title until it lapses.
    var armedNote: String? = nil
    /// A shake or flick just moved this window — the card dips a beat.
    var pulsed = false
    let actions: DockPreviewActions
    @ViewState private var hovering = false
    @ViewState private var shake = DockEnhanceMath.ShakeDetector()

    var body: some View {
        VStack(spacing: 4) {
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
                .contextMenu {
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
                if hovering {
                    HStack(spacing: 4) {
                        verb("xmark", help: "Close window") { actions.performWindowAction(window, actions.onClose) }
                        verb(window.minimized ? "arrow.up.left.and.arrow.down.right" : "minus",
                             help: window.minimized ? "Bring back" : "Minimize") {
                            actions.performWindowAction(window, actions.onMinimize)
                        }
                        if let fullScreen = window.fullScreen {
                            verb(fullScreen ? "arrow.down.left.and.arrow.up.right"
                                            : "arrow.up.right.and.arrow.down.left",
                                 help: fullScreen ? "Leave full screen" : "Full screen") {
                                actions.performWindowAction(window, actions.onFullScreen)
                            }
                        }
                    }
                    .padding(5)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let agent {
                    DockAgentDot(mark: agent)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            if let armedNote {
                Text(armedNote)
                    .font(.caption2.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: size.width)
            } else if showsTitle || window.minimized {
                HStack(spacing: 3) {
                    if window.minimized {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    if showsTitle {
                        Text(window.title)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: size.width)
            }
            if armedNote == nil, let agent {
                // What the agent in this window is doing — the fact the
                // panel's row would show, one quiet line.
                Text(agent.statusLine)
                    .font(.system(size: 9, weight: agent.isWaiting ? .semibold : .regular))
                    .foregroundStyle(agent.isWaiting ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: size.width)
            }
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quaternary.opacity(0.45))))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor, lineWidth: selected ? 2 : 0))
        // A waiting agent's card is outlined in its provider's colour; a
        // guarded close's first press thickens it.
        .overlay {
            if let agent, agent.isWaiting || armedNote != nil {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(agent.accent.opacity(0.9), lineWidth: armedNote != nil ? 3 : 1.5)
                    .padding(selected ? 3 : 0)
                    .allowsHitTesting(false)
            }
        }
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

    @ViewBuilder
    private var face: some View {
        Group {
            if let thumbnail = window.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    // A transparent-window capture still needs a floor,
                    // but a black wash fills the .fit letterbox too and
                    // reads as a dead band atop the image. The card's
                    // own quiet surface backs the margins instead.
                    .background(.quaternary.opacity(0.5))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                    VStack(spacing: 5) {
                        if let icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 34, height: 34)
                        }
                        Text(window.minimized ? "Minimized" : "No preview")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: size.width, height: size.height)
            }
        }
        .opacity(window.minimized ? 0.6 : 1)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }

    private func verb(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The past-`compactListLimit` face: one dense row per window — title,
/// minimized mark, the same hover verbs as a card — instead of
/// thumbnails a many-windowed app would only smear. Compact also
/// means no captures: nothing here ever flashes the recording dot.
struct DockPreviewCompactList: View {
    let windows: [DockPreviewWindow]
    var agents: [Int: DockAgentMark] = [:]
    var armedWindowID: Int? = nil
    var armedNote: String? = nil
    let actions: DockPreviewActions

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 2) {
                ForEach(windows) { window in
                    DockPreviewCompactRow(window: window, agent: agents[window.id],
                                          armedNote: armedWindowID == window.id ? armedNote : nil,
                                          actions: actions)
                }
            }
            .padding(2)
        }
        .frame(maxHeight: 264)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// One chip in a folder pop: the type icon over the name — a click
/// opens the file. Directories read with a subtle folder badge so a
/// pop's nesting is visible at a glance.
private struct DockFolderChip: View {
    let entry: DockFolderEntry
    let actions: DockPreviewActions
    /// The chip's box — the grid lays out on it.
    static let width: CGFloat = 96
    static let height: CGFloat = 64
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
            VStack(spacing: 4) {
                Image(nsImage: thumbnail ?? entry.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 34, height: 34)
                Text(entry.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: Self.width - 4, height: Self.height - 12)
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quaternary.opacity(0.45))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            guard !entry.isDirectory else { return }
            thumbnail = await DockFolderThumbs.thumbnail(for: entry.url)
        }
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

/// One row of the compact list — click raises, hover shows the verbs.
private struct DockPreviewCompactRow: View {
    let window: DockPreviewWindow
    var agent: DockAgentMark? = nil
    var armedNote: String? = nil
    let actions: DockPreviewActions
    @ViewState private var hovering = false

    var body: some View {
        Button { actions.pick(window) } label: {
            HStack(spacing: 6) {
                if let agent {
                    DockAgentDot(mark: agent, size: 7)
                }
                if window.minimized {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                if window.fullScreen == true {
                    Image(systemName: "arrow.up.right.and.arrow.down.left")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                Text(armedNote ?? window.title)
                    .font(armedNote == nil ? .callout : .callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if hovering {
                    HStack(spacing: 4) {
                        verb("xmark", help: "Close window") { actions.performWindowAction(window, actions.onClose) }
                        verb(window.minimized ? "arrow.up.left.and.arrow.down.right" : "minus",
                             help: window.minimized ? "Bring back" : "Minimize") {
                            actions.performWindowAction(window, actions.onMinimize)
                        }
                        if let fullScreen = window.fullScreen {
                            verb(fullScreen ? "arrow.down.left.and.arrow.up.right"
                                            : "arrow.up.right.and.arrow.down.left",
                                 help: fullScreen ? "Leave full screen" : "Full screen") {
                                actions.performWindowAction(window, actions.onFullScreen)
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: 300)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(MiddleClickCatcher { actions.performWindowAction(window, actions.onClose) })
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(window.title)
    }

    private func verb(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A waiting agent this app hosts, answerable from the Dock: the mark,
/// the session and what it asks — what it would run, and the red mark
/// when that is destructive — then Deny / Approve through the same
/// `answer_ask` the panel sends (the daemon raises the terminal first,
/// or the agent's own hook takes it). Where the hook holds the ask,
/// Always Allow sits between them, and a held question offers its
/// options instead of Approve; both go through the shared answer desk.
/// Where the daemon says the ask can't be answered from outside, the
/// buttons disable and say where it can be; once answered, the row
/// shows the daemon's verdict instead of guessing success.
private struct DockAskRow: View {
    let mark: DockAgentMark
    let note: String?
    let answering: Bool
    let actions: DockPreviewActions

    /// The mark's ask with its session filled in, for the desk.
    private var ask: CoreAsk? {
        mark.ask.map { ask in
            var ask = ask
            if ask.session == nil { ask.session = mark.sessionID }
            return ask
        }
    }

    var body: some View {
        let desk = AskAnswerDesk.shared
        let busy = answering || (desk?.isPending(mark.sessionID) ?? false)
        HStack(spacing: 8) {
            DockAgentDot(mark: mark)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(mark.label)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if ask?.isDestructive == true {
                        AskRiskMark(size: 10)
                    }
                }
                Text(mark.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let preview = ask?.previewLine {
                    AskPreviewLine(text: preview, size: 10.5,
                                   tint: ask?.isDestructive == true ? Color.red.opacity(0.85) : .secondary)
                }
            }
            .frame(maxWidth: 260, alignment: .leading)
            Spacer(minLength: 8)
            if let line = note ?? desk?.note(for: mark.sessionID)?.text {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let ask, let desk, AskVerbs.chooses(ask) {
                Button("Deny") { Task { await desk.answer(ask, .deny) } }
                    .controlSize(.small)
                    .disabled(busy)
                DockAskChoices(ask: ask, desk: desk, accent: mark.accent, busy: busy)
            } else if let ask {
                let answerable = ask.canAnswer && !ask.wantsTextReply
                Button("Deny") { actions.onAnswer?(ask, false) }
                    .controlSize(.small)
                    .disabled(!answerable || busy)
                if let desk, answerable, AskVerbs.alwaysAllows(ask) {
                    Button("Always Allow") { Task { await desk.answer(ask, .always) } }
                        .controlSize(.small)
                        .disabled(busy)
                        .help("Approve, and let \(mark.providerName) remember the rule it offered")
                }
                Button("Approve") { actions.onAnswer?(ask, true) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(mark.accent)
                    .disabled(!answerable || busy)
                    .help(answerable ? "Approve — \(mark.providerName) carries on"
                                     : "Answer this one in the session's window")
            }
        }
        .padding(.vertical, 2)
        .help("\(mark.providerName) · \(mark.label)\n\(mark.cwd ?? "")")
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
                if index == 0 {
                    option(label).buttonStyle(.borderedProminent).tint(accent)
                } else {
                    option(label)
                }
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
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(busy)
            }
        }
    }

    private func option(_ label: String) -> some View {
        Button(label) {
            if let choice = choices.first { desk.pick(label, in: choice, of: ask) }
        }
        .controlSize(.small)
        .disabled(busy)
        .help("Answer “\(label)”")
    }
}

/// The player tile's Now Playing row — DockDoor's media widget: the
/// artwork, "Title — Artist", and the transport the shared MediaRemote
/// feed sends for real. Paused state dims the play glyph.
private struct DockMediaRow: View {
    let media: AlcoveMedia
    let actions: DockPreviewActions

    var body: some View {
        VStack(spacing: 3) {
            transport
            // Seek without opening the player: a continuous hairline of
            // the playhead, the times either side. Only when the source
            // named both a playhead and a length — never a bar at 0:00.
            if let duration = media.duration, duration > 0, media.elapsed != nil {
                DockMediaScrubber(media: media, duration: duration) { actions.onMediaSeek?($0) }
            }
            // The line the notch Shelf is singing — its own LRCLIB cache,
            // stepped to this row's playhead; no lookup of the Dock's own.
            // Silent between stamps and whenever the Shelf has no lyrics.
            if let synced = actions.lyrics() {
                TimelineView(.periodic(from: .now, by: media.playing ? 0.5 : 30)) { context in
                    if let line = synced.line(at: media.liveElapsed(at: context.date) ?? 0) {
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 8) {
            Group {
                if let data = media.artworkData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: "music.note")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(media.displayLine)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Button { actions.onMediaCommand?(.previousTrack) } label: {
                    Image(systemName: "backward.fill")
                }
                .help("Previous track")
                Button { actions.onMediaCommand?(.togglePlayPause) } label: {
                    Image(systemName: media.playing ? "pause.fill" : "play.fill")
                }
                .help(media.playing ? "Pause" : "Play")
                Button { actions.onMediaCommand?(.nextTrack) } label: {
                    Image(systemName: "forward.fill")
                }
                .help("Next track")
            }
            .font(.system(size: 12))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help(media.displayLine)
    }
}

/// The player row's playhead: elapsed, a thin continuous track, the
/// length. A click or drag on the track seeks there. The playhead
/// advances between feed pushes from the sampled elapsed + timestamp.
private struct DockMediaScrubber: View {
    let media: AlcoveMedia
    let duration: Double
    let onSeek: (Double) -> Void
    @ViewState private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = media.liveElapsed(at: context.date) ?? 0
            let fraction = dragFraction ?? min(1, max(0, elapsed / duration))
            HStack(spacing: 6) {
                Text(DockEnhanceMath.clock(dragFraction.map { $0 * duration } ?? elapsed))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(.secondary)
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                    .frame(height: 3)
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
                Text(DockEnhanceMath.clock(duration))
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .help("Drag to seek")
    }
}

/// The calendar row — DockDoor's calendar widget, HyperDock's list.
/// On the Calendar tile: the rest of today (up to three, each with its
/// own Join) and a quiet "Free until 3:30" when nothing is on now; on a
/// meeting app's tile, the one event whose link opens there. The row
/// only exists when the grant already covers it or is still unasked
/// ("Show events" is the explicit opt-in, never a prompt from a bare
/// hover).
private struct DockCalendarRow: View {
    let events: [ShelfCalendarModel.Event]
    let freeUntil: Date?
    let needsAuth: Bool
    let actions: DockPreviewActions

    var body: some View {
        if needsAuth {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                Button("Show events") { actions.onCalendarAuth?() }
                    .controlSize(.small)
                    .help("Allow calendar access to preview upcoming events")
            }
            .padding(.vertical, 2)
        } else if !events.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let freeUntil {
                    Text("Free until \(freeUntil.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                    eventRow(event)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func eventRow(_ event: ShelfCalendarModel.Event) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.callout)
                    .lineLimit(1)
                Text(timeLine(event))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let url = event.url {
                Button("Join") { actions.onCalendarJoin?(url) }
                    .controlSize(.small)
                    .help("Join the meeting link")
            }
        }
    }

    /// "Now – 3:30 PM" for what's on, "2:00 – 2:30 PM" otherwise; a
    /// tomorrow event says so.
    private func timeLine(_ event: ShelfCalendarModel.Event) -> String {
        let now = Date()
        let end = event.end.formatted(date: .omitted, time: .shortened)
        if event.start <= now { return "Now – \(end)" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let prefix = Calendar.current.isDateInToday(event.start) ? "" : "Tomorrow "
        return "\(prefix)\(start) – \(end)"
    }
}
