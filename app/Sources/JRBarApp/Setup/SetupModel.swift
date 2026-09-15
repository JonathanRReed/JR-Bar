import AppKit
import ApplicationServices
import EventKit
import JRBarCore
import JRBarUI
import UserNotifications

/// One row on the Agents step: the same facts the Settings › Agents row
/// reads (`health.detected`, `health.hooks`), flattened so the step and
/// the tests never touch a `CoreState`.
struct SetupAgent: Identifiable, Equatable, Sendable {
    /// The provider id, e.g. `"claude"`.
    var id: String
    var name: String
    /// The agent's CLI was found on this Mac (`health.detected`); nil
    /// when the daemon does not say.
    var detected: Bool?
    /// `health.hooks` word — `"ok"`, `"missing"`, `"stale"`; nil when the
    /// daemon reports no hook state at all.
    var hookStatus: String?

    /// The Settings › Agents row's words, shared so the walkthrough and
    /// the page can never disagree.
    func statusWord(monitorLive: Bool) -> String {
        switch hookStatus {
        case "ok": return "Live"
        case "missing": return "Not installed"
        case "stale": return "Quiet"
        case nil: return monitorLive ? "Unknown" : "Monitor offline"
        case let other?: return other.capitalized
        }
    }
}

/// The reply's own words under a row — the setup page's form of the
/// Settings page's `HookNote`.
struct SetupNote: Equatable, Sendable {
    var text: String
    var isError: Bool

    init(_ text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }
}

/// The five permission rows, in the order the step shows them. Each
/// names the existing code path that grants or checks it — the step is
/// a hub over flows that already exist, never a new request path.
enum SetupPermission: String, CaseIterable, Sendable, Identifiable {
    case notifications
    case calendar
    case screenRecording
    case accessibility
    case fullDiskAccess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notifications: return "Notifications"
        case .calendar: return "Calendar"
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .fullDiskAccess: return "Full Disk Access"
        }
    }

    /// One sentence in user terms: what the grant buys.
    var enables: String {
        switch self {
        case .notifications:
            return "A banner when a session finishes or needs you — the ask can even carry Approve and Deny."
        case .calendar:
            return "The next meeting on the notch card, with a Join button."
        case .screenRecording:
            return "Lets Fold see the desktop to fold it; nothing is uploaded."
        case .accessibility:
            return "Answering asks straight into the session's terminal, and following Alcove's capsule."
        case .fullDiskAccess:
            return "Focus sync — the monitor reads the active Focus so the lights quiet down in Do Not Disturb."
        }
    }

    var symbol: String {
        switch self {
        case .notifications: return "bell.badge.fill"
        case .calendar: return "calendar"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility: return "accessibility"
        case .fullDiskAccess: return "internaldrive.fill"
        }
    }

    /// macOS offers a real prompt for these; the rest are grant-by-pane
    /// only, so their button is "Open Settings…" from the start.
    var canPrompt: Bool {
        switch self {
        case .notifications, .calendar, .screenRecording: return true
        case .accessibility, .fullDiskAccess: return false
        }
    }

    /// What the row's button says and whether it opens a System Settings
    /// pane rather than a prompt — nil when there is nothing to press.
    /// Denied always deep-links: a second prompt is never offered.
    func action(for status: SetupPermissionStatus) -> (title: String, opensSettings: Bool)? {
        switch status {
        case .granted, .unavailable:
            return nil
        case .denied:
            return ("Open Settings…", true)
        case .needed, .unknown:
            return canPrompt ? ("Grant…", false) : ("Open Settings…", true)
        }
    }
}

/// A row's live answer to "does JR-Bar have it".
enum SetupPermissionStatus: String, Equatable, Sendable {
    /// Green dot.
    case granted
    /// Amber dot — the Grant/Open Settings button applies.
    case needed
    /// Amber dot — refused once; the only way back is the pane.
    case denied
    /// Grey dot — nothing this build can ask for (e.g. notifications on
    /// an unbundled `swift run`, which has no notification centre).
    case unavailable
    /// Grey dot — not probed yet.
    case unknown

    var word: String {
        switch self {
        case .granted: return "Granted"
        case .needed: return "Needed"
        case .denied: return "Denied"
        case .unavailable: return "Not available"
        case .unknown: return "Unknown"
        }
    }
}

/// What the menu-bar style rows preview — the same four facts
/// `MenuBarStylePicker` computes from the core.
struct SetupIconPreview: Equatable, Sendable {
    var meters: [StatusMeter] = []
    var overflow: Int = 0
    var sessions: [SessionDot] = []
    var label: String? = nil
}

/// The walkthrough's world as closures, injectable so tests never touch
/// TCC, EventKit, UserNotifications or a socket. `live(core:)` builds
/// the real one on the same code paths the Settings pages use; the
/// defaults render a safe placeholder before the delegate wires anything.
@MainActor
struct SetupModel {
    /// Whether the daemon is connected with a state frame.
    var monitorLive: () -> Bool = { false }
    /// The Agents step's rows — `health.detected` / `health.hooks` flattened.
    var agents: () -> [SetupAgent] = { [] }
    /// `install_hooks` awaited for one provider; the reply's own words
    /// become the row note, the same reading `SettingsStore.runHook` gives.
    var installHooks: (String) async -> SetupNote = { _ in SetupNote("Monitor offline", isError: true) }
    /// Re-probes every row: EventKit, the notification centre,
    /// `CGPreflightScreenCaptureAccess`, `AXIsProcessTrusted`, the FDA probe.
    var refreshPermissions: () async -> [SetupPermission: SetupPermissionStatus] = { [:] }
    /// The row's button: the real request where one exists, the
    /// system-settings deep link otherwise.
    var act: (SetupPermission) async -> Void = { _ in }
    /// The Screen Bar's visibility, read and written through the
    /// delegate's `setScreenBar` (app-state + daemon, kept in step there).
    var screenBarShown: () -> Bool = { true }
    var setScreenBar: (Bool) -> Void = { _ in }
    /// `menu_bar_icon_style`, read and written through the Settings
    /// store's path (app-state + daemon write-through).
    var iconStyle: () -> String = { StatusIconStyle.agents.rawValue }
    var setIconStyle: (String) -> Void = { _ in }
    /// What the style rows preview — live providers when the core has
    /// them, the shared sample otherwise.
    var iconPreview: () -> SetupIconPreview = {
        SetupIconPreview(meters: StatusItemController.sampleMeters,
                         sessions: StatusItemController.sampleSessionDots)
    }
}

extension SetupModel {
    /// The Accessibility pane — the same deep link the panel's
    /// refused-ask toast offers (`PanelStore.answerRefused`).
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    /// The Notifications pane — the same deep link Settings ›
    /// Notifications & Focus shows when banners are denied.
    static let notificationsSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
    /// Calendars privacy, for a denied calendar row.
    static let calendarSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
    /// Full Disk Access — the pane the legacy setup window's FDA row
    /// opened for `focus_sync` (`openFullDiskAccessSettings:`).
    static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// The real closures, built on the daemon's model. Nothing here
    /// invents a request path: hook installs go through
    /// `installHooksNow` with `runHook`'s reply reading, notifications
    /// and calendar ask through the same system APIs the existing flows
    /// use, and Screen Recording reuses `FoldCapturePermission` outright.
    static func live(core: CoreModel) -> SetupModel {
        var model = SetupModel()
        model.monitorLive = { [weak core] in core?.isLive ?? false }
        model.agents = { [weak core] in
            guard let core else { return [] }
            let document = SettingsDocument(core.settings?.document ?? .object([:]))
            return SettingsKey.providers.map { provider in
                SetupAgent(
                    id: provider,
                    name: ProviderStyle.style(for: provider, document: document).name,
                    detected: core.state?.health?["detected"]?[provider]?.boolValue,
                    hookStatus: core.state?.health?["hooks"]?[provider]?.stringValue)
            }
        }
        model.installHooks = { [weak core] provider in
            await Self.installHooks(provider, on: core)
        }
        model.refreshPermissions = { await Self.probePermissions() }
        model.act = { permission in await Self.act(on: permission) }
        model.iconPreview = { [weak core] in Self.iconPreview(core: core) }
        return model
    }

    /// `install_hooks` awaited, read exactly the way
    /// `SettingsStore.runHook` reads it: a refused reply is the error
    /// line, `results[provider].ok == false` carries the per-provider
    /// failure, a `warning` shows instead of a bare success.
    static func installHooks(_ provider: String, on core: CoreModel?) async -> SetupNote {
        guard let core, core.isLive else { return SetupNote("Monitor offline", isError: true) }
        do {
            let reply = try await core.installHooksNow(providers: [provider])
            if !reply.ok {
                return SetupNote(reply.error?.message ?? reply.error?.code ?? "refused", isError: true)
            }
            let result = reply.result?["results"]?[provider]
            if result?["ok"]?.boolValue == false {
                return SetupNote(result?["error"]?.stringValue ?? "failed", isError: true)
            }
            if let warning = result?["warning"]?.stringValue, !warning.isEmpty {
                return SetupNote(warning, isError: true)
            }
            return SetupNote("Hooks installed", isError: false)
        } catch {
            return SetupNote(String(describing: error), isError: true)
        }
    }

    // MARK: Permission probes — each is the check the owning feature runs

    static func probePermissions() async -> [SetupPermission: SetupPermissionStatus] {
        var statuses: [SetupPermission: SetupPermissionStatus] = [
            // FoldCapturePermission's own preflight — it never prompts.
            // The probe asks live (`granted` is the 30 s cache meant
            // for the per-frame path), which also refreshes that cache.
            .screenRecording: FoldCapturePermission.recheck() ? .granted : .needed,
            // The check AlcoveFollower runs before reading Alcove's frames.
            .accessibility: AXIsProcessTrusted() ? .granted : .needed,
            .fullDiskAccess: probeFullDiskAccess() ? .granted : .needed,
        ]
        statuses[.calendar] = calendarStatus()
        statuses[.notifications] = await notificationStatus()
        return statuses
    }

    /// `EKEventStore.authorizationStatus(for: .event)` — the same status
    /// read `ShelfCalendarModel.authorizeAndLoad` switches on.
    static func calendarStatus() -> SetupPermissionStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .denied: return .denied
        case .restricted: return .unavailable
        case .notDetermined, .writeOnly: return .needed
        @unknown default: return .unknown
        }
    }

    /// The notification centre's answer, with NotificationBridge's rule
    /// for unbundled runs: no bundle identifier means no centre at all.
    static func notificationStatus() async -> SetupPermissionStatus {
        guard Bundle.main.bundleIdentifier != nil else { return .unavailable }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .needed
        @unknown default: return .unknown
        }
    }

    /// The same fact `focus_sync` needs: readability of the Focus
    /// daemon's assertions file, TCC-protected under Full Disk Access.
    /// The legacy setup window ran `focus_sync.configured_focus_modes()`
    /// and caught the refusal; here the probe is a plain read of the
    /// file the daemon's `is_focus_active` reads. It answers for this
    /// process — in the packaged build the helper shares the app's grant,
    /// while a dev `swift run` can misreport, so the row's copy names
    /// the monitor, not the app.
    static func probeFullDiskAccess() -> Bool {
        let path = NSString("~/Library/DoNotDisturb/DB/Assertions.json").expandingTildeInPath
        return (try? Data(contentsOf: URL(fileURLWithPath: path))) != nil
    }

    // MARK: Permission requests — the flows that already exist

    /// The row button: the real prompt where macOS offers one, the
    /// system-settings pane otherwise — and the pane for anything the
    /// user already denied, which never prompts twice.
    static func act(on permission: SetupPermission) async {
        switch permission {
        case .notifications: await requestNotifications()
        case .calendar: await requestCalendar()
        case .screenRecording: requestScreenRecording()
        case .accessibility: NSWorkspace.shared.open(accessibilitySettingsURL)
        case .fullDiskAccess: NSWorkspace.shared.open(fullDiskAccessSettingsURL)
        }
    }

    /// NotificationBridge asks with `.alert/.sound/.badge` the first
    /// time a banner is due; the walkthrough asks with the same options
    /// up front instead, and deep-links to the Notifications pane once
    /// denied — the same link Settings › Notifications & Focus shows.
    static func requestNotifications() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        switch await notificationStatus() {
        case .needed:
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        case .denied:
            NSWorkspace.shared.open(notificationsSettingsURL)
        default:
            break
        }
    }

    /// `requestFullAccessToEvents`, the call `ShelfCalendarModel` makes
    /// from its calendar button; a denied row deep-links instead.
    static func requestCalendar() async {
        switch calendarStatus() {
        case .needed:
            let store = EKEventStore()
            _ = try? await store.requestFullAccessToEvents()
        case .denied, .unavailable:
            NSWorkspace.shared.open(calendarSettingsURL)
        default:
            break
        }
    }

    /// `FoldCapturePermission.request()` — the Fold card's own path.
    /// Request may prompt; when it answers without granting (declined,
    /// or an already-denied entry that no longer prompts) the pane that
    /// owns the toggle opens instead.
    static func requestScreenRecording() {
        guard !FoldCapturePermission.granted else { return }
        if !FoldCapturePermission.request() {
            NSWorkspace.shared.open(FoldCapturePermission.settingsURL)
        }
    }

    // MARK: Menu-bar icon preview — `MenuBarStylePicker`'s own facts

    /// The meters, dots, overflow and label the picker's rows draw, from
    /// the live core when it has any and the shared samples otherwise —
    /// the same derivation `MenuBarStylePicker` runs, kept here so the
    /// setup step previews the reader's own menu bar too.
    static func iconPreview(core: CoreModel?) -> SetupIconPreview {
        guard let core else {
            return SetupIconPreview(meters: StatusItemController.sampleMeters,
                                    sessions: StatusItemController.sampleSessionDots,
                                    label: StatusIconRenderer.label(active: 2, needsYou: 1, ready: 0))
        }
        let document = SettingsDocument(core.settings?.document ?? .object([:]))
        let preferred = document.strings("usage_graph_providers") ?? []
        let shown = AppDelegate.meteredProviders(preferred: preferred, usage: core.isLive ? core.usage : [])
        let meters: [StatusMeter] = shown.isEmpty ? StatusItemController.sampleMeters
            : shown.prefix(StatusIconRenderer.maxMeters).map { provider in
                StatusItemController.meter(
                    for: provider.id,
                    fraction: UsageCenterStore.primaryWindow(of: provider).flatMap { $0.usedPct }.map { $0 / 100 },
                    approximate: provider.isDerived,
                    document: document)
            }
        let live = core.isLive ? core.sessions : []
        let sessions: [SessionDot] = live.isEmpty ? StatusItemController.sampleSessionDots
            : live.sorted { rank($0) < rank($1) }.map { session in
                let activity = SessionActivity.reduce(session)
                let state: StatusDotState = session.ask != nil || activity == .waiting ? .ask
                    : activity == .failed ? .error
                    : activity == .working ? .working
                    : activity == .done ? .done : .idle
                return SessionDot(id: session.id, state: state,
                                  accentHex: activity == .working
                                    ? ProviderStyle.style(for: session.provider, document: document).accentHex : nil)
            }
        let label: String?
        if core.isLive, let aggregate = core.state?.aggregate {
            label = StatusIconRenderer.label(active: aggregate.active, needsYou: aggregate.needsYou,
                                             ready: aggregate.ready) ?? "quiet"
        } else {
            label = StatusIconRenderer.label(active: 2, needsYou: 1, ready: 0)
        }
        return SetupIconPreview(meters: meters, overflow: max(0, shown.count - StatusIconRenderer.maxMeters),
                                sessions: sessions, label: label)
    }

    /// Asks lead, then failures, work and done — the panel's order, the
    /// same ranking `MenuBarStylePicker` uses.
    private static func rank(_ session: CoreSession) -> Int {
        if session.ask != nil { return 0 }
        switch SessionActivity.reduce(session) {
        case .waiting: return 1
        case .failed: return 2
        case .working: return 3
        case .done: return 4
        case .ended: return 5
        case .idle: return 6
        }
    }
}
