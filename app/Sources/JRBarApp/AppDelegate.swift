import AppKit
import JRBarCore
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var screenBar: ScreenBarController?
    private var interaction: ScreenBarInteraction?
    private var feed: LEDFeed?
    private var monitor: AgentStateMonitor?
    private var core: CoreModel?
    private var store: PanelStore?
    private var panel: PanelController?
    private var settingsStore: SettingsStore?
    private var settingsWindow: SettingsWindowController?
    private var socketWatcher: FileWatcher?
    private var lastFileProgram: (text: String, source: LEDFeed.Source)?
    private var lastLightsSource: String?
    private static let showScreenBarKey = "showScreenBar"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Self.showScreenBarKey: true])

        let statusItem = StatusItemController()
        let screenBar = ScreenBarController()
        let feed = LEDFeed()
        let monitor = AgentStateMonitor()
        let core = CoreModel()
        let store = PanelStore(core: core)
        let panel = PanelController(store: store)
        let settingsStore = SettingsStore(core: core)
        let settingsWindow = SettingsWindowController(store: settingsStore)
        self.settingsStore = settingsStore
        self.settingsWindow = settingsWindow
        installMainMenu()
        self.statusItem = statusItem
        self.screenBar = screenBar
        self.feed = feed
        self.monitor = monitor
        self.core = core
        self.store = store
        self.panel = panel

        // Status item ↔ panel.
        panel.setAnchorProvider { [weak statusItem] in statusItem?.anchorRect }
        panel.onOpenStateChange = { [weak statusItem] open in statusItem?.setPanelOpen(open) }
        statusItem.onTogglePanel = { [weak panel] in panel?.toggle() }
        statusItem.onToggleScreenBar = { [weak self] shown in self?.setScreenBar(shown: shown) }
        store.onToggleScreenBar = { [weak self] shown in self?.setScreenBar(shown: shown) }
        store.onQuit = { NSApp.terminate(nil) }

        // Screen Bar hover and click: hit-tested against the band, never focus-stealing.
        let interaction = ScreenBarInteraction(
            bandRect: { [weak screenBar] in screenBar?.bandScreenRect },
            focus: { [weak store] in store?.screenBarFocus },
            onOpen: { [weak core] session in core?.openSession(session) }
        )
        self.interaction = interaction
        screenBar.onGeometryChange = { [weak interaction] in interaction?.geometryChanged() }
        store.onOpenSettings = { [weak settingsWindow] in settingsWindow?.show() }
        statusItem.onOpenSettings = { [weak settingsWindow] in settingsWindow?.show() }

        // File feeds: the fallback until the daemon is connected.
        feed.onProgram = { [weak self] text, source in
            guard let self else { return }
            self.lastFileProgram = (text, source)
            self.store?.feedDescription = source.description
            if self.core?.isLive != true { self.applyFileProgram() }
        }
        monitor.onChange = { [weak self] state, detail in
            guard let self else { return }
            self.store?.fallbackState = state
            self.store?.fallbackDetail = detail
            self.refreshAggregate()
        }

        // Daemon protocol: beats the files whenever it is live.
        core.onEvent = { [weak self] event in self?.handle(event: event) }
        observeCore()
        watchSocketDirectory(core.socketPath)

        let shown = defaults.bool(forKey: Self.showScreenBarKey)
        statusItem.isScreenBarShown = shown
        store.screenBarShown = shown
        if shown { screenBar.show(); interaction.start() }
        feed.start()
        monitor.start()
        core.start()

        // Developer switches: `JRBAR_OPEN_PANEL=1` opens the panel shortly
        // after launch (screenshots, design passes) without a click;
        // `JRBAR_OPEN_SETTINGS=<page>` opens the Settings window on that page
        // (general, agents, usage, devices, lighting, notifications, remote,
        // advanced, or effects).
        let environment = ProcessInfo.processInfo.environment
        if environment["JRBAR_OPEN_PANEL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak panel] in
                MainActor.assumeIsolated { panel?.open() }
            }
        }
        if let pageName = environment["JRBAR_OPEN_SETTINGS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak settingsWindow, weak settingsStore] in
                MainActor.assumeIsolated {
                    let page = SettingsStore.Page(rawValue: pageName)
                    settingsWindow?.show(page: page ?? .general)
                    if pageName == "effects" { settingsStore?.page = .lighting; settingsStore?.route = [.effects] }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panel?.close()
        interaction?.stop()
        screenBar?.hide()
        core?.stop()
    }

    /// An accessory app has no menu bar of its own, but the Settings window's
    /// text fields still need the Edit menu's responder chain for ⌘C/⌘V/⌘A.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit JR-Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    @objc private func openSettings(_ sender: Any?) {
        settingsWindow?.show()
    }

    // MARK: Screen Bar visibility

    private func setScreenBar(shown: Bool) {
        UserDefaults.standard.set(shown, forKey: Self.showScreenBarKey)
        statusItem?.isScreenBarShown = shown
        store?.screenBarShown = shown
        if shown { screenBar?.show(); interaction?.start() } else { interaction?.stop(); screenBar?.hide() }
    }

    // MARK: Core observation

    /// Re-arms an observation of the model's facts after every change and
    /// pushes them into the status item and the Screen Bar. Observation
    /// coalesces bursts (the daemon caps at 20 state messages a second) into
    /// one main-queue turn.
    private func observeCore() {
        guard let core else { return }
        withObservationTracking {
            _ = core.connection
            _ = core.state?.generation
            _ = core.state?.aggregate
            _ = core.lights
            _ = core.hello
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.coreDidChange()
                self?.observeCore()
            }
        }
    }

    private func coreDidChange() {
        guard let core, let statusItem else { return }
        switch core.connection {
        case .connected where core.state != nil:
            statusItem.setCore(description: "connected (\(core.hello?.coreVersion ?? "?"))")
        case .connected:
            statusItem.setCore(description: "connected, waiting for state")
        case .connecting(let attempt):
            statusItem.setCore(description: attempt <= 1 ? "connecting" : "reconnecting (try \(attempt))")
        case .disconnected(let reason):
            statusItem.setCore(description: "disconnected · \(reason)")
        case .idle:
            statusItem.setCore(description: "idle")
        }
        refreshAggregate()
        refreshLights()
    }

    private func refreshAggregate() {
        guard let store, let statusItem else { return }
        statusItem.update(state: store.aggregate, detail: store.headerCounts)
    }

    private func refreshLights() {
        guard let core, let screenBar else { return }
        if core.isLive, let surface = core.lights?.screenBar, !surface.program.isEmpty {
            screenBar.apply(programText: surface.program, anchorEpoch: surface.anchor)
            let why = surface.why.map { " · \($0.replacingOccurrences(of: "_", with: " "))" } ?? ""
            let description = "core" + why + (screenBar.lastRejection.map { " (refused: \($0))" } ?? "")
            if description != lastLightsSource {
                lastLightsSource = description
                statusItem?.setFeed(description: description)
            }
        } else if !core.isLive {
            applyFileProgram()
        }
    }

    /// Puts the last file-feed program back on the bar (startup, or the
    /// daemon went away).
    private func applyFileProgram() {
        guard let screenBar, let last = lastFileProgram else { return }
        screenBar.apply(programText: last.text)
        let description = last.source.description + (screenBar.lastRejection.map { " (refused: \($0))" } ?? "")
        if description != lastLightsSource {
            lastLightsSource = description
            statusItem?.setFeed(description: description)
        }
    }

    // MARK: Events

    private func handle(event: CoreEvent) {
        if let sound = event.sound, event.notify == true, let nsSound = NSSound(named: NSSound.Name(sound.capitalized)) {
            nsSound.play()
        }
        NSLog("JR-Bar: core event %@ %@ %@", event.kind, event.label ?? "", event.session ?? "")
    }

    // MARK: Socket directory watch

    /// The daemon may start after us: when its directory changes, retry at
    /// once instead of waiting out the backoff.
    private func watchSocketDirectory(_ socketPath: String) {
        let directory = (socketPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: directory) else { return }
        socketWatcher = FileWatcher(path: directory, mask: [.write, .link, .attrib]) { [weak self] _ in
            self?.core?.retryNow()
        }
        socketWatcher?.start()
    }
}
