import AppKit
import Carbon
import JRBarCore
import JRBarUI
import Observation
import OSLog
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: StatusItemController?
    private var screenBar: ScreenBarController?
    private var interaction: ScreenBarInteraction?
    private var alcove: AlcoveFollower?
    private var feed: LEDFeed?
    private var monitor: AgentStateMonitor?
    private var core: CoreModel?
    private var store: PanelStore?
    /// The HUD a closed panel's feedback lands in (`showFeedback`).
    private let feedbackHUD = PaletteHUD()
    private var panel: PanelController?
    private var settingsStore: SettingsStore?
    private var settingsWindow: SettingsWindowController?
    private var historyStore: HistoryStore?
    private var historyWindow: HistoryWindowController?
    private var overviewWindow: OverviewWindowController?
    private var usageStore: UsageCenterStore?
    private var usageWindow: UsageCenterWindowController?
    private var effectsStore: EffectStudioStore?
    private var effectsWindow: EffectStudioWindowController?
    private var deckStore: DeckStore?
    private var controlCenterWindow: ControlCenterWindowController?
    private var whatsNewWindow: WhatsNewWindowController?
    private var rail: DeckRailController?
    private var events: EventCoordinator?
    private var toysStore: ToysStore?
    /// The mic/camera reading as the daemon's `presence`, and the call
    /// fact back for the toys.
    private var presence: PresenceReporter?
    private var utilitiesStore: UtilitiesStore?
    private var supervisor: CoreSupervisor?
    /// Keeps the settings seal: the Keychain key, the daemon's word on it and
    /// the Settings banner (SettingsSeal.swift).
    private var sealCoordinator: SettingsSealCoordinator?
    private var socketWatcher: FileWatcher?
    private var updater: SparkleUpdater?
    private var hotkey: PanelHotkey?
    /// The shelf's own summon key (⌃⌥D) — a second Carbon registration
    /// through the same `PanelHotkey` plumbing, its own signature.
    private var shelfHotkey: PanelHotkey?
    private var studioHotkey: PanelHotkey?
    private var checkForUpdatesItem: NSMenuItem?
    private var wasLive = false
    /// Speaks each new ask once to VoiceOver.
    private let askAnnouncer = AskAnnouncer()
    private var pendingHookRefreshStamp: String?
    private var lastFileProgram: (text: String, source: LEDFeed.Source, anchor: Double?)?
    private var lastLightsSource: String?
    /// When the last `completed` event arrived: the menu bar's state dot
    /// holds green for `completionDotWindow` after it.
    private var lastCompletionAt: Date?
    private var completionReset: Timer?
    /// The app's remembered facts (hooks stamp, login item, Screen Bar) in
    /// `~/.local/state/jrbar/app-state.json`; user defaults are Sparkle's.
    private var appStateFile = AppStateFile()
    private var isolatedPreview: IsolatedPreviewRuntime?
    private var appState = AppState()
    /// The user-defaults keys the same facts lived under before the JSON
    /// file; read once to seed the file on a Mac where they did persist.
    private static let showScreenBarKey = "showScreenBar"
    private static let hooksInstalledForKey = "bundledHooksInstalledFor"
    private static let loginItemRegisteredKey = "loginItemRegisteredOnFirstRun"

    private var terminationSignal: DispatchSourceSignal?
    /// The `flock` fd holding `SingleInstanceLock` for this process's
    /// life — never closed, so the lock outlives every surface.
    private var instanceLockFD: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowPresenter.logSuppressionAtLaunch()
        do {
            isolatedPreview = try IsolatedPreviewRuntime.readCurrent()
        } catch {
            NSLog("JR-Bar: invalid isolated preview configuration")
            exit(1)
        }
        if let isolatedPreview {
            appStateFile = AppStateFile(url: isolatedPreview.file("app-state.json"))
        }
        loadAppState()

        // `JRBAR_LOGIN_ITEM=on|off|status` only touches the login item and
        // exits: scripts/install-agents.sh uses it to hand the Mac between
        // the packaged app (login item) and the dev LaunchAgents.
        if isolatedPreview == nil, let request = ProcessInfo.processInfo.environment["JRBAR_LOGIN_ITEM"], !request.isEmpty {
            let service = SMAppService.mainApp
            do {
                switch request {
                case "on": try service.register()
                case "off": try service.unregister()
                default: break
                }
                print("login item: \(Self.describe(service.status))")
                exit(0)
            } catch {
                print("login item: \(error.localizedDescription)")
                exit(1)
            }
        }

        // `JRBAR_APPEARANCE=light|dark` pins every window to one appearance
        // (screenshots of both looks without touching the system setting).
        switch ProcessInfo.processInfo.environment["JRBAR_APPEARANCE"]?.lowercased() {
        case "light", "aqua": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark", "darkaqua": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }

        // One live instance per state directory — a second JR-Bar draws
        // a second Screen Bar, island, and covers over the first's, which
        // reads as doubled bands and ghost surfaces. This runs after the
        // env-var early exits so `JRBAR_LOGIN_ITEM` still answers from a
        // direct exec while the app is up.
        // Only proven contention yields. A lock that cannot be taken here at
        // all (an unwritable state directory, no `flock`) is said and the
        // app runs on, so it never quits silently as "already running".
        let instanceLog = Logger(subsystem: "devin.jrbar", category: "instance")
        var lockNotice: String?
        // A predecessor that is quitting still holds the lock for up to the
        // daemon's three-second grace; the person who quits and reopens at
        // once must get a running app and its icon, so the launch waits
        // that out (bounded) instead of yielding to a process that is
        // about to be gone.
        guard let lock = SingleInstanceLock.acquire(wait: .launch, onUnavailable: { code in
            let notice = "single-instance lock unavailable (errno \(code): \(String(cString: strerror(code)))) - continuing without it"
            instanceLog.error("\(notice, privacy: .public)")
            NSLog("JR-Bar: %@", notice)
            lockNotice = notice
        }) else {
            let line = "JR-Bar is already running — this instance yields."
            instanceLog.notice("\(line, privacy: .public)")
            print(line)
            // Whoever opened this copy wanted JR-Bar in front of them: ask
            // the running one to show itself rather than leave them with
            // nothing happening.
            DistributedNotificationCenter.default().postNotificationName(
                Self.showRequestName, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        instanceLockFD = lock

        // `pkill JR-Bar` (or a logout) must still stop the supervised core:
        // turn SIGTERM into an orderly quit so applicationWillTerminate runs.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // Not `NSApp.terminate` here: this handler runs as a block on the
        // main dispatch queue, and a quit that waits for the daemon
        // (`.terminateLater`) spins a nested loop that cannot run the reply
        // queued on that same serial queue. The run loop's own queue can.
        source.setEventHandler {
            Self.shutdownLog.notice("signal.received")
            RunLoop.main.perform(inModes: Self.quitModes) { NSApp.terminate(nil) }
        }
        source.resume()
        terminationSignal = source

        let core = CoreModel()
        if let lockNotice { core.appendLocalLog(level: "supervisor", lockNotice) }
        let providerList = ProviderListStore(core: core, legacy: appState.menuBarProviders)
        let store = PanelStore(core: core, providerList: providerList, screenBarShown: appState.showScreenBar)
        // The daemon first. It takes seconds to be ready, and every
        // surface below is built in the meantime rather than before it
        // is spawned: that construction used to hold the spawn back a
        // second after exec. Nothing the supervisor reports is handled
        // before this launch returns (its callbacks hop to the main
        // actor), so the wiring below is in place by then.
        let bundledCore = startCoreSupervision(core: core, store: store)
        let statusItem = StatusItemController()
        let screenBar = ScreenBarController(nativeNoticesEnabled: isolatedPreview == nil)
        let feed = isolatedPreview == nil ? LEDFeed() : nil
        let monitor = isolatedPreview == nil ? AgentStateMonitor() : nil
        let panel = PanelController(store: store)
        let settingsStore = SettingsStore(core: core, providerList: providerList)
        settingsStore.seal = sealCoordinator
        let settingsWindow = SettingsWindowController(store: settingsStore)
        self.settingsStore = settingsStore
        self.settingsWindow = settingsWindow
        // The menu bar style is the app's own: seed the picker from
        // `app-state.json` and write every choice straight back to it.
        settingsStore.menuBarIconStyle = appState.menuBarIconStyle ?? StatusIconStyle.agents.rawValue
        settingsStore.onSetMenuBarIconStyle = { [weak self] value in
            guard let self else { return }
            self.appState.menuBarIconStyle = value
            self.persistAppState()
            self.refreshIconStyle()
        }
        providerList.onPresentationChange = { [weak self] in
            guard let self else { return }
            if self.appState.menuBarProviders != .init() {
                self.appState.menuBarProviders = .init()
                self.persistAppState()
            }
            self.refreshIconStyle()
        }
        providerList.onRowsChange = { [weak self] in self?.refreshIconStyle() }
        // Toys: the fun-first page. Its state lives in `app-state.json`
        // like the rest of the app's remembered facts, so the delegate
        // stays the file's only writer and the store just hands back
        // the blob.
        // The card's timers and tray are one store behind both surfaces
        // — the glass card and the island's grown card read the same
        // files, so twin models would fire a timer twice and clobber
        // each other's persist.
        let cardTimers = ShelfTimerModel(storeURL: isolatedPreview?.file("shelf-timers.json"),
                                         schedulingEnabled: isolatedPreview == nil)
        let cardTray = ShelfTrayModel()
        let toysStore = ToysStore(core: core, settings: settingsStore, state: appState.toys,
                                  cardModel: NotchCardModel(timers: cardTimers, tray: cardTray,
                                      utility: isolatedPreview == nil ? nil : ShelfUtilityModel(power: AlcovePowerState(
                                          hasBattery: false, onAC: true, charging: false, percent: nil, fullyCharged: false)),
                                      runtimeEnabled: isolatedPreview == nil),
                                  nativeSourcesEnabled: isolatedPreview == nil,
                                  aquariumSave: isolatedPreview.map { AquariumSaveFile(url: $0.file("aquarium.json")) } ?? AquariumSaveFile())
        toysStore.onPersist = { [weak self] state in
            guard let self else { return }
            self.appState.toys = state
            self.persistAppState()
        }
        self.toysStore = toysStore
        toysStore.notchBuddy.onOpenRefused = { [weak self] text in self?.showFeedback(text) }
        settingsStore.toys = toysStore
        // Confetti's colour and aim: the focused session's provider (the
        // same one `jrbar://confetti` resolves) and the icon's face.
        toysStore.focusedProvider = { [weak self] in self?.focusedConfettiProvider(.focused) }
        toysStore.iconFrame = { [weak statusItem] in statusItem?.anchorRect }
        // Utilities: the serious half. Its state lives beside the toys'
        // in `app-state.json` under `utilities`, same single-writer rule
        // — the store hands back the blob and the delegate writes it.
        let utilitiesStore = UtilitiesStore(core: core, settings: settingsStore,
                                            state: appState.utilities)
        utilitiesStore.onPersist = { [weak self] state in
            guard let self else { return }
            self.appState.utilities = state
            self.persistAppState()
        }
        self.utilitiesStore = utilitiesStore
        settingsStore.utilities = utilitiesStore
        // The app's own status item is the Menu Bar utility's boundary:
        // everything left of it is the hidden run.
        utilitiesStore.menuBar.host = statusItem
        // The Item Bar's photographed glyphs — the app's own; tests never
        // get a camera, so no test captures the screen or writes the cache.
        if isolatedPreview == nil {
            utilitiesStore.menuBar.glyphCamera = MenuBarGlyphCamera()
        } else {
            utilitiesStore.menuBar.spacingWrite = { _, _ in true }
        }
        // …and its memory of the apps the bar has shown, for the right
        // ear's newcomer nudge — the app's, for the same reason.
        utilitiesStore.menuBar.newcomerMemory = MenuBarNewcomerMemory()
        // One answer desk for every ask surface: the panel's, which the
        // notch, the Dock preview and the Rail answer through too. An
        // answer it lands steps the notch's ask capsule down at once.
        AskAnswerDesk.shared = store.askDesk
        store.askDesk.onAnswered = { [weak toysStore] session, request in
            toysStore?.notch.resolveAsk(session: session, request: request)
        }
        // "Try it": the made-up ask comes up where the person's real ones do.
        DemoAskStore.shared.presenter = { [weak self] in self?.presentAskSurface() }
        // One way to open a session: a live session the daemon cannot find
        // opens through the Dock's window locator, off main, instead of
        // stopping at "not found".
        if isolatedPreview == nil {
            SessionOpener.wiring = SessionOpener.Wiring(core: core, utilities: utilitiesStore)
            // Software update: the embedded Sparkle, or a stub that says why not.
            let updater = SparkleUpdater(log: { [weak core] line in core?.appendLocalLog(level: "updater", line) })
            self.updater = updater
            settingsStore.refreshUpdater()
            settingsStore.observeUpdaterChanges()
        }
        store.onCheckForUpdates = { [weak self] in self?.checkForUpdates(nil) }
        statusItem.onCheckForUpdates = { [weak self] in self?.checkForUpdates(nil) }
        statusItem.showsCreatorMicro = { [weak store] in store?.hasCreatorMicro == true }
        installMainMenu()
        self.statusItem = statusItem
        startStatusIconWatchdog(statusItem)
        self.screenBar = screenBar
        self.feed = feed
        self.monitor = monitor
        self.core = core
        self.store = store
        self.panel = panel

        // Status item ↔ panel.
        panel.setAnchorProvider { [weak statusItem] in statusItem?.anchorRect }
        panel.onOpenStateChange = { [weak statusItem] open in
            statusItem?.setPanelOpen(open)
            if open { LaunchNotices.shared.panelOpened() }
        }
        statusItem.onTogglePanel = { [weak panel] in panel?.toggle() }
        statusItem.onUnsnoozeAll = { [weak core] in core?.snooze(session: nil, seconds: 0) }
        // Menu open is the reader's moment: force a usage refresh so the
        // meters answer with now, not the idle cadence's last reading.
        // The daemon admission-controls the poke, so rapid opens cost
        // nothing extra.
        statusItem.onMenuWillOpen = { [weak core] in
            guard let core else { return }
            Task { try? await core.refreshUsage() }
        }
        // The optional global hotkey (Settings › General) toggles the panel
        // through the same path the status item's click does.
        let hotkey = PanelHotkey()
        hotkey.onPress = { [weak panel] in panel?.toggle() }
        hotkey.setEnabled(settingsStore.panelHotkeyEnabled)
        settingsStore.panelHotkeyRegistrationFailed = hotkey.registrationFailed
        settingsStore.onPanelHotkeyChange = { [weak hotkey, weak settingsStore] on in
            hotkey?.setEnabled(on)
            settingsStore?.panelHotkeyRegistrationFailed = hotkey?.registrationFailed ?? false
        }
        self.hotkey = hotkey
        // Yoink's drop-target summon: ⌃⌥D toggles the island's shelf
        // card (the band's glass card with no island drawn) — open
        // pinned, a second press folds it. The band click's own
        // expand/collapse pair drives both directions so the card obeys
        // every existing guard (fold engaged, capsule mid-show).
        let shelfHotkey = PanelHotkey(signature: OSType(0x6A726273),
                                      keyCode: UInt32(kVK_ANSI_D))
        shelfHotkey.onPress = { [weak toysStore] in
            _ = toysStore?.notch.toggleShelf()
        }
        shelfHotkey.setEnabled(settingsStore.shelfHotkeyEnabled)
        settingsStore.shelfHotkeyRegistrationFailed = shelfHotkey.registrationFailed
        settingsStore.onShelfHotkeyChange = { [weak shelfHotkey, weak settingsStore] on in
            shelfHotkey?.setEnabled(on)
            settingsStore?.shelfHotkeyRegistrationFailed = shelfHotkey?.registrationFailed ?? false
        }
        self.shelfHotkey = shelfHotkey
        let studioHotkey = PanelHotkey(id: PanelHotkey.studioID, title: "Open Studio", defaultChord: PanelHotkey.studioDefault)
        studioHotkey.onPress = { [weak store] in store?.openEffects() }
        studioHotkey.setEnabled(settingsStore.studioHotkeyEnabled)
        settingsStore.studioHotkeyRegistrationFailed = studioHotkey.registrationFailed
        settingsStore.onStudioHotkeyChange = { [weak studioHotkey, weak settingsStore] on in
            studioHotkey?.setEnabled(on)
            settingsStore?.studioHotkeyRegistrationFailed = studioHotkey?.registrationFailed ?? false
        }
        self.studioHotkey = studioHotkey
        statusItem.onToggleScreenBar = { [weak self] shown in self?.setScreenBar(shown: shown) }
        store.onToggleScreenBar = { [weak self] shown in self?.setScreenBar(shown: shown) }
        store.onQuit = { NSApp.terminate(nil) }

        // The notch's glass drop-down — the band's peek and pin drive
        // it. It is the fallback surface: while the Notch island is
        // drawn the island itself grows into the card and the band's
        // gestures route to the toy instead, so the two can never both
        // be up. It hangs under the band, else the notch itself.
        let notchCard = NotchCardPresenter(
            model: NotchCardModel(timers: cardTimers, tray: cardTray,
                                      utility: isolatedPreview == nil ? nil : ShelfUtilityModel(power: AlcovePowerState(
                                          hasBattery: false, onAC: true, charging: false, percent: nil, fullyCharged: false)),
                                      runtimeEnabled: isolatedPreview == nil))
        // The Dock's player row borrows the Shelf's synced line — one
        // LRCLIB cache for the notch and the Dock, never a second lookup.
        utilitiesStore.dock.enhance.lyrics = { [weak notchCard, weak toysStore] in
            notchCard?.model.utility.lyrics.lyrics ?? toysStore?.notch.cardModel.utility.lyrics.lyrics
        }
        // …and its "Send to Shelf" lands in the one shared tray.
        utilitiesStore.dock.enhance.sendToShelf = { [weak cardTray] urls in cardTray?.add(urls) }
        // The Dock offers Send to Shelf only while the shelf takes files.
        toysStore.notch.onShelfSwitch = { [weak utilitiesStore, weak cardTray, weak notchCard] on in
            if !on { notchCard?.releaseShelfKeyboard() }
            let send: @MainActor ([URL]) -> Void = { urls in cardTray?.add(urls) }
            utilitiesStore?.dock.enhance.sendToShelf = on ? send : nil
        }
        notchCard.model.mirrorEnabled = { [weak toysStore] in toysStore?.state.notch.mirror ?? false }
        notchCard.focus = { [weak self] in self?.store?.screenBarFocus }
        notchCard.sessionRows = { [weak self] in
            NotchIsland.summarize(self?.core?.sessions ?? []).rows
        }
        notchCard.meters = { [weak self] in
            guard self?.toysStore?.state.notch.showUsage ?? true else { return [] }
            return NotchIsland.meters(self?.core?.state?.usage)
        }
        notchCard.anchor = { [weak self] in
            self?.screenBar?.bandScreenRect
                ?? NotchCardPresenter.notchAnchor()
        }
        // The docked buddy and toasts hang under the band; the card
        // drops below them, and their frame joins its hover corridor.
        notchCard.clearance = { [weak self] in
            self?.events?.hud.panelClearance ?? 0
        }
        // …and its calendar and reminders glances follow the Notch
        // settings' switches, the same as the grown island's.
        notchCard.model.presenceEnabled = { [weak core] in core?.settings?.document["presence_enabled"]?.boolValue ?? true }
        notchCard.model.mediaEnabled = { [weak toysStore] in toysStore?.state.notch.mediaEnabled ?? false }
        notchCard.model.calendarEnabled = { [weak toysStore] in toysStore?.state.notch.calendar ?? true }
        notchCard.model.remindersEnabled = { [weak toysStore] in toysStore?.state.notch.reminders ?? true }
        // Lyrics ask LRCLIB only once the switch is on and agreed to.
        toysStore.notch.wireLyrics(notchCard.model.utility.lyrics)
        notchCard.model.heldAwake = { [weak self] in self?.core?.state?.power?.keepAwake == true }
        // A reminder left from the glass card's session row says where
        // the run worked, as the island's does.
        notchCard.model.sessionCwd = { [weak self] id in self?.core?.state?.session(withID: id)?.cwd }

        // Screen Bar hover and click: hit-tested against the band and the
        // drawn wing chips, never focus-stealing.
        let interaction = ScreenBarInteraction(
            card: notchCard,
            hitRects: { [weak screenBar] in screenBar?.hoverScreenRects ?? [] },
            focus: { [weak store] in store?.screenBarFocus }
        )
        self.interaction = interaction
        interaction.underBandRegion = { [weak self] in
            self?.events?.hud.panelFrame
        }
        // The island's frame is part of the region — a click on the
        // island (or its grown card) must not read as outside.
        interaction.extraHitTest = { [weak screenBar] in screenBar?.shoulderContains($0) ?? false }
        interaction.extraHitRects = { [weak self] in
            self?.toysStore?.notch.islandScreenRect.map { [$0] } ?? []
        }
        // While the island is drawn it IS the notch's card: the band's
        // hover arms nothing, and its pin/dismiss grow and fold the
        // island instead of touching the glass panel.
        interaction.islandOwnsNotch = { [weak self] in
            self?.toysStore?.notch.isDrawingIsland ?? false
        }
        interaction.islandExpanded = { [weak self] in
            self?.toysStore?.notch.islandExpanded ?? false
        }
        interaction.onIslandExpand = { [weak self] in
            self?.toysStore?.notch.expandFromBand()
        }
        interaction.onIslandCollapse = { [weak self] in
            self?.toysStore?.notch.collapseFromBand()
        }
        // Hovering an ear is hovering the island — and a pointer still
        // on the band is not a leave for the island's collapse timer.
        // `fromBar` carries how the pointer arrived so the island's
        // debounce keeps its menu-bar floor.
        interaction.onIslandHover = { [weak self] hovering, fromBar in
            self?.toysStore?.notch.bandHover(hovering, fromBar: fromBar)
        }
        // The ear under the pointer swells — the tell that the notch is
        // alive while the island's debounce decides on the card.
        interaction.onWingHover = { [weak screenBar] side in screenBar?.hoverWing(side) }
        toysStore.notch.pointerOnBand = { [weak interaction] in interaction?.hovering ?? false }
        // With no island drawn, ⌃⌥D and `jrbar://shelf` open the glass
        // card on its Shelf page instead — the same two pages.
        toysStore.notch.toggleGlassShelf = { [weak interaction] in
            interaction?.toggleShelfCard() ?? "JR-Bar is still starting."
        }
        toysStore.notch.useGlassShelfKeyboard = { [weak notchCard] in
            guard let notchCard else { return "JR-Bar is still starting." }
            return notchCard.useShelfKeyboard()
        }
        toysStore.notch.releaseGlassShelfKeyboard = { [weak notchCard] in notchCard?.releaseShelfKeyboard() }
        // The grown island's card reads the same facts the glass one
        // does.
        toysStore.notch.cardFocus = { [weak self] in self?.store?.screenBarFocus }
        // The island's Screen-Bar-live read: the local show/hide flag,
        // never the daemon doc — a dead core must not un-bare the
        // island over the bar's ears.
        toysStore.notch.screenBarShown = { [weak store] in store?.screenBarShown ?? false }
        // One call fact: the notch's mic and camera reading goes to the
        // daemon as `presence` and comes back for the toys. The monitor
        // runs for that report while the daemon is there, and for the
        // ears while they can draw the dots — with the island off too.
        // What moves those answers re-syncs it: the daemon coming or
        // going, the band shown or hidden, a capsule on its flanks, the
        // wings setting.
        // JR-Bar's own Mirror, on either card surface, is the camera in
        // use but not a call.
        if isolatedPreview == nil {
            let presence = PresenceReporter(core: core, cards: { [weak toysStore, weak glassCard = notchCard.model] in
                [toysStore?.notch.cardModel, glassCard].compactMap { $0 }
            })
            self.presence = presence
            toysStore.notch.onSensorsChanged = { [weak presence] in presence?.noteSensors($0) }
            toysStore.notch.sensorsWantedForPresence = { [weak presence] in presence?.wantsSensors ?? false }
            toysStore.notch.sensorsWantedElsewhere = { [weak self] in self?.screenBar?.drawsSensorDots ?? false }
            presence.onDemandChanged = { [weak toysStore] in toysStore?.notch.syncSensorMonitor() }
            // The toys hush for a call: Confetti holds its burst and its
            // pop, the tank its cards, the buddy its hop.
            presence.onCallChanged = { [weak toysStore] in toysStore?.noteCallPresence($0) }
            presence.coreChanged()
            observeSensorDots()
        }
        // Wing gestures: an outward flick dismisses a side, a horizontal
        // swipe on the band summons dismissed wings back. The pull wires
        // make the ear ride the finger until the flick commits.
        interaction.wingSideAt = { [weak screenBar] point in screenBar?.wingSide(atScreenPoint: point) }
        toysStore.notch.wingOwnsGesture = { [weak screenBar] point in
            screenBar?.wingSide(atScreenPoint: point) != nil
        }
        // Nobody can see the band — asleep, or stepped aside for a video:
        // the hover poll parks with the band's own clocks.
        screenBar.onLiveChange = { [weak self, weak interaction, weak screenBar, weak notch = toysStore.notch] live in
            notch?.island?.setShoulderInput(live ? screenBar?.shoulderScreenPath : nil)
            notch?.bandHandlesHover = live
            interaction?.setParked(!live)
            self?.rearmAskAgeTick()
        }
        interaction.onWingDismiss = { [weak screenBar] side in screenBar?.dismissWing(side) }
        interaction.onWingRestore = { [weak screenBar] in screenBar?.restoreWings() }
        let canRestoreIslandWings: @MainActor @Sendable (NSPoint) -> Bool = { [weak screenBar, weak notch = toysStore.notch] point in
            guard let screenBar, let notch, let frame = notch.island?.presentedFrame else { return false }
            let headerHeight = max(44, notch.notchDepth + ScreenBarGeometry.wingEarDrop)
            return screenBar.wingRestorationContains(point, island: frame, headerHeight: headerHeight)
        }
        interaction.extraHitTest = { [weak screenBar] point in
            screenBar?.shoulderContains(point) == true || canRestoreIslandWings(point)
        }
        interaction.canRestoreIslandWings = canRestoreIslandWings
        toysStore.notch.canRestoreIslandWings = canRestoreIslandWings
        interaction.onWingPull = { [weak screenBar] side, dx in screenBar?.pullWing(side, to: dx) }
        interaction.onWingPullEnd = { [weak screenBar] side in screenBar?.releaseWingPull(side) }
        // The left ear's mark IS the focused session — a click opens it
        // outright rather than only growing the card past it.
        interaction.onWingActivate = { [weak self] side in
            guard let self, side == .left else { return false }
            let focus = self.store?.screenBarFocus
            guard let session = focus?.focusSession ?? focus?.clickSession else { return false }
            Task { @MainActor [weak self] in
                if let refusal = await SessionOpener.open(session) { self?.showFeedback(refusal) }
            }
            return true
        }
        // The right ear carries the keep-awake cup: a right-click on it
        // is the duration menu the notch chip and the footer cup offer.
        interaction.onWingSecondaryClick = { side, point in
            guard side == .right else { return false }
            KeepAwakeMenu.popUp(at: point)
            return true
        }
        interaction.rightWingOpensPeek = { [weak screenBar] in
            screenBar?.peekAvailable ?? false
        }
        screenBar.onAccessibilityPress = { [weak interaction] in
            interaction?.accessibilityPress() ?? false
        }
        screenBar.onAccessibilityWing = { [weak interaction] side in
            interaction?.accessibilityActivateWing(side) ?? false
        }
        // The right ear is the menu bar's reveal, update and newcomer
        // surface: its marks, and the black peek of hidden glyphs.
        screenBar.attachMenuBar(utilitiesStore.menuBar, interaction: interaction)
        screenBar.peek.onVisibilityChange = { [weak notch = toysStore.notch] shown in
            notch?.menuPopupShown = shown
        }
        // The card's timers: a due timer is one banner, never an agent
        // launch. Both card surfaces share `cardTimers`, so one wiring
        // covers the glass card and the grown island alike.
        let fireTimer: @MainActor @Sendable (ShelfTimerModel.Entry) -> Void = { [weak self] entry in
            self?.events?.notifications.deliver(.init(
                identifier: "shelf-timer:\(entry.id)",
                title: entry.label,
                body: "Timer done.",
                category: .plain))
        }
        cardTimers.onFire = fireTimer
        screenBar.focusProvider = { [weak store] in store?.screenBarFocus }
        screenBar.onGeometryChange = { [weak self, weak interaction, weak screenBar, weak notch = toysStore.notch] in
            notch?.island?.setShoulderInput(screenBar?.shoulderScreenPath)
            interaction?.geometryChanged()
            self?.rearmAskAgeTick()
        }
        // Alcove: the band follows the capsule while the setting is on and Alcove is up.
        if isolatedPreview == nil {
            let alcove = AlcoveFollower()
            alcove.onChange = { [weak self, weak screenBar] capsule in
                screenBar?.capsule = capsule
                self?.toysStore?.noteAlcoveCapsule(capsule)
                self?.toysStore?.notch.syncSensorMonitor()
                self?.lastLightsSource = nil
                self?.refreshLights()
            }
            self.alcove = alcove
        }
        store.onOpenSettings = { [weak settingsWindow] page in settingsWindow?.show(page: page) }
        statusItem.onOpenSettings = { [weak settingsWindow] in settingsWindow?.show() }

        // History window (⌘Y).
        let historyStore = HistoryStore(core: core)
        let historyWindow = HistoryWindowController(store: historyStore)
        self.historyStore = historyStore
        self.historyWindow = historyWindow
        store.onOpenHistory = { [weak historyWindow] in historyWindow?.show() }
        store.onOpenEvents = { [weak historyWindow] in historyWindow?.showEvents() }
        statusItem.onOpenHistory = { [weak historyWindow] in historyWindow?.show() }

        // Overview window (⌘O): the scoped roster workspace.
        let overviewStore = OverviewStore(core: core, sessionUsage: store.sessionUsage)
        // The Usage heatmap's day click, one window over.
        overviewStore.onOpenHistoryDay = { [weak historyWindow] day in historyWindow?.show(day: day) }
        let overviewWindow = OverviewWindowController(store: overviewStore)
        self.overviewWindow = overviewWindow
        store.onOpenOverview = { [weak overviewWindow] in overviewWindow?.show() }
        statusItem.onOpenOverview = { [weak overviewWindow] in overviewWindow?.show() }
        // The pinned card's roster affordance opens the same window —
        // on the glass card and on the island's grown one.
        notchCard.onOpenOverview = { [weak overviewWindow] in overviewWindow?.show() }
        toysStore.notch.onOpenOverview = { [weak overviewWindow] in overviewWindow?.show() }
        utilitiesStore.agents.onOpenOverview = { [weak overviewWindow] in overviewWindow?.show() }
        utilitiesStore.agents.connectionDescription = { [weak store] in
            store?.connectionDescription ?? "Monitor not connected"
        }
        utilitiesStore.agents.onOpenMonitorDetails = { [weak overviewWindow] in
            overviewWindow?.show(link: "core")
        }
        utilitiesStore.menuBar.coreFacts = { [weak core, weak store] in
            guard let core, let store else { return MenuBarCoreFacts() }
            return MenuBarCoreFacts.read(core: core, aggregate: store.aggregate)
        }

        // Event Replay is History's Events tab: History owns the journal,
        // and its rows point at the Overview's inspector for a session's
        // full story.
        statusItem.onOpenReplay = { [weak historyWindow] in historyWindow?.showEvents() }
        historyStore.onRevealSession = { [weak overviewWindow] id in overviewWindow?.show(selecting: id) }

        // Usage Center (⌘U) and Effect Studio windows.
        let usageStore = UsageCenterStore(core: core, sessionUsage: store.sessionUsage)
        let usageWindow = UsageCenterWindowController(store: usageStore)
        self.usageStore = usageStore
        self.usageWindow = usageWindow
        store.onOpenUsageCenter = { [weak usageWindow] provider in
            // A provider id means the panel's usage row was clicked:
            // scroll to that card and flash it.
            usageWindow?.show(focusedProvider: provider)
        }
        statusItem.onOpenUsageCenter = { [weak usageWindow] in usageWindow?.show() }
        settingsStore.onOpenUsageCenter = { [weak usageWindow] in usageWindow?.show() }
        let effectsStore = EffectStudioStore(core: core)
        let effectsWindow = EffectStudioWindowController(store: effectsStore)
        self.effectsStore = effectsStore
        self.effectsWindow = effectsWindow
        store.onOpenEffects = { [weak effectsWindow] in effectsWindow?.show() }
        statusItem.onOpenEffects = { [weak effectsWindow] in effectsWindow?.show() }
        settingsStore.onOpenEffects = { [weak effectsWindow] in effectsWindow?.show() }
        let menuBarRules = utilitiesStore.menuBar.stateRules
        menuBarRules.sceneLease.connect(to: core)
        menuBarRules.quietLease.connect(to: core)

        let deckStore = DeckStore(core: core)
        let controlCenterWindow = ControlCenterWindowController(store: deckStore)
        let rail = DeckRailController(store: deckStore)
        self.deckStore = deckStore
        self.controlCenterWindow = controlCenterWindow
        self.rail = rail
        store.onOpenControlCenter = { [weak controlCenterWindow] in controlCenterWindow?.show() }
        statusItem.onOpenControlCenter = { [weak controlCenterWindow] in controlCenterWindow?.show() }
        settingsStore.onOpenControlCenter = { [weak controlCenterWindow] in controlCenterWindow?.show() }
        deckStore.onOpenControlCenter = { [weak controlCenterWindow] in controlCenterWindow?.show() }

        // ⌘⇧K is JR-Bar's palette, not only the menu bar's: register
        // every source past the menu bar's own rows, the frecency it
        // ranks by, and the panel's toast as the HUD's voice for the
        // verbs that report through it. While the Menu Bar utility is
        // parked the palette keeps its key on its own.
        let commandBar = utilitiesStore.menuBar.actions.commandBar
        commandBar.sources = PaletteWiring.sources(
            panel: store, effects: effectsStore,
            toggles: { [weak toysStore] in toysStore?.notch.cardModel.utility.toggles },
            aquarium: { [weak toysStore] in toysStore?.aquarium },
            confetti: { [weak toysStore] in toysStore?.confetti },
            history: historyStore,
            windows: PaletteWiring.Windows(
                overview: { [weak overviewWindow] in overviewWindow?.show() },
                usageCenter: { [weak usageWindow] provider in usageWindow?.show(focusedProvider: provider) },
                history: { [weak historyWindow] in historyWindow?.show() },
                effects: { [weak effectsWindow] in effectsWindow?.show() },
                deck: { [weak controlCenterWindow] in controlCenterWindow?.show() },
                replay: { [weak historyWindow] in historyWindow?.showEvents() },
                panel: { [weak panel] in panel?.toggle() },
                checkForUpdates: { [weak self] in self?.checkForUpdates(nil) },
                settings: { [weak settingsWindow] chapter in settingsWindow?.show(chapter: chapter) }))
        commandBar.palette.usage = { [weak utilitiesStore] in utilitiesStore?.state.commandUses ?? PaletteUsage() }
        commandBar.palette.recordUse = { [weak utilitiesStore] key in utilitiesStore?.state.commandUses.record(key) }
        commandBar.palette.toggleFavorite = { [weak utilitiesStore] key in
            utilitiesStore?.state.commandUses.toggleFavorite(key)
        }
        commandBar.palette.forgetUse = { [weak utilitiesStore] key in
            utilitiesStore?.state.commandUses.forget(key)
        }
        commandBar.palette.toastFeed = { [weak store] in store?.toast }
        commandBar.openSettings = { [weak settingsWindow] in settingsWindow?.show(page: .utilities) }
        // Command Palette… in More, the right-click menu and the app menu.
        store.onOpenPalette = { [weak commandBar] in commandBar?.open() }
        statusItem.onOpenPalette = { [weak commandBar] in commandBar?.open() }
        utilitiesStore.menuBar.actions.paletteBinding = { [weak utilitiesStore] in
            utilitiesStore?.menuBar.resolvedHotkeyBindings().first { $0.action == .commandBar }
        }

        // Events → the Mac: sounds, banners, the HUD, the amber pulse, the chime.
        let events = EventCoordinator(core: core, hudAnchor: { [weak screenBar] in screenBar?.bandScreenRect })
        self.events = events
        events.toys = toysStore
        // Smart suppression is the Agent utility's own toggle — a
        // session's pane already in front earns silence, not noise.
        events.quietWhenPaneFrontmost = { [weak utilitiesStore] in
            utilitiesStore?.agents.settings().quietWhenPaneFrontmost ?? true
        }
        // The Agent Overview card's per-provider alert rules: how loud
        // each provider's asks, finishes, failures and escalation may be.
        events.deliveryRules = { [weak utilitiesStore, weak core, weak store] delivery, event in
            var delivery = delivery
            if let rules = utilitiesStore?.agents.settings().alertRules, !rules.isEmpty {
                delivery = AgentAlertRules.apply(delivery, to: event, state: core?.state, rules: rules,
                                                 currentStage: core?.state?.escalation?.stageNumber)
            }
            // A panel row's "Notify when done" is the explicit ask: it
            // banners that one ending whatever the switches say.
            if store?.consumeDoneWatch(for: event) == true {
                delivery = AgentAlertRules.notifyWhenDone(delivery, event: event, state: core?.state)
            }
            return delivery
        }
        // The HUD panel is the Notch Buddy's home: it lives there between
        // toasts and steps aside while one is up.
        events.hud.buddy = toysStore.notchBuddy
        // The level capsules ride the notch's own switch and provider:
        // they draw while the notch is ours and on.
        events.hud.mediaHUDAllowed = { [weak toysStore] in
            let notch = toysStore?.state.notch ?? NotchSettings()
            return notch.enabled && notch.provider == .jrbar && notch.mediaHUD
        }
        // The consuming tap's license: same notch gate as the capsules
        // plus its own opt-in — a disabled notch or a flipped setting
        // drops the tap back to listen-only at the next key event.
        events.hud.mediaKeys.replaceHUDWanted = { [weak toysStore] in
            let notch = toysStore?.state.notch ?? NotchSettings()
            return notch.enabled && notch.provider == .jrbar
                && notch.mediaHUD && notch.replaceSystemHUD
        }
        events.hud.alertsAllowed = { [weak toysStore] in
            let notch = toysStore?.state.notch ?? NotchSettings()
            return notch.enabled && notch.provider == .jrbar && notch.alerts
        }
        events.hud.soundEffectsAllowed = { [weak toysStore] in
            let notch = toysStore?.state.notch ?? NotchSettings()
            return notch.enabled && notch.provider == .jrbar && notch.soundEffects
        }
        // The tap and the announcement watchers start only now that the
        // real gates are in; the tap then re-syncs on every notch reconcile.
        if isolatedPreview == nil { events.hud.startSystemWatchers() }
        if isolatedPreview == nil {
            toysStore.notch.onMediaGateChanged = { [weak events] in
                events?.hud.syncMediaTap()
            }
        }
        // An announcement the island queued, then gave up to newer news,
        // takes the pill instead of vanishing.
        toysStore.notch.onCapsuleEvicted = { [weak events] notice in
            events?.hud.islandDropped(notice)
        }
        events.onStatusPulse = { [weak statusItem] on in statusItem?.setEscalationPulse(on) }
        events.onOpenRefused = { [weak self] text in self?.showFeedback(text) }
        // Approve/Deny on a banner go through the panel's desk, pinned to
        // the banner's own ask; a refusal becomes a follow-up banner that
        // opens the session on click.
        events.askDesk = store.askDesk

        // File feeds: the fallback until the daemon is connected.
        feed?.onProgram = { [weak self] text, source, anchor in
            guard let self else { return }
            // A strip giving way to the idle breath fades rather than cuts.
            if case .device = self.lastFileProgram?.source, source == .builtInIdle {
                self.screenBar?.crossfadeNextProgram()
            }
            self.lastFileProgram = (text, source, anchor)
            self.store?.feedDescription = source.description
            if self.core?.isLive != true { self.applyFileProgram() }
        }
        monitor?.onChange = { [weak self] state, detail in
            guard let self else { return }
            self.store?.fallbackState = state
            self.store?.fallbackDetail = detail
            self.refreshAggregate()
        }

        // Durable reoffers revisit receipt-aware Confetti without replaying
        // notifications, aquarium cues or the event history.
        core.onResetReplay = { [weak self] event in
            self?.toysStore?.confetti.noteEvent(event)
        }
        // Daemon protocol: beats the files whenever it is live.
        core.onEvent = { [weak events, weak self] event in
            events?.handle(event)
            if event.kind == "completed" { self?.noteCompletion() }
            // The daemon finished a transcript scan: the panel's sparklines
            // were drawn from a partial answer and can be redrawn now.
            if event.kind == CoreEvent.usageHistoryReadyKind { self?.store?.refreshSparklines(force: true) }
            // A deck key asked for a window or the waiting ask: the same
            // router a jrbar:// link runs through.
            if let command = AppCommand.requested(by: event) {
                _ = Task {
                    guard AppCommand.requested(by: event) == command else { return }
                    await AppCommandRouter.shared.perform(command)
                }
            }
        }
        observeCore()
        watchSocketDirectory(core.socketPath)

        // The supervised daemon started at the top of this launch; the
        // packaged integration refresh and login item wait for the wiring.
        if let bundledCore { completePackagedLaunch(with: bundledCore, core: core) }

        let shown = appState.showScreenBar
        ScreenBarInteraction.diag("didFinishLaunching shown=\(shown)")
        statusItem.isScreenBarShown = shown
        store.screenBarShown = shown
        if shown { screenBar.show(); interaction.start() }
        refreshAlcoveFollowing()
        feed?.start()
        monitor?.start()
        core.start()
        // Turn on whatever the Utilities page has on — a parked utility
        // owns nothing until this lands.
        if isolatedPreview == nil {
            utilitiesStore.applySettings()
        } else {
            utilitiesStore.menuBar.applySettings()
        }
        if isolatedPreview == nil { wireShell() }

        // The first-run walkthrough: agents, permissions, menu bar.
        // `shouldPresentOnLaunch` gates the auto-show, which asks to come
        // active but never forces it (`showOnLaunch`); Settings ›
        // General's "Run Setup Again" opens the same window.
        if isolatedPreview == nil {
            let setup = SetupWindowController.shared
            setup.store.model = .live(core: core)
            setup.store.model.permissionPlan = { [weak self, weak core] in
                guard let self else { return SetupPermissionPlan(active: []) }
                let toys = self.toysStore?.state ?? self.appState.toys
                let utilities = self.utilitiesStore?.state ?? self.appState.utilities
                let document = SettingsDocument(core?.settings?.document ?? .object([:]))
                let followsAlcove = self.appState.showScreenBar && toys.notch.enabled
                    && toys.notch.provider == .alcove && (self.alcove?.isAlcoveRunning ?? false)
                    && (document.bool("screen_bar_follow_alcove") ?? true)
                return SetupPermissionPlan.features(toys: toys, utilities: utilities,
                                                    document: document, followsAlcove: followsAlcove)
            }
            setup.store.model.screenBarShown = { [weak self] in self?.appState.showScreenBar ?? true }
            setup.store.model.setScreenBar = { [weak self] shown in self?.setScreenBar(shown: shown) }
            setup.store.model.iconStyle = { [weak settingsStore] in
                settingsStore?.menuBarIconStyle ?? StatusIconStyle.agents.rawValue
            }
            setup.store.model.setIconStyle = { [weak settingsStore] in settingsStore?.menuBarIconStyle = $0 }
            setup.store.onOpenToys = { [weak settingsWindow] in settingsWindow?.show(chapter: .toys) }
            let setupShown = setup.store.shouldPresentOnLaunch
            if setupShown { setup.showOnLaunch() }

            // What's New: once per release, after Setup has run to its end
            // and never in the launch that shows it, at the first moment the
            // monitor is live, the session unlocked and nothing full screen
            // in front. Closing it stamps the release in setup.json.
            let whatsNew = WhatsNewWindowController()
            whatsNew.markSeen = { [weak setup] release in setup?.store.markWhatsNewSeen(release) }
            self.whatsNewWindow = whatsNew
            if WhatsNewGate.isArmed(setupFinished: setup.store.hasFinished, setupShownThisLaunch: setupShown,
                                    seen: setup.store.whatsNewSeen) {
                whatsNew.arm(core: core)
            }

        }

        // Developer switches: `JRBAR_OPEN_PANEL=1` opens the panel shortly
        // after launch (screenshots, design passes) without a click;
        // `JRBAR_OPEN_SETTINGS=<page>` opens the Settings window on that page
        // (general, agents, usage, devices, lighting, toys, notifications,
        // remote, advanced, or effects); `JRBAR_SCREEN_BAR=on|off` flips the Screen
        // Bar the way the status item's toggle does (screenshots without the
        // band, and a persistence check for the remembered value).
        let environment = ProcessInfo.processInfo.environment
        switch environment["JRBAR_SCREEN_BAR"]?.lowercased() {
        case "on", "1": setScreenBar(shown: true)
        case "off", "0": setScreenBar(shown: false)
        default: break
        }
        if let openPanel = environment["JRBAR_OPEN_PANEL"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak panel] in
                MainActor.assumeIsolated { panel?.open() }
            }
            // `JRBAR_OPEN_PANEL=why` also hovers the "Why this light" row;
            // `=clear` sends Clear finished once the core is live, so the
            // footer's Undo offer can be photographed.
            if openPanel == "why" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak panel] in
                    MainActor.assumeIsolated { panel?.showWhyPopover() }
                }
            }
            if openPanel == "clear" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak store] in
                    MainActor.assumeIsolated { store?.clearCompleted() }
                }
            }
        }
        // `JRBAR_RENDER_ICONS=/dir` writes the status item styles as PNGs
        // (8×) for design review, then carries on.
        if let directory = environment["JRBAR_RENDER_ICONS"], !directory.isEmpty {
            // Once at launch (so a run with no daemon still produces the
            // sheet) and again once the core has answered, with the
            // reader's own providers in the columns.
            StatusItemController.renderStyles(to: directory)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak statusItem] in
                MainActor.assumeIsolated {
                    guard let statusItem, !statusItem.meters.isEmpty || !statusItem.sessionDots.isEmpty else { return }
                    StatusItemController.renderStyles(to: directory, live: statusItem.meters, liveDots: statusItem.sessionDots)
                    print("status icons: re-rendered with \(statusItem.meters.count) live meters, \(statusItem.sessionDots.count) sessions")
                }
            }
        }
        // `JRBAR_OPEN_WHATS_NEW=1` opens What's New by hand (screenshots);
        // closing it stamps the release like any close.
        if environment["JRBAR_OPEN_WHATS_NEW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.whatsNewWindow?.show() }
            }
        }
        if environment["JRBAR_OPEN_HISTORY"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak historyWindow] in
                MainActor.assumeIsolated { historyWindow?.show() }
            }
        }
        // `JRBAR_OPEN_USAGE=1` opens the Usage Center; `JRBAR_OPEN_EFFECTS=1`
        // (or an effect id) opens the Effect Studio, on that effect.
        if environment["JRBAR_OPEN_USAGE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak usageWindow] in
                MainActor.assumeIsolated { usageWindow?.show() }
            }
        }
        if let effect = environment["JRBAR_OPEN_EFFECTS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak effectsWindow] in
                MainActor.assumeIsolated { effectsWindow?.show(effect: effect == "1" ? nil : effect) }
            }
        }
        // `JRBAR_OPEN_CONTROL_CENTER=1` opens the Control Center;
        // `JRBAR_DECK_RAIL=left|right|top|bottom` asks the core to show the
        // rail on that edge once live (screenshots).
        if let mode = environment["JRBAR_OPEN_CONTROL_CENTER"] {
            // `apply`, `restore` or `clear` also opens that sheet once the
            // core is live, so the sheet's plan request has a socket (screenshots).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak controlCenterWindow, weak deckStore, weak core] in
                MainActor.assumeIsolated {
                    controlCenterWindow?.show()
                    guard ["apply", "restore", "clear"].contains(mode) else { return }
                    _ = Task { @MainActor in
                        for _ in 0..<40 where core?.isLive != true { try? await Task.sleep(for: .milliseconds(250)) }
                        switch mode {
                        case "apply": deckStore?.openApplySheet()
                        case "restore": deckStore?.openRestoreSheet()
                        default: deckStore?.openClearAbsentSheet()
                        }
                    }
                }
            }
        }
        if let edgeName = environment["JRBAR_DECK_RAIL"], let edge = DeckRailEdge(rawValue: edgeName) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak core] in
                MainActor.assumeIsolated {
                    _ = Task { _ = try? await core?.deckRail(edge: edge) }
                }
            }
        }
        if let pageName = environment["JRBAR_OPEN_SETTINGS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak settingsWindow, weak effectsWindow] in
                MainActor.assumeIsolated {
                    if pageName == "effects" { effectsWindow?.show(); return }
                    settingsWindow?.show(named: pageName)
                }
            }
        }
        if let device = environment["JRBAR_OPEN_CALIBRATE"] {
            // Opens the calibration sheet on that device id -- the
            // screenshot path for the sheet (mock core only). Shows the
            // Settings window on Devices first when nothing else did.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak settingsWindow] in
                MainActor.assumeIsolated {
                    if environment["JRBAR_OPEN_SETTINGS"] == nil { settingsWindow?.show(page: .devices) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak settingsStore] in
                MainActor.assumeIsolated { settingsStore?.calibrating = device }
            }
        }
    }

    /// The note a second launch posts before it yields, and the running
    /// instance answers: bring JR-Bar up for the person who just opened it.
    nonisolated static let showRequestName = Notification.Name("com.jonathanreed.jrbar.show-request")

    private var statusIconWatchdog: StatusIconWatchdog?
    private var showRequestObserver: NSObjectProtocol?

    /// The last resort behind the icon's other guards: if our own icon
    /// cannot be proven on the bar some seconds after launch, the item is
    /// recreated, with the reason logged. Also answers a second launch's request to show itself.
    private func startStatusIconWatchdog(_ statusItem: StatusItemController) {
        let log = Logger(subsystem: "devin.jrbar", category: "status-item")
        let watchdog = StatusIconWatchdog(
            proof: { [weak self, weak statusItem] in
                guard let statusItem else { return StatusIconProof() }
                let utility = self?.utilitiesStore?.menuBar
                return StatusIconProof(
                    itemVisibleFlag: statusItem.isFlaggedVisible,
                    itemOnRow: statusItem.isOnBarRow,
                    styleDrawsIcon: statusItem.anchorWantsVisibleSeat)
            },
            act: { [weak self, weak statusItem] action in
                switch action {
                case .none:
                    break
                case .showItem:
                    statusItem?.ensureVisible()
                case .recreateItem(let resetPlacement, let reason):
                    statusItem?.recreate(resetPlacement: resetPlacement, reason: reason)
                }
            })
        watchdog.start()
        statusIconWatchdog = watchdog
        showRequestObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.showRequestName, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.bringUp() }
        }
    }

    /// Someone opened JR-Bar while it runs: Finder, Spotlight, the Dock,
    /// `open`, or a second copy yielding. The menu bar item may be exactly
    /// what they cannot find, so Settings opens (the one window that is
    /// always available) and the icon is re-checked at once.
    private func bringUp() {
        statusIconWatchdog?.reopened()
        settingsWindow?.show()
    }

    /// A launch of the running app lands here, as `applicationShouldHandleReopen`
    /// — the Dock icon of a regular app, `open JR-Bar.app`, a double click.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Our own Launch Services fallback (`WindowFront`) is no one looking
        // for the icon: the window it was bringing forward is the answer.
        if WindowFront.consumeOwnReopen() {
            statusIconWatchdog?.reopened()
            return false
        }
        bringUp()
        return false
    }

    /// Set once a quit has begun, so nothing starts the daemon behind it.
    private var isQuitting = false

    /// The modes a quit's nested loop may be turning in while it waits for
    /// the daemon.
    private static let quitModes: [RunLoop.Mode] = [.default, .common, .modalPanel, .eventTracking]

    /// A quit gives the daemon its SIGTERM and up to three seconds before
    /// SIGKILL. That wait happens here, on a background queue, while the run
    /// loop keeps turning, and not on the main thread inside
    /// `applicationWillTerminate`, which stalled the whole app for as long as
    /// the daemon took to leave.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.shutdownLog.notice("quit.requested")
        isQuitting = true
        SingleInstanceLock.markQuitting(instanceLockFD)
        guard let supervisor, supervisor.state != .stopped, supervisor.state != .idle else {
            Self.shutdownLog.notice("quit.immediate")
            return .terminateNow
        }
        // The item leaves the bar now, not when the daemon is gone.
        Self.shutdownLog.notice("status-item.remove.begin")
        statusItem?.tearDown()
        Self.shutdownLog.notice("status-item.remove.end")
        DispatchQueue.global(qos: .userInitiated).async {
            Self.shutdownLog.notice("core.stop.begin")
            supervisor.stop(gracePeriod: 3.0)
            Self.shutdownLog.notice("core.stop.end")
            // The run loop's queue, not the main dispatch queue: a quit that
            // began inside a block on that queue cannot drain it.
            RunLoop.main.perform(inModes: Self.quitModes) {
                Self.shutdownLog.notice("quit.reply")
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.shutdownLog.notice("cleanup.begin")
        // First word: this instance is on its way out. A relaunch inside
        // the daemon's grace below waits for the lock rather than yielding
        // to a process that is about to be gone, which left no icon at all.
        SingleInstanceLock.markQuitting(instanceLockFD)
        statusIconWatchdog?.stop()
        if let showRequestObserver {
            DistributedNotificationCenter.default().removeObserver(showRequestObserver)
        }
        // Finish debounced edits before the main run loop stops.
        toysStore?.save()
        toysStore?.shutdown()
        utilitiesStore?.save()
        Self.shutdownLog.notice("cleanup.persistence.end")
        hotkey?.unregister()
        studioHotkey?.unregister()
        panel?.close()
        interaction?.stop()
        screenBar?.hide()
        events?.reset()
        Self.shutdownLog.notice("cleanup.surfaces.end")
        // The palette folds and its parked ⌘⇧K lets go for good — the
        // utility's stop below would otherwise re-arm it.
        utilitiesStore?.menuBar.actions.shutDownPalette()
        // A clean quit puts the menu bar's hidden items back before the
        // spacers vanish with the process. The "while" rules
        // keep their LED scene: the write that would put yours back could
        // never land, and the next launch restores it once the core is
        // live.
        utilitiesStore?.menuBar.stop(forQuit: true)
        Self.shutdownLog.notice("cleanup.menu-bar.end")
        if isolatedPreview == nil { utilitiesStore?.stop() }
        Self.shutdownLog.notice("cleanup.utilities.end")
        // The item leaves the bar now, not when the process ends behind
        // the daemon's grace.
        statusItem?.tearDown()
        // The child gets SIGTERM and three seconds before SIGKILL.
        supervisor?.stop(gracePeriod: 3.0)
        Self.shutdownLog.notice("cleanup.supervisor.end")
        core?.stop()
        Self.shutdownLog.notice("cleanup.transport.end")
        // Everything this instance owned is down: hand the lock back so
        // the next launch does not wait on our exit.
        SingleInstanceLock.release(instanceLockFD)
        instanceLockFD = -1
        Self.shutdownLog.notice("cleanup.complete.end")
    }

    // MARK: Core supervision

    /// The daemon's stdout/stderr in the unified log. Public on purpose:
    /// NSLog's arguments are private, so `log show` read every line —
    /// the refresh-timing flight recorder, the errors — as `<private>`,
    /// and the in-app log already shows the same text on this Mac.
    nonisolated private static let coreLog = Logger(subsystem: "devin.jrbar", category: "core")
    nonisolated private static let shutdownLog = Logger(subsystem: "devin.jrbar", category: "shutdown")

    /// Core supervision: with JRBAR_CORE_EXEC set, the daemon is our
    /// child and we keep it alive. A packaged bundle carries its own
    /// daemon under Contents/Helpers and supervises that. Otherwise we
    /// connect to whatever listens on the socket (the dev LaunchAgents).
    /// Returns the bundled daemon when that is the one started, for the
    /// first run's hook install.
    private func startCoreSupervision(core: CoreModel, store: PanelStore) -> CoreSupervisor.BundledCore? {
        guard isolatedPreview == nil else { return nil }
        // The key the daemon seals its protected settings with, read from the
        // Keychain once, when the supervisor first needs it, and never with a
        // prompt (docs/CORE-PROTOCOL.md, "Protected settings").
        let sealHolder = SettingsSealKeyHolder(store: KeychainSettingsSealKeyStore())
        let sealKey: @Sendable () -> SettingsSealHandoff? = { sealHolder.handoff() }
        let seal = SettingsSealCoordinator(holder: sealHolder, send: { [weak core] command in
            guard let core else { throw CoreClientError.notConnected }
            return try await core.send(command, timeout: 15)
        })
        sealCoordinator = seal
        core.onSettingsFrame = { [weak core, weak seal] settings in
            seal?.settingsArrived(settings, authenticated: core?.authState == .authenticated)
        }
        if let command = ProcessInfo.processInfo.environment["JRBAR_CORE_EXEC"], !command.isEmpty {
            if let supervisor = CoreSupervisor(commandLine: command, authSecret: core.authSecret, sealKey: sealKey) {
                attachSupervisor(supervisor, describedAs: "`\(command)`", sealHolder: sealHolder, core: core, store: store)
            }
            return nil
        }
        guard let bundled = CoreSupervisor.bundledCore(in: Bundle.main) else { return nil }
        attachSupervisor(CoreSupervisor(bundled: bundled, authSecret: core.authSecret, sealKey: sealKey), describedAs: "the bundled daemon (\(bundled.buildStamp))",
                         sealHolder: sealHolder, core: core, store: store)
        return bundled
    }

    private func attachSupervisor(_ supervisor: CoreSupervisor, describedAs description: String,
                                  sealHolder: SettingsSealKeyHolder, core: CoreModel, store: PanelStore) {
        self.supervisor = supervisor
        supervisor.onOutput = { [weak core] stream, line in
            Task { @MainActor [weak core] in
                core?.appendLocalLog(level: stream == "stderr" ? "core" : (stream == "supervisor" ? "supervisor" : "core"), line)
            }
            Self.coreLog.notice("\(stream, privacy: .public): \(line, privacy: .public)")
        }
        supervisor.onStateChange = { [weak self, weak core, weak store] state in
            Task { @MainActor [weak self, weak core, weak store] in
                store?.supervisorState = state
                if case .running = state { core?.retryNow() }
                self?.coreDidChange()
            }
        }
        store.onRestartCore = { [weak supervisor] in supervisor?.restart() }
        watchAuthentication(of: core, supervisor: supervisor)
        store.supervisorState = .idle
        core.appendLocalLog(level: "supervisor", "supervising \(description)")
        // The Keychain read for the seal key is a synchronous call; it is made
        // off the main thread, and the daemon starts once the key is held.
        sealHolder.warm { [weak self, weak supervisor] in
            DispatchQueue.main.async {
                guard let self, let supervisor, !self.isQuitting else { return }
                supervisor.start()
            }
        }
    }

    /// The daemon this app starts holds the app's secret. When it will not
    /// authenticate the connection, the app restarts it once (a fresh child, a
    /// fresh secret) and otherwise leaves `core.authState` and the log to say
    /// why; another daemon holding the socket is not ours to restart.
    private func watchAuthentication(of core: CoreModel, supervisor: CoreSupervisor) {
        var restarts = 0
        core.onAuthenticated = { [weak self] in
            restarts = 0
            self?.sealCoordinator?.authenticationSucceeded()
        }
        sealCoordinator?.onNeedsDaemonRestart = { [weak supervisor] in supervisor?.restart() }
        core.onAuthRefused = { [weak supervisor, weak core] reason in
            switch reason {
            case .proofRejected, .noReply, .daemonOffersNoChallenge:
                guard let supervisor, restarts < 1 else { return }
                restarts += 1
                core?.appendLocalLog(level: "supervisor", "restarting the daemon once to give it a fresh secret")
                supervisor.restart()
            case .peerIsNotOurDaemon:
                break
            }
        }
    }

    /// Fresh setup chooses its providers. An upgrade refreshes only the
    /// integrations the daemon still recognizes as JR-Bar's.
    private func completePackagedLaunch(with bundled: CoreSupervisor.BundledCore, core: CoreModel) {
        let stamp = bundled.buildStamp
        switch PackagedHookRefresh.action(previous: appState.bundledHooksInstalledFor,
                                         current: stamp, coreLive: false) {
        case .stampOnly:
            appState.bundledHooksInstalledFor = stamp
            persistAppState()
        case .wait:
            pendingHookRefreshStamp = stamp
        case .none, .refresh:
            break
        }
        if !appState.loginItemRegistered {
            // The very first launch opens the panel once, so the one
            // surface a menu-bar app has is found without a lucky click.
            // `loginItemRegistered` is the flag — it is only ever false
            // before this first run completes. Setup, which presents on
            // that launch too, goes first: the panel waits until it is
            // finished or dismissed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                MainActor.assumeIsolated {
                    SetupWindowController.shared.afterClose { self?.panel?.open() }
                }
            }
            do {
                try SMAppService.mainApp.register()
                core.appendLocalLog(level: "supervisor", "launch at login: registered (Settings › General turns it off)")
            } catch {
                core.appendLocalLog(level: "supervisor", "launch at login: \(error.localizedDescription)")
            }
            appState.loginItemRegistered = true
            persistAppState()
        }
    }

    private func refreshPackagedHooksIfNeeded(core: CoreModel) {
        guard core.isLive, let stamp = pendingHookRefreshStamp,
              PackagedHookRefresh.peerMatches(connected: core.connection.isConnected,
                                              peerPID: core.hello?.pid, supervisor: supervisor?.state) else { return }
        pendingHookRefreshStamp = nil
        Task { @MainActor [weak self, weak core] in
            guard let core else { return }
            do {
                let reply = try await core.refreshHooksNow()
                guard let self else { return }
                if let providers = PackagedHookRefresh.completedProviders(in: reply) {
                    self.appState.bundledHooksInstalledFor = stamp
                    self.persistAppState()
                    core.appendLocalLog(level: "hooks", "refreshed \(providers.count) existing integrations for \(stamp)")
                } else {
                    let results = reply.result?["results"]?.objectValue ?? [:]
                    for (provider, result) in results where result["ok"]?.boolValue != true {
                        let reason = result["error"]?.stringValue ?? "refresh did not confirm success"
                        core.appendLocalLog(level: "hooks", "\(provider): \(reason)")
                    }
                    if let reason = reply.error?.message { core.appendLocalLog(level: "hooks", reason) }
                    self.showHookRefreshFailure()
                }
            } catch {
                core.appendLocalLog(level: "hooks", "refresh failed: \(error)")
                self?.showHookRefreshFailure()
            }
        }
    }

    private func showHookRefreshFailure() {
        store?.show(toast: "Existing integrations could not refresh. JR-Bar will retry next launch.",
                    actionTitle: "Open Settings") { [weak self] in
            self?.settingsWindow?.show(page: .agents)
        }
    }

    // MARK: App state

    /// Reads `app-state.json`, seeding it from the user-defaults keys the
    /// facts used to live under when the file does not exist yet, and logs
    /// what came back so a relaunch can be checked from the console.
    private func loadAppState() {
        if let isolatedPreview {
            _ = appStateFile.loadChecked()
            appState = isolatedPreview.reviewState()
            return
        }
        let defaults = UserDefaults.standard
        let loaded = appStateFile.loadChecked()
        appState = loaded.state
        if case .unreadable(let why) = loaded.outcome {
            tellAppStateWasUnreadable(why)
        }
        if !appStateFile.exists {
            var seeded = false
            if let stamp = defaults.string(forKey: Self.hooksInstalledForKey) {
                appState.bundledHooksInstalledFor = stamp; seeded = true
            }
            if defaults.object(forKey: Self.showScreenBarKey) != nil {
                appState.showScreenBar = defaults.bool(forKey: Self.showScreenBarKey); seeded = true
            }
            if defaults.bool(forKey: Self.loginItemRegisteredKey) {
                appState.loginItemRegistered = true; seeded = true
            }
            if seeded { persistAppState() }
        }
        NSLog("JR-Bar app state (%@): hooksInstalledFor=%@ showScreenBar=%d loginItemRegistered=%d; defaults: %@=%@",
              appStateFile.url.path, appState.bundledHooksInstalledFor ?? "nil",
              appState.showScreenBar ? 1 : 0, appState.loginItemRegistered ? 1 : 0,
              SparkleUpdater.automaticChecksDefaultsKey,
              defaults.object(forKey: SparkleUpdater.automaticChecksDefaultsKey).map { "\($0)" } ?? "nil")
    }

    /// The saved choices could not be read, so this launch runs on the
    /// defaults. Said once, on the panel's next opening: the next save keeps
    /// the old file beside the new one as a recovery copy, so nothing is lost,
    /// and a launch after that finds a readable file and says nothing.
    private func tellAppStateWasUnreadable(_ why: String) {
        NSLog("JR-Bar app state (%@) could not be used: %@", appStateFile.url.path, why)
        let stateFile = appStateFile.url
        LaunchNotices.shared.post(.init(
            key: "app-state-unreadable",
            text: "JR-Bar could not read its saved choices, so it started from the defaults. The old file is kept beside the new one.",
            actionTitle: "Show") {
                DesktopServices.automatic.reveal([stateFile])
            })
    }

    private func persistAppState() {
        do {
            try appStateFile.save(appState)
        } catch {
            core?.appendLocalLog(level: "supervisor", "app state: could not write \(appStateFile.url.path): \(error.localizedDescription)")
            NSLog("JR-Bar app state: could not write %@: %@", appStateFile.url.path, error.localizedDescription)
        }
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval (System Settings › General › Login Items)"
        case .notRegistered: return "not registered"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    /// An accessory app has no menu bar of its own, but the Settings window's
    /// text fields still need the Edit menu's responder chain for ⌘C/⌘V/⌘A.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(AppMenuVerb.commandPalette.menuItem(action: #selector(openCommandPalette(_:)), target: nil))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ","))
        appMenu.addItem(NSMenuItem(title: "History", action: #selector(openHistory(_:)), keyEquivalent: "y"))
        appMenu.addItem(NSMenuItem(title: "Overview", action: #selector(openOverview(_:)), keyEquivalent: "o"))
        appMenu.addItem(NSMenuItem(title: "Usage Center", action: #selector(openUsageCenter(_:)), keyEquivalent: "u"))
        appMenu.addItem(NSMenuItem(title: "Effect Studio…", action: #selector(openEffects(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Creator Micro…", action: #selector(openControlCenter(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let checkForUpdates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdates.target = self
        if let updater, !updater.isAvailable { checkForUpdates.toolTip = updater.availability.description }
        checkForUpdatesItem = checkForUpdates
        appMenu.addItem(checkForUpdates)
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

    // MARK: Software update

    /// "Check for Updates…" from the app menu, the panel or Settings ›
    /// General (`NSApp.sendAction(#selector(AppDelegate.checkForUpdates(_:)), to: nil, from: nil)`
    /// reaches this through the responder chain). Sparkle shows its own UI.
    @objc func checkForUpdates(_ sender: Any?) {
        guard let updater, updater.isAvailable else {
            let why = "Software update: \(updater?.availability.description ?? "unavailable")"
            settingsStore?.report(error: why)
            showFeedback(why)
            return
        }
        updater.checkForUpdates(sender)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates(_:)) {
            return updater?.canCheckForUpdates ?? false
        }
        return true
    }

    @objc private func openUsageCenter(_ sender: Any?) {
        usageWindow?.show()
    }

    @objc private func openControlCenter(_ sender: Any?) {
        controlCenterWindow?.show()
    }

    @objc private func openCommandPalette(_ sender: Any?) {
        utilitiesStore?.menuBar.actions.commandBar.open()
    }

    @objc private func openEffects(_ sender: Any?) {
        effectsWindow?.show()
    }

    @objc private func openHistory(_ sender: Any?) {
        historyWindow?.show()
    }

    @objc private func openOverview(_ sender: Any?) {
        overviewWindow?.show()
    }

    // MARK: Screen Bar visibility

    /// Two stores name the same fact: the app's `app-state.json`
    /// (`showScreenBar`, which owns the window) and the daemon's
    /// `virtual_status_device_enabled` (which owns the `screen_bar`
    /// device and whether the lights target it). They are kept in step
    /// last-write-wins: a toggle here writes through to the daemon, and
    /// a change that arrives in the settings document (Settings ›
    /// Devices, another client) is adopted here. On first contact a
    /// daemon value that is already present initializes the app side;
    /// when the daemon carries none, the app's remembered state is
    /// pushed once so the `screen_bar` device agrees with the window.
    /// A choice made while the daemon is down is the exception: it wins
    /// on reconnect and is pushed then, because the daemon's value at
    /// that moment is only what it last heard, never a newer choice.
    /// `ScreenBarDaemonSync` decides each case; this class only acts.
    private var screenBarSync = ScreenBarDaemonSync()

    private func setScreenBar(shown: Bool, syncDaemon: Bool = true) {
        appState.showScreenBar = shown
        persistAppState()
        statusItem?.isScreenBarShown = shown
        store?.screenBarShown = shown
        if shown { screenBar?.show(); interaction?.start() } else { interaction?.stop(); screenBar?.hide() }
        refreshAlcoveFollowing()
        toysStore?.notch.syncSensorMonitor()
        if syncDaemon { pushScreenBarSetting(shown) }
    }

    /// The write-through half of the sync, for a person's toggle. With the
    /// daemon connected the value is written at once. With it down, the
    /// choice is remembered as made offline and pushed when the daemon
    /// comes back, ahead of whatever value it still holds.
    private func pushScreenBarSetting(_ shown: Bool) {
        let live = core?.isLive == true
        screenBarSync.toggled(shown: shown, live: live, now: Date())
        defer { rearmAskAgeTick() }
        guard live else { return }
        sendScreenBarSetting(shown)
    }

    /// `set_setting virtual_status_device_enabled`.
    private func sendScreenBarSetting(_ shown: Bool) {
        let generation = screenBarSync.writeGeneration
        _ = Task { @MainActor [weak self] in
            guard let self, let core = self.core,
                  self.screenBarSync.writeGeneration == generation else { return }
            do {
                let reply = try await core.setSetting("virtual_status_device_enabled", value: .bool(shown))
                if !reply.ok {
                    self.screenBarSync.pushRefused(forGeneration: generation)
                    core.appendLocalLog(level: "warn", "screen bar: virtual_status_device_enabled refused (\(reply.error?.code ?? "?"))")
                }
            } catch {
                // A daemon that went away under the write may never have
                // heard it: keep it as an offline choice for the reconnect.
                if core.isLive {
                    self.screenBarSync.pushRefused(forGeneration: generation)
                } else {
                    self.screenBarSync.pushLostOffline(forGeneration: generation)
                }
            }
        }
    }

    /// Run on every core change: `ScreenBarDaemonSync` compares the
    /// settings document's `virtual_status_device_enabled` with what the
    /// band is doing, and this carries out its answer. A mismatch that is
    /// not our own write still landing is the daemon's newer choice (the
    /// user's, from Settings › Devices & Lighting or another client) and the band
    /// follows; a choice made while the daemon was down is pushed to it.
    private func reconcileScreenBarSetting() {
        guard let core else { return }
        defer { rearmAskAgeTick() }
        let document = core.settings.map { SettingsDocument($0.document) }
        let decision = screenBarSync.reconcile(live: core.isLive,
                                               daemonValue: document?.bool("virtual_status_device_enabled"),
                                               appValue: appState.showScreenBar, now: Date())
        switch decision {
        case .none, .agree, .wait:
            break
        case .push(let value):
            sendScreenBarSetting(value)
        case .adopt(let value):
            setScreenBar(shown: value, syncDaemon: false)
        }
    }

    // MARK: Core observation

    /// Facts read by the status item, Screen Bar and menu rules.
    static func observedAppFacts(_ core: CoreModel) {
        _ = core.isLive
        _ = core.allSessions
        _ = core.asks
        _ = core.aggregate
        _ = core.usage
        _ = core.devices
        _ = core.escalation
        _ = core.unseenCompletions
        _ = core.hiddenCount
        _ = core.power
        _ = core.focus
        _ = core.presence
    }

    /// Coalesces changed facts into one main-queue turn. A clock or health
    /// update leaves this registration in place.
    private func observeCore() {
        guard let core else { return }
        withObservationTracking {
            _ = core.connection
            Self.observedAppFacts(core)
            _ = core.lights
            _ = ScreenBarLiveStatus.shared.motionNote
            _ = ScreenBarLiveStatus.shared.followingAlcove
            _ = core.hello
            _ = core.settings?.generation
            // The media ear rides the shared feed's reduce — tracked so
            // a track starting or pausing re-lays the wings on its own.
            _ = store?.media
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.coreDidChange()
                self?.observeCore()
            }
        }
    }

    /// The island's mic/camera reading, carried onto the ears: with the
    /// ears drawn the island rests bare, so the dots it would show ride
    /// the right ear instead. Re-armed after every change, like
    /// `observeCore`; the island's own switch and poll lifetime decide
    /// what the reading is — and whether there is one, which the Screen
    /// Bar card's camera hold row reads.
    private func observeSensorDots() {
        guard let notch = toysStore?.notch else { return }
        // The monitor may read for the presence report with the dots
        // switched off; the ears draw — and the camera hold holds on —
        // only what the switch allows.
        let indicatorsOn = notch.sensorIndicatorsEnabled
        screenBar?.sensors = indicatorsOn ? notch.sensorState : NotchSensorState()
        rearmAskAgeTick()
        // A reading exists while the monitor runs, for the island, the
        // ears or the presence report alike — not only under the island.
        let readable = ScreenBarCameraHold.readable(monitorReading: notch.sensorsReading,
                                                    indicatorsOn: indicatorsOn)
        let status = ScreenBarLiveStatus.shared
        if status.cameraReadable != readable { status.cameraReadable = readable }
        withObservationTracking {
            _ = notch.sensorState
            _ = notch.islandVisible
            _ = notch.sensorIndicatorsEnabled
            _ = notch.sensorsReading
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeSensorDots() }
        }
    }

    private var coreRefresh = AppCoreRefresh()
    private var lastRefreshMedia: AlcoveMedia?

    private func coreDidChange() {
        guard let core, let statusItem else { return }
        store?.providerList.synchronize()
        let changes = coreRefresh.take(core)
        if core.isLive, !changes.intersection([.settings, .connection]).isEmpty, let providerList = store?.providerList {
            Task { await providerList.refresh() }
        }
        let media = store?.media.flatMap { $0.playing ? $0.bundleIdentifier : nil }
        let mediaChanged = store?.media != lastRefreshMedia
        lastRefreshMedia = store?.media
        let rosterChanged = !changes.intersection([.roster, .settings, .connection]).isEmpty
        if rosterChanged || changes.contains(.usage) || mediaChanged {
            screenBar?.updateAccessibility()
            screenBar?.wings = store?.screenBarWings ?? .empty
            screenBar?.earMarks = store?.screenBarEarMarks ?? ScreenBarEarMarks()
            screenBar?.nowPlaying = media
            rearmAskAgeTick()
        }
        if changes.contains(.devices) { screenBar?.hardware = core.isLive ? core.devices : nil }
        refreshPackagedHooksIfNeeded(core: core)
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
        if let supervisor, let store, store.supervisorState != nil {
            switch supervisor.state {
            case .crashed(let failures): statusItem.setCore(description: "crashed \(failures)× · restart from the panel")
            case .backingOff(let failures, let delay): statusItem.setCore(description: "exited (\(failures)×), restarting in \(String(format: "%.1f", delay)) s")
            default: break
            }
        }
        let live = core.isLive
        if rosterChanged, live { askAnnouncer.note(core.asks) }
        if wasLive, !live { events?.reset() }
        if live != wasLive { syncFileFeeds(live: live, core: core) }
        wasLive = live
        if changes.refreshesAggregate { refreshAggregate() }
        if !changes.intersection([.roster, .usage, .devices, .connection]).isEmpty {
            utilitiesStore?.menuBar.coreFactsChanged()
        }
        if rosterChanged || changes.contains(.usage) { refreshIconStyle() }
        if !changes.intersection([.settings, .connection]).isEmpty {
            refreshAlcoveFollowing()
            refreshScreenBarGlow()
            refreshScreenBarGeometry()
            reconcileScreenBarSetting()
            toysStore?.notch.syncSensorMonitor()
        }
        // This also reads local motion and Alcove state. Its own program
        // and description guards keep identical inputs quiet.
        refreshLights()
    }

    /// One task refreshes timed UI at its next boundary. Stable state frames
    /// leave the wake alone, and no clock runs without a timed input.
    private var askAgeTick: Task<Void, Never>?
    private var askAgeTickAt: Double?
    private var rearmingAskAgeTick = false

    private func rearmAskAgeTick() {
        guard !rearmingAskAgeTick else { return }
        rearmingAskAgeTick = true
        defer { rearmingAskAgeTick = false }
        store?.compactAwakeEligible = screenBar?.canCycleCompactAwake ?? false
        let usage = core?.isLive == true ? core?.usage ?? [] : []
        let rows = store?.rows ?? []
        let elapsedSince = rows.compactMap { $0.since?.timeIntervalSince1970 }
        let pendingUntil = screenBarSync.pending.map { $0.at.timeIntervalSince1970 + ScreenBarDaemonSync.pendingWindow }
        let deadlines = rows.compactMap(\.snoozedUntil) + [pendingUntil].compactMap { $0 }
        let next = AppCoreRefresh.nextTick(askTick: store?.nextAskAgeTick(), usage: usage,
                                          elapsedSince: elapsedSince, deadlines: deadlines,
                                          now: Date().timeIntervalSince1970)
        screenBar?.earMarks = store?.screenBarEarMarks ?? ScreenBarEarMarks()
        guard next != askAgeTickAt || askAgeTick == nil || next == nil else { return }
        askAgeTick?.cancel()
        askAgeTick = nil
        askAgeTickAt = next
        guard let next else { return }
        // A hair past the boundary, so the ask age or provider turn has stepped.
        let delay = max(0, next - Date().timeIntervalSince1970) + 0.05
        askAgeTick = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.askAgeTick = nil
            self.reconcileScreenBarSetting()
            self.refreshAggregate()
            self.refreshIconStyle()
            self.screenBar?.wings = self.store?.screenBarWings ?? .empty
            self.screenBar?.earMarks = self.store?.screenBarEarMarks ?? ScreenBarEarMarks()
            self.interaction?.card.geometryChanged()
            self.rearmAskAgeTick()
        }
    }

    /// `screen_bar_follow_alcove` (default on) while the bar is shown.
    private func refreshAlcoveFollowing() {
        guard let alcove else { return }
        let document = core?.settings.map { SettingsDocument($0.document) }
        let wanted = document?.bool(SettingsPath("screen_bar_follow_alcove")) ?? true
        alcove.enabled = wanted && appState.showScreenBar
    }

    /// `screen_bar_min_glow` — the housing rim's dial, live from the
    /// settings document.
    private func refreshScreenBarGlow() {
        let document = core?.settings.map { SettingsDocument($0.document) }
        if let glow = document?.double("screen_bar_min_glow") {
            screenBar?.minGlow = CGFloat(glow)
        }
    }

    /// The settings the panel itself honours, live from the document.
    /// Every one defaults to today's behaviour while the key is absent:
    /// `screen_bar_show_in_full_screen` (the `.fullScreenAuxiliary`
    /// membership), `virtual_status_device_wraps_menu_bar` (the wings),
    /// `screen_bar_notch_wings` / `screen_bar_wing_notices` (the wing
    /// slots and their device notices), and `screen_bar_gap_width` /
    /// `screen_bar_wing_length` (manual geometry — JSON null is
    /// Automatic, so `double` reads it as nil).
    private func refreshScreenBarGeometry() {
        guard let screenBar else { return }
        let document = core?.settings.map { SettingsDocument($0.document) }
        screenBar.showsInFullScreen = document?.bool("screen_bar_show_in_full_screen") ?? true
        screenBar.wrapMenuBar = document?.bool("virtual_status_device_wraps_menu_bar") ?? true
        screenBar.gapWidth = document?.double("screen_bar_gap_width").map { CGFloat($0) }
        screenBar.wingLength = document?.double("screen_bar_wing_length").map { CGFloat($0) }
        screenBar.notchWingsEnabled = document?.bool("screen_bar_notch_wings") ?? true
        screenBar.wingNoticesEnabled = document?.bool("screen_bar_wing_notices") ?? true
        screenBar.notchProfile = NotchProfile(setting: document?.string("screen_bar_notch_profile"))
        screenBar.notchCornerManual = document?.double("screen_bar_notch_corner").map { CGFloat($0) }
        screenBar.hiddenApps = document?.strings("screen_bar_hidden_apps") ?? []
    }

    private func refreshAggregate() {
        guard let store, let statusItem else { return }
        statusItem.update(state: store.aggregate, detail: store.headerCounts)
        let now = Date()
        statusItem.setSnoozed(store.rows.filter { $0.isSnoozed(now: now) }.count)
    }

    /// `menu_bar_icon_style` plus what each style shows: the meters (one
    /// per provider shown in the panel, in that order), the ring's primary
    /// window and the label's aggregate counts.
    private func refreshIconStyle() {
        guard let core, let statusItem, let store else { return }
        let document = core.settings.map { SettingsDocument($0.document) }
        // App state supplies the launch-time style before the first core frame.
        statusItem.iconStyle = StatusIconStyle(setting: appState.menuBarIconStyle)
        let preferred = document?.strings("usage_graph_providers") ?? []
        let usage = core.isLive ? core.usage : []
        let iconUsage = store.providerList.arranged(
            Self.meteredProviders(preferred: preferred, usage: usage), provider: { $0.id }, surface: .menuBar)
        let primary = iconUsage.first
        let window = primary?.windows.first { $0.name.lowercased() == "5h" } ?? primary?.windows.first
        // A window with no reading draws no ring at all: an empty ring is
        // a ring at zero, and this window was never measured. A stale or
        // lapsed reading is not a reading of the window running now, and
        // the ring has no faint form, so it draws no ring either.
        let ring = primary.map { Self.meterReading(of: $0, window: window, now: Date().timeIntervalSince1970) }
        statusItem.ringFraction = ring?.stale == true ? nil : ring?.fraction
        refreshMeters(preferred: preferred, usage: usage)
        refreshSessionDots()
        if core.isLive, let aggregate = core.state?.aggregate {
            let failed = core.sessions.filter { SessionActivity.reduce($0) == .failed }.count
            statusItem.labelText = StatusIconRenderer.label(active: aggregate.active, needsYou: aggregate.needsYou, ready: aggregate.ready, failed: failed)
        } else {
            statusItem.labelText = nil
        }
        // The state is the source of truth for the stage-2 pulse (an app
        // launched mid-escalation never saw the event).
        if core.isLive, let state = core.state {
            let ceiling = EventPolicy.escalationCeiling(document?.string("escalation_tier"))
            let stage = min(state.escalation?.stageNumber ?? 0, ceiling)
            let asksOpen = !state.asks.isEmpty || state.mainSessions.contains { $0.ask != nil }
            statusItem.setEscalation(stage: stage, asksOpen: asksOpen)
        } else {
            statusItem.setEscalation(stage: 0, asksOpen: false)
        }
    }

    /// The meter strip: one cell per provider the panel shows (Settings ›
    /// Usage, "Show in the panel", in that order), each metered by its
    /// primary window — the 5 h one when the provider has it, else the
    /// first it reports. Providers that report no window at all (signed
    /// out, disabled) are left out rather than drawn empty. Past
    /// `maxMeters` the rest become "+n". A stale figure is drawn faint,
    /// and a window whose reset has passed is drawn unread.
    private func refreshMeters(preferred: [String], usage: [CoreProviderUsage]) {
        guard let statusItem, let store else { return }
        let document = core?.settings.map { SettingsDocument($0.document) }
        let shown = store.providerList.arranged(
            Self.meteredProviders(preferred: preferred, usage: usage), provider: { $0.id }, surface: .menuBar)
        let cap = StatusIconRenderer.maxMeters
        let now = Date().timeIntervalSince1970
        statusItem.meters = shown.prefix(cap).map { provider in
            let window = UsageCenterStore.primaryWindow(of: provider)
            let reading = Self.meterReading(of: provider, window: window, now: now)
            // The percent styles need the window's reset stamp (the
            // countdown swap) and its pace verdict (the compact tint).
            // Same daemon-forecast pick the Usage Center card applies:
            // the provider-level forecast only speaks for the
            // conventional 5h lane.
            let conventional = window?.id == UsageCenterStore.conventionalWindow(of: provider)?.id
            let daemon = window?.forecast ?? (conventional ? provider.forecast : provider.forecast.map { CoreUsageForecast(exhaustsAt: nil, pace: $0.pace) })
            // An old or lapsed figure says nothing about where the window
            // is heading now, so it gets no verdict to tint with.
            var verdict: UsageForecast.Verdict?
            if reading.current, let w = window {
                let samples = core?.usageSamples.samples(provider: provider.identity, window: w.name) ?? []
                verdict = UsageForecaster.forecast(window: w, daemon: daemon, samples: samples, now: now).verdict
            }
            var meter = StatusItemController.meter(for: provider.id,
                                                   fraction: reading.fraction,
                                                   approximate: provider.isDerived,
                                                   document: document,
                                                   resetsAt: window?.resetsAt,
                                                   verdict: verdict)
            meter.stale = reading.stale
            return meter
        }
        statusItem.meterOverflow = max(0, shown.count - cap)
        statusItem.dotState = dotState()
    }

    /// The `agents` strip: one dot per session in the panel's order (asks,
    /// waiting, failed, working, done), plus the tooltip's one line per
    /// session. `store.rows` is the panel's own ordering, so the icon and
    /// the panel can never disagree about who leads.
    private func refreshSessionDots() {
        guard let statusItem, let store else { return }
        let rows = store.providerList.arranged(store.rows, provider: { $0.style.id }, surface: .menuBar)
        let now = Date()
        statusItem.sessionDots = rows.map { row in
            // A snoozed ask still owns its dot but draws it dim and still:
            // a muted mailbox pulsing amber in the strip is the snooze not
            // working from the only place it must visibly work.
            SessionDot(id: row.id, state: Self.sessionDotState(for: row),
                       accentHex: row.activity == .working ? row.style.accentHex : nil,
                       dimmed: row.isSnoozed(now: now))
        }
        statusItem.sessionLines = rows.map { Self.sessionTooltipLine(for: $0, now: now) }
    }

    /// A row's dot colour: an open ask (or a wait) is amber, a failure
    /// red, a working run its provider's accent, a fresh completion green.
    static func sessionDotState(for row: SessionRow) -> StatusDotState {
        if row.ask != nil { return .ask }
        switch row.activity {
        case .waiting: return .ask
        case .failed: return .error
        case .working: return .working
        case .done: return .done
        case .idle, .ended: return .idle
        }
    }

    /// "docs-sweep · waiting on you 2h 31m · Gemini" — a snoozed row adds
    /// "· snoozed until 08:00" so the strip's dim dot is explained, and a
    /// peer's session gets "… · on studio-mac" so the tooltip never
    /// implies a local window exists for it.
    static func sessionTooltipLine(for row: SessionRow, now: Date) -> String {
        var word = row.activity.word.lowercased()
        if let elapsed = PanelStore.elapsed(since: row.since, now: now) { word += " \(elapsed)" }
        if row.isSnoozed(now: now), let until = row.snoozedUntil {
            word += " · snoozed until \(PanelStore.clockTime(Date(timeIntervalSince1970: until)))"
        }
        if row.isRemote, let machine = row.remoteMachine { word += " · on \(machine)" }
        return "\(row.label) · \(word) · \(row.style.name)"
    }

    /// What the icon may say about one provider's window. A window whose
    /// reset has passed describes a window that is over and has no
    /// reading for the one running now, so its figure is dropped and the
    /// column is drawn unread. A provider the daemon marks stale keeps its
    /// last figure, flagged so the column draws it faint.
    struct MeterReading: Equatable {
        var fraction: Double?
        var stale: Bool
        /// Neither stale nor lapsed: the figure, if there is one, is how
        /// full the window is now.
        var current: Bool
    }

    nonisolated static func meterReading(of provider: CoreProviderUsage, window: CoreUsageWindow?, now: Double) -> MeterReading {
        let stale = provider.isStale
        let lapsed = window?.resetsAt.map { $0 <= now } ?? false
        let fraction = lapsed ? nil : window?.usedPct.map { $0 / 100 }
        return MeterReading(fraction: fraction, stale: stale, current: !stale && !lapsed)
    }

    /// The providers the strip meters, in the panel's order: the ones
    /// named by `usage_graph_providers` first, then anything else the
    /// daemon reports, each of which must have a window to meter. The
    /// list orders, it does not filter — a provider the daemon measures
    /// stays metered even when the preference names only others, or the
    /// strip is empty for every provider whose only entry is the
    /// preference's own default.
    nonisolated static func meteredProviders(preferred: [String], usage: [CoreProviderUsage]) -> [CoreProviderUsage] {
        let metered = usage.filter { !$0.windows.isEmpty }
        guard !preferred.isEmpty else { return metered }
        var seen = Set<String>()
        var result: [CoreProviderUsage] = []
        for id in preferred {
            guard let provider = metered.first(where: { $0.id == id }), seen.insert(provider.identity).inserted else { continue }
            result.append(provider)
        }
        for provider in metered where seen.insert(provider.identity).inserted {
            result.append(provider)
        }
        return result
    }

    /// The dot at the left of the strip: an open ask beats a failure,
    /// a failure beats work, work beats a fresh completion, and a
    /// completion holds for `completionDotWindow` before the dot goes quiet
    /// again.
    ///
    /// A failure ranks BELOW an open ask deliberately: an unanswered ask is
    /// costing you time right now and one keystroke ends it, where a
    /// failure has already stopped and will wait. It ranks above work for
    /// the same reason in reverse. Before this there was no failed state at
    /// all here -- a run that crashed showed the working dot if anything
    /// else was running, and the quiet hollow dot if nothing was.
    static let completionDotWindow: TimeInterval = 6

    private func dotState() -> StatusDotState {
        guard let core, core.isLive, let state = core.state else { return .idle }
        if !state.asks.isEmpty || state.mainSessions.contains(where: { $0.ask != nil }) { return .ask }
        if core.sessions.contains(where: { SessionActivity.reduce($0) == .failed }) { return .error }
        if state.aggregate.active > 0 || core.sessions.contains(where: { SessionActivity.reduce($0) == .working }) { return .working }
        if let at = lastCompletionAt, Date().timeIntervalSince(at) < Self.completionDotWindow { return .done }
        return .idle
    }

    /// The last `completed` event, for the green dot. A timer puts the dot
    /// back to quiet when the window runs out (no state may arrive in that
    /// time to do it for us).
    private func noteCompletion() {
        lastCompletionAt = Date()
        completionReset?.invalidate()
        completionReset = Timer.scheduledTimer(withTimeInterval: Self.completionDotWindow + 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIconStyle() }
        }
        refreshIconStyle()
    }

    private func refreshLights() {
        guard let core, let screenBar else { return }
        if core.isLive, let surface = core.lights?.screenBar, !surface.program.isEmpty {
            screenBar.apply(programText: surface.program, anchorEpoch: surface.anchor, stripTransfer: surface.stripTransfer)
            let why = surface.why.map { " · \($0.replacingOccurrences(of: "_", with: " "))" } ?? ""
            let description = "monitor" + why + (screenBar.lastRejection.map { " (refused: \($0))" } ?? "") + lightsSuffix(screenBar)
            if description != lastLightsSource {
                lastLightsSource = description
                statusItem?.setFeed(description: description)
            }
        } else if !core.isLive {
            applyFileProgram()
        }
    }

    /// " · still under Reduce Motion · following Alcove": why the band is
    /// not moving or what it is tracking, for the status menu's lights
    /// line. Render-path detail (frame counts) stays in the log.
    private func lightsSuffix(_ screenBar: ScreenBarController) -> String {
        var suffix = ""
        if let note = screenBar.menuMotionNote { suffix += " · \(note)" }
        if screenBar.capsule != nil { suffix += " · following Alcove" }
        return suffix
    }

    /// Puts the last file-feed program back on the bar (startup, or the
    /// daemon went away).
    private func applyFileProgram() {
        guard let screenBar, let last = lastFileProgram else { return }
        // The anchor is the file's write instant — the firmware restarts
        // on every LEDS.LED write, so the bar phase-locks to that, not
        // to whenever this read landed.
        screenBar.apply(programText: last.text, anchorEpoch: last.anchor)
        ScreenBarLiveStatus.shared.noteOfflineFeed(last.source)
        let description = last.source.description + (screenBar.lastRejection.map { " (refused: \($0))" } ?? "") + lightsSuffix(screenBar)
        if description != lastLightsSource {
            lastLightsSource = description
            statusItem?.setFeed(description: description)
        }
    }

    // MARK: Socket directory watch

    /// The daemon may start after us: when its directory changes, retry at
    /// once instead of waiting out the backoff. Only while it is not live —
    /// a live daemon writes that directory dozens of times a minute.
    private func watchSocketDirectory(_ socketPath: String) {
        guard isolatedPreview == nil else { return }
        let directory = (socketPath as NSString).deletingLastPathComponent
        guard socketWatcher == nil, FileManager.default.fileExists(atPath: directory) else { return }
        socketWatcher = FileWatcher(path: directory, mask: [.write, .link, .attrib]) { [weak self] _ in
            self?.core?.retryNow()
        }
        socketWatcher?.start()
    }

    /// The file feeds are the fallback while the daemon is not live: the
    /// state-directory monitor, the strip's LEDS.LED watches and the socket
    /// directory watch stop when it goes live and start again — the
    /// monitor reading at once — when it goes away.
    private func syncFileFeeds(live: Bool, core: CoreModel) {
        guard isolatedPreview == nil else { return }
        if live {
            monitor?.stop()
            feed?.stop()
            socketWatcher?.stop()
            socketWatcher = nil
        } else {
            monitor?.start()
            feed?.start()
            watchSocketDirectory(core.socketPath)
        }
    }
}

// MARK: - Shell wiring: the toggle strip, links, shortcuts

extension AppDelegate {
    /// The app-level pieces the system lane adds, wired once after the
    /// stores exist: the toggle strip's view of the Dock utility's
    /// preview hold.
    fileprivate func wireShell() {
        // A Dock chip flip while a preview holds the Dock out waits for
        // the hold to let go — the hold's restore would undo it.
        SystemTogglesStore.shared.state.dockHoldActive = { [weak self] in
            self?.utilitiesStore?.dock.enhance.autohideHold.holding ?? false
        }
        // Eject leaves every strip the daemon lists as mounted, beyond
        // the volume-name rule it applies itself.
        SystemTogglesStore.shared.state.protectedVolumePaths = { [weak self] in
            self?.core?.devices.compactMap(\.path) ?? []
        }
        // Awake is the daemon's one keep-awake lease: the chip, links and
        // Shortcuts send it, `state.power.hold` is what the chip shows.
        if let core { SystemTogglesStore.shared.state.attachLease(to: core) }
        wireCommandRouter()
        // App actions bound on Settings › Shortcuts, and the one key the
        // daemon's retired registry held, adopted when its settings land.
        AppHotkeys.shared.start()
        settingsStore?.onSetActionShortcut = { chord, id in AppHotkeys.shared.setChord(chord, for: id) }
        adoptLegacyShortcuts()
        // Notices outside a click wait for the panel; the ones worth
        // keeping also land once in Notification Center.
        let notices = LaunchNotices.shared
        notices.panelIsOpen = { [weak self] in self?.panel?.isOpen == true }
        notices.showToast = { [weak self] in self?.store?.show(toast: $0.text, actionTitle: $0.actionTitle, action: $0.action) }
        notices.deliverBanner = { [weak self] id, title, body in
            self?.events?.notifications.deliver(.init(identifier: id, title: title, body: body, category: .plain))
        }
        notices.withdrawBanner = { [weak self] id in self?.events?.notifications.withdraw(identifier: id) }
        // The one-status-item decision: put back the Control Center items an
        // older build hid, and say once what became of its extra items.
        OneItemMigration.forgetRetiredItemPlacements(in: .standard)
        if let utilitiesStore, let controlCenter = UserDefaults(suiteName: "com.apple.controlcenter") {
            OneItemMigration.run(
                retired: utilitiesStore.state.menuBar.retiredExtras,
                clearRetired: { [weak utilitiesStore] in utilitiesStore?.state.menuBar.retiredExtras = [] },
                controlCenter: controlCenter, ours: UserDefaults.standard,
                relaunchControlCenter: OneItemMigration.relaunchControlCenter,
                log: { [weak self] in self?.core?.appendLocalLog(level: "menubar", $0) },
                notices: notices,
                openSettings: { [weak self] in self?.settingsWindow?.show(page: nil) })
        }
        // A scheduled update Sparkle leaves to us, never a window over
        // the work; once Sparkle's own window is seen, the notice goes.
        updater?.onUpdateReady = { [weak self] version in
            notices.say(.init(key: "update-ready", text: "JR-Bar \(version) is ready", actionTitle: "Update…") {
                self?.checkForUpdates(nil)
            })
            notices.deliverBanner("update-ready", "JR-Bar \(version) is ready", "Choose Check for Updates… when it suits you.")
        }
        updater?.onUpdateAttended = { notices.withdraw(key: "update-ready") }
        // A sound held for a live microphone says so in the log.
        events?.sounds.onHeldForCall = { [weak self] name in
            self?.core?.appendLocalLog(level: "sound", "\(name) held: the microphone is live")
        }
        // Confetti's pop plays through the same player: one audio engine
        // on the alert device, and a held pop is logged like the rest.
        toysStore?.confetti.sounds = events?.sounds
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated {
                InstalledCopies.mentionOnce()
                SetupWindowController.shared.reviewPermissionHealth { self?.core?.appendLocalLog(level: "setup", $0) }
            }
        }
    }

    /// `jrbar://` links: every URL the scheme brings runs through the
    /// router, refused out loud when it names nothing JR-Bar does.
    func application(_ application: NSApplication, open urls: [URL]) {
        _ = Task {
            for url in urls where url.scheme?.lowercased() == AppCommand.scheme {
                await AppCommandRouter.shared.open(url)
            }
        }
    }

    /// A line for the person that did not come from a panel click — a
    /// link, a shortcut, a banner, the ear. The panel's toast while it is
    /// open or a palette verb is listening for it; with the panel shut
    /// the toast would go unseen, so the HUD says it on the screen under
    /// the pointer.
    private func showFeedback(_ text: String, symbol: String = "exclamationmark.circle.fill") {
        let route = PanelStore.feedbackRoute(panelOpen: store?.isOpen == true,
                                             paletteListening: PaletteVerbScope.ticket != nil)
        switch route {
        case .toast: store?.show(toast: text)
        case .hud: feedbackHUD.show(text, symbol: symbol, near: nil)
        }
    }

    /// The router's hands: the same paths the panel, the status menu and
    /// the summon keys already take, so a link or a shortcut does
    /// exactly what the click would.
    private func wireCommandRouter() {
        let router = AppCommandRouter.shared
        router.onRefused = { [weak self] text in self?.showFeedback(text) }
        router.showPanel = { [weak self] toggle in
            if toggle { self?.panel?.toggle() } else { self?.panel?.open() }
        }
        router.openSettings = { [weak self] page in
            self?.settingsWindow?.show(named: page)
        }
        router.openWindow = { [weak self] window in
            switch window {
            case .overview: self?.overviewWindow?.show()
            case .history: self?.historyWindow?.show()
            case .usage: self?.usageWindow?.show()
            case .effects: self?.effectsWindow?.show()
            case .controlCenter: self?.controlCenterWindow?.show()
            case .setup: SetupWindowController.show()
            case .whatsNew: self?.whatsNewWindow?.show()
            }
        }
        router.openOverviewGraph = { [weak self] in self?.overviewWindow?.showGraph() }
        // The palette's Open the Tank, only ever on: a link that could
        // close the tank would be a toggle, and this one is not.
        router.openAquarium = { [weak self] in
            guard let tank = self?.toysStore?.aquarium else { return "JR-Bar is still starting." }
            tank.isOn = true
            return nil
        }
        store?.onManualQuietApplied = { [weak router] seconds in router?.manualQuietApplied(seconds: seconds) }
        router.quiet = { [weak self] mode, seconds, onApplied in
            guard let self, let core = self.core, let store = self.store else { return "JR-Bar is still starting." }
            guard core.isLive else { return "The monitor is not connected. Quiet needs it." }
            let result = await store.requestQuiet(mode: mode ?? store.quietMode, seconds: seconds,
                                                  feedback: false, onApplied: onApplied).value
            switch result {
            case .applied(let message): self.showFeedback(message, symbol: "moon.fill"); return nil
            case .refused(let message): return message
            }
        }
        router.sessionsNow = { [weak self] in self?.core?.sessions ?? [] }
        router.endQuiet = { [weak self] onApplied in
            guard let self, let core = self.core, let store = self.store else { return "JR-Bar is still starting." }
            guard core.isLive else { return "The monitor is not connected." }
            let result = await store.requestQuiet(mode: store.quietMode, seconds: 0,
                                                  feedback: false, onApplied: onApplied).value
            switch result {
            case .applied(let message): self.showFeedback(message, symbol: "checkmark.circle.fill"); return nil
            case .refused(let message): return message
            }
        }
        router.setScreenBar = { [weak self] on in
            guard let self else { return }
            self.setScreenBar(shown: on ?? !self.appState.showScreenBar)
        }
        router.fireConfetti = { [weak self] tint in
            // An explicit ask, like the card's Test burst: it fires even
            // while the toy is off — in the linked provider's or session's
            // colour, else the focused session's, else the Toys tint.
            self?.toysStore?.confetti.testBurst(provider: self?.focusedConfettiProvider(tint))
        }
        router.menuBar = { [weak self] verb in
            guard let menuBar = self?.utilitiesStore?.menuBar, menuBar.isOn else {
                return "The Menu Bar utility is off — turn it on in Utilities."
            }
            switch verb {
            case .reveal: menuBar.menuBarActionsRevealHidden(menuBar.actions)
            case .toggle: menuBar.menuBarActionsToggleReveal(menuBar.actions)
            case .alwaysHidden: menuBar.menuBarActionsRevealAlwaysHidden(menuBar.actions)
            case .commandBar: menuBar.openCommandBar()
            }
            return nil
        }
        // The checks a link can fail at once stay synchronous; the open
        // itself is awaited, and a refusal after it is said the same way.
        router.openSession = { [weak self] id in
            guard let core = self?.core, core.isLive else { return "The monitor is not connected." }
            guard core.state?.session(withID: id) != nil else { return "No session \(id.prefix(40)) is being watched." }
            Task { @MainActor [weak self] in
                if let refusal = await SessionOpener.open(id) { self?.showFeedback(refusal) }
            }
            return nil
        }
        router.revealAsk = { [weak self] in
            guard let core = self?.core, core.isLive else { return "The monitor is not connected." }
            guard !core.asks.isEmpty else { return "No agent is waiting on you." }
            // The notch card or the panel, whichever the asks arrive on;
            // both list the longest-waiting ask first, with Approve and Deny.
            self?.presentAskSurface()
            return nil
        }
        // The ⌃⌥D key's own toggle, so the link lands on the Shelf page
        // too rather than on Now.
        router.toggleShelf = { [weak self] in
            guard let notch = self?.toysStore?.notch else { return "JR-Bar is still starting." }
            return notch.toggleShelf()
        }
        router.useShelfKeyboard = { [weak self] in
            guard let notch = self?.toysStore?.notch else { return "JR-Bar is still starting." }
            return notch.useShelfKeyboard()
        }
    }

    /// Re-armed on every settings document until the daemon's retired
    /// reveal key has been read once.
    private func adoptLegacyShortcuts() {
        guard let core, !AppHotkeys.shared.legacySettled else { return }
        withObservationTracking {
            _ = core.settings?.generation
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.adoptLegacyShortcuts() }
        }
        guard let document = core.settings?.document else { return }
        AppHotkeys.shared.adoptLegacy(shortcuts: document["global_action_shortcuts"])
    }
}

extension AppDelegate {
    /// Opens the surface the person's asks arrive on: the notch's card
    /// while the island is the notch's face (it lists the longest-waiting
    /// ask first, with its verbs), else the panel. Opening only: nothing
    /// is answered, and a surface already open stays as it is.
    func presentAskSurface() {
        if let notch = toysStore?.notch, notch.isDrawingIsland, !notch.foldEngaged {
            // An ask already on the island's face is reached where it is:
            // the keyboard goes to its verbs (nothing focused, nothing
            // answered until a person moves onto one and presses it).
            if notch.engageAskKeyboard() { return }
            if !notch.islandExpanded { notch.expandFromBand() }
            return
        }
        panel?.open()
    }
}

extension AppDelegate {
    /// The provider a confetti ask names: the link's own, a session's, or
    /// the session the Screen Bar is focused on — one resolution for the
    /// link, the card's Try it and the palette.
    func focusedConfettiProvider(_ tint: AppCommand.ConfettiTint) -> String? {
        let sessions = core?.state?.sessions ?? []
        return AppCommand.confettiProvider(
            tint, focused: store?.screenBarFocus.focusSession,
            providerOf: { AppCommand.provider(ofSession: $0, in: sessions) })
    }
}
