import JRBarUI
import AppKit
import JRBarCore
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications

/// The Settings window's state. The daemon's document is the only source of
/// truth; this store overlays the edits it has sent and not yet seen echoed,
/// so a slider does not snap back between the write and the next `settings`
/// message, and turns paths into SwiftUI bindings.
@MainActor
@Observable
final class SettingsStore {
    enum Page: String, CaseIterable, Identifiable, Hashable {
        case general, agents, usage, devices, utilities, lighting, toys, notifications, sounds, shortcuts, remote, advanced

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .agents: return "Agents"
            case .usage: return "Usage"
            case .devices: return "Devices & Screen Bar"
            case .utilities: return "Utilities"
            case .lighting: return "Lighting"
            case .toys: return "Toys"
            case .notifications: return "Notifications & Focus"
            case .sounds: return "Sounds"
            case .shortcuts: return "Shortcuts"
            case .remote: return "Remote"
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
            case .advanced: return "wrench.and.screwdriver.fill"
            }
        }

        /// System Settings tints every sidebar icon; these follow its palette.
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
            case .toys: return Color(red: 0.93, green: 0.30, blue: 0.62)
            case .notifications: return Color(nsColor: .systemRed)
            case .sounds: return Color(nsColor: .systemPurple)
            case .shortcuts: return Color(nsColor: .systemBlue)
            case .remote: return Color(nsColor: .systemTeal)
            case .advanced: return Color(nsColor: .systemGray)
            }
        }

        /// The daemon-document page this page resets; nil for pages with
        /// no daemon keys (Toys keeps its state in `app-state.json`).
        var catalogue: SettingsKey.Page? { SettingsKey.Page(rawValue: rawValue) }
    }

    let core: CoreModel
    var page: Page = .general {
        // A search hit names its row only on its own page; choosing any
        // other page retires it.
        didSet { if searchHit?.page != page { searchHit = nil } }
    }
    /// The Toys page's store, created beside this one in the delegate.
    /// Weak: the delegate owns it.
    weak var toys: ToysStore?
    /// The Utilities page's store, same seat as `toys`. Weak: the
    /// delegate owns it.
    weak var utilities: UtilitiesStore?
    /// Lighting › Effects… opens the Effect Studio window.
    var onOpenEffects: (@MainActor () -> Void)?
    /// Devices › Creator Micro 2 › Open Control Center…
    var onOpenControlCenter: (@MainActor () -> Void)?
    /// Usage › Open Usage Center… — where the graphs actually live.
    var onOpenUsageCenter: (@MainActor () -> Void)?
    var deck: DeckState? { core.deck }
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
    var launchAtLogin: Bool = false
    var launchAtLoginError: String?

    @ObservationIgnored private var pending: [String: JSONValue] = [:]
    @ObservationIgnored private var throttles: [String: DispatchWorkItem] = [:]
    @ObservationIgnored private var errorClear: DispatchWorkItem?
    /// Bumped whenever the overlay changes so observers re-read.
    private var overlayVersion = 0

    /// `menu_bar_icon_style`: the daemon's settings dataclass does carry
    /// this field and round-trips it in the document, but the document
    /// only exists after connect — so the app still keeps a launch-time
    /// copy in `app-state.json` for the moments before the first frame.
    var menuBarIconStyle: String = StatusIconStyle.agents.rawValue {
        didSet {
            guard menuBarIconStyle != oldValue else { return }
            onSetMenuBarIconStyle?(menuBarIconStyle)
            set("menu_bar_icon_style", .string(menuBarIconStyle))
        }
    }
    /// Persists the choice; wired to `AppState` by the delegate.
    var onSetMenuBarIconStyle: (@MainActor (String) -> Void)?

    /// "Summon the panel with ⌃⌥J": an app-local UserDefaults key (not a
    /// daemon setting); the delegate registers/unregisters the Carbon
    /// hot-key when it flips.
    var panelHotkeyEnabled: Bool = UserDefaults.standard.bool(forKey: PanelHotkey.defaultsKey) {
        didSet {
            guard panelHotkeyEnabled != oldValue else { return }
            UserDefaults.standard.set(panelHotkeyEnabled, forKey: PanelHotkey.defaultsKey)
            onPanelHotkeyChange?(panelHotkeyEnabled)
        }
    }
    var onPanelHotkeyChange: (@MainActor (Bool) -> Void)?

    /// The delegate mirrors `PanelHotkey.registrationFailed` here so the
    /// toggle can say "⌃⌥J is taken by another app" instead of silently
    /// doing nothing while looking enabled.
    var panelHotkeyRegistrationFailed = false

    /// "Summon the shelf with ⌃⌥D" — Yoink's drop-target summon. Same
    /// app-local UserDefaults pattern as the panel's key; the delegate
    /// toggles the island card on the press.
    static let shelfHotkeyDefaultsKey = "shelfHotkeyEnabled"
    var shelfHotkeyEnabled: Bool = UserDefaults.standard.bool(forKey: shelfHotkeyDefaultsKey) {
        didSet {
            guard shelfHotkeyEnabled != oldValue else { return }
            UserDefaults.standard.set(shelfHotkeyEnabled, forKey: Self.shelfHotkeyDefaultsKey)
            onShelfHotkeyChange?(shelfHotkeyEnabled)
        }
    }
    var onShelfHotkeyChange: (@MainActor (Bool) -> Void)?
    var shelfHotkeyRegistrationFailed = false

    /// Bumped on every chord write so views re-read the defaults-backed
    /// chords below.
    private var hotkeyChordVersion = 0

    /// The panel's and the shelf's chords — the persisted rebind, the
    /// shipped ⌃⌥J / ⌃⌥D, or nil once cleared on Settings › Shortcuts.
    var panelHotkeyChord: HotkeyChord? {
        _ = hotkeyChordVersion
        return HotkeyChordDefaults.chord(for: PanelHotkey.panelID, fallback: PanelHotkey.panelDefault)
    }

    var shelfHotkeyChord: HotkeyChord? {
        _ = hotkeyChordVersion
        return HotkeyChordDefaults.chord(for: PanelHotkey.shelfID, fallback: PanelHotkey.shelfDefault)
    }

    /// The keys as General's rows name them: "⌃⌥J", or a plain phrase
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
            HotkeyChordDefaults.set(chord, for: id)
            hotkeyChordVersion += 1
            if chord != nil, !panelHotkeyEnabled {
                panelHotkeyEnabled = true
            } else {
                onPanelHotkeyChange?(panelHotkeyEnabled)
            }
        case PanelHotkey.shelfID:
            HotkeyChordDefaults.set(chord, for: id)
            hotkeyChordVersion += 1
            if chord != nil, !shelfHotkeyEnabled {
                shelfHotkeyEnabled = true
            } else {
                onShelfHotkeyChange?(shelfHotkeyEnabled)
            }
        default:
            if let action = MenuBarHotkeyAction.allCases.first(where: { MenuBarHotkeys.registryID(for: $0) == id }) {
                utilities?.menuBar.setHotkeyChord(chord, for: action)
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

    /// Settings › Sounds — app-local, since the app plays the sounds.
    /// Every write persists at once; the event player reads them at each
    /// sound, so a change lands on the next one.
    var soundPreferences: SoundPreferences = SoundPreferences.load() {
        didSet { if soundPreferences != oldValue { soundPreferences.save() } }
    }

    /// The page's preview voice — the same player, the same choices.
    @ObservationIgnored private lazy var soundPreview = SoundPlayer()

    func previewSound(_ name: String) {
        soundPreview.preview(name)
    }

    // MARK: Search

    /// The sidebar's search text; non-empty swaps the page list for hits.
    var searchQuery = ""
    /// The row a search result was picked for — the page names it at the
    /// top until another page is chosen.
    var searchHit: SettingsSearchEntry?

    /// Every searchable row: the daemon pages' titled rows, each page,
    /// the shortcut catalogue, and the toys and utilities as they are.
    var searchEntries: [SettingsSearchEntry] {
        var entries = SettingsSearch.rows + SettingsSearch.pages + SettingsSearch.shortcutRows
        entries += MenuBarHotkeyAction.allCases.map {
            SettingsSearchEntry(.shortcuts, "Menu bar", MenuBarHotkeys.title(for: $0))
        }
        if let utilities {
            let cards: [any Toy] = [utilities.menuBar, utilities.dock, utilities.agents, utilities.dataHoarder]
            entries += cards.map { SettingsSearchEntry(.utilities, $0.name, $0.name, subtitle: $0.blurb) }
        }
        if let toys {
            entries += toys.toys.map {
                // The notch reads as a utility and sits on that page.
                SettingsSearchEntry($0.id == "notch" ? .utilities : .toys, $0.name, $0.name, subtitle: $0.blurb)
            }
        }
        return entries
    }

    var searchResults: [SettingsSearchEntry] {
        SettingsSearch.search(searchQuery, in: searchEntries)
    }

    /// A result picked: its page, named at the top.
    func reveal(_ entry: SettingsSearchEntry) {
        searchHit = entry
        page = entry.page
    }

    /// macOS's answer to the notification permission, asked by the
    /// Notifications page on appear: the banner toggle can read on while
    /// delivery is denied at the system level, and a silent denial is
    /// indistinguishable from a bug.
    var notificationPermissionDenied = false

    func refreshNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor [weak self] in self?.notificationPermissionDenied = denied }
        }
    }

    init(core: CoreModel) {
        self.core = core
        refreshLaunchAtLogin()
    }

    // MARK: Document

    /// The daemon's document with unsent-or-unechoed edits applied.
    var document: SettingsDocument {
        _ = overlayVersion
        var document = SettingsDocument(core.settings?.document ?? .object([:]))
        for (path, value) in pending {
            document = document.replacing(SettingsPath(path), with: value)
        }
        return document
    }

    var hasDocument: Bool { core.settings != nil }
    var generation: Int { core.settings?.generation ?? 0 }

    func isProvided(_ path: String) -> Bool {
        _ = overlayVersion
        return SettingsDocument(core.settings?.document ?? .object([:])).contains(SettingsPath(path))
    }

    func value(_ path: String) -> JSONValue? { document.value(at: SettingsPath(path)) }

    // MARK: Writes

    /// Sends `set_setting`. `throttled` coalesces a slider's stream into one
    /// write every 120 ms, the last value always winning.
    func set(_ path: String, _ value: JSONValue, throttled: Bool = false) {
        pending[path] = value
        overlayVersion += 1
        throttles[path]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush(path) }
        }
        throttles[path] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (throttled ? 0.12 : 0), execute: work)
    }

    private func flush(_ path: String) {
        throttles[path] = nil
        guard let value = pending[path] else { return }
        pendingWrites += 1
        Task { [weak self] in
            guard let self else { return }
            defer { self.pendingWrites -= 1 }
            do {
                let reply = try await self.core.setSetting(SettingsPath(path), value: value)
                if !reply.ok {
                    self.report(error: reply.error?.message ?? "\(path): refused (\(reply.error?.code ?? "error"))")
                    self.dropPending(path)
                } else {
                    self.settlePending(path, value: value, echoed: reply.result?["value"])
                }
            } catch {
                self.report(error: "\(path): \(error)")
                self.dropPending(path)
            }
        }
    }

    /// Once the daemon's document carries the value, the overlay is not
    /// needed; if the echo is late, give it a moment rather than snapping.
    /// `echoed` is the reply's own normalised `value`: when the daemon kept
    /// something else (a clamped number, a refused flag) the overlay must
    /// drop at once and say so, not paint the asked-for value until the
    /// document push lands.
    private func settlePending(_ path: String, value: JSONValue, echoed: JSONValue? = nil) {
        if let echoed, !echoed.isNull, !Self.sameValue(echoed, value) {
            dropPending(path, ifStill: value)
            report(error: "\(path): the monitor kept \(Self.describeValue(echoed)) instead")
            return
        }
        let inDocument = SettingsDocument(core.settings?.document ?? .object([:])).value(at: SettingsPath(path)) == value
        if inDocument || throttles[path] != nil {
            if inDocument { dropPending(path, ifStill: value) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            MainActor.assumeIsolated { self?.dropPending(path, ifStill: value) }
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

    private func dropPending(_ path: String, ifStill value: JSONValue? = nil) {
        if let value, pending[path] != value { return }
        pending[path] = nil
        overlayVersion += 1
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
            get: { self.document.bool(SettingsPath(path)) ?? fallback },
            set: { self.set(path, .bool($0)) }
        )
    }

    func double(_ path: String, default fallback: Double = 0, throttled: Bool = true) -> Binding<Double> {
        Binding(
            get: { self.document.double(SettingsPath(path)) ?? fallback },
            set: { self.set(path, .number($0), throttled: throttled) }
        )
    }

    func int(_ path: String, default fallback: Int = 0) -> Binding<Int> {
        Binding(
            get: { self.document.int(SettingsPath(path)) ?? fallback },
            set: { self.set(path, .number(Double($0))) }
        )
    }

    func string(_ path: String, default fallback: String = "") -> Binding<String> {
        Binding(
            get: { self.document.string(SettingsPath(path)) ?? fallback },
            set: { self.set(path, .string($0)) }
        )
    }

    /// A string that may be JSON null (`provider_pin`, `signal_policy`);
    /// `nilToken` stands for null in a picker.
    func optionalString(_ path: String, nilToken: String = "") -> Binding<String> {
        Binding(
            get: { self.document.string(SettingsPath(path)) ?? nilToken },
            set: { self.set(path, $0 == nilToken ? .null : .string($0)) }
        )
    }

    func stringList(_ path: String) -> Binding<[String]> {
        Binding(
            get: { self.document.strings(SettingsPath(path)) ?? [] },
            set: { self.set(path, .array($0.map(JSONValue.string))) }
        )
    }

    /// Membership of `item` in a string list as a toggle.
    func listMember(_ path: String, _ item: String) -> Binding<Bool> {
        Binding(
            get: { (self.document.strings(SettingsPath(path)) ?? []).contains(item) },
            set: { on in
                var items = self.document.strings(SettingsPath(path)) ?? []
                if on, !items.contains(item) { items.append(item) }
                if !on { items.removeAll { $0 == item } }
                self.set(path, .array(items.map(JSONValue.string)))
            }
        )
    }

    /// A nullable number as (automatic, value) for the geometry rows.
    func isNull(_ path: String) -> Bool {
        guard let value = document.value(at: SettingsPath(path)) else { return true }
        return value.isNull
    }

    /// A hex colour string as a SwiftUI `Color`.
    func color(_ path: String, default fallback: String) -> Binding<Color> {
        Binding(
            get: {
                let hex = self.document.string(SettingsPath(path)) ?? fallback
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
                let minutes = self.document.int(SettingsPath(path)) ?? fallback
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                self.set(path, .number(Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))))
            }
        )
    }

    // MARK: Devices

    struct DeviceEntry: Identifiable {
        let index: Int
        let id: String
        let name: String
        let kind: String
        var prefix: String { "devices.\(index)" }
    }

    /// Devices from the settings document, kind resolved through the
    /// state's device list when the document does not say.
    var deviceEntries: [DeviceEntry] {
        let known = Dictionary(core.devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return document.deviceEntries.map { index, id, entry in
            let state = known[id]
            let name = entry["name"]?.stringValue ?? state?.name ?? id
            let kind = state?.kind ?? Self.guessKind(id: id, name: name)
            return DeviceEntry(index: index, id: id, name: name, kind: kind)
        }
    }

    private static func guessKind(id: String, name: String) -> String {
        let text = (id + " " + name).lowercased()
        if text.contains("status-bar") || text.contains("screen bar") { return "screen_bar" }
        if text.contains("dot") { return "dot" }
        if text.contains("pro") || text.contains("sidepulse") { return "pro" }
        return "unknown"
    }

    func stateDevice(_ id: String) -> CoreDevice? { core.devices.first { $0.id == id } }

    // MARK: Hooks

    /// Providers a hook install/uninstall is in flight for; the row
    /// disables its buttons and the reply's per-provider result is shown.
    private(set) var hookBusy: Set<String> = []

    func hookStatus(_ provider: String) -> String? {
        core.state?.health?["hooks"]?[provider]?.stringValue
    }

    /// `health.detected[provider]`: whether the agent's CLI was found on
    /// this Mac — nil means the daemon does not say.
    func hookDetected(_ provider: String) -> Bool? {
        core.state?.health?["detected"]?[provider]?.boolValue
    }

    /// `health.sources[provider]`: whether the provider's hook feed is
    /// still delivering (`fresh`) and how many seconds since the last
    /// event it accepted (`heard_age_seconds`, nil when it never has).
    /// The panel's quiet-feed marker reads the same decode through
    /// `CoreState.sourceHealth(for:)`.
    func sourceHealth(_ provider: String) -> (fresh: Bool, heardAgeSeconds: Double?)? {
        core.state?.sourceHealth(for: provider)
    }

    /// `health.intake`: the intake report's verdict codes (`hook_state`,
    /// `source_health`) and the `silence_seconds` bound behind them.
    var intakeHealth: (hookState: String?, sourceHealth: String?, silenceSeconds: Double?)? {
        core.state?.intakeHealth
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

    func uninstallHooks(_ provider: String) {
        runHook(provider: provider, verb: "Remove") { try await self.core.uninstallHooksNow(providers: [provider]) }
    }

    private func runHook(provider: String, verb: String, _ body: @escaping @MainActor () async throws -> CoreReply) {
        guard !hookBusy.contains(provider) else { return }
        guard core.isLive else {
            noteHook(provider, "Monitor offline", isError: true)
            return
        }
        hookBusy.insert(provider)
        Task { [weak self] in
            guard let self else { return }
            defer { self.hookBusy.remove(provider) }
            do {
                let reply = try await body()
                if !reply.ok {
                    let message = reply.error?.message ?? reply.error?.code ?? "refused"
                    self.noteHook(provider, message, isError: true)
                    self.report(error: "\(verb) hooks for \(provider): \(message)")
                    return
                }
                let result = reply.result?["results"]?[provider]
                if result?["ok"]?.boolValue == false {
                    let message = result?["error"]?.stringValue ?? "failed"
                    self.noteHook(provider, message, isError: true)
                    self.report(error: "\(verb) hooks for \(provider): \(message)")
                } else if let warning = result?["warning"]?.stringValue, !warning.isEmpty {
                    self.noteHook(provider, warning, isError: true)
                    self.report(error: "\(provider): \(warning)")
                } else {
                    self.noteHook(provider, verb == "Install" ? "Hooks installed" : "Removed",
                                  isError: false)
                    self.show(status: verb == "Install" ? "Hooks installed for \(provider)" : "Hooks removed for \(provider)")
                }
            } catch {
                self.noteHook(provider, String(describing: error), isError: true)
                self.report(error: "\(verb) hooks for \(provider): \(error)")
            }
        }
    }

    // MARK: Claude plan limits

    /// `claude_plan_limits_enabled` is consent-gated: the daemon persists
    /// it only together with this build's `claude_plan_limits_consent_version`
    /// stamp (`_settings_legacy._claude_plan_limits_consented`). The stamp is
    /// written first so a consent-aware core sees it already in the
    /// document; a core that applies the stamp itself answers with the
    /// normalised `value`, and a bounce is said out loud instead of the
    /// toggle flipping and quietly reverting.
    func setClaudePlanLimits(_ on: Bool) {
        pending["claude_plan_limits_enabled"] = .bool(on)
        overlayVersion += 1
        pendingWrites += 1
        Task { [weak self] in
            guard let self else { return }
            defer { self.pendingWrites -= 1 }
            do {
                if on {
                    _ = try await self.core.setSetting("claude_plan_limits_consent_version", value: .number(1))
                }
                let reply = try await self.core.setSetting("claude_plan_limits_enabled", value: .bool(on))
                if !reply.ok {
                    self.dropPending("claude_plan_limits_enabled", ifStill: .bool(on))
                    self.report(error: "claude_plan_limits_enabled: \(reply.error?.message ?? reply.error?.code ?? "refused")")
                    return
                }
                if on, reply.result?["value"]?.boolValue != true {
                    self.dropPending("claude_plan_limits_enabled", ifStill: .bool(on))
                    self.report(error: "Plan limits stayed off: the monitor applies its own consent stamp and did not keep the write")
                    return
                }
                self.settlePending("claude_plan_limits_enabled", value: .bool(on), echoed: reply.result?["value"])
            } catch {
                self.dropPending("claude_plan_limits_enabled", ifStill: .bool(on))
                self.report(error: "claude_plan_limits_enabled: \(error)")
            }
        }
    }

    // MARK: Usage

    /// False when the daemon says this provider has no quota source at all
    /// (`quota_source: false`): metering it would be a dead checkbox.
    /// A provider the daemon has never listed keeps its checkbox.
    func hasQuotaSource(_ provider: String) -> Bool {
        core.usage.filter { $0.id == provider }.allSatisfy { $0.quotaSource }
    }

    // MARK: Remote

    /// `serve_token`: copies the loopback status endpoint's bearer token
    /// to the pasteboard. The token is fetched on demand, never stored.
    func copyServeToken() {
        Task { [weak self] in
            guard let self else { return }
            do {
                if let token = try await self.core.serveToken(), !token.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token, forType: .string)
                    self.show(status: "Serve token copied")
                } else {
                    self.report(error: "The monitor did not hand over a serve token")
                }
            } catch {
                self.report(error: "serve_token: \(error)")
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
                self.doctorReport = reply.ok ? (reply.result ?? .object([:])) : .object(["error": .string(reply.error?.message ?? "doctor failed")])
            } catch {
                self.doctorReport = .object(["error": .string("\(error)")])
            }
        }
    }

    func resetPage(_ page: Page) {
        guard let catalogue = page.catalogue else { return }
        let paths = SettingsKey.resetPaths(on: catalogue, in: SettingsDocument(core.settings?.document ?? .object([:])))
        guard !paths.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.core.resetSettings(paths: paths)
                if !reply.ok { self.report(error: reply.error?.message ?? "reset refused") }
            } catch {
                self.report(error: "reset: \(error)")
            }
        }
    }

    func revealStateFolder() {
        let directory = (core.socketPath as NSString).deletingLastPathComponent
        let url = URL(fileURLWithPath: directory)
        if FileManager.default.fileExists(atPath: directory) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    // MARK: Launch at login

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Software update

    /// Re-reads the updater's state; the delegate calls it once the updater
    /// exists and whenever Sparkle's automatic-checks flag changes.
    func refreshUpdater() {
        let updater = SparkleUpdater.shared
        updaterAvailable = updater?.isAvailable ?? false
        updaterHint = updaterAvailable ? nil : (updater?.availability.description ?? "Sparkle.framework is not in this build")
        automaticUpdateChecks = updater?.automaticallyChecksForUpdates ?? false
        lastUpdateCheck = updater?.lastUpdateCheckDate
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

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
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
