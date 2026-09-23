import AppKit
import JRBarCore
import OSLog
import SwiftUI

/// The palette window: Liquid Glass, nonactivating but key-capable —
/// the search field types while whatever app was frontmost stays
/// frontmost, so a menu-bar item pressed from here opens over the app
/// you were in, and a session raised from here is the only activation.
@MainActor
final class PalettePanel: NSPanel {
    static let width: CGFloat = 660
    static let height: CGFloat = 452
    static let cornerRadius: CGFloat = 18

    init<Content: View>(content: Content) {
        let frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.height)
        let hosting = NSHostingView(rootView: content)
        let glass = NSGlassEffectView(frame: frame)
        glass.cornerRadius = Self.cornerRadius
        glass.style = .regular
        glass.contentView = hosting
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        contentView = GlassBackdrop.rounded(glass, cornerRadius: Self.cornerRadius)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: glass.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .moveToActiveSpace]
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        setAccessibilityLabel("JR-Bar command palette")
        if ProcessInfo.processInfo.environment["JRBAR_CAPTURE_CARD"] == nil {
            sharingType = .none
        }
    }

    // The whole point of a nonactivating panel: key events reach it
    // while the frontmost app keeps focus.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Where the palette stands on `screen`: centred, its top a little
    /// under a fifth of the way down the visible frame — Spotlight's and
    /// Raycast's height, clear of the notch, the Screen Bar and the
    /// island, which own the top edge.
    static func origin(on visible: NSRect) -> NSPoint {
        let top = visible.maxY - (visible.height * 0.18).rounded()
        return NSPoint(x: (visible.midX - width / 2).rounded(), y: top - height)
    }
}

/// The confirmation a verb leaves after the palette folds — one glass
/// line where the palette stood, gone in a moment. VoiceOver hears it
/// as an announcement.
@MainActor
final class PaletteHUD {
    static let height: CGFloat = 36
    static let life: TimeInterval = 1.8
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, symbol: String = "checkmark.circle.fill", near anchor: NSRect?) {
        hide()
        let hosting = NSHostingView(rootView: PaletteHUDView(text: text, symbol: symbol))
        let size = hosting.fittingSize
        let frame = NSRect(x: 0, y: 0, width: max(120, size.width), height: Self.height)
        let glass = NSGlassEffectView(frame: frame)
        glass.cornerRadius = Self.height / 2
        glass.style = .regular
        glass.contentView = hosting
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = GlassBackdrop.rounded(glass, cornerRadius: Self.height / 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        let visible = (NSScreen.screenWithMouse ?? NSScreen.main)?.visibleFrame ?? .zero
        let reference = anchor ?? NSRect(origin: PalettePanel.origin(on: visible),
                                         size: NSSize(width: PalettePanel.width, height: PalettePanel.height))
        panel.setFrameOrigin(NSPoint(x: (reference.midX - frame.width / 2).rounded(),
                                     y: reference.maxY - frame.height))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.14
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        if NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.life, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func fadeOut() {
        guard let panel else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0 : 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            MainActor.assumeIsolated {
                panel?.orderOut(nil)
                if self?.panel === panel { self?.panel = nil }
            }
        })
    }
}

extension NSScreen {
    /// The screen under the pointer — where the person is looking.
    @MainActor
    static var screenWithMouse: NSScreen? {
        let point = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}

/// The palette's coordinator: gathers rows from every source on open,
/// routes keys through `PaletteKeys`, runs verbs, remembers what ran,
/// and leaves a HUD line behind. One instance, held by the ⌘⇧K entry
/// point (`MenuBarCommandBar`), so the hotkey, the utility card's
/// button and the icon menu all open the same palette.
@MainActor
final class PaletteController {
    nonisolated static let log = Logger(subsystem: "devin.jrbar", category: "palette")

    /// Every source, asked in order on each open.
    var sources: @MainActor () -> [any PaletteSource] = { [] }
    /// The frecency table, read at open.
    var usage: @MainActor () -> PaletteUsage = { PaletteUsage() }
    /// A row ran — record it against its id.
    var recordUse: @MainActor (String) -> Void = { _ in }
    /// A store that reports through its own toast (the panel's): after
    /// a verb runs, the palette listens to it for a few seconds and
    /// shows what it says in the HUD, so "Approved · typed into the
    /// session's terminal" or a refusal is heard even with the panel
    /// shut.
    var toastFeed: (@MainActor () -> String?)?
    /// The field's placeholder.
    var prompt = "Search menu bar, sessions and commands…"
    /// False only in tests: the session runs — sources, rows, keys —
    /// with no window on anyone's screen.
    var presentsWindow = true

    let model = PaletteModel()
    let hud = PaletteHUD()
    private var panel: PalettePanel?
    private(set) var isOpen = false
    private var openedAtUptime: TimeInterval = 0
    private var monitors: [Any] = []
    private var workspaceObserver: NSObjectProtocol?
    private var activeSources: [any PaletteSource] = []
    private var searchTask: Task<Void, Never>?
    /// How long the query must hold still before slower sources search.
    static let searchDebounce: Duration = .milliseconds(180)
    /// How long a verb's store toast still counts as its answer.
    static let toastWindow: TimeInterval = 8

    func toggle() {
        if isOpen { close() } else { open() }
    }

    /// Gathers the rows and presents the palette on the screen under
    /// the pointer.
    func open() {
        if isOpen { close() }
        hud.hide()
        activeSources = sources()
        for source in activeSources { source.prepare() }
        isOpen = true
        model.load(items: gather(), usage: usage())
        guard presentsWindow else { return }
        let view = PaletteView(
            model: model, prompt: prompt,
            onQueryChange: { [weak self] in self?.queryChanged() },
            onActivate: { [weak self] id in self?.activate(rowID: id) },
            onRun: { [weak self] rowID, actionID in self?.run(rowID: rowID, actionID: actionID) },
            onToggleActions: { [weak self] in self?.toggleActions() })
        let panel = PalettePanel(content: view)
        let visible = (NSScreen.screenWithMouse ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(PalettePanel.origin(on: visible))
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        openedAtUptime = ProcessInfo.processInfo.systemUptime
        installMonitors()
    }

    /// Every source's rows, read under observation: whatever a builder
    /// touched (the daemon's state, a toggle's read-back, the scene)
    /// re-gathers the list the moment it changes, for as long as the
    /// palette is up.
    private func gather() -> [PaletteItem] {
        let sources = activeSources
        return withObservationTracking {
            sources.flatMap { $0.items() }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.regather() }
        }
    }

    private func regather() {
        guard isOpen else { return }
        model.reload(items: gather())
    }

    func close() {
        guard isOpen else { return }
        removeMonitors()
        searchTask?.cancel()
        searchTask = nil
        panel?.orderOut(nil)
        panel = nil
        isOpen = false
        activeSources = []
        PaletteAppIcons.reset()
    }

    isolated deinit {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        panel?.orderOut(nil)
    }

    // MARK: Running verbs

    /// A click on a row: select it, then do what Return would.
    func activate(rowID: String) {
        model.select(id: rowID)
        submit()
    }

    /// Return: the row's first verb, or its action panel for a
    /// menu-only row.
    func submit() {
        guard let item = model.selected else { return }
        if item.opensActions {
            model.openActions()
        } else if let primary = item.primary {
            run(primary, of: item)
        }
    }

    func toggleActions() {
        if model.actionsOpen { model.closeActions() } else { model.openActions() }
    }

    func run(rowID: String, actionID: String) {
        guard let item = model.rows.first(where: { $0.id == rowID }),
              let action = item.actions.first(where: { $0.id == actionID }) else { return }
        run(action, of: item)
    }

    /// Fold first — the frontmost app gets its keyboard back before a
    /// menu opens over it — then record the row, listen for the store's
    /// answer, run, and show the verb's own line if it has one.
    func run(_ action: PaletteAction, of item: PaletteItem) {
        let anchor = panel?.frame
        model.closeActions()
        close()
        recordUse(item.id)
        listenForToast(until: Date().addingTimeInterval(Self.toastWindow), anchor: anchor)
        Self.log.debug("run \(item.id, privacy: .public) · \(action.id, privacy: .public)")
        if let line = action.run() {
            hud.show(line, near: anchor)
        }
    }

    // MARK: Keys

    /// The one key path: every key-down in the palette's window passes
    /// through `PaletteKeys`; what it claims is swallowed, the rest
    /// reaches the focused field. Composition (an input method's marked
    /// text) always wins — Return commits the syllable, not a verb.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isOpen, let panel, event.window === panel else { return event }
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
        let command = PaletteKeys.command(keyCode: event.keyCode,
                                          characters: event.charactersIgnoringModifiers,
                                          modifiers: event.modifierFlags)
        return handle(command) ? nil : event
    }

    /// Applies one key command; true when the palette used it.
    @discardableResult
    func handle(_ command: PaletteKeyCommand) -> Bool {
        if model.actionsOpen {
            switch command {
            case .up: model.moveAction(-1)
            case .down: model.moveAction(1)
            case .pageUp, .pageDown: return true
            case .submit:
                if let item = model.selected, let action = model.selectedAction { run(action, of: item) }
            case .cancel: model.closeActions()
            case .chord(let chord):
                if chord == .actionPanel { model.closeActions(); return true }
                guard let item = model.selected, let action = item.action(for: chord) else {
                    return unclaimed(chord)
                }
                run(action, of: item)
            case .passThrough: return false
            }
            return true
        }
        switch command {
        case .up: model.move(-1)
        case .down: model.move(1)
        case .pageUp: model.page(-8)
        case .pageDown: model.page(8)
        case .submit: submit()
        case .cancel:
            // Spotlight's two-step: the first ⎋ clears what you typed,
            // the second folds the palette.
            if model.query.isEmpty { close() } else { model.query = ""; queryChanged() }
        case .chord(let chord):
            if chord == .actionPanel { toggleActions(); return true }
            if let item = model.selected, let action = item.action(for: chord) {
                run(action, of: item)
                return true
            }
            return unclaimed(chord)
        case .passThrough:
            return false
        }
        announceSelection()
        return true
    }

    /// A chord no verb on the row claims. ⌃ chords are the field's
    /// (⌃A, ⌃E, ⌃K edit the query). A ⌘ chord is the palette's either
    /// way: the key window is ours while the frontmost app is not, so
    /// an unclaimed ⌘H would reach JR-Bar's own menu and hide every
    /// JR-Bar window — the Screen Bar with them — and ⌘Q would quit
    /// it. ⌘W and ⌘Q fold the palette; JR-Bar's own window chords
    /// (`windowChords`) fold it and go on to the menu that owns them;
    /// the rest do nothing.
    private func unclaimed(_ chord: PaletteShortcut) -> Bool {
        guard chord.modifiers.contains(.command) else { return false }
        if chord == .command("w") || chord == .command("q") {
            close()
            return true
        }
        if Self.windowChords.contains(chord) {
            close()
            return false
        }
        return true
    }

    /// The app menu's own key equivalents — Settings, History,
    /// Overview, Usage Center — so the chords JR-Bar already teaches
    /// work from the palette too.
    static let windowChords: Set<PaletteShortcut> = [
        .command(","), .command("y"), .command("o"), .command("u"),
    ]

    /// With VoiceOver on, the field keeps focus while ↑/↓ walk the
    /// list, so the row under the highlight is spoken.
    private func announceSelection() {
        guard NSWorkspace.shared.isVoiceOverEnabled, let item = model.selected else { return }
        let text = model.actionsOpen ? (model.selectedAction?.title ?? "") : item.title
        guard !text.isEmpty else { return }
        NSAccessibility.post(element: panel as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    // MARK: Slower sources

    /// The query moved: re-ask the slower sources once it settles.
    func queryChanged() {
        searchTask?.cancel()
        let query = model.query
        guard !PaletteModel.trimmed(query).isEmpty else {
            model.noteSearching(false)
            return
        }
        let sources = activeSources
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled, let self else { return }
            self.model.noteSearching(true)
            var found: [PaletteItem] = []
            for source in sources {
                found += await source.results(for: query)
                if Task.isCancelled { return }
            }
            self.model.setSearchResults(found, for: query)
        }
    }

    // MARK: The store's answer

    /// Watches `toastFeed` until `deadline`: each new line it reports
    /// becomes the HUD. Armed before the verb runs, so a toast the verb
    /// raises synchronously is caught as surely as a daemon's late
    /// reply.
    private func listenForToast(until deadline: Date, anchor: NSRect?) {
        guard let feed = toastFeed else { return }
        withObservationTracking {
            _ = feed()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, Date() < deadline else { return }
                if let line = feed(), !line.isEmpty {
                    self.hud.show(line, symbol: "text.bubble.fill", near: anchor)
                }
                self.listenForToast(until: deadline, anchor: anchor)
            }
        }
    }

    // MARK: Dismissal

    private func installMonitors() {
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handle(event) ?? event
        }) {
            monitors.append(keys)
        }
        // A click anywhere but the palette folds it — the Item Bar's
        // read: the panel takes key but never activation, so "outside"
        // is a monitor's call, not a resign event.
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.noteOutsideClick(event)
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.noteOutsideClick(event)
            return event
        }) {
            monitors.append(local)
        }
        // ⌘⇥ to another app is leaving too.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
    }

    nonisolated private func noteOutsideClick(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        let timestamp = event.timestamp
        Task { @MainActor [weak self] in
            guard let self, let panel = self.panel else { return }
            guard timestamp > self.openedAtUptime else { return }
            guard !panel.frame.contains(point) else { return }
            self.close()
        }
    }
}
