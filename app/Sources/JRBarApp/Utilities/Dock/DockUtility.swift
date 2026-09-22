import AppKit
import JRBarCore
import Observation
import SwiftUI

/// The Dock utility (docs/TOY-PARITY.md, "Dock — Enhance"): Apple's
/// Dock stays, and `enhance` — the AX hover watcher — floats window
/// previews over it. The main thread constructs it once, wires
/// `settings` to the persisted `DockSettings`, sets the persist
/// callback, and calls `start()`/`stop()` from the card toggle and
/// `applySettings()` on every settings change.
///
/// The Replace bar is gone; what survives of it is `appleDock`, the
/// save-and-restore control over `com.apple.dock autohide`, kept so a
/// Mac the old bar left with Apple's Dock hidden gets it back on the
/// first launch of this build.
@MainActor
@Observable
final class DockUtility {
    /// The live settings read — wire to `UtilitiesStore`'s dock state.
    var settings: @MainActor () -> DockSettings = { DockSettings() }
    /// The card's write path: a mutated copy lands in the store's
    /// `state`, whose `didSet` persists it and re-applies the utility —
    /// the same shape `MenuBarUtility` uses.
    var onSettingsChange: (@MainActor (DockSettings) -> Void)?

    /// Apple's own dock's hide/restore control — restore-only now.
    let appleDock: AppleDockControl
    /// The hover watcher: the AX poll and the preview panel.
    let enhance: DockEnhanceController
    /// ⌥⇥ / ⌘⇥ — owned here, not by the watcher, so the chords stay
    /// live with the previews off or handed to DockDoor.
    let switcher: DockSwitcherController

    /// The daemon's live sessions — wired by `UtilitiesStore` to
    /// `core.state.sessions`. The switcher and the previews read it to
    /// mark the windows agents run in; nothing is fetched for it.
    var sessions: @MainActor () -> [CoreSession] = { [] }
    /// The daemon's pinned asks (`state.asks`) — the episode ids an
    /// Approve / Deny from a preview pins its answer to.
    var asks: @MainActor () -> [CoreAsk] = { [] }
    /// `answer_ask`, awaited — wired to `CoreModel.answerAskNow`. nil
    /// (no daemon) leaves the preview's ask rows read-only.
    var sendAnswer: (@MainActor (_ session: String, _ approve: Bool, _ request: String?) async throws -> CoreReply)?

    /// The live sessions as Dock marks — what the switcher and the
    /// previews both read.
    func agentMarks() -> [DockAgentMark] {
        DockAgentMark.marks(from: sessions(), asks: asks())
    }

    /// A preview's Approve / Deny — `PanelStore.answer`'s guards, and the
    /// daemon's own verdict as the line the row shows. `only_if_frontmost`
    /// stays false: the daemon raises the session's terminal first.
    static func answer(_ ask: CoreAsk, approve: Bool,
                       send: (@MainActor (String, Bool, String?) async throws -> CoreReply)?) async -> String {
        guard let session = ask.session, !session.isEmpty else {
            return "This ask has no session left to answer"
        }
        guard ask.canAnswer else { return "Answer this one in the session's window" }
        if CoreSession.isRemoteID(session) {
            return "Runs on \(CoreSession.remoteMachine(inID: session) ?? "another Mac") — answer it there"
        }
        guard let send else { return "The monitor is not answering" }
        do {
            let reply = try await send(session, approve, ask.request)
            if reply.ok { return approve ? "Approved" : "Denied" }
            return "Couldn't answer: \(reply.error?.message ?? reply.error?.code ?? "refused")"
        } catch {
            return "No answer from the monitor — the ask is still open"
        }
    }

    /// True while the card is on and applied — the watcher, the
    /// switcher, or both run under it.
    private(set) var running = false

    // MARK: Provider — who renders

    /// Re-resolved on every workspace launch/terminate so an external
    /// pick's running/installed state flips live in the card — the
    /// notch's pattern; stored so Observation tracks the read.
    private(set) var workspaceVersion = 0
    /// The provider watch's observers — installed for the object's
    /// life in `init`.
    @ObservationIgnored private var providerObservers: [NSObjectProtocol] = []

    /// The picked counterpart's probe — nil while JR-Bar renders.
    private var externalProbe: ExternalAppProbe? {
        switch settings().provider {
        case .jrbar: return nil
        case .dockDoor: return ExternalProviders.dockDoor
        case .activeDock: return ExternalProviders.activeDock
        }
    }

    /// The card's write path for the picker — same shape as `bind`.
    var providerBinding: Binding<DockProvider> {
        Binding(get: { self.settings().provider },
                set: { p in self.update { $0.provider = p } })
    }

    /// The counterpart's app URL — the card's "Open" button.
    var externalURL: URL? {
        _ = workspaceVersion
        return externalProbe?.url
    }

    /// What the card's chip says while a counterpart owns the surface —
    /// nil under `.jrbar`, so the card falls back to the watcher copy.
    var providerNote: String? {
        guard let probe = externalProbe else { return nil }
        _ = workspaceVersion
        let name = providerName
        if !probe.installed { return "\(name) isn't installed — pick JR-Bar or install it" }
        return probe.running
            ? "\(name) is rendering the previews — ours are parked"
            : "\(name) isn't running — ours stay parked"
    }

    /// The picked counterpart's display name for the note.
    private var providerName: String {
        switch settings().provider {
        case .jrbar: return "JR-Bar"
        case .dockDoor: return "DockDoor"
        case .activeDock: return "ActiveDock"
        }
    }

    /// The card's "Open" — launches the picked counterpart.
    func openExternal() { externalProbe?.open() }

    // MARK: Switcher provider — who owns ⌥⇥

    /// The switcher picker's write path.
    var switcherProviderBinding: Binding<DockSwitcherProvider> {
        Binding(get: { self.settings().switcherProvider },
                set: { p in self.update { $0.switcherProvider = p } })
    }

    /// The picked switcher counterpart's probe — nil while JR-Bar owns
    /// the chords.
    private var switcherProbe: ExternalAppProbe? {
        Self.probe(for: settings().switcherProvider)
    }

    static func probe(for provider: DockSwitcherProvider) -> ExternalAppProbe? {
        switch provider {
        case .jrbar: return nil
        case .altTab: return ExternalProviders.altTab
        case .witch: return ExternalProviders.witch
        case .contexts: return ExternalProviders.contexts
        }
    }

    static func displayName(_ provider: DockSwitcherProvider) -> String {
        switch provider {
        case .jrbar: return "JR-Bar"
        case .altTab: return "AltTab"
        case .witch: return "Witch"
        case .contexts: return "Contexts"
        }
    }

    /// The switcher counterpart's app URL — the card's "Open".
    var switcherExternalURL: URL? {
        _ = workspaceVersion
        return switcherProbe?.url
    }

    func openSwitcherExternal() { switcherProbe?.open() }

    /// What the card says while a counterpart owns the chords — or,
    /// while ours does, which running rival may be bound to the same
    /// chord. nil when there is nothing to say.
    var switcherNote: String? {
        _ = workspaceVersion
        let current = settings()
        if let probe = switcherProbe {
            let name = Self.displayName(current.switcherProvider)
            if !probe.installed { return "\(name) isn't installed — pick JR-Bar or install it" }
            return probe.running
                ? "\(name) owns the switcher — ours is parked"
                : "\(name) isn't running — ours stays parked"
        }
        guard current.switcherWanted else { return nil }
        let running = Self.chordRivals.filter { $0.probe.running }.map(\.name)
        return Self.conflictNote(running: running,
                                 windowChord: current.enhance.windowSwitcher,
                                 appChord: current.enhance.appSwitcher)
    }

    /// The switchers known to bind ⌥⇥ or ⌘⇥ themselves.
    static let chordRivals: [(name: String, probe: ExternalAppProbe)] = [
        ("AltTab", ExternalProviders.altTab),
        ("DockDoor", ExternalProviders.dockDoor),
        ("Witch", ExternalProviders.witch),
        ("Contexts", ExternalProviders.contexts),
    ]

    /// "AltTab is running and may also take ⌥⇥" — the double-switcher
    /// explanation, built from the rivals actually running.
    static func conflictNote(running: [String], windowChord: Bool, appChord: Bool) -> String? {
        guard let first = running.first, windowChord || appChord else { return nil }
        let chord = windowChord && appChord ? "⌥⇥ or ⌘⇥" : (windowChord ? "⌥⇥" : "⌘⇥")
        let who = running.count == 1 ? "\(first) is" : running.dropLast().joined(separator: ", ")
            + " and \(running[running.count - 1]) are"
        return "\(who) running and may also take \(chord)"
    }

    /// Default-argument expressions are evaluated in the caller's
    /// (nonisolated) context under Swift 6, so the main-actor
    /// `AppleDockControl()` can't be a default value — callers pass
    /// nil and the main-actor body builds it.
    init(appleDock: AppleDockControl? = nil,
         autohideHold: DockAutohideHold? = nil) {
        self.appleDock = appleDock ?? AppleDockControl()
        let hold = autohideHold ?? DockAutohideHold()
        hold.onLog = { DockEnhanceController.log.notice("\($0, privacy: .public)") }
        let preferences = DockEnhancePreferences()
        let switcher = DockSwitcherController()
        self.switcher = switcher
        self.enhance = DockEnhanceController(preferences: preferences, autohideHold: hold,
                                             switcher: switcher)
        preferences.read = { [weak self] in self?.settings().enhance ?? DockEnhanceSettings() }
        preferences.write = { [weak self] updated in
            self?.update { $0.enhance = updated }
        }
        // The chords read the settings live; the tap mirrors them on
        // every apply (`reconcile`).
        switcher.isAllowed = { [weak self] in
            guard let settings = self?.settings() else { return false }
            return settings.switcherWanted && settings.enhance.windowSwitcher
        }
        switcher.isCmdAllowed = { [weak self] in
            guard let settings = self?.settings() else { return false }
            return settings.switcherWanted && settings.enhance.appSwitcher
        }
        // Stills need the same Screen Recording grant the previews use —
        // the shared 30 s cache, so a watcher that isn't running can't
        // leave the answer stale.
        switcher.thumbsAllowed = { [weak self] in
            guard let self, FoldCapturePermission.granted else { return false }
            return self.settings().enhance.showThumbnails
        }
        switcher.offscreenAllowed = { [weak self] in
            self?.settings().enhance.includeOffscreenWindows ?? false
        }
        switcher.agentMarks = { [weak self] in self?.agentMarks() ?? [] }
        enhance.agentMarks = { [weak self] in self?.agentMarks() ?? [] }
        enhance.answerAsk = { [weak self] ask, approve in
            await Self.answer(ask, approve: approve, send: self?.sendAnswer)
        }
        // Provider watch: a counterpart launching or quitting flips
        // the card's note live while ours is parked under it.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            providerObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.workspaceVersion += 1
                    let current = self.settings()
                    if current.provider != .jrbar || current.switcherProvider != .jrbar {
                        self.applySettings()
                    }
                }
            })
        }
    }

    /// Turn the card on. No-op unless the card is on. Apple's Dock is
    /// the stage, so any hide of ours still in place is undone first;
    /// then the watcher and the switcher each start if their own half
    /// of the settings wants them.
    func start() {
        guard !running else { return }
        guard settings().enabled else { return }
        running = true
        appleDock.restore()
        reconcile()
    }

    func stop() {
        guard running else { return }
        enhance.stop()
        switcher.stop()
        running = false
    }

    /// The caller's "settings changed" nudge: start on enable, stop on
    /// disable, and otherwise re-seat the two halves — a provider pick
    /// or the hover-previews switch parks one without the other.
    func applySettings() {
        migrateLegacyEnhanceDefaults()
        // A preview hold the last life never released left `autohide`
        // off in `com.apple.dock` — hand it back before anything else.
        enhance.autohideHold.recoverIfNeeded()
        // A previous life's Replace bar may have left Apple's Dock
        // hidden under our saved values — hand them back regardless of
        // whether the watcher is running.
        appleDock.restore()
        let current = settings()
        if current.enabled, !running {
            start()
        } else if !current.enabled, running {
            stop()
        } else if running {
            reconcile()
        }
    }

    /// Which halves run for these settings: the hover watcher when
    /// JR-Bar renders the previews, and the key tap whenever either
    /// the watcher (its preview keys ride the tap) or our own chords
    /// want it.
    static func halves(for settings: DockSettings) -> (watcher: Bool, tap: Bool) {
        (settings.previewsWanted, settings.previewsWanted || settings.switcherWanted)
    }

    private func reconcile() {
        let wanted = Self.halves(for: settings())
        if wanted.watcher { enhance.start() } else { enhance.stop() }
        if wanted.tap { switcher.start() } else { switcher.stop() }
        // The tap can't read main-actor settings mid-callback; mirror
        // the chord switches into it on every apply.
        switcher.syncSettings()
    }

    /// True once the pre-schema `UserDefaults` knobs have been folded
    /// into `DockSettings.enhance` — the write itself persists through
    /// the store, so a second pass only ever finds removed keys.
    private var migratedEnhanceDefaults = false

    /// Builds before `DockSettings.enhance` wrote two `UserDefaults`
    /// keys — a contract violation (`app-state.json` owns persisted
    /// state). Fold whichever exist into the settings once, then drop
    /// the keys; an unset key means "no value to carry".
    private func migrateLegacyEnhanceDefaults() {
        guard !migratedEnhanceDefaults else { return }
        migratedEnhanceDefaults = true
        let defaults = UserDefaults.standard
        let delay = defaults.object(forKey: DockEnhancePreferences.legacyDelayKey) as? Double
        let thumbnails = defaults.object(forKey: DockEnhancePreferences.legacyThumbnailsKey) as? Bool
        guard delay != nil || thumbnails != nil else { return }
        update { draft in
            if let delay { draft.enhance.previewDelay = delay }
            if let thumbnails { draft.enhance.showThumbnails = thumbnails }
        }
        defaults.removeObject(forKey: DockEnhancePreferences.legacyDelayKey)
        defaults.removeObject(forKey: DockEnhancePreferences.legacyThumbnailsKey)
    }

    /// The card's "Open Settings" for the Accessibility row.
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The card's "Open Settings" for the Screen Recording row.
    func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Card writes

    /// A card edit: mutate a copy of the persisted settings and hand it
    /// to the store, whose `state` write persists and re-applies.
    func update(_ mutate: (inout DockSettings) -> Void) {
        var draft = settings()
        mutate(&draft)
        onSettingsChange?(draft)
    }

    /// A binding into the persisted settings; the store's `didSet`
    /// debounces the write, so a dragged slider doesn't stream saves.
    func bind<T>(_ keyPath: WritableKeyPath<DockSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings()[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } })
    }
}

/// The switchers the Dock card can hand ⌥⇥ to, or warn about when ours
/// shares the chord with them.
extension ExternalProviders {
    /// Free (GPL-3): lwouis' AltTab.
    static let altTab = ExternalAppProbe(
        bundleIDs: ["com.lwouis.alt-tab-macos"],
        appNames: ["AltTab.app"])
    /// Paid: Many Tricks' Witch.
    static let witch = ExternalAppProbe(
        bundleIDs: ["com.manytricks.Witch"],
        appNames: ["Witch.app"])
    /// Paid: Contexts.
    static let contexts = ExternalAppProbe(
        bundleIDs: ["com.contextsformac.Contexts"],
        appNames: ["Contexts.app"])
}
