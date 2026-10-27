import JRBarUI
import AppKit
import JRBarCore
import Observation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// The Settings window's state. The daemon's document is the only source of
/// truth; this store overlays the edits it has sent and not yet seen echoed,
/// so a slider does not snap back between the write and the next `settings`
/// message, and turns paths into SwiftUI bindings.
@MainActor
@Observable
final class SettingsStore {
    /// Sidebar pages and the older chapter names accepted by deep links.
    enum Page: String, CaseIterable, Identifiable, Hashable {
        case general, agents, alerts, devices, notch, utilities, shortcuts, remote, privacy, integrations, advanced

        var id: String { rawValue }

        /// The chapters this page holds, top to bottom.
        var chapters: [Chapter] {
            switch self {
            case .general: return [.general]
            case .agents: return [.agents, .usage]
            case .alerts: return [.notifications, .sounds]
            case .devices: return [.devices, .lighting]
            case .notch: return [.notch]
            case .privacy: return [.privacy]
            case .integrations: return [.integrations]
            case .advanced: return [.advanced]
            case .utilities: return [.utilities, .toys]
            case .shortcuts: return [.shortcuts]
            case .remote: return [.remote]
            }
        }

        var title: String {
            switch self {
            case .general: return "General"
            case .agents: return "Providers"
            case .alerts: return "Alerts & Sounds"
            case .devices: return "Devices"
            case .utilities: return "Utilities & Toys"
            case .shortcuts: return "Shortcuts"
            case .remote: return "Remote"
            case .notch: return "Notch & Shelf"
            case .privacy: return "Privacy"
            case .integrations: return "Integrations"
            case .advanced: return "Advanced"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .agents: return "person.2.fill"
            case .alerts: return "bell.badge.fill"
            case .devices: return "light.beacon.max.fill"
            case .utilities: return "wrench.and.screwdriver.fill"
            case .shortcuts: return "command"
            case .remote: return "antenna.radiowaves.left.and.right"
            case .notch: return "macbook"
            case .privacy: return "hand.raised.fill"
            case .integrations: return "puzzlepiece.extension.fill"
            case .advanced: return "slider.horizontal.3"
            }
        }

        /// System Settings tints every sidebar icon; these follow its palette.
        var tint: Color {
            switch self {
            case .general: return Color(nsColor: .systemGray)
            case .agents: return Color(nsColor: .systemBlue)
            case .alerts: return Color(nsColor: .systemRed)
            case .devices: return Color(nsColor: .systemOrange)
            case .utilities: return Color(nsColor: .systemIndigo)
            case .shortcuts: return Color(nsColor: .systemPurple)
            case .remote: return Color(nsColor: .systemTeal)
            case .notch: return Color(nsColor: .systemGray)
            case .privacy: return Color(nsColor: .systemGreen)
            case .integrations: return Color(nsColor: .systemCyan)
            case .advanced: return Color(nsColor: .systemGray)
            }
        }

        /// The daemon-document pages this page resets: every chapter
        /// that has keys, apart from Advanced (which only holds tools).
        var resettable: [SettingsKey.Page] {
            switch self {
            case .general: return [.general]
            case .agents: return [.agents, .usage]
            case .alerts: return [.notifications, .remote]
            case .utilities: return [.notifications]
            case .devices: return [.devices]
            case .privacy: return [.agents, .usage, .notifications]
            case .remote: return [.remote]
            default: return []
            }
        }

        private static let powerPaths: Set<String> = [
            "agent_keep_awake_enabled", "keep_display_awake", "closed_lid_awake_policy",
            "closed_lid_grace_minutes", "keep_awake_on_battery",
        ]
        private static let privacyPaths: Set<String> = [
            "presence_enabled", "capacity_history_enabled", "capacity_history_retention_days",
            "provider_status_feeds_enabled", "provider_update_checks_enabled",
        ]
        private static let devicePaths: Set<String> = [
            "virtual_status_device_enabled", "screen_bar_follow_alcove", "screen_bar_show_in_full_screen",
            "screen_bar_gap_width", "screen_bar_wing_length", "screen_bar_notch_wings",
            "screen_bar_notch_profile", "screen_bar_notch_corner", "screen_bar_hidden_apps",
            "global_brightness_scale", "devices_linked", "linked_dot_scale", "linked_follow_brightness",
            "dot_extend_style", "dot_extend_side", "linked_dot_phase_trim_ms", "linked_dot_clock_correction",
            "linked_sync_tolerance_ms", "link_screen_bar_to_hardware", "screen_bar_phase_offset_ms", "screen_bar_min_glow",
        ]

        private static let alertRemotePaths: Set<String> = [
            "escalation_webhook_url", "webhook_events", "ntfy_enabled", "ntfy_topic", "ntfy_only_when_away",
        ]

        func resetPaths(in document: SettingsDocument) -> [String] {
            resettable.flatMap { SettingsKey.resetPaths(on: $0, in: document) }.filter { path in
                let power = Self.powerPaths.contains(path)
                let privacy = Self.privacyPaths.contains(path) || path.hasPrefix("transcript_monitoring.")
                switch self {
                case .alerts: return !power && !privacy && (SettingsKey.keys(on: .notifications).contains { $0.path == path } || Self.alertRemotePaths.contains(path))
                case .remote: return !Self.alertRemotePaths.contains(path)
                case .utilities: return power
                case .privacy: return privacy
                case .devices:
                    if path.hasPrefix("devices.") {
                        return ["enabled", "brightness", "auto_brightness_enabled", "led_direction", "dot_travel_style", "red_gain", "green_gain", "blue_gain", "resting_glow"].contains(path.components(separatedBy: ".").last ?? "")
                    }
                    return Self.devicePaths.contains(path)
                default: return !power && !privacy
                }
            }
        }

        /// A page or chapter named in a link, a script or an old
        /// preference: the page that holds it, and the chapter to bring
        /// into view when the name is a chapter's.
        static func destination(named name: String) -> (page: Page, chapter: Chapter?)? {
            let key = name.lowercased()
            if key == "providers" { return (.agents, nil) }
            if let chapter = Chapter(rawValue: key) { return (chapter.page, chapter) }
            if let page = Page(rawValue: key) { return (page, nil) }
            return nil
        }

        /// Every name a link may use: the pages and the chapters.
        static var linkNames: Set<String> {
            Set(allCases.map(\.rawValue)).union(Chapter.allCases.map(\.rawValue)).union(["providers"])
        }
    }

    /// The twelve areas Settings has grown, each now a chapter of a page.
    /// Search entries, resets, cards and deep links still speak in them.
    enum Chapter: String, CaseIterable, Identifiable, Hashable {
        case general, agents, usage, devices, notch, utilities, lighting, toys, notifications, sounds, shortcuts, remote, privacy, integrations, advanced

        var id: String { rawValue }

        var page: Page {
            switch self {
            case .general: return .general
            case .advanced: return .advanced
            case .notch: return .notch
            case .privacy: return .privacy
            case .integrations: return .integrations
            case .agents, .usage: return .agents
            case .notifications, .sounds: return .alerts
            case .devices, .lighting: return .devices
            case .utilities, .toys: return .utilities
            case .shortcuts: return .shortcuts
            case .remote: return .remote
            }
        }

        var title: String {
            switch self {
            case .general: return "General"
            case .agents: return "Agents"
            case .usage: return "Usage"
            case .devices: return "Devices & Screen Bar"
            case .utilities: return "Utilities"
            case .lighting: return "Lighting"
            case .toys: return "Toys"
            case .notifications: return "Alerts & Focus"
            case .sounds: return "Sounds"
            case .shortcuts: return "Shortcuts"
            case .remote: return "Remote"
            case .notch: return "Notch & Shelf"
            case .privacy: return "Privacy"
            case .integrations: return "Integrations"
            case .advanced: return "Advanced"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .agents: return "person.2.fill"
            case .usage: return "chart.bar.fill"
            case .devices: return "light.beacon.max.fill"
            case .utilities: return "wrench.and.screwdriver"
            case .lighting: return "paintpalette.fill"
            case .toys: return "party.popper.fill"
            case .notifications: return "bell.badge.fill"
            case .sounds: return "speaker.wave.2.fill"
            case .shortcuts: return "command"
            case .remote: return "antenna.radiowaves.left.and.right"
            case .notch: return "macbook"
            case .privacy: return "hand.raised.fill"
            case .integrations: return "puzzlepiece.extension.fill"
            case .advanced: return "slider.horizontal.3"
            }
        }

        /// The chapter's own tint, worn by its cards and search hits.
        var tint: Color {
            switch self {
            case .general: return Color(nsColor: .systemGray)
            case .agents: return Color(nsColor: .systemBlue)
            case .usage: return Color(nsColor: .systemGreen)
            case .devices: return Color(nsColor: .systemOrange)
            case .utilities: return Color(nsColor: .systemIndigo)
            case .lighting: return Color(nsColor: .systemPink)
            // The Toys tint is a warm magenta from the contract, not the
            // palette's pink — Lighting already owns that one.
            case .toys: return Color(nsColor: .systemPink)
            case .notifications: return Color(nsColor: .systemRed)
            case .sounds: return Color(nsColor: .systemPurple)
            case .shortcuts: return Color(nsColor: .systemBlue)
            case .remote: return Color(nsColor: .systemTeal)
            case .notch: return Color(nsColor: .systemGray)
            case .privacy: return Color(nsColor: .systemGreen)
            case .integrations: return Color(nsColor: .systemCyan)
            case .advanced: return Color(nsColor: .systemGray)
            }
        }

        /// The daemon-document page this chapter resets; nil for chapters
        /// with no daemon keys (Toys keeps its state in `app-state.json`).
        var catalogue: SettingsKey.Page? { SettingsKey.Page(rawValue: rawValue) }
    }

    let core: CoreModel
    let providerUsage = ProviderUsageSwitchesModel(active: false)
    /// Settings › Devices & Lighting › Firmware (`FirmwareStore.swift`).
    let firmware: FirmwareStore
    let t3Integration = T3CodeModel()
    var subpage: String?
    var selectedProvider: String?

    var page: Page = .general {
        // A search hit names its row only on its own page; choosing any
        // other page retires it.
        didSet {
            if oldValue != page { subpage = nil; selectedProvider = nil }
            if searchHit?.page != page {
                searchHit = nil
                highlightedCard = nil
            }
        }
    }
    /// The Toys page's store, created beside this one in the delegate.
    /// Weak: the delegate owns it.
    weak var toys: ToysStore?
    /// The Utilities page's store, same seat as `toys`. Weak: the
    /// delegate owns it.
    weak var utilities: UtilitiesStore?
    /// Lighting › Effects… opens the Studio window.
    var onOpenStudioSearch: (@MainActor (SettingsSearchEntry) -> Void)?
    var onOpenStudioDevices: (@MainActor () -> Void)?
    var onOpenEffects: (@MainActor () -> Void)?
    /// Devices opens the Creator Micro window.
    var onOpenControlCenter: (@MainActor () -> Void)?
    /// Usage › Open Usage Center… — where the graphs actually live.
    var onOpenUsageCenter: (@MainActor () -> Void)?
    /// `state.deck`, observed on its own: it changes when the pad does,
    /// not on every `state` push.
    var deck: DeckState? {
        refreshFacts()
        _ = deckMirror.value
        return facts.deck
    }
    var calibrating: String?
    var doctorReport: JSONValue?
    var doctorRunning = false
    var lastError: String?
    /// A transient confirmation line ("Hooks installed for Claude") under
    /// the same auto-clear clock as `lastError`.
    var status: String?
    var resetTarget: Page?
    var pendingWrites = 0
    /// Software-update channel: an app concern, kept in user defaults for
    /// Sparkle's delegate (`SparkleUpdater.allowedChannels(from:)`).
    var updateChannel: String = UserDefaults.standard.string(forKey: SparkleUpdater.channelDefaultsKey) ?? "stable" {
        didSet {
            UserDefaults.standard.set(updateChannel, forKey: SparkleUpdater.channelDefaultsKey)
            if updateChannel != oldValue { SparkleUpdater.shared?.channelDidChange() }
        }
    }
    /// Settings › General › Software Update, mirrored from `SparkleUpdater.shared`
    /// (`refreshUpdater()`): whether this build embeds Sparkle, why not when
    /// it does not, and the automatic-checks flag Sparkle persists itself.
    var updaterAvailable = false
    var updaterHint: String? = "Sparkle.framework is not in this build"
    var automaticUpdateChecks = false
    var lastUpdateCheck: Date?
    @ObservationIgnored var readLastUpdateCheck: () -> Date? = { SparkleUpdater.shared?.lastUpdateCheckDate }
    var launchAtLogin: Bool = false
    var launchAtLoginError: String?
    var loginItemState: LoginItemState = .unknown
    var launchAtLoginBusy = false
    @ObservationIgnored private var launchAtLoginChanging = false
    @ObservationIgnored private var launchAtLoginGeneration = UUID()
    @ObservationIgnored private var launchAtLoginTask: Task<Void, Never>?
    /// How the launch-at-login state is read. `SMAppService.status` is a
    /// synchronous XPC round trip, normally 3 ms and once 250 ms of a
    /// hang, so it runs off the main thread; a test hands in its own.
    @ObservationIgnored var launchAtLoginStatus: @Sendable () -> Bool = SettingsStore.systemLaunchAtLogin {
        didSet {
            let read = launchAtLoginStatus
            loginItemStateReader = { read() ? .enabled : .notRegistered }
        }
    }
    @ObservationIgnored var loginItemStateReader: @Sendable () -> LoginItemState = {
        LoginItemState(SMAppService.mainApp.status)
    }
    @ObservationIgnored var loginItemChange: @Sendable (Bool) throws -> Void = { on in
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    /// The window is open but none of it shows: covered, minimised or on
    /// another Space. Every LED preview holds its frame
    /// (`ledPreviewsHeld`) until some of the window shows again. The
    /// window controller writes it from the window's occlusion.
    var windowCovered = false

    @ObservationIgnored private var pending: [String: JSONValue] = [:]
    // Returning to an earlier value is still a new edit.
    @ObservationIgnored private var pendingTokens: [String: UUID] = [:]
    @ObservationIgnored var settingWriter: ((SettingsPath, JSONValue) async throws -> CoreReply)?
    @ObservationIgnored private var throttles: [String: DispatchWorkItem] = [:]
    @ObservationIgnored private var errorClear: DispatchWorkItem?

    // MARK: Mirrors
    //
    // What a page shows of the monitor, kept so that one change re-renders
    // only the rows that read it. The caches below are always what the
    // core holds now; the observable mirrors trail them by at most one
    // run-loop turn after a push, and only a mirror whose value really
    // changed is written. Reads refresh the caches first, so a read right
    // after a push is never stale, and then touch the mirror so the view
    // reading it is invalidated when it moves.

    /// One cell per document path a view has read.
    @ObservationIgnored private var cells: [SettingsPath: SettingsPathCell] = [:]
    /// The monitor's document as last read, and the same with the unsent
    /// or unechoed edits (`pending`) laid over it.
    @ObservationIgnored private var daemonDocument = SettingsDocument()
    @ObservationIgnored private var overlaidDocument = SettingsDocument()
    /// An overlay edit left bookkeeping for the sync: the device list
    /// (`devicesStale`, set only when the edit touched `devices`) and the
    /// whole-document version compare. Settling them once a turn keeps a
    /// slider's `set` stream off the document walk.
    @ObservationIgnored private var overlayBookkeepingStale = false
    @ObservationIgnored private var devicesStale = false
    /// The root the device list is built from.
    private static let devicesPath = SettingsPath("devices")
    @ObservationIgnored private var daemonHasDocument = false
    @ObservationIgnored private var daemonGeneration = 0
    @ObservationIgnored private var daemonSchema: Int?
    /// Counts changes to the monitor's own document (`settingsRevision`).
    @ObservationIgnored private var daemonRevision = 0
    /// The overlaid document the last `documentVersion` bump stood for.
    @ObservationIgnored private var versionedDocument = SettingsDocument()
    /// `core.settings` moved since the caches were read.
    @ObservationIgnored private var documentStale = true
    /// `core.state`, `lights`, readiness or the connection moved since `facts` was read.
    @ObservationIgnored private var factsStale = true
    /// The caches moved and the mirrors have not caught up yet.
    @ObservationIgnored private var documentMirrorsStale = true
    @ObservationIgnored private var factsMirrorsStale = true
    @ObservationIgnored private var mirrorSyncScheduled = false
    @ObservationIgnored private var watchingSettings = false
    @ObservationIgnored private var watchingFacts = false
    @ObservationIgnored private var facts = SettingsCoreFacts()
    /// Something has read the facts since the Settings window last
    /// closed — or at all. While nothing has, a push only marks them
    /// stale: a window never opened costs a `state` push nothing but
    /// the mark, and every public reader flips this on first.
    @ObservationIgnored private var factsInUse = false
    @ObservationIgnored private var deviceListCache: [DeviceEntry] = []
    /// The newest `last_write` per device id, read only on the device
    /// card's own 5 s clock: every write moves it, and no mirror carries it.
    @ObservationIgnored private var lastWrites: [String: Double] = [:]

    /// Bumped whenever the overlaid document changes, for readers of the
    /// whole `document`.
    private var documentVersion = 0
    @ObservationIgnored private let hasDocumentMirror = SettingsMirror(false)
    @ObservationIgnored private let generationMirror = SettingsMirror(0)
    @ObservationIgnored private let schemaMirror = SettingsMirror<Int?>(nil)
    @ObservationIgnored private let revisionMirror = SettingsMirror(0)
    @ObservationIgnored private let deviceListMirror = SettingsMirror<[DeviceEntry]>([])
    @ObservationIgnored private let liveMirror = SettingsMirror(false)
    @ObservationIgnored private let hookStatusMirror = SettingsMirror<[String: String]>([:])
    @ObservationIgnored private let hookDetectedMirror = SettingsMirror<[String: Bool]>([:])
    @ObservationIgnored private let runningMirror = SettingsMirror<Set<String>>([])
    @ObservationIgnored private let deviceFactsMirror = SettingsMirror<[String: CoreDevice]>([:])
    @ObservationIgnored private let deviceSurfaceMirror = SettingsMirror<[String: CoreLightSurface]>([:])
    @ObservationIgnored private let dotLinkMirror = SettingsMirror<CoreDotLink?>(nil)
    @ObservationIgnored private let dotSurfaceMirror = SettingsMirror<CoreLightSurface?>(nil)
    @ObservationIgnored private let screenBarSurfaceMirror = SettingsMirror<CoreLightSurface?>(nil)
    @ObservationIgnored private let closedLidMirror = SettingsMirror<CoreClosedLid?>(nil)
    @ObservationIgnored private let peersMirror = SettingsMirror<[CorePeer]?>(nil)
    @ObservationIgnored private let deckMirror = SettingsMirror<DeckState?>(nil)

    /// `menu_bar_icon_style`: the daemon's settings dataclass does carry
    /// this field and round-trips it in the document, but the document
    /// only exists after connect — so the app still keeps a launch-time
    /// copy in `app-state.json` for the moments before the first frame.
    var menuBarIconStyle: String = StatusIconStyle.agents.rawValue {
        didSet {
            guard menuBarIconStyle != oldValue else { return }
            onSetMenuBarIconStyle?(menuBarIconStyle)
            if !copyingImportedIconStyle { set("menu_bar_icon_style", .string(menuBarIconStyle)) }
        }
    }
    let providerList: ProviderListStore
    var menuBarProviders: MenuBarProviderPreferences {
        get { providerList.preferences }
        set {
            let choices = newValue
            Task { try? await providerList.setPreferences(choices) }
        }
    }

    @ObservationIgnored private var copyingImportedIconStyle = false
    /// Persists the choice; wired to `AppState` by the delegate.
    var onSetMenuBarIconStyle: (@MainActor (String) -> Void)?

    @ObservationIgnored private let shortcutDefaults: UserDefaults
    /// "Summon the panel with ⌥⌘J": an app-local UserDefaults key (not a
    /// daemon setting); the delegate registers/unregisters the Carbon
    /// hot-key when it flips.
    var panelHotkeyEnabled: Bool = false {
        didSet {
            guard panelHotkeyEnabled != oldValue else { return }
            shortcutDefaults.set(panelHotkeyEnabled, forKey: PanelHotkey.defaultsKey)
            onPanelHotkeyChange?(panelHotkeyEnabled)
        }
    }
    var onPanelHotkeyChange: (@MainActor (Bool) -> Void)?

    /// The delegate mirrors `PanelHotkey.registrationFailed` here so the
    /// toggle can say "⌥⌘J is taken by another app" instead of silently
    /// doing nothing while looking enabled.
    var panelHotkeyRegistrationFailed = false

    /// "Summon the shelf with ⌃⌥D" — Yoink's drop-target summon. Same
    /// app-local UserDefaults pattern as the panel's key; the delegate
    /// toggles the island card on the press.
    static let shelfHotkeyDefaultsKey = "shelfHotkeyEnabled"
    var shelfHotkeyEnabled: Bool = false {
        didSet {
            guard shelfHotkeyEnabled != oldValue else { return }
            shortcutDefaults.set(shelfHotkeyEnabled, forKey: Self.shelfHotkeyDefaultsKey)
            onShelfHotkeyChange?(shelfHotkeyEnabled)
        }
    }
    var onShelfHotkeyChange: (@MainActor (Bool) -> Void)?
    var shelfHotkeyRegistrationFailed = false

    static let studioHotkeyDefaultsKey = "studioHotkeyEnabled"
    var studioHotkeyEnabled: Bool = true {
        didSet {
            guard studioHotkeyEnabled != oldValue else { return }
            shortcutDefaults.set(studioHotkeyEnabled, forKey: Self.studioHotkeyDefaultsKey)
            onStudioHotkeyChange?(studioHotkeyEnabled)
        }
    }
    var onStudioHotkeyChange: (@MainActor (Bool) -> Void)?
    var studioHotkeyRegistrationFailed = false
    var studioHotkeyChord: HotkeyChord? {
        _ = hotkeyChordVersion
        return HotkeyChordDefaults.chord(for: PanelHotkey.studioID, fallback: PanelHotkey.studioDefault, defaults: shortcutDefaults)
    }

    /// Bumped on every chord write so views re-read the defaults-backed
    /// chords below.
    private var hotkeyChordVersion = 0

    /// The panel's and the shelf's chords — the persisted rebind, the
    /// shipped ⌥⌘J / ⌃⌥D, or nil once cleared on Settings › Shortcuts.
    var panelHotkeyChord: HotkeyChord? {
        _ = hotkeyChordVersion
        return HotkeyChordDefaults.chord(for: PanelHotkey.panelID, fallback: PanelHotkey.panelDefault, defaults: shortcutDefaults)
    }

    var shelfHotkeyChord: HotkeyChord? {
        _ = hotkeyChordVersion
        return HotkeyChordDefaults.chord(for: PanelHotkey.shelfID, fallback: PanelHotkey.shelfDefault, defaults: shortcutDefaults)
    }

    /// The keys as General's rows name them: "⌥⌘J", or a plain phrase
    /// once no key is bound.
    var panelHotkeyLabel: String { panelHotkeyChord?.displayString ?? "the panel shortcut" }
    var shelfHotkeyLabel: String { shelfHotkeyChord?.displayString ?? "the shelf shortcut" }

    /// The recorder's write for any shortcut Settings lists, by its
    /// registry id. Recording a key switches its shortcut on — the
    /// person just asked for it — and re-registers through the hook the
    /// delegate already wired; nil unbinds.
    func setShortcut(_ chord: HotkeyChord?, for id: String) {
        switch id {
        case PanelHotkey.panelID:
            HotkeyChordDefaults.set(chord, for: id, defaults: shortcutDefaults)
            hotkeyChordVersion += 1
            if chord != nil, !panelHotkeyEnabled {
                panelHotkeyEnabled = true
            } else {
                onPanelHotkeyChange?(panelHotkeyEnabled)
            }
        case PanelHotkey.studioID:
            HotkeyChordDefaults.set(chord, for: id, defaults: shortcutDefaults)
            hotkeyChordVersion += 1
            if chord != nil, !studioHotkeyEnabled {
                studioHotkeyEnabled = true
            } else {
                onStudioHotkeyChange?(studioHotkeyEnabled)
            }
        case PanelHotkey.shelfID:
            HotkeyChordDefaults.set(chord, for: id, defaults: shortcutDefaults)
            hotkeyChordVersion += 1
            if chord != nil, !shelfHotkeyEnabled {
                shelfHotkeyEnabled = true
            } else {
                onShelfHotkeyChange?(shelfHotkeyEnabled)
            }
        default:
            if let action = MenuBarHotkeyAction.allCases.first(where: { MenuBarHotkeys.registryID(for: $0) == id }) {
                utilities?.menuBar.setHotkeyChord(chord, for: action)
            } else if let binding = utilities?.state.menuBar.itemHotkeyBindings.first(where: { $0.id == id }) {
                utilities?.menuBar.setItemHotkeyChord(chord, for: binding.target)
            } else {
                onSetActionShortcut?(chord, id)
                hotkeyChordVersion += 1
            }
        }
    }

    /// An app action's chord (Settings › Shortcuts › Actions and Quick
    /// toggles) — nil until one is recorded.
    func actionShortcut(_ id: String) -> HotkeyChord? {
        _ = hotkeyChordVersion
        return HotkeyChordDefaults.chord(for: id, fallback: nil)
    }

    /// Where an app-action shortcut's write goes — the delegate's
    /// `AppHotkeys`, which persists it and re-registers.
    var onSetActionShortcut: (@MainActor (HotkeyChord?, String) -> Void)?

    // MARK: Sounds

    /// Settings › Alerts & Sounds — app-local, since the app plays the sounds.
    /// Every write persists at once; the event player reads them at each
    /// sound, so a change lands on the next one.
    var soundPreferences: SoundPreferences = SoundPreferences.load() {
        didSet {
            if soundPreferences != oldValue {
                soundPreferences.save()
                NotificationCenter.default.post(name: SoundPlayer.preferencesDidChange, object: nil)
            }
        }
    }

    /// The page's preview voice — the same player, the same choices.
    @ObservationIgnored private lazy var soundPreview = SoundPlayer()

    func previewSound(_ name: String) {
        soundPreview.preview(name)
    }

    // MARK: Search

    /// The sidebar's search text; non-empty swaps the page list for hits.
    var searchQuery = "" {
        didSet { if searchQuery != oldValue { scheduleSearch(from: oldValue) } }
    }
    /// The hits the sidebar lists for `searchQuery`: worked out when the
    /// typing pauses for 80 ms (at once for the first letter), never in a
    /// view's body.
    private(set) var searchHits: [SettingsSearchEntry] = []
    @ObservationIgnored private var searchWork: DispatchWorkItem?
    @ObservationIgnored private var searchIndexCache: (entries: [SettingsSearchEntry], index: [SettingsSearch.Indexed])?
    /// The row a search result was picked for — the page names it at the
    /// top until another page is chosen.
    var searchHit: SettingsSearchEntry?

    /// Toy and utility cards held open on their pages, by toy id — a
    /// search hit opens its card, and a card stays as the person left
    /// it while the app runs.
    var expandedCards: Set<String> = []
    /// The folds (`SettingsFoldRow`) open now, by id. They start folded
    /// and stay as the person leaves them while the app runs.
    var openFolds: Set<String> = []
    /// The card a search hit landed on, lit on its page until the page
    /// lets it go.
    var highlightedCard: String?
    /// Bumped by every reveal into a card, so the page scrolls to it
    /// again even when the same card is picked twice.
    private(set) var revealRequest = 0
    /// The chapter `open(chapter:)` asked for, until its page has scrolled to it.
    var pendingChapter: Chapter?

    /// The scroll anchor a card's row carries on its page.
    nonisolated static func cardAnchor(_ card: String) -> String { "card:\(card)" }

    /// Every searchable row: the daemon pages' titled rows, each page,
    /// the shortcut catalogue, the toys and utilities as they are, and
    /// the titled rows inside their cards.
    var searchEntries: [SettingsSearchEntry] {
        var entries = SettingsSearch.rows + SettingsSearch.pages + SettingsSearch.shortcutRows
        entries += providerList.providers.flatMap { row -> [SettingsSearchEntry] in
            let name = ProviderPalette.displayName(for: row.id)
            let card = "provider:\(row.id)"
            var rows = [SettingsSearchEntry(.agents, "Providers", name, card: card)]
            if row.usageConsent != nil {
                rows.append(SettingsSearchEntry(.usage, "Provider usage", "Show \(name) usage",
                                                subtitle: row.usageConsent?.detail, card: card))
            }
            if ["factory", "kimi", "kilo"].contains(row.id) {
                rows.append(SettingsSearchEntry(.usage, "Provider usage", "\(name) API key", card: card))
            }
            return rows
        }
        if !ProviderUsageRoadmap.upcoming(availableProviderIDs: Set(providerList.providers.map(\.id))).isEmpty {
            entries.append(SettingsSearchEntry(.usage, "Coming soon", "Coming soon", keywords: ["copilot"]))
        }
        entries += MenuBarHotkeyAction.allCases.map {
            SettingsSearchEntry(.shortcuts, "Menu bar", MenuBarHotkeys.title(for: $0))
        }
        var cards: [(chapter: Chapter, toy: any Toy)] = []
        if let utilities {
            cards += ([utilities.menuBar, utilities.dock, utilities.agents] as [any Toy])
                .map { (.utilities, $0) }
        }
        if let toys {
            // The notch reads as a utility and sits on that page.
            if let notch = toys.notch { cards.append((.notch, notch)) }
            cards += toys.toys.map { (.toys, $0) }
        }
        for (chapter, toy) in cards {
            entries.append(SettingsSearchEntry(chapter, toy.name, toy.name, subtitle: toy.blurb, card: toy.id))
            entries += toy.searchRows.map {
                SettingsSearchEntry(chapter, toy.name, $0.title, subtitle: $0.hint,
                                    keywords: $0.keywords, card: toy.id)
            }
        }
        return entries
    }

    /// `searchEntries` with their words folded, rebuilt only when the
    /// entries change (a toy or utility comes or goes).
    private var searchIndex: [SettingsSearch.Indexed] {
        let entries = searchEntries
        if let cache = searchIndexCache, cache.entries == entries { return cache.index }
        let index = entries.map(SettingsSearch.Indexed.init)
        searchIndexCache = (entries, index)
        return index
    }

    /// The hits for the query as it stands, worked out now.
    var searchResults: [SettingsSearchEntry] {
        SettingsSearch.search(searchQuery, in: searchIndex)
    }

    private func scheduleSearch(from previous: String) {
        searchWork?.cancel()
        searchWork = nil
        let startingOut = SettingsSearch.words(previous).isEmpty
        if startingOut || SettingsSearch.words(searchQuery).isEmpty {
            settleSearch()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.settleSearch() }
        }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Lists the hits for the query now; the debounce calls it, and a
    /// test calls it in place of waiting.
    func settleSearch() {
        searchWork?.cancel()
        searchWork = nil
        let hits = searchResults
        if hits != searchHits { searchHits = hits }
    }

    /// A result picked: its page, named at the top — and for a row in a
    /// toy or utility card, that card opened, scrolled to and lit.
    func reveal(_ entry: SettingsSearchEntry) {
        if entry.chapter == .lighting || entry.title == "Open Studio" {
            openFolds.formUnion(folds(holding: entry))
            if entry.chapter == .lighting, let onOpenStudioSearch { onOpenStudioSearch(entry) }
            else if ["Role", "Also glow for finished runs"].contains(entry.title) { onOpenStudioDevices?() }
            else { onOpenEffects?() }
            return
        }
        searchHit = entry
        pendingChapter = nil
        page = entry.page
        subpage = entry.card ?? (SettingsFold.isAdvanced(chapter: entry.chapter, group: entry.group) ? "advanced" : nil)
        selectedProvider = entry.title == "Read plan limits" ? "claude" : nil
        if entry.title == "Clicks Open" { selectedProvider = providerList.providers.first?.id }
        if entry.group == "Calibration profiles" { subpage = "calibration" }
        openFolds.formUnion(folds(holding: entry))
        if let card = entry.card, card.hasPrefix("provider:") {
            selectedProvider = String(card.dropFirst("provider:".count))
            subpage = nil
        } else if let card = entry.card {
            expandedCards.insert(card)
            highlightedCard = card
        } else {
            highlightedCard = nil
        }
        // Every hit asks the page to scroll: to its card, or to the group
        // the row sits in.
        revealRequest += 1
    }

    /// Opens a page at one of its chapters: how a link, the command
    /// palette or a button elsewhere in the app names "Usage" or "Sounds"
    /// now that those sit on a page with another chapter.
    func open(chapter: Chapter) {
        searchHit = nil
        highlightedCard = nil
        pendingChapter = chapter
        page = chapter.page
        subpage = nil
        selectedProvider = nil
        if chapter == .lighting { onOpenEffects?() }
        revealRequest += 1
    }

    /// Opens whatever a link or script named: a page, or a chapter of one.
    /// A name nobody holds opens General.
    func open(named name: String?) {
        guard let name, let found = Page.destination(named: name) else {
            page = .general
            return
        }
        if let chapter = found.chapter { open(chapter: chapter) } else { page = found.page }
    }

    /// The scroll anchor a group's header carries on its page.
    nonisolated static func groupAnchor(_ group: String) -> String { "group:\(group)" }

    /// Open or fold one card by hand.
    func setCard(_ card: String, expanded: Bool) {
        if expanded { expandedCards.insert(card) } else { expandedCards.remove(card) }
    }

    func isFoldOpen(_ id: String) -> Bool { openFolds.contains(id) }

    func setFold(_ id: String, open: Bool) {
        if open { openFolds.insert(id) } else { openFolds.remove(id) }
    }

    /// The folds a search hit's row sits in: a device card's rows are in
    /// every device's fold, a group behind one fold is behind that one.
    func folds(holding entry: SettingsSearchEntry) -> [String] {
        var folds = groupFolds(holding: entry)
        if SettingsFold.isAdvanced(chapter: entry.chapter, group: entry.group) {
            folds.append(SettingsFold.advanced(entry.page))
        }
        for nested in SettingsFold.nested where nested.chapter == entry.chapter && nested.group == entry.group
            && nested.titles.contains(entry.title) {
            folds.append(nested.fold)
        }
        return folds
    }

    private func groupFolds(holding entry: SettingsSearchEntry) -> [String] {
        switch (entry.chapter, entry.group) {
        case (.devices, "Creator Micro"): return [SettingsFold.creatorMicro]
        case (.devices, "Stream Deck"): return [SettingsFold.streamDeck]
        case (.lighting, "Provider colours"): return [SettingsFold.providerColours]
        case (.shortcuts, "Actions"): return [SettingsFold.shortcutActions]
        case (.shortcuts, "Quick toggles"): return [SettingsFold.quickToggles]
        default: return []
        }
    }

    /// macOS's answer to the notification permission, asked by the
    /// Notifications page on appear: the banner toggle can read on while
    /// delivery is denied at the system level, and a silent denial is
    /// indistinguishable from a bug.
    var notificationPermissionDenied = false

    /// The settings seal: the Keychain key, the daemon's word on it and the
    /// banner above every page (SettingsSealViews.swift). Nil when the app
    /// is not supervising a daemon of its own.
    var seal: SettingsSealCoordinator?

    func refreshNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor [weak self] in self?.notificationPermissionDenied = denied }
        }
    }

    /// The launch-at-login state is read by the General page when it
    /// shows (`refreshLaunchAtLogin`), not here: the read is an XPC call.
    init(core: CoreModel, providerList: ProviderListStore? = nil, firmware: FirmwareStore? = nil, shortcutDefaults: UserDefaults = .standard) {
        self.shortcutDefaults = shortcutDefaults
        self.panelHotkeyEnabled = shortcutDefaults.bool(forKey: PanelHotkey.defaultsKey)
        self.shelfHotkeyEnabled = shortcutDefaults.bool(forKey: Self.shelfHotkeyDefaultsKey)
        self.studioHotkeyEnabled = shortcutDefaults.object(forKey: Self.studioHotkeyDefaultsKey) as? Bool ?? true
        self.core = core
        self.hookRemover = { try await core.uninstallHooksNow(providers: $0) }
        self.pageResetter = { try await core.resetSettings(paths: $0) }
        self.providerList = providerList ?? ProviderListStore(core: core)
        self.firmware = firmware ?? FirmwareStore { name, args in try await core.send(name, args: args) }
        watchSettings()
        watchFacts()
        syncMirrors()
    }

    // MARK: Document

    /// The daemon's document with unsent-or-unechoed edits applied. A view
    /// that reads it re-renders on every change to any path; a row should
    /// read its own path instead (`values`, `value(at:)`, the bindings).
    var document: SettingsDocument {
        refreshDocument()
        _ = documentVersion
        return overlaidDocument
    }

    var hasDocument: Bool {
        refreshDocument()
        _ = hasDocumentMirror.value
        return daemonHasDocument
    }

    var generation: Int {
        refreshDocument()
        _ = generationMirror.value
        return daemonGeneration
    }

    /// Moves when the monitor's own document changes: not when it is sent
    /// again unchanged, and not with a local edit still in flight. For a
    /// view that asks the monitor to render something from the document.
    var settingsRevision: Int {
        refreshDocument()
        _ = revisionMirror.value
        return daemonRevision
    }

    /// The schema the monitor's document says it speaks.
    var settingsSchema: Int? {
        refreshDocument()
        _ = schemaMirror.value
        return daemonSchema
    }

    /// Whether the monitor's own document carries `path` (JSON null
    /// counts); observed on that path alone.
    func isProvided(_ path: String) -> Bool { isProvided(SettingsPath(path)) }

    func isProvided(_ path: SettingsPath) -> Bool {
        refreshDocument()
        let mirrored = cell(path).provided
        return documentMirrorsStale ? daemonDocument.contains(path) : mirrored
    }

    /// One path of the overlaid document, observed on that path alone.
    func value(at path: SettingsPath) -> JSONValue? {
        refreshDocument()
        let mirrored = cell(path).value
        return documentMirrorsStale ? overlaidDocument.value(at: path) : mirrored
    }

    /// A provider's style with its configured colour, observed on that
    /// colour's path alone.
    func providerStyle(_ provider: String) -> ProviderStyle {
        ProviderStyle.style(for: provider, document: values.document([SettingsPath("colors.agent_colors.\(provider)")]))
    }

    /// Path-by-path reads with `SettingsDocument`'s own vocabulary:
    /// `store.values.bool("idle_dim_enabled")`.
    var values: SettingsValues { SettingsValues(store: self) }

    private func cell(_ path: SettingsPath) -> SettingsPathCell {
        if let cell = cells[path] { return cell }
        let cell = SettingsPathCell(value: overlaidDocument.value(at: path), provided: daemonDocument.contains(path))
        cells[path] = cell
        return cell
    }

    /// The monitor's document with `pending` laid over it.
    private func overlay(_ document: SettingsDocument) -> SettingsDocument {
        var document = document
        for (path, value) in pending {
            document = document.replacing(SettingsPath(path), with: value)
        }
        return document
    }

    /// Re-reads `core.settings` when it moved. The read is not observed
    /// (`CoreReading`): a row that asks for one path in the moment between
    /// a push and the sync after it must not end up observing the whole
    /// document through the store.
    private func refreshDocument() {
        guard documentStale else { return }
        documentStale = false
        let settings = CoreReading.now(core).settings
        let previous = daemonDocument
        daemonDocument = SettingsDocument(settings?.document ?? .object([:]))
        if daemonDocument != previous { daemonRevision += 1 }
        daemonHasDocument = settings != nil
        daemonGeneration = settings?.generation ?? 0
        daemonSchema = settings?.schema
        overlaidDocument = overlay(daemonDocument)
        deviceListCache = computeDeviceEntries()
        documentMirrorsStale = true
    }

    /// Re-reads what the pages show of `state` and `lights` when they
    /// moved, unobserved for the same reason. A read marks the facts in
    /// use, so the pushes after it keep their mirrors current.
    private func refreshFacts() {
        factsInUse = true
        refreshFactsCache()
    }

    private func refreshFactsCache() {
        guard factsStale else { return }
        factsStale = !watchingFacts
        let now = CoreReading.now(core)
        facts = SettingsCoreFacts(state: now.state, lights: now.lights, live: now.live)
        lastWrites = Dictionary((now.state?.devices ?? []).compactMap { device in device.lastWrite.map { (device.id, $0) } },
                                uniquingKeysWith: { first, _ in first })
        deviceListCache = computeDeviceEntries()
        factsMirrorsStale = true
    }

    /// `core.settings` is watched for the moment it changes (Observation's
    /// will-set), which marks the caches stale and books a mirror sync.
    private func watchSettings() {
        watchingSettings = true
        withObservationTracking {
            _ = core.settings
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.watchingSettings = false
                self.documentStale = true
                self.scheduleMirrorSync()
            }
        }
    }

    private func watchFacts() {
        watchingFacts = true
        withObservationTracking {
            _ = core.state
            _ = core.lights
            _ = core.connection
            _ = core.isLive
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.watchingFacts = false
                self.factsStale = true
                self.scheduleMirrorSync()
            }
        }
    }

    /// The sync runs as a run-loop block, which the loop services before
    /// it next draws, so a push reaches the rows in the same frame.
    private func scheduleMirrorSync() {
        guard !mirrorSyncScheduled else { return }
        mirrorSyncScheduled = true
        let loop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mirrorSyncScheduled = false
                self.syncMirrors()
            }
        }
        CFRunLoopWakeUp(loop)
    }

    /// Brings every mirror up to the caches, writing only the ones whose
    /// value moved. The run loop calls it after a push; a test calls it to
    /// stand in for that turn.
    func syncMirrors() {
        if !watchingSettings { watchSettings() }
        if !watchingFacts { watchFacts() }
        refreshDocument()
        if factsInUse { refreshFactsCache() }
        if documentMirrorsStale {
            documentMirrorsStale = false
            deviceListCache = computeDeviceEntries()
            for (path, cell) in cells {
                cell.update(value: overlaidDocument.value(at: path), provided: daemonDocument.contains(path))
            }
            bumpDocumentVersionIfChanged()
            hasDocumentMirror.update(daemonHasDocument)
            overlayBookkeepingStale = false
            devicesStale = false
            generationMirror.update(daemonGeneration)
            schemaMirror.update(daemonSchema)
            revisionMirror.update(daemonRevision)
        }
        if overlayBookkeepingStale {
            overlayBookkeepingStale = false
            if devicesStale {
                devicesStale = false
                deviceListCache = computeDeviceEntries()
            }
            bumpDocumentVersionIfChanged()
        }
        if factsMirrorsStale {
            factsMirrorsStale = false
            liveMirror.update(facts.live)
            hookStatusMirror.update(facts.hookStatuses)
            hookDetectedMirror.update(facts.hookDetections)
            runningMirror.update(facts.runningProviders)
            deviceFactsMirror.update(facts.devices)
            deviceSurfaceMirror.update(facts.deviceSurfaces)
            dotLinkMirror.update(facts.dotLink)
            dotSurfaceMirror.update(facts.dotSurface)
            screenBarSurfaceMirror.update(facts.screenBarSurface)
            closedLidMirror.update(facts.closedLid)
            peersMirror.update(facts.peers)
            deckMirror.update(facts.deck)
        }
        deviceListMirror.update(deviceListCache)
    }

    /// The Settings window closed: its rows are gone, so pushes stop
    /// refreshing the facts until something reads them again.
    func settingsWindowDidClose() {
        factsInUse = false
    }

    private func bumpDocumentVersionIfChanged() {
        guard versionedDocument != overlaidDocument else { return }
        versionedDocument = overlaidDocument
        documentVersion += 1
    }

    /// A local edit or a dropped one: the overlay moved at `path`, so only
    /// the cells on that path (above or below it) can have changed, and
    /// they are told now — a read must not wait a turn. The device list
    /// and the whole-document version compare wait for the run loop's
    /// sync, so a slider's stream of `set` calls pays them once a turn,
    /// not once a tick.
    private func overlayChanged(at path: SettingsPath) {
        refreshDocument()
        overlaidDocument = overlay(daemonDocument)
        if path.overlaps(Self.devicesPath) { devicesStale = true }
        overlayBookkeepingStale = true
        scheduleMirrorSync()
        guard !documentMirrorsStale else { return }
        for (cellPath, cell) in cells where cellPath.overlaps(path) {
            cell.update(value: overlaidDocument.value(at: cellPath), provided: cell.provided)
        }
    }

    // MARK: Writes

    @ObservationIgnored private var pendingOrigins: [String: SettingsPath] = [:]
    private struct SettingWrite {
        let path: SettingsPath
        let origin: SettingsPath
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var settingWrites: [UUID: SettingWrite] = [:]

    private static func containsPath(_ parent: SettingsPath, _ child: SettingsPath) -> Bool {
        child.segments.starts(with: parent.segments)
    }

    /// Sends `set_setting`. `throttled` coalesces a slider's stream into one
    /// write every 120 ms, the last value always winning.
    func set(_ path: String, _ value: JSONValue, throttled: Bool = false) {
        let requested = SettingsPath(path)
        var writePath = path
        var writeValue = value
        if let ancestor = pending.keys.filter({
            let candidate = SettingsPath($0)
            return candidate.segments.count < requested.segments.count && Self.containsPath(candidate, requested)
        }).max(by: { SettingsPath($0).segments.count < SettingsPath($1).segments.count }),
           let ancestorValue = pending[ancestor] {
            let relative = SettingsPath(segments: Array(requested.segments.dropFirst(SettingsPath(ancestor).segments.count)))
            let merged = SettingsDocument(ancestorValue).replacing(relative, with: value)
            guard merged.value(at: relative) == value else {
                report(error: saveFailure(path, "Another change to it is still being saved."))
                return
            }
            writePath = ancestor
            writeValue = merged.root
        }
        let target = SettingsPath(writePath)
        for obsolete in Array(pending.keys) where Self.containsPath(target, SettingsPath(obsolete)) {
            throttles[obsolete]?.cancel()
            throttles[obsolete] = nil
            pending[obsolete] = nil
            pendingTokens[obsolete] = nil
            pendingOrigins[obsolete] = nil
        }
        pending[writePath] = writeValue
        pendingTokens[writePath] = UUID()
        pendingOrigins[writePath] = requested
        overlayChanged(at: target)
        throttles[writePath]?.cancel()
        let flushPath = writePath
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { _ = self?.flush(flushPath) }
        }
        throttles[writePath] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (throttled ? 0.12 : 0), execute: work)
    }

    /// Selects an alerts profile: one `set_setting` per key it owns, and
    /// nothing else. The individual switches keep working afterwards.
    func apply(_ profile: AlertsProfile) {
        for write in profile.writes { set(write.key, write.value) }
    }

    @discardableResult
    func flush(_ path: String) -> Task<Void, Never>? {
        throttles[path]?.cancel()
        throttles[path] = nil
        guard let value = pending[path], let token = pendingTokens[path] else { return nil }
        let target = SettingsPath(path)
        let origin = pendingOrigins[path] ?? target
        let dependencies = settingWrites.values.filter {
            $0.path.overlaps(target) && ($0.path != target || $0.origin != origin || origin != target || $0.origin != $0.path)
        }.map(\.task)
        let writeID = UUID()
        pendingWrites += 1
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.pendingWrites -= 1
                self.settingWrites[writeID] = nil
            }
            for dependency in dependencies { await dependency.value }
            guard self.pendingTokens[path] == token else { return }
            do {
                let reply = try await self.writeSetting(SettingsPath(path), value: value)
                guard self.pendingTokens[path] == token else { return }
                if !reply.ok {
                    self.report(error: self.saveFailure(path, reply.error?.sentence ?? "The monitor refused it."))
                    self.dropPending(path, token: token)
                } else {
                    self.settlePending(path, value: value, echoed: reply.result?["value"], token: token)
                }
            } catch {
                guard self.pendingTokens[path] == token else { return }
                self.report(error: self.saveFailure(path, MonitorWords.reason(error)))
                self.dropPending(path, token: token)
            }
        }
        settingWrites[writeID] = SettingWrite(path: target, origin: origin, task: task)
        return task
    }

    private func writeSetting(_ path: SettingsPath, value: JSONValue) async throws -> CoreReply {
        if let writer = settingWriter { return try await writer(path, value) }
        return try await core.setSetting(path, value: value)
    }

    /// Once the daemon's document carries the value, the overlay is not
    /// needed; if the echo is late, give it a moment rather than snapping.
    /// `echoed` is the reply's own normalised `value`: when the daemon kept
    /// something else (a clamped number, a refused flag) the overlay must
    /// drop at once and say so, not paint the asked-for value until the
    /// document push lands.
    /// Internal for the overlay-rule tests.
    func settlePending(_ path: String, value: JSONValue, echoed: JSONValue? = nil, token: UUID? = nil) {
        if let token, pendingTokens[path] != token { return }
        if let echoed, !echoed.isNull, !Self.sameValue(echoed, value) {
            dropPending(path, ifStill: value, token: token)
            report(error: saveFailure(path, "The monitor kept \(Self.describeValue(echoed)) instead."))
            return
        }
        refreshDocument()
        let inDocument = daemonDocument.value(at: SettingsPath(path)) == value
        if inDocument || throttles[path] != nil {
            if inDocument { dropPending(path, ifStill: value, token: token) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            MainActor.assumeIsolated { self?.dropPending(path, ifStill: value, token: token) }
        }
    }

    /// Loose reply-vs-request comparison: hex colours compare
    /// case-insensitively, numbers by value.
    static func sameValue(_ a: JSONValue, _ b: JSONValue) -> Bool {
        if a == b { return true }
        if let sa = a.stringValue, let sb = b.stringValue {
            if normalizedColorHex(sa) != nil || normalizedColorHex(sb) != nil {
                return normalizedColorHex(sa) == normalizedColorHex(sb)
            }
        }
        if let na = a.doubleValue, let nb = b.doubleValue, a.stringValue == nil, b.stringValue == nil {
            return na == nb
        }
        return false
    }

    /// `false` → "off", `42` → "42", a string in quotes.
    static func describeValue(_ value: JSONValue) -> String {
        switch value {
        case .bool(let on): return on ? "on" : "off"
        case .number(let number): return number == number.rounded() ? "\(Int(number))" : "\(number)"
        case .string(let text): return "“\(text)”"
        case .null: return "nothing"
        default: return "a different value"
        }
    }

    private func dropPending(_ path: String, ifStill value: JSONValue? = nil, token: UUID? = nil) {
        if let token, pendingTokens[path] != token { return }
        if let value, pending[path] != value { return }
        guard pending.removeValue(forKey: path) != nil else { return }
        pendingTokens[path] = nil
        pendingOrigins[path] = nil
        overlayChanged(at: SettingsPath(path))
    }

    /// Each control's title by its setting path, noted as the control is
    /// built, so a failed save can name what did not save.
    @ObservationIgnored private(set) var controlTitles: [String: String] = [:]

    func noteControlTitle(_ title: String, for path: String) {
        if controlTitles[path] != title { controlTitles[path] = title }
    }

    /// "Couldn't save Brightness. The monitor did not answer in time."
    /// The control's title when one is known, never the key path.
    func saveFailure(_ path: String, _ reason: String) -> String {
        let name = controlTitles[path] ?? controlTitles[path.split(separator: ".").first.map(String.init) ?? path]
        let subject = name.map { "Couldn't save \($0)." } ?? "Couldn't save that setting."
        return reason.isEmpty ? subject : subject + " " + reason
    }

    func report(error: String) {
        lastError = error
        status = nil
        errorClear?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.lastError = nil } }
        errorClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    func show(status text: String) {
        status = text
        lastError = nil
        errorClear?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.status = nil } }
        errorClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    // MARK: Bindings

    func bool(_ path: String, default fallback: Bool = false) -> Binding<Bool> {
        Binding(
            get: { self.values.bool(SettingsPath(path)) ?? fallback },
            set: { self.set(path, .bool($0)) }
        )
    }

    func double(_ path: String, default fallback: Double = 0, throttled: Bool = true) -> Binding<Double> {
        Binding(
            get: { self.values.double(SettingsPath(path)) ?? fallback },
            set: { self.set(path, .number($0), throttled: throttled) }
        )
    }

    func int(_ path: String, default fallback: Int = 0) -> Binding<Int> {
        Binding(
            get: { self.values.int(SettingsPath(path)) ?? fallback },
            set: { self.set(path, .number(Double($0))) }
        )
    }

    func string(_ path: String, default fallback: String = "") -> Binding<String> {
        Binding(
            get: { self.values.string(SettingsPath(path)) ?? fallback },
            set: { self.set(path, .string($0)) }
        )
    }

    /// A string that may be JSON null (`provider_pin`, `signal_policy`);
    /// `nilToken` stands for null in a picker.
    func optionalString(_ path: String, nilToken: String = "") -> Binding<String> {
        Binding(
            get: { self.values.string(SettingsPath(path)) ?? nilToken },
            set: { self.set(path, $0 == nilToken ? .null : .string($0)) }
        )
    }

    func stringList(_ path: String) -> Binding<[String]> {
        Binding(
            get: { self.values.strings(SettingsPath(path)) ?? [] },
            set: { self.set(path, .array($0.map(JSONValue.string))) }
        )
    }

    /// Membership of `item` in a string list as a toggle.
    func listMember(_ path: String, _ item: String) -> Binding<Bool> {
        Binding(
            get: { (self.values.strings(SettingsPath(path)) ?? []).contains(item) },
            set: { on in
                var items = self.values.strings(SettingsPath(path)) ?? []
                if on, !items.contains(item) { items.append(item) }
                if !on { items.removeAll { $0 == item } }
                self.set(path, .array(items.map(JSONValue.string)))
            }
        )
    }

    /// A nullable number as (automatic, value) for the geometry rows.
    func isNull(_ path: String) -> Bool {
        guard let value = value(at: SettingsPath(path)) else { return true }
        return value.isNull
    }

    /// A hex colour string as a SwiftUI `Color`.
    func color(_ path: String, default fallback: String) -> Binding<Color> {
        Binding(
            get: {
                let hex = self.values.string(SettingsPath(path)) ?? fallback
                return Color(nsColor: NSColor(hex: hex) ?? .gray)
            },
            set: { color in
                guard let hex = NSColor(color).hexString else { return }
                self.set(path, .string(hex), throttled: true)
            }
        )
    }

    /// Minutes since midnight as a `Date` for `DatePicker`.
    func minutesOfDay(_ path: String, default fallback: Int) -> Binding<Date> {
        Binding(
            get: {
                let minutes = self.values.int(SettingsPath(path)) ?? fallback
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                self.set(path, .number(Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))))
            }
        )
    }

    // MARK: Devices

    struct DeviceEntry: Identifiable, Equatable {
        let index: Int
        let id: String
        let name: String
        let kind: String
        var prefix: String { "devices.\(index)" }
    }

    /// Devices from the settings document, kind resolved through the
    /// state's device list when the document does not say. Observed as
    /// one list that changes only when a device comes, goes or is
    /// renamed, not on every edit to a device's settings.
    var deviceEntries: [DeviceEntry] {
        refreshDocument()
        refreshFacts()
        _ = deviceListMirror.value
        if devicesStale {
            // The edit's recompute waits for the mirror sync, but a read
            // must not see the pre-edit list even for one turn.
            devicesStale = false
            deviceListCache = computeDeviceEntries()
        }
        return deviceListCache
    }

    private func computeDeviceEntries() -> [DeviceEntry] {
        let known = Dictionary(facts.devices.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        return overlaidDocument.deviceEntries.map { index, id, entry in
            let state = known[Self.factDeviceID(id)]
            let name = entry["name"]?.stringValue ?? state?.name ?? id
            let kind = state?.kind ?? Self.guessKind(id: id, name: name)
            return DeviceEntry(index: index, id: id, name: name, kind: kind)
        }
    }

    private static func factDeviceID(_ id: String) -> String {
        id == "virtual:status-bar" ? "screen-bar" : id
    }

    static func guessKind(id: String, name: String) -> String {
        let text = (id + " " + name).lowercased()
        if text.contains("status-bar") || text.contains("screen bar") { return "screen_bar" }
        if text.contains("dot") { return "dot" }
        if text.contains("pro") || text.contains("sidepulse") { return "pro" }
        return "unknown"
    }

    /// The device as the last `state` has it, `last_write` and all: every
    /// state push moves it. A page row reads `deviceFacts` instead.


    /// The device as the last `state` has it, without `last_write` and
    /// `write_health`, which move with every write; observed as a whole
    /// that changes only when something a card shows does.
    func deviceFacts(_ id: String) -> CoreDevice? {
        refreshFacts()
        _ = deviceFactsMirror.value
        return facts.devices[Self.factDeviceID(id)]
    }

    /// When the monitor last wrote the device (epoch seconds). Not
    /// observed: the card's "written N s ago" line reads it on its own
    /// 5 s clock.
    func deviceLastWrite(_ id: String) -> Double? {
        refreshFacts()
        return lastWrites[Self.factDeviceID(id)]
    }

    /// The `lights` surface the device plays (`DeviceHealthLine.surface`).
    func deviceSurface(_ id: String) -> CoreLightSurface? {
        refreshFacts()
        _ = deviceSurfaceMirror.value
        return facts.deviceSurfaces[Self.factDeviceID(id)]
    }

    /// The Dot's `dot_link` word and its own surface, from `lights`.
    var dotLink: CoreDotLink? {
        refreshFacts()
        _ = dotLinkMirror.value
        return facts.dotLink
    }

    var dotSurface: CoreLightSurface? {
        refreshFacts()
        _ = dotSurfaceMirror.value
        return facts.dotSurface
    }

    var screenBarSurface: CoreLightSurface? {
        refreshFacts()
        _ = screenBarSurfaceMirror.value
        return facts.screenBarSurface
    }

    /// `state.power.closed_lid`.
    var closedLid: CoreClosedLid? {
        refreshFacts()
        _ = closedLidMirror.value
        return facts.closedLid
    }

    /// `state.peers`.
    var peers: [CorePeer]? {
        refreshFacts()
        _ = peersMirror.value
        return facts.peers
    }

    /// A Pro strip is connected now.
    var stripPresent: Bool {
        refreshFacts()
        _ = deviceFactsMirror.value
        return facts.devices.values.contains { $0.kind == "pro" && $0.isPresent }
    }

    /// `CoreModel.isLive`, observed on its own: it moves when the monitor
    /// connects or goes, not on every `state` push.
    var isLive: Bool {
        refreshFacts()
        _ = liveMirror.value
        return facts.live
    }

    /// Providers with a retained session, including workers.
    var runningProviders: Set<String> {
        refreshFacts()
        _ = runningMirror.value
        return facts.runningProviders
    }

    // MARK: Hooks

    /// Providers a hook install/uninstall is in flight for; the row
    /// disables its buttons and the reply's per-provider result is shown.
    private(set) var hookBusy: Set<String> = []

    func hookStatus(_ provider: String) -> String? {
        refreshFacts()
        _ = hookStatusMirror.value
        return facts.hookStatuses[provider]
    }

    /// `health.detected[provider]`: whether the agent's CLI was found on
    /// this Mac — nil means the daemon does not say.
    func hookDetected(_ provider: String) -> Bool? {
        refreshFacts()
        _ = hookDetectedMirror.value
        return facts.hookDetections[provider]
    }

    /// A result line the Agents page shows ON the provider's row — the
    /// reply's own words for 6 s, secondary on success, red on failure.
    struct HookNote: Equatable {
        let text: String
        let isError: Bool
    }
    private(set) var hookNotes: [String: HookNote] = [:]
    @ObservationIgnored private var hookNoteClear: [String: DispatchWorkItem] = [:]

    private func noteHook(_ provider: String, _ text: String, isError: Bool) {
        hookNotes[provider] = HookNote(text: text, isError: isError)
        hookNoteClear[provider]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hookNotes[provider] = nil }
        }
        hookNoteClear[provider] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// The same transient line for the Creator Micro card — the enable
    /// toggle's answer lands on its row, not only in the banner.
    private(set) var deckNote: HookNote?
    @ObservationIgnored private var deckNoteClear: DispatchWorkItem?

    func noteDeck(_ text: String, isError: Bool) {
        deckNote = HookNote(text: text, isError: isError)
        deckNoteClear?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.deckNote = nil }
        }
        deckNoteClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// `install_hooks` awaited: the reply's `results[provider]` carries
    /// `ok`, `changed`, `warning`; a refusal becomes the error line —
    /// and the row note, so the answer lands where the click happened.
    func installHooks(_ provider: String) {
        runHook(provider: provider, verb: "Install") { try await self.core.installHooksNow(providers: [provider]) }
    }

    var pendingIntegrationRemoval: String?
    @ObservationIgnored var hookRemover: ([String]) async throws -> CoreReply
    @ObservationIgnored var pageResetter: ([String]) async throws -> CoreReply

    func requestIntegrationRemoval(_ provider: String) {
        guard !hookBusy.contains(provider), isLive else { return }
        pendingIntegrationRemoval = provider
    }

    func cancelIntegrationRemoval() { pendingIntegrationRemoval = nil }

    @discardableResult
    func confirmIntegrationRemoval() -> Task<Void, Never>? {
        guard let provider = pendingIntegrationRemoval else { return nil }
        pendingIntegrationRemoval = nil
        return runHook(provider: provider, verb: "Remove") { try await self.hookRemover([provider]) }
    }

    @discardableResult
    private func runHook(provider: String, verb: String, _ body: @escaping @MainActor () async throws -> CoreReply) -> Task<Void, Never>? {
        guard !hookBusy.contains(provider) else { return nil }
        guard core.isLive else {
            noteHook(provider, MonitorWords.label, isError: true)
            return nil
        }
        hookBusy.insert(provider)
        return Task { [weak self] in
            guard let self else { return }
            defer { self.hookBusy.remove(provider) }
            do {
                let reply = try await body()
                if !reply.ok {
                    let message = reply.error?.sentence ?? "The monitor refused that."
                    self.noteHook(provider, message, isError: true)
                    self.report(error: "\(verb) hooks for \(ProviderPalette.displayName(for: provider)): \(message)")
                    return
                }
                let result = reply.result?["results"]?[provider]
                if result?["ok"]?.boolValue == false {
                    let message = result?["error"]?.stringValue ?? "failed"
                    self.noteHook(provider, message, isError: true)
                    self.report(error: "\(verb) hooks for \(ProviderPalette.displayName(for: provider)): \(message)")
                } else if let warning = result?["warning"]?.stringValue, !warning.isEmpty {
                    self.noteHook(provider, warning, isError: true)
                    self.report(error: "\(ProviderPalette.displayName(for: provider)): \(warning)")
                } else {
                    self.noteHook(provider, verb == "Install" ? "Hooks installed" : "Removed",
                                  isError: false)
                    self.show(status: verb == "Install" ? "Hooks installed for \(ProviderPalette.displayName(for: provider))" : "Hooks removed for \(ProviderPalette.displayName(for: provider))")
                }
            } catch {
                self.noteHook(provider, MonitorWords.reason(error), isError: true)
                self.report(error: "\(verb) hooks for \(ProviderPalette.displayName(for: provider)): \(MonitorWords.reason(error))")
            }
        }
    }

    // MARK: Provider updates

    /// Providers whose Update click is waiting on the daemon's reply. The
    /// reply comes at once (the updater runs on a daemon thread); the run
    /// itself shows in `core.providerUpdates`, so a second click is also
    /// refused while that says `running`.
    private(set) var updateBusy: Set<String> = []

    /// `provider_update`: runs the provider's own updater. Explicit only: a
    /// click on a row's Update button. A refusal (no updater, not installed,
    /// busy) is the reply's own sentence on the row, as an install's is.
    func updateProvider(_ provider: String) {
        guard !updateBusy.contains(provider), core.providerUpdates[provider]?.isRunning != true else { return }
        guard core.isLive else {
            noteHook(provider, MonitorWords.label, isError: true)
            return
        }
        updateBusy.insert(provider)
        Task { [weak self] in
            guard let self else { return }
            defer { self.updateBusy.remove(provider) }
            do {
                let start = try await self.core.updateProvider(provider)
                if !start.started {
                    self.noteHook(provider, start.message.isEmpty ? "Not started" : start.message, isError: true)
                }
            } catch {
                let words = MonitorWords.reason(error)
                self.noteHook(provider, words, isError: true)
            }
        }
    }

    // MARK: Claude plan limits

    /// `claude_plan_limits_enabled` is consent-gated: the daemon persists
    /// it only together with this build's `claude_plan_limits_consent_version`
    /// stamp (`settings._claude_plan_limits_consented`). The stamp is
    /// written first so a consent-aware core sees it already in the
    /// document; a core that applies the stamp itself answers with the
    /// normalised `value`, and a bounce is said out loud instead of the
    /// toggle flipping and quietly reverting.
    @discardableResult
    func setClaudePlanLimits(_ on: Bool) -> Task<Void, Never> {
        pending["claude_plan_limits_enabled"] = .bool(on)
        let token = UUID()
        pendingTokens["claude_plan_limits_enabled"] = token
        overlayChanged(at: "claude_plan_limits_enabled")
        pendingWrites += 1
        return Task { [weak self] in
            guard let self else { return }
            defer { self.pendingWrites -= 1 }
            do {
                if on {
                    _ = try await self.writeSetting("claude_plan_limits_consent_version", value: .number(1))
                }
                guard self.pendingTokens["claude_plan_limits_enabled"] == token else { return }
                let reply = try await self.writeSetting("claude_plan_limits_enabled", value: .bool(on))
                guard self.pendingTokens["claude_plan_limits_enabled"] == token else { return }
                if !reply.ok {
                    self.dropPending("claude_plan_limits_enabled", ifStill: .bool(on))
                    self.report(error: "Couldn't change plan limits. " + (reply.error?.sentence ?? "The monitor refused it."))
                    return
                }
                if on, reply.result?["value"]?.boolValue != true {
                    self.dropPending("claude_plan_limits_enabled", ifStill: .bool(on))
                    self.report(error: "Plan limits stayed off. The monitor did not keep the change.")
                    return
                }
                self.settlePending("claude_plan_limits_enabled", value: .bool(on), echoed: reply.result?["value"], token: token)
            } catch {
                guard self.pendingTokens["claude_plan_limits_enabled"] == token else { return }
                self.dropPending("claude_plan_limits_enabled", ifStill: .bool(on))
                self.report(error: "Couldn't change plan limits. " + MonitorWords.reason(error))
            }
        }
    }

    // MARK: Remote

    /// `serve_token`: copies the loopback status endpoint's bearer token
    /// to the pasteboard, marked concealed so a clipboard manager that
    /// honours the convention leaves it out of its history.
    func copyServeToken() {
        Task { [weak self] in
            guard let self else { return }
            do {
                if let token = try await self.core.serveToken(), !token.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token, forType: .string)
                    NSPasteboard.general.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                    self.show(status: "Key copied")
                } else {
                    self.report(error: "Couldn't copy the key. The monitor did not hand one over.")
                }
            } catch {
                self.report(error: "Couldn't copy the key. " + MonitorWords.reason(error))
            }
        }
    }

    /// Settings › Alerts & Sounds › Phone alert › Test: one fixed line to the saved
    /// ntfy topic, only because the button was pressed. The daemon words the
    /// outcome; it is shown as given.
    var phoneAlertTesting = false

    func testPhoneAlert() {
        guard !phoneAlertTesting else { return }
        phoneAlertTesting = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.phoneAlertTesting = false }
            do {
                let outcome = try await self.core.testPhoneAlert()
                if outcome.sent {
                    self.show(status: outcome.message)
                } else {
                    self.report(error: outcome.message)
                }
            } catch {
                self.report(error: "The monitor did not answer the test")
            }
        }
    }

    // MARK: Actions

    func runDoctor() {
        doctorRunning = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.doctorRunning = false }
            do {
                let reply = try await self.core.doctor()
                self.doctorReport = reply.ok ? (reply.result ?? .object([:])) : .object(["error": .string(reply.error?.sentence ?? "The doctor did not finish.")])
            } catch {
                self.doctorReport = .object(["error": .string(MonitorWords.reason(error))])
            }
        }
    }

    /// "Copy diagnostics" is gathering (the doctor round-trip).
    var diagnosticsCopying = false

    /// Settings › General › Advanced › Copy diagnostics: the Doctor's reply (when
    /// the monitor is up), every Setup permission read without prompting,
    /// both builds and the log tail, redacted, onto the pasteboard.
    func copyDiagnostics() {
        guard !diagnosticsCopying else { return }
        diagnosticsCopying = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.diagnosticsCopying = false }
            var doctor: JSONValue?
            if self.core.isLive {
                do {
                    let reply = try await self.core.doctor()
                    doctor = reply.ok ? (reply.result ?? .object([:]))
                        : .object(["error": .string(reply.error?.sentence ?? "The doctor did not finish.")])
                } catch {
                    doctor = .object(["error": .string("\(error)")])
                }
            }
            var statuses = await SetupModel.probePermissions()
            statuses[.lidHelper] = SetupModel.lidHelperStatus(
                helperInstalled: self.core.isLive ? self.core.state?.power?.closedLid?.helperInstalled : nil)
            let bundle = Bundle.main
            let facts = DiagnosticsReport.Facts(
                appVersion: AppVersion.describe(bundle: bundle),
                appCommit: bundle.object(forInfoDictionaryKey: "JRBarCommit") as? String,
                system: Self.systemDescription(),
                bundlePath: bundle.bundlePath,
                connection: self.connectionDescription,
                coreVersion: self.core.hello?.coreVersion,
                doctor: doctor,
                permissions: SetupPermission.allCases.map { ($0.title, (statuses[$0] ?? .unknown).word) },
                log: self.core.logTail,
                home: FileManager.default.homeDirectoryForCurrentUser.path,
                generated: Date())
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(DiagnosticsReport.text(facts), forType: .string)
            self.show(status: "Diagnostics copied — paste them into a report or a session")
        }
    }

    // MARK: Transfer

    /// An opened export waiting on its checklist.
    var pendingImport: SettingsBundle?
    /// An import is writing (the monitor's keys go one `set_setting` each).
    var importing = false

    /// Advanced › Transfer › Export: every category into one file the
    /// person names. The monitor's part is whatever document is live; a
    /// monitor that is down exports the app's part alone.
    func exportSettings() {
        let bundle = SettingsBundle.make(
            document: core.settings?.document, schema: core.settings?.schema,
            utilities: utilities?.state, toys: toys?.state,
            defaults: UserDefaults.standard.dictionaryRepresentation(),
            appVersion: AppVersion.describe(), now: Date())
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "JR-Bar Settings.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.message = "The file holds the menu bar's curated apps, your shortcuts and your ntfy topic; keep it where only you can read it. Webhook URLs and hook programs are never written to it."
        guard WindowPresenter.automatic.runModal(panel) == .OK, let url = panel.url else { return }
        Task {
            do {
                try await Task.detached(priority: .utility) { try bundle.write(to: url) }.value
                let parts = bundle.categories.map { $0.title.lowercased() }
                show(status: "Exported \(parts.joined(separator: ", ")) to \(url.lastPathComponent)")
            } catch {
                report(error: "Export: \(error.localizedDescription)")
            }
        }
    }

    /// Advanced › Transfer › Import: read a file, then show its checklist.
    func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard WindowPresenter.automatic.runModal(panel) == .OK, let url = panel.url else { return }
        Task {
            let reader = BackgroundLookupCache<URL, Result<SettingsBundle, Error>>(load: { url in
                Result { try SettingsBundle.read(contentsOf: url) }
            })
            guard let result = await reader.resolve(url) else {
                report(error: "Import: file read timed out")
                return
            }
            do { pendingImport = try result.get() }
            catch { report(error: "Import: \(error.localizedDescription)") }
        }
    }

    /// Applies the ticked categories. The monitor's keys go through
    /// `set_setting` one at a time — the daemon validates each, and a
    /// refusal names its key instead of failing the rest; only keys this
    /// monitor knows and values that differ are written. The Utilities
    /// and Toys pages take their state whole, through their own stores,
    /// so every utility re-applies at once.
    @discardableResult
    func applyImport(_ bundle: SettingsBundle, categories: Set<SettingsBundle.Category>) -> Task<Void, Never>? {
        guard !categories.isEmpty, !importing else { return nil }
        pendingImport = nil
        importing = true
        return Task { [weak self] in
            guard let self else { return }
            defer { self.importing = false }
            var done: [String] = []
            var problems: [String] = []
            var needsYourOK: [String] = []
            let wantsMonitor = categories.contains(.monitor) || categories.contains(.devices)
            if wantsMonitor, !self.core.isLive {
                problems.append("monitor settings need the monitor running")
            }
            if categories.contains(.monitor), self.core.isLive {
                let plan = bundle.monitorWrites(against: self.core.settings?.document)
                let style = bundle.monitor["menu_bar_icon_style"]?.stringValue
                let importedStyle = style.flatMap { StatusIconStyle(rawValue: $0) }
                var styleLanded = importedStyle.map {
                    self.core.settings?.document["menu_bar_icon_style"] == .string($0.rawValue)
                } ?? false
                var refused: [String] = []
                for write in plan.writes {
                    let landed = await self.write(write.key, write.value)
                    if !landed { refused.append(write.key) }
                    if write.key == "menu_bar_icon_style" { styleLanded = landed }
                }
                if styleLanded, let importedStyle {
                    // This write already landed. Copy it to the picker and
                    // status item without sending it to the monitor again.
                    self.copyingImportedIconStyle = true
                    self.menuBarIconStyle = importedStyle.rawValue
                    self.copyingImportedIconStyle = false
                }
                done.append("\(plan.writes.count - refused.count) monitor settings")
                if !refused.isEmpty { problems.append("refused " + refused.joined(separator: ", ")) }
                if !plan.unknown.isEmpty { problems.append("\(plan.unknown.count) this monitor does not know were skipped") }
                needsYourOK += plan.needsYourOK
            }
            if categories.contains(.devices), self.core.isLive, let devices = bundle.devices {
                var landed = self.core.settings?.document["devices"] == devices
                if !landed { landed = await self.write("devices", devices) }
                if landed { done.append("devices") } else { problems.append("the devices were refused") }
            }
            if categories.contains(.utilities) {
                if let state = SettingsBundle.decode(UtilitiesState.self, from: bundle.utilities), let utilities = self.utilities {
                    let kept = SettingsBundle.utilitiesForImport(state, over: utilities.state)
                    utilities.state = kept.state
                    needsYourOK += kept.needsYourOK
                    done.append("utilities")
                } else {
                    problems.append("the utilities could not be read")
                }
            }
            if categories.contains(.toys) {
                if let state = SettingsBundle.decode(ToysState.self, from: bundle.toys), let toys = self.toys {
                    let kept = SettingsBundle.toysForImport(state, over: toys.state)
                    toys.replaceState(kept.state)
                    needsYourOK += kept.needsYourOK
                    done.append("toys")
                } else {
                    problems.append("the toys could not be read")
                }
            }
            if categories.contains(.preferences) {
                let preferences = self.applyPreferences(bundle.preferences)
                done.append("\(preferences.applied) preferences")
                needsYourOK += preferences.needsYourOK
                if !preferences.refused.isEmpty {
                    problems.append("skipped shortcuts the recorder would refuse: " + preferences.refused.joined(separator: ", "))
                }
                if !preferences.malformed.isEmpty {
                    problems.append("preferences could not be read: " + preferences.malformed.joined(separator: ", "))
                }
            }
            var summary = "Imported " + (done.isEmpty ? "nothing" : done.joined(separator: ", "))
            if !needsYourOK.isEmpty {
                let names = Array(Set(needsYourOK)).sorted().joined(separator: ", ")
                summary += ". Needs your OK on this Mac, left off: " + names
            }
            if problems.isEmpty {
                self.show(status: summary)
            } else {
                self.report(error: summary + " — " + problems.joined(separator: "; "))
            }
        }
    }

    /// One awaited `set_setting`; true when the monitor took it.
    private func write(_ key: String, _ value: JSONValue) async -> Bool {
        do {
            let reply = try await writeSetting(SettingsPath(key), value: value)
            guard reply.ok else { return false }
            if let echoed = reply.result?["value"], !echoed.isNull { return Self.sameValue(echoed, value) }
            return true
        } catch {
            return false
        }
    }

    /// The app's preferences, each through the path its own control
    /// takes so it lands live: chords re-register (first, so the file's
    /// own on/off switches win after a recorded key turns one on), the
    /// switches flip their registrations, the channel and automatic
    /// checks reach Sparkle, and sounds and the strip re-read. A chord
    /// the recorder would refuse is not bound; its id comes back in
    /// `refused` for the summary to name.
    private func applyPreferences(_ preferences: [String: JSONValue]) -> (applied: Int, refused: [String], malformed: [String], needsYourOK: [String]) {
        let chordPrefix = "hotkeyChord."
        var applied = 0
        var refused: [String] = []
        var malformed: [String] = []
        var needsYourOK: [String] = []
        for key in preferences.keys.sorted() where key.hasPrefix(chordPrefix) {
            let id = String(key.dropFirst(chordPrefix.count))
            switch SettingsBundle.importedChord(preferences[key]) {
            case .unbound: setShortcut(nil, for: id)
            case .chord(let chord): setShortcut(chord, for: id)
            case .refused:
                refused.append(id)
                continue
            }
            applied += 1
        }
        let defaults = UserDefaults.standard
        for key in preferences.keys.sorted() where !key.hasPrefix(chordPrefix) {
            guard let value = preferences[key], let object = SettingsBundle.defaultsValue(value) else {
                malformed.append(key)
                continue
            }
            switch key {
            case PanelHotkey.defaultsKey:
                guard let on = value.boolValue else { malformed.append(key); continue }
                panelHotkeyEnabled = on
            case Self.studioHotkeyDefaultsKey:
                guard let on = value.boolValue else { malformed.append(key); continue }
                studioHotkeyEnabled = on
            case Self.shelfHotkeyDefaultsKey:
                guard let on = value.boolValue else { malformed.append(key); continue }
                shelfHotkeyEnabled = on
            case SparkleUpdater.channelDefaultsKey:
                guard let channel = value.stringValue else { malformed.append(key); continue }
                updateChannel = channel
            case SparkleUpdater.automaticChecksDefaultsKey:
                guard let on = value.boolValue else { malformed.append(key); continue }
                if let held = SettingsBundle.preferenceNeedsYourOK(key, value, currentlyOn: automaticUpdateChecks) {
                    needsYourOK.append(held)
                    continue
                }
                setAutomaticUpdateChecks(on)
            case SystemTogglesStore.awakeDisplayDefaultsKey:
                guard let on = value.boolValue else { malformed.append(key); continue }
                SystemTogglesStore.shared.setAwakeKeepsDisplay(on)
            default:
                defaults.set(object, forKey: key)
            }
            applied += 1
        }
        if applied > 0 {
            soundPreferences = SoundPreferences.load()
            SystemTogglesStore.shared.state.strip = SystemTogglesStore.loadStrip()
        }
        return (applied, refused, malformed, needsYourOK)
    }

    /// The monitor's connection for Copy diagnostics, raw reason included.
    /// People read `MonitorWords` instead (the Advanced page's Connection row).
    var connectionDescription: String {
        switch core.connection {
        case .connected where core.state != nil: return "Connected"
        case .connected: return "Connected, waiting for state"
        case .connecting(let attempt): return attempt <= 1 ? "Connecting" : "Reconnecting (try \(attempt))"
        case .disconnected(let reason): return "Disconnected (\(reason))"
        case .idle: return "Idle"
        }
    }

    /// "macOS 27.2 (Build …) · Mac16,1" — the OS and the hardware model.
    static func systemDescription() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let name = String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let os = "macOS " + ProcessInfo.processInfo.operatingSystemVersionString
        return name.isEmpty ? os : "\(os) · \(name)"
    }

    /// What the reset confirmation says: what goes back, what that takes
    /// with it that the page does not show, and what it leaves alone.
    nonisolated static func resetMessage(for page: Page) -> String {
        var text = "The monitor's settings on this page go back to their defaults."
        switch page {
        case .general: text += " The menu bar icon returns to its default look."
        case .agents: text += " Track turns on and providers return to the menu bar and panel. Usage consent stays as you chose it. Session clicks return to their defaults."
        case .devices: text += " That includes device switches, brightness, colour gains and resting glow, direction, Screen Bar placement and hidden apps."
        case .alerts: text += " That includes your per-Focus dim rules."
        default: break
        }
        return text + " Shortcuts, sounds, window choices and other settings that live in the app are not touched. This cannot be undone."
    }

    @discardableResult
    func resetPage(_ page: Page) -> Task<Void, Never>? {
        let document = SettingsDocument(core.settings?.document ?? .object([:]))
        let paths = page.resetPaths(in: document)
        guard !paths.isEmpty else { return nil }
        return Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.pageResetter(paths)
                if reply.ok {
                    // The icon style has a copy in the app that the picker and
                    // the status item read; the monitor's reset does not reach it.
                    if page == .general {
                        self.menuBarIconStyle = StatusIconStyle.agents.rawValue
                    }
                    if page == .agents {
                        try await self.providerList.resetPresentationAndTracking(resetDisplay: document.contains("provider_display"))
                    }
                    self.show(status: "\(page.title) is back to its defaults")
                } else {
                    self.report(error: "Couldn't reset \(page.title). " + (reply.error?.sentence ?? "The monitor refused it."))
                }
            } catch {
                self.report(error: "Couldn't reset \(page.title). " + MonitorWords.reason(error))
            }
        }
    }

    func openKeepAwakeSettings() {
        page = .utilities
        subpage = "keepAwake"
    }

    func revealStateFolder() {
        let directory = (core.socketPath as NSString).deletingLastPathComponent
        let url = URL(fileURLWithPath: directory)
        DesktopServices.automatic.reveal([url])
    }

    // MARK: Launch at login

    /// Reads the launch-at-login state off the main thread and lands it
    /// here; the returned task finishes once it has.
    @discardableResult
    func refreshLaunchAtLogin() -> Task<Void, Never> {
        if launchAtLoginChanging, let task = launchAtLoginTask { return task }
        launchAtLoginTask?.cancel()
        let generation = UUID()
        launchAtLoginGeneration = generation
        launchAtLoginBusy = true
        let read = loginItemStateReader
        let task = Task { [weak self] in
            let state = await Task.detached(priority: .userInitiated) { read() }.value
            guard let self, self.launchAtLoginGeneration == generation else { return }
            guard !Task.isCancelled else {
                self.launchAtLoginBusy = false
                return
            }
            self.loginItemState = state
            self.launchAtLogin = state.isEnabled
            self.launchAtLoginError = nil
            self.launchAtLoginBusy = false
        }
        launchAtLoginTask = task
        return task
    }

    nonisolated static let systemLaunchAtLogin: @Sendable () -> Bool = {
        SMAppService.mainApp.status == .enabled
    }

    var launchAtLoginSubtitle: String {
        if launchAtLoginBusy { return launchAtLoginChanging ? "Changing the login item…" : "Checking the login item…" }
        return launchAtLoginError ?? loginItemState.subtitle
    }

    @discardableResult
    func setLaunchAtLogin(_ on: Bool) -> Task<Void, Never> {
        // A status read may be replaced, but a registration cannot be
        // canceled once macOS has received it. Keep writes serial.
        if launchAtLoginChanging, let task = launchAtLoginTask { return task }
        launchAtLoginTask?.cancel()
        let generation = UUID()
        launchAtLoginGeneration = generation
        launchAtLoginBusy = true
        launchAtLoginChanging = true
        let change = loginItemChange
        let read = loginItemStateReader
        let task = Task { [weak self] in
            var failure: String?
            do {
                try await Task.detached(priority: .userInitiated) { try change(on) }.value
            } catch {
                failure = error.localizedDescription
            }
            let state = await Task.detached(priority: .userInitiated) { read() }.value
            guard let self, self.launchAtLoginGeneration == generation else { return }
            self.loginItemState = state
            self.launchAtLogin = state.isEnabled
            self.launchAtLoginError = failure
            self.launchAtLoginBusy = false
            self.launchAtLoginChanging = false
        }
        launchAtLoginTask = task
        return task
    }

    // MARK: Software update

    /// Re-reads the updater's state; the delegate calls it once the updater
    /// exists, its automatic-checks flag changes, or a check finishes.
    func refreshUpdater() {
        let updater = SparkleUpdater.shared
        updaterAvailable = updater?.isAvailable ?? false
        updaterHint = updaterAvailable ? nil : (updater?.availability.description ?? "Sparkle.framework is not in this build")
        automaticUpdateChecks = updater?.automaticallyChecksForUpdates ?? false
        lastUpdateCheck = readLastUpdateCheck()
    }

    /// The app keeps these observers for its lifetime; tests remove their own.
    @discardableResult
    func observeUpdaterChanges(in center: NotificationCenter = .default) -> [NSObjectProtocol] {
        [SparkleUpdater.automaticChecksDidChange, SparkleUpdater.updateCycleDidFinish].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshUpdater() }
            }
        }
    }

    /// The "Automatically check for updates" toggle: Sparkle owns the value.
    func setAutomaticUpdateChecks(_ on: Bool) {
        guard let updater = SparkleUpdater.shared, updater.isAvailable else {
            refreshUpdater()
            return
        }
        updater.automaticallyChecksForUpdates = on
        refreshUpdater()
    }

    /// "Check for Updates…" from the General page: the same action the app
    /// menu and the panel use, through the responder chain to `AppDelegate`.
    func checkForUpdates() {
        NSApp.sendAction(#selector(AppDelegate.checkForUpdates(_:)), to: nil, from: nil)
    }

}

extension NSColor {
    /// `#RRGGBB` in sRGB, the form the settings document stores.
    var hexString: String? {
        guard let srgb = usingColorSpace(.sRGB) else { return nil }
        let r = Int((srgb.redComponent * 255).rounded()), g = Int((srgb.greenComponent * 255).rounded()), b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}

/// The folds the heavy pages keep their long runs under.
enum SettingsFold {
    static func device(_ id: String) -> String { "device:\(id)" }
    static let screenBar = "devices:screen-bar"
    static let creatorMicro = "devices:creator-micro"
    static let streamDeck = "devices:stream-deck"
    static let providerColours = "lighting:provider-colours"
    static let shortcutActions = "shortcuts:actions"
    static let quickToggles = "shortcuts:quick-toggles"
    /// The disclosure rows a search hit may sit inside.
    static func advanced(_ page: SettingsStore.Page) -> String { "advanced:\(page.rawValue)" }
    static let screenBarAdvanced = "devices:screen-bar-advanced"
    static let dotClock = "devices:dot-clock"

    /// The groups that sit inside their page's Advanced disclosure, by
    /// chapter. Everything in the Advanced chapter does.
    static let advancedGroups: [SettingsStore.Chapter: Set<String>] = [
        .agents: ["Ask lifetime"],
        .usage: ["Claude Code status line", "Hooks"],
        .notifications: ["Silent sessions", "Calendar & reminders", "Escalation", "Battery", "Webhook"],
        .sounds: ["Output", "Your own sounds"],
        .shortcuts: ["Command line", "Links"],
    ]

    /// Whether a search hit's row sits behind its page's Advanced fold.
    static func isAdvanced(chapter: SettingsStore.Chapter, group: String) -> Bool {
        advancedGroups[chapter]?.contains(group) == true
    }

    /// Rows listed in search that live inside one of those disclosures.
    static let nested: [(chapter: SettingsStore.Chapter, group: String, titles: Set<String>, fold: String)] = [
        (.devices, "Screen Bar", ["Gap width", "Wing length"], screenBarAdvanced),
        (.devices, "Pro & Dot", ["Keep in step", "Sync tolerance"], dotClock),
    ]
}

// MARK: - Path-by-path observation

/// One path of the settings document, observed on its own: its value with
/// the unsent edits laid over it, and whether the monitor's own document
/// carries it. `SettingsStore` writes a cell only when its value moved,
/// so an edit or a `settings` push re-renders the rows that read that
/// path and no others.
@MainActor
@Observable
final class SettingsPathCell {
    private(set) var value: JSONValue?
    private(set) var provided: Bool

    init(value: JSONValue?, provided: Bool) {
        self.value = value
        self.provided = provided
    }

    func update(value: JSONValue?, provided: Bool) {
        if self.value != value { self.value = value }
        if self.provided != provided { self.provided = provided }
    }
}

/// One observable value that is written only when it changes.
@MainActor
@Observable
final class SettingsMirror<Value: Equatable> {
    private(set) var value: Value

    init(_ value: Value) { self.value = value }

    func update(_ value: Value) {
        if self.value != value { self.value = value }
    }
}

/// `SettingsDocument`'s reads, each observed on its own path — what a
/// page body asks instead of `store.document`, so it re-renders when the
/// paths it read change and not on every edit elsewhere.
@MainActor
struct SettingsValues {
    let store: SettingsStore

    func value(at path: SettingsPath) -> JSONValue? { store.value(at: path) }
    func bool(_ path: SettingsPath) -> Bool? { value(at: path)?.boolValue }
    func double(_ path: SettingsPath) -> Double? { value(at: path)?.doubleValue }
    func int(_ path: SettingsPath) -> Int? { value(at: path)?.intValue }
    func string(_ path: SettingsPath) -> String? { value(at: path)?.stringValue }
    func strings(_ path: SettingsPath) -> [String]? { value(at: path)?.arrayValue?.compactMap(\.stringValue) }
    func object(_ path: SettingsPath) -> [String: JSONValue]? { value(at: path)?.objectValue }
    func array(_ path: SettingsPath) -> [JSONValue]? { value(at: path)?.arrayValue }

    /// `colors.agent_colors.<provider>` as a canonical `#RRGGBB`.
    func agentColorHex(_ provider: String) -> String? {
        string(SettingsPath("colors.agent_colors.\(provider)")).flatMap(normalizedColorHex)
    }

    /// `devices[]`'s index for a device id, from the store's device list.
    func deviceIndex(id: String) -> Int? {
        store.deviceEntries.first { $0.id == id }?.index
    }

    /// A document holding only `paths`, read path by path — for the
    /// helpers that take a whole `SettingsDocument` but look at a few keys.
    func document(_ paths: [SettingsPath]) -> SettingsDocument {
        paths.reduce(SettingsDocument()) { document, path in
            guard let value = value(at: path) else { return document }
            return document.replacing(path, with: value)
        }
    }
}

/// What the Settings pages show of `state` and `lights`, read in one
/// pass. Each field has its own mirror on the store.
struct SettingsCoreFacts: Equatable {
    var live = false
    var hookStatuses: [String: String] = [:]
    var hookDetections: [String: Bool] = [:]
    var runningProviders: Set<String> = []
    /// Devices by id with `last_write` and `write_health` taken out.
    var devices: [String: CoreDevice] = [:]
    var deviceSurfaces: [String: CoreLightSurface] = [:]
    var dotLink: CoreDotLink?
    var dotSurface: CoreLightSurface?
    var screenBarSurface: CoreLightSurface?
    var closedLid: CoreClosedLid?
    var peers: [CorePeer]?
    var deck: DeckState?

    init() {}

    init(state: CoreState?, lights: CoreLights?, live: Bool) {
        self.live = live
        let health = state?.health
        for provider in SettingsKey.providers {
            if let status = health?["hooks"]?[provider]?.stringValue { hookStatuses[provider] = status }
            if let found = health?["detected"]?[provider]?.boolValue { hookDetections[provider] = found }
        }
        runningProviders = Set((state?.sessions ?? []).map(\.provider))
        let all = state?.devices ?? []
        for device in all where devices[device.id] == nil {
            var still = device
            still.lastWrite = nil
            still.writeHealth = nil
            devices[device.id] = still
        }
        for device in all where deviceSurfaces[device.id] == nil {
            if let surface = DeviceHealthLine.surface(for: device, lights: lights, devices: all) {
                deviceSurfaces[device.id] = surface
            }
        }
        dotLink = lights?.dotLink
        dotSurface = lights?.dot
        screenBarSurface = lights?.screenBar
        closedLid = state?.power?.closedLid
        peers = state?.peers
        deck = state?.deck
    }
}

/// What the core holds now, read from its stored properties without
/// registering an Observation access. The store watches these itself
/// and syncs its mirrors from them; a view reading a mirror in the
/// moment before that sync would otherwise start observing the whole
/// `state`, `lights` or `settings` through the store. Should the model's
/// storage ever read differently, the plain (observed) reads stand in.
@MainActor
enum CoreReading {
    struct Now {
        var settings: CoreSettings?
        var state: CoreState?
        var lights: CoreLights?
        var live: Bool
    }

    static func now(_ core: CoreModel) -> Now {
        var settings: CoreSettings?, state: CoreState?, lights: CoreLights?
        var live: Bool?
        var found = 0
        for child in Mirror(reflecting: core).children {
            switch child.label {
            case "_settingsFrame": settings = (child.value as? CoreSettingsFrame)?.settings; found += 1
            case "_state": state = child.value as? CoreState; found += 1
            case "_lights": lights = child.value as? CoreLights; found += 1
            case "_isLive": live = child.value as? Bool; found += 1
            default: continue
            }
            if found == 4 { break }
        }
        guard found == 4, let live else {
            return Now(settings: core.settings, state: core.state, lights: core.lights,
                       live: core.isLive)
        }
        return Now(settings: settings, state: state, lights: lights, live: live)
    }
}

private extension SettingsPath {
    /// One path lies along the other (or they are the same path): a write
    /// to either can change what a read of the other returns.
    func overlaps(_ other: SettingsPath) -> Bool {
        let shared = min(segments.count, other.segments.count)
        return segments.prefix(shared) == other.segments.prefix(shared)
    }
}
