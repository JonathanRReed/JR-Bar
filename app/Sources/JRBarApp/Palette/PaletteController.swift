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
    /// Every Space, full-screen ones too. `.canJoinAllSpaces` already
    /// puts the panel on whichever Space is active; adding
    /// `.moveToActiveSpace` beside it makes AppKit throw from
    /// `setCollectionBehavior:`, which kept the palette from ever
    /// opening.
    static let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

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
        collectionBehavior = Self.behavior
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
        // The palette's own Space rule — one list, so the HUD can never
        // drift back to the pair AppKit refuses.
        panel.collectionBehavior = PalettePanel.behavior
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

/// One verb's claim on the toasts it raises. The palette runs every
/// verb under a fresh ticket (`PaletteVerbScope.ticket`); a store that
/// reports through a toast hands each line to the ticket it runs under.
/// The verb's own call and every task it starts inherit the ticket, so
/// the daemon's late verdict is heard as that verb's answer — and a
/// toast an unrelated event raised a second later is not.
@MainActor
@Observable
final class PaletteVerbTicket {
    /// What the verb raised, oldest first; the HUD shows the newest.
    private(set) var lines: [String] = []

    nonisolated init() {}

    func hear(_ line: String) {
        guard !line.isEmpty else { return }
        lines.append(line)
    }
}

/// The ticket the running code answers to, if a palette verb started it.
enum PaletteVerbScope {
    @TaskLocal static var ticket: PaletteVerbTicket?
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
/// point (`MenuBarCommandBar`), so the hotkey — registered or parked —
/// and the utility card's button open the same palette.
@MainActor
final class PaletteController {
    nonisolated static let log = Logger(subsystem: "devin.jrbar", category: "palette")

    /// Every source, asked in order on each open.
    var sources: @MainActor () -> [any PaletteSource] = { [] }
    /// The frecency table, read at open.
    var usage: @MainActor () -> PaletteUsage = { PaletteUsage() }
    /// A row ran — record it against its id.
    var recordUse: @MainActor (String) -> Void = { _ in }
    /// Pin or unpin a row by id — the frecency table's favorites. nil
    /// leaves the verb off every row.
    var toggleFavorite: (@MainActor (String) -> Void)?
    /// Drop a row's habit — Raycast's Reset Ranking. nil leaves the verb
    /// off every row.
    var forgetUse: (@MainActor (String) -> Void)?
    /// A store that reports through its own toast (the panel's): after
    /// a verb runs, the palette listens for a few seconds and shows the
    /// lines that verb raised in the HUD, so "Approved · sent through
    /// the agent's permission hook" or a refusal is heard even with the
    /// panel shut. Which lines count is the verb's ticket's call
    /// (`PaletteVerbTicket`), never the clock's: a toast some other
    /// event raised meanwhile is not this verb's answer. nil hears
    /// nothing.
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
    /// the pointer. It counts as open only once the panel is up: a
    /// panel that fails to build leaves ⌘⇧K free to try again, not a
    /// toggle stuck on a palette nobody can see.
    func open() {
        if isOpen { close() }
        hud.hide()
        activeSources = sources()
        for source in activeSources { source.prepare() }
        model.typedRows = { [weak self] query in
            self?.activeSources.flatMap { $0.typedItems(for: query) } ?? []
        }
        model.load(items: gather(), usage: usage())
        guard presentsWindow else {
            isOpen = true
            return
        }
        let view = PaletteView(
            model: model, prompt: prompt,
            onQueryChange: { [weak self] in self?.queryChanged() },
            onActivate: { [weak self] id in self?.activate(rowID: id) },
            onRun: { [weak self] rowID, actionID in self?.run(rowID: rowID, actionID: actionID) },
            onToggleActions: { [weak self] in self?.toggleActions() },
            onInputChange: { [weak self] in self?.inputChanged() },
            onSubmitInput: { [weak self] in self?.submitInput() },
            onCancelInput: { [weak self] in self?.cancelInput() })
        let panel = PalettePanel(content: view)
        let visible = (NSScreen.screenWithMouse ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(PalettePanel.origin(on: visible))
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        isOpen = true
        openedAtUptime = ProcessInfo.processInfo.systemUptime
        installMonitors()
    }

    /// Every source's rows, read under observation: whatever a builder
    /// touched (the daemon's state, a toggle's read-back, the scene)
    /// re-gathers the list the moment it changes, for as long as the
    /// palette is up.
    private func gather() -> [PaletteItem] {
        let sources = activeSources
        let items = withObservationTracking {
            sources.flatMap { $0.items() }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.regather() }
        }
        let table = usage()
        let now = Date()
        return items.map {
            withResetVerb(withFavoriteVerb($0, pinned: table.isFavorite($0.id)),
                          used: table.score(for: $0.id, at: now) > 0)
        }
    }

    /// A row with a habit takes Reset Ranking last: it runs with the
    /// palette up, and the row leaves Suggestions where it stood.
    private func withResetVerb(_ item: PaletteItem, used: Bool) -> PaletteItem {
        guard let forgetUse, used else { return item }
        var reset = item
        reset.actions.append(PaletteAction(
            id: "palette.resetRanking", title: "Reset Ranking", symbol: "arrow.counterclockwise",
            keepsOpen: true) {
            forgetUse(item.id)
            return nil
        })
        return reset
    }

    /// ⌘⇧P — pin or unpin the row.
    static let favoriteChord = PaletteShortcut.commandShift("p")

    /// Whether a row can be a favorite: not an ask, a session or an
    /// archive hit — those come and go, and a pin would point at nothing
    /// by tomorrow.
    static func canPin(_ item: PaletteItem) -> Bool {
        !item.urgent && item.section != .sessions && item.section != .archive
    }

    /// Every pinnable row gets the pin as its last verb. It runs with the
    /// palette up: the row moves to (or out of) Favorites in place.
    private func withFavoriteVerb(_ item: PaletteItem, pinned: Bool) -> PaletteItem {
        guard let toggleFavorite, Self.canPin(item) else { return item }
        var pinnable = item
        pinnable.actions.append(PaletteAction(
            id: "palette.favorite", title: pinned ? "Remove from Favorites" : "Add to Favorites",
            symbol: pinned ? "star.slash" : "star", shortcut: Self.favoriteChord, keepsOpen: true) {
            toggleFavorite(item.id)
            return nil
        })
        return pinnable
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
        model.endInput()
        PaletteAppIcons.reset()
    }

    isolated deinit {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        panel?.orderOut(nil)
    }

    // MARK: Running verbs

    /// A click on a row: select it, then do what Return would. The row
    /// a verb's field answers is context while the field is open, not a
    /// button.
    func activate(rowID: String) {
        guard !model.inputActive else { return }
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
        model.closeActions()
        // A verb that takes words opens its field; Return there is the run.
        if model.beginInput(action, of: item) {
            announce(action.input?.prompt ?? action.title)
            return
        }
        if action.keepsOpen {
            _ = action.run()
            model.usage = usage()
            if isOpen { model.reload(items: gather()) }
            return
        }
        finish(item: item, action: action) { action.run() }
    }

    /// Fold, record, listen, run — the tail every verb shares, the
    /// field's submit included.
    ///
    /// Only a gathered row is recorded: habit ranks `model.items` and
    /// nothing else. A slower source's hit carries other apps' words in
    /// its id — a Safari page title, a recent document's name — so
    /// saving it would write a third-party title to app-state.json that
    /// no ranking ever reads, and push real habits out of the capped
    /// table. The log keeps the id private for the same reason.
    private func finish(item: PaletteItem, action: PaletteAction, run: () -> String?) {
        let anchor = panel?.frame
        let ranked = model.items.contains { $0.id == item.id }
        close()
        if ranked { recordUse(item.id) }
        let ticket = PaletteVerbTicket()
        if toastFeed != nil {
            listen(to: ticket, until: Date().addingTimeInterval(Self.toastWindow), anchor: anchor)
        }
        Self.log.debug("run \(item.id, privacy: .private) · \(action.id, privacy: .public)")
        // The verb runs under its ticket: the toast it raises now, or
        // from a task it starts, is heard as its answer.
        if let line = PaletteVerbScope.$ticket.withValue(ticket, operation: run) {
            hud.show(line, near: anchor)
        }
    }

    // MARK: A verb's field

    /// Every edit reaches the verb's draft keeper.
    func inputChanged() {
        model.inputAction?.input?.onChange?(model.inputText)
    }

    /// Return in the field: hand the words over and fold. Nothing but
    /// whitespace, or words the verb would refuse, sends nothing — the
    /// field stays open.
    func submitInput() {
        guard let item = model.inputItem, let action = model.inputAction, let input = action.input else {
            model.endInput()
            return
        }
        let words = model.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, input.accepts(words) else { return }
        finish(item: item, action: action) { input.submit(words) }
    }

    /// ⎋ in the field: back to the list, the query as it was. The draft
    /// has been kept edit by edit.
    func cancelInput() {
        model.endInput()
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
        if model.inputActive {
            // The verb's field: Return — or the ⌘↩ that opened it —
            // sends, ⎋ backs out, the list stays still underneath.
            switch command {
            case .submit, .chord(.secondary): submitInput()
            case .cancel: cancelInput()
            case .up, .down, .pageUp, .pageDown: break
            case .chord(let chord):
                return chord == .actionPanel ? true : unclaimed(chord)
            case .passThrough: return false
            }
            return true
        }
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
        guard let item = model.selected else { return }
        announce(model.actionsOpen ? (model.selectedAction?.title ?? "") : item.title)
    }

    /// One line for VoiceOver — the row under the highlight, or the
    /// field a verb just opened ("Reply to fix-ci…").
    private func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled, !text.isEmpty else { return }
        NSAccessibility.post(element: panel as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    // MARK: Slower sources

    /// The query moved: re-ask the slower sources once it settles. They
    /// run side by side and each answer lands as it comes, in source
    /// order — one slow Accessibility read of the front app's menus
    /// never holds the archive's or History's hits back.
    func queryChanged() {
        searchTask?.cancel()
        let query = model.query
        guard !PaletteModel.trimmed(query).isEmpty else {
            model.noteSearching(false)
            return
        }
        let count = activeSources.count
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled, let self else { return }
            self.model.noteSearching(true)
            guard count > 0 else {
                self.model.setSearchResults([], for: query)
                return
            }
            let run = PaletteSearchRun(count: count)
            // One read per source, by its place: each finds its source
            // on the main actor, where every source lives, and while one
            // waits on another app's Accessibility the rest carry on.
            let reads = (0..<count).map { index in
                Task { @MainActor [weak self] in
                    guard let source = self?.activeSources[safe: index] else { return }
                    let found = await source.results(for: query)
                    guard !Task.isCancelled, let self else { return }
                    run.answers.record(found, at: index)
                    self.model.setSearchResults(run.answers.items, for: query,
                                                finished: run.answers.isComplete)
                }
            }
            await withTaskCancellationHandler {
                for read in reads { await read.value }
            } onCancel: {
                for read in reads { read.cancel() }
            }
        }
    }

    // MARK: The store's answer

    /// Watches the verb's ticket until `deadline`: each line the verb
    /// raised becomes the HUD. Armed before the verb runs, so a toast
    /// the verb raises synchronously is caught as surely as a daemon's
    /// late reply — and a toast nothing this verb did raised is never
    /// shown as its answer.
    ///
    /// The ticket's own registrar keeps the change handler, so the
    /// handler holds the ticket weakly: a verb that raises nothing (open
    /// an app, hide an item) frees its ticket once it returns rather
    /// than waiting on a line that never comes. A task the verb started
    /// keeps its ticket through the task-local, so a late toast is
    /// still heard; the handler runs inside the ticket's own change,
    /// with the ticket alive, and holds it strongly only for the hop.
    private func listen(to ticket: PaletteVerbTicket, until deadline: Date, anchor: NSRect?) {
        let heard = ticket.lines.count
        withObservationTracking {
            _ = ticket.lines
        } onChange: { [weak self, weak ticket] in
            guard let ticket else { return }
            Task { @MainActor [weak self] in
                guard let self, Date() < deadline else { return }
                if ticket.lines.count > heard, let line = ticket.lines.last, !line.isEmpty {
                    self.hud.show(line, symbol: "text.bubble.fill", near: anchor)
                }
                self.listen(to: ticket, until: deadline, anchor: anchor)
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
