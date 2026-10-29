import AppKit
import ApplicationServices
import AVFoundation
import CoreBluetooth
import CoreLocation
import EventKit
import Intents
import JRBarCore
import JRBarUI
import UserNotifications

/// One row on the Agents step: the same facts the Settings › Agents & Usage row
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

    /// The Settings › Agents & Usage row's words, shared so the walkthrough and
    /// the page can never disagree.
    func statusWord(monitorLive: Bool) -> String {
        monitorLive ? HookStatus(hookStatus).word : MonitorWords.label
    }
}

/// One provider's usage question on the Agents step: "Show Claude usage?"
/// with the daemon's own sentence under it (`list_providers` →
/// `usage_consent`), so Setup, Settings and the Usage Center say one thing.
struct SetupUsageOffer: Identifiable, Equatable, Sendable {
    /// The provider id, e.g. `"claude"`.
    var id: String
    var name: String
    /// "Show Claude usage?"
    var question: String
    /// "JR-Bar will ask Anthropic for your usage with the sign-in Claude
    /// Code already has. Nothing else is sent."
    var summary: String
    /// Whether the person has already said yes (an earlier run, the
    /// Settings switch, or an upgrade that kept a working provider).
    var isOn: Bool
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

/// The permission rows, in the order the step shows them. Each names
/// the existing code path that grants or checks it — the step is a hub
/// over flows that already exist, never a new request path.
enum SetupPermission: String, CaseIterable, Sendable, Identifiable {
    case notifications
    case calendar
    case reminders
    case camera
    case screenRecording
    case audioCapture
    case bluetooth
    case accessibility
    case automation
    case location
    case fullDiskAccess
    case focusStatus
    case lidHelper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notifications: return "Notifications"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .camera: return "Camera"
        case .screenRecording: return "Screen Recording"
        case .audioCapture: return "System Audio"
        case .bluetooth: return "Bluetooth"
        case .accessibility: return "Accessibility"
        case .automation: return "Automation"
        case .location: return "Location"
        case .fullDiskAccess: return "Full Disk Access"
        case .focusStatus: return "Focus Status"
        case .lidHelper: return "Closed-lid helper"
        }
    }

    /// One sentence in user terms: what the grant buys.
    var enables: String {
        switch self {
        case .notifications:
            return "A banner when a session finishes or needs you — the ask can even carry Approve and Deny."
        case .calendar:
            return "The next meeting on the notch card, with a Join button."
        case .reminders:
            return "The shelf's reminder list — checking one off writes back to Reminders."
        case .camera:
            return "The notch card's Mirror row — the Mac's own camera, live only while the row is on."
        case .screenRecording:
            return "Lets Fold see the desktop to fold it; nothing is uploaded."
        case .audioCapture:
            return "The media row's live visualizer — it taps the playing app's output, keeps nothing."
        case .bluetooth:
            return "The notch's connect announcements — \"AirPods connected\"."
        case .accessibility:
            return "Answering asks straight into the session's terminal, and following Alcove's capsule."
        case .automation:
            return "The Dark chip, and the Dock chip's fallback — JR-Bar asks System Events to switch the appearance or the Dock's auto-hide."
        case .location:
            return "Wi-Fi rules in the Menu Bar utility — macOS only tells apps a network's name with Location on. Nothing reads where you are."
        case .fullDiskAccess:
            return "Names of active Focus modes for individual dimming, alert and calibration rules. JR-Bar's background helper needs access too."
        case .focusStatus:
            return "Whether Focus is on, for React to Focus modes, Menu Bar rules and the status item's moon. Mode names use Full Disk Access."
        case .lidHelper:
            return "Agents keep running with the lid shut (Utilities & Toys › Keep Awake). Copy the command, paste it in Terminal; it asks for your password once."
        }
    }

    var symbol: String {
        switch self {
        case .notifications: return "bell.badge.fill"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .camera: return "camera.fill"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .audioCapture: return "waveform"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        case .accessibility: return "accessibility"
        case .automation: return "gearshape.2.fill"
        case .location: return "location.fill"
        case .fullDiskAccess: return "internaldrive.fill"
        case .focusStatus: return "moon.fill"
        case .lidHelper: return "laptopcomputer"
        }
    }

    /// macOS offers a real prompt for these; the rest are grant-by-pane
    /// only (or have no public request at all — audio capture is asked
    /// by the tap's first start), so their button is "Open Settings…"
    /// from the start.
    var canPrompt: Bool {
        switch self {
        case .notifications, .calendar, .reminders, .camera, .screenRecording,
             .focusStatus, .automation, .location, .bluetooth:
            return true
        case .accessibility, .fullDiskAccess, .audioCapture, .lidHelper:
            return false
        }
    }

    /// What the row's button says and whether it opens a System Settings
    /// pane rather than a prompt — nil when there is nothing to press.
    /// Denied always deep-links: a second prompt is never offered. The
    /// closed-lid helper is no TCC grant at all — a sudoers rule only
    /// Terminal can install — so its button copies the command.
    func action(for status: SetupPermissionStatus) -> (title: String, opensSettings: Bool)? {
        if self == .lidHelper {
            return status == .needed ? ("Copy Command", false) : nil
        }
        switch status {
        case .granted, .unavailable:
            return nil
        case .writeOnly:
            return ("Allow Full Access…", true)
        case .denied, .restricted:
            return ("Open Settings…", true)
        case .unknown where self != .automation:
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
    case restricted
    case writeOnly
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
        case .restricted: return "Restricted"
        case .writeOnly: return "Full access needed"
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
    var connectedLights: () -> [String] = { [] }
    /// The Agents step's rows — `health.detected` / `health.hooks` flattened.
    var agents: () -> [SetupAgent] = { [] }
    /// The usage questions for the providers found on this Mac, one each,
    /// with the daemon's words. Asked when the Agents step opens.
    var usageOffers: () async throws -> [SetupUsageOffer] = { [] }
    /// The person's answer for one provider: `true` is "Turn on", `false`
    /// withdraws it. Never called for "Not now", which asks nothing.
    var setUsage: (String, Bool) async -> SetupNote = { _, _ in SetupNote(MonitorWords.label, isError: true) }
    /// `install_hooks` awaited for one provider; the reply's own words
    /// become the row note, the same reading `SettingsStore.runHook` gives.
    var installHooks: (String) async -> SetupNote = { _ in SetupNote(MonitorWords.label, isError: true) }
    /// Re-probes every row: EventKit (events + reminders), the
    /// notification centre, `CGPreflightScreenCaptureAccess`,
    /// `AVCaptureDevice`, `CBManager.authorization`, `AXIsProcessTrusted`,
    /// `INFocusStatusCenter`, the FDA probe. Audio capture has no public
    /// status read — its row stays "Unknown" with a pane link.
    var refreshPermissions: () async -> [SetupPermission: SetupPermissionStatus] = { [:] }
    var permissionPlan: () -> SetupPermissionPlan = { SetupPermissionPlan(active: []) }
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
    /// Alerts & Sounds shows when banners are denied.
    static let notificationsSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
    /// Calendars privacy, for a denied calendar row.
    static let calendarSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
    /// Reminders privacy, for a denied reminders row.
    static let remindersSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!
    /// Camera privacy — the same deep link the notch card's Mirror row
    /// offers when the owner has said no (`NotchCardView`).
    static let cameraSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
    /// Bluetooth privacy, for the notch's connect announcements.
    static let bluetoothSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!
    /// macOS 15+ folds the audio-capture consent into the "Screen &
    /// System Audio Recording" pane — the same anchor Screen Recording
    /// uses (`FoldCapturePermission.settingsURL`).
    static let audioCaptureSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    /// The Focus privacy pane — `INFocusStatusCenter`'s own TCC service,
    /// a grant apart from Full Disk Access.
    static let focusSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Focus")!
    /// Full Disk Access — the pane where the person grants the read that
    /// `focus_sync` needs for the Focus assertions file.
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
        model.connectedLights = { [weak core] in
            (core?.devices ?? []).filter { $0.connected == true }.map { $0.name ?? $0.kind }
        }
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
        model.usageOffers = { [weak core] in try await Self.usageOffers(on: core) }
        model.setUsage = { [weak core] provider, on in await Self.setUsage(provider, on: on, core: core) }
        model.refreshPermissions = { [weak core] in
            var statuses = await Self.probePermissions()
            // The daemon owns the helper's install state (`power.closed_lid`).
            statuses[.lidHelper] = Self.lidHelperStatus(
                helperInstalled: core?.isLive == true ? core?.state?.power?.closedLid?.helperInstalled : nil)
            return statuses
        }
        model.act = { permission in await Self.act(on: permission) }
        model.iconPreview = { [weak core] in Self.iconPreview(core: core) }
        return model
    }

    /// One question per provider the daemon found on this Mac and has a
    /// usage switch for. A provider the daemon does not say it found gets
    /// no question here; Settings › Agents & Usage lists every provider.
    static func usageOffers(on core: CoreModel?) async throws -> [SetupUsageOffer] {
        guard let core, core.isLive else { return [] }
        let rows = try await core.listProviders()
        let detected = core.state?.health?["detected"]
        return rows.compactMap { row in
            guard row.instance == "default", let consent = row.usageConsent,
                  detected?[row.id]?.boolValue == true else { return nil }
            return SetupUsageOffer(
                id: row.id,
                name: ProviderStyle.style(for: row.id).name,
                question: consent.question,
                summary: consent.summary,
                isOn: consent.granted)
        }
    }

    /// `set_provider_usage_consent` with source `setup`, read the way
    /// `installHooks` reads its reply: the daemon's words on a refusal.
    static func setUsage(_ provider: String, on: Bool, core: CoreModel?) async -> SetupNote {
        guard let core, core.isLive else { return SetupNote(MonitorWords.label, isError: true) }
        do {
            try await core.setProviderUsageConsent(provider, enabled: on, source: "setup")
            return SetupNote(on ? "Usage on" : "Usage off", isError: false)
        } catch let error as CoreReplyError {
            return SetupNote(error.sentence, isError: true)
        } catch {
            return SetupNote(MonitorWords.reason(error), isError: true)
        }
    }

    /// `install_hooks` awaited, read exactly the way
    /// `SettingsStore.runHook` reads it: a refused reply is the error
    /// line, `results[provider].ok == false` carries the per-provider
    /// failure, a `warning` shows instead of a bare success.
    static func installHooks(_ provider: String, on core: CoreModel?) async -> SetupNote {
        guard let core, core.isLive else { return SetupNote(MonitorWords.label, isError: true) }
        do {
            let reply = try await core.installHooksNow(providers: [provider])
            if !reply.ok {
                return SetupNote(reply.error?.sentence ?? "The monitor refused that.", isError: true)
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
            return SetupNote(MonitorWords.reason(error), isError: true)
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
            .fullDiskAccess: .unknown,
            // The app's own Focus grant — MenuBarTriggers' rules and
            // the combined status item's moon read `INFocusStatusCenter`.
            .focusStatus: focusStatus(),
            // The announce watcher's IOBluetooth registration is what
            // prompts; `CBManager.authorization` reads TCC without it.
            .bluetooth: bluetoothStatus(),
            // No public preflight for the process tap's consent —
            // the row is honest about not knowing.
            .audioCapture: .unknown,
        ]
        statuses[.calendar] = calendarStatus()
        statuses[.reminders] = reminderStatus()
        statuses[.camera] = cameraStatus()
        statuses[.notifications] = await notificationStatus()
        // Asked without prompting — the same read the Dark chip makes
        // before it flips.
        statuses[.automation] = automationStatus(
            await Task.detached { AutomationPermission.systemEvents(ask: false) }.value)
        statuses[.location] = locationStatus(locationManager.authorizationStatus,
                                             servicesEnabled: CLLocationManager.locationServicesEnabled())
        return statuses
    }

    /// The System Events grant as a row. Unavailable (System Events not
    /// running, so macOS cannot say) reads Unknown with a Grant button —
    /// the grant path launches it first.
    static func automationStatus(_ permission: AutomationPermission) -> SetupPermissionStatus {
        switch permission {
        case .granted: return .granted
        case .needsConsent: return .needed
        case .denied: return .denied
        case .unavailable: return .unknown
        }
    }

    /// `CLLocationManager.authorizationStatus`: either "authorized" is a
    /// grant; Location Services off for the whole Mac reads as denied,
    /// since only the pane can change it.
    static func locationStatus(_ status: CLAuthorizationStatus, servicesEnabled: Bool) -> SetupPermissionStatus {
        guard servicesEnabled else { return .denied }
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .needed
        @unknown default: return .unknown
        }
    }

    /// The helper's row from the daemon's `power.closed_lid.helper_installed`;
    /// Unknown while the monitor is not connected.
    static func lidHelperStatus(helperInstalled: Bool?) -> SetupPermissionStatus {
        switch helperInstalled {
        case true?: return .granted
        case false?: return .needed
        case nil: return .unknown
        }
    }

    /// The one-time install command the row copies. It runs `/bin/sh`
    /// with a fixed script and no program from the app bundle, so the
    /// root-run step never executes a file the person's own account can
    /// replace. The script writes the same two-line sudoers rule as
    /// `lid_sleep.sleep_helper_sudoers_rule`, which names `/usr/bin/pmset`
    /// only. `sudo` because the helper is a sudoers rule; nothing else in
    /// JR-Bar ever asks for a password.
    static func lidHelperCommand() -> String {
        "sudo /bin/sh -c '\(lidHelperScript())'"
    }

    /// The script `lidHelperCommand` hands to `sh`. It takes the user from
    /// `$SUDO_USER` (letters, digits, `.`, `_` and `-` only), checks the
    /// rule with `visudo -cf` while it still has a dotted temporary name
    /// that sudo ignores, and only then moves it into place at mode 0440.
    /// The directory and `visudo` are parameters so a test can run it
    /// without root; the defaults are the real ones.
    static func lidHelperScript(sudoersDirectory: String = "/etc/sudoers.d",
                                visudo: String = "/usr/sbin/visudo") -> String {
        let rule = #"%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"#
        let target = "\(sudoersDirectory)/jrbar-disablesleep"
        let steps = [
            #"case "$SUDO_USER" in ""|*[!A-Za-z0-9._-]*) echo "run this with sudo from your own account" >&2; exit 1;; esac"#,
            "f=$(/usr/bin/mktemp \(sudoersDirectory)/.jrbar-XXXXXX) || exit 1",
            #"printf "\#(rule)" "$SUDO_USER" > "$f""#,
            #"/bin/chmod 440 "$f""#,
            #"if \#(visudo) -cf "$f" >/dev/null; then /bin/mv "$f" \#(target) && echo "closed-lid helper installed"; "#
                + #"else /bin/rm -f "$f"; echo "visudo refused the rule" >&2; exit 1; fi"#,
        ]
        return steps.joined(separator: "; ")
    }

    /// `EKEventStore.authorizationStatus(for: .event)` — the same status
    /// read `ShelfCalendarModel.authorizeAndLoad` switches on.
    static func calendarStatus() -> SetupPermissionStatus {
        eventKitStatus(EKEventStore.authorizationStatus(for: .event))
    }

    static func eventKitStatus(_ status: EKAuthorizationStatus) -> SetupPermissionStatus {
        switch status {
        case .fullAccess: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .needed
        case .writeOnly: return .writeOnly
        @unknown default: return .unknown
        }
    }

    /// `EKEventStore.authorizationStatus(for: .reminder)` — the same
    /// status read `ShelfReminders` switches on.
    static func reminderStatus() -> SetupPermissionStatus {
        eventKitStatus(EKEventStore.authorizationStatus(for: .reminder))
    }

    /// `AVCaptureDevice.authorizationStatus(for: .video)` — the read
    /// `ShelfMirrorModel` runs before it ever opens the lens.
    static func cameraStatus() -> SetupPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .needed
        @unknown default: return .unknown
        }
    }

    /// `CBCentralManager.authorization` — the class property reads the
    /// Bluetooth TCC state without standing a central up, so the probe
    /// can never prompt. The explicit button creates a central without
    /// scanning; announcements register only when their setting is on.
    static func bluetoothStatus() -> SetupPermissionStatus {
        switch CBCentralManager.authorization {
        case .allowedAlways: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .needed
        @unknown default: return .unknown
        }
    }

    /// `INFocusStatusCenter.default.authorizationStatus` — the app's
    /// own Focus grant, which `MenuBarSystemTriggerSource` polls only
    /// once authorized and asks for from its "add rule" path. Entirely
    /// separate from the monitor's Full-Disk-Access read of the Focus
    /// database — one grant never stands in for the other.
    static func focusStatus() -> SetupPermissionStatus {
        switch INFocusStatusCenter.default.authorizationStatus {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .needed
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

    // MARK: Permission requests — the flows that already exist

    /// The row button: the real prompt where macOS offers one, the
    /// system-settings pane otherwise — and the pane for anything the
    /// user already denied, which never prompts twice.
    static func act(on permission: SetupPermission) async {
        switch permission {
        case .notifications: await requestNotifications()
        case .calendar: await requestCalendar()
        case .reminders: await requestReminders()
        case .camera: await requestCamera()
        case .screenRecording: requestScreenRecording()
        case .audioCapture: await requestAudioCapture()
        case .bluetooth: await requestBluetooth()
        case .accessibility:
            // macOS lists an app in the Accessibility pane only once it has
            // asked: opening the pane alone can leave the person looking for
            // a JR-Bar that is not there. The button is the ask.
            accessibilityPrompt()
            openSettingsPane(accessibilitySettingsURL)
        case .automation: await requestAutomation()
        case .location: await requestLocation()
        case .fullDiskAccess: DesktopServices.automatic.open(fullDiskAccessSettingsURL)
        case .focusStatus: await requestFocusStatus()
        case .lidHelper: copyLidHelperCommand()
        }
    }

    /// What registers JR-Bar with Accessibility and shows macOS's own
    /// request. A test replaces it, so nothing is asked from a suite.
    nonisolated(unsafe) static var accessibilityPrompt: () -> Void = {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// How a row opens its System Settings pane.
    static var openSettingsPane: @MainActor (URL) -> Void = { DesktopServices.automatic.open($0) }

    /// Location privacy, for a denied row (and Location Services off).
    static let locationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!

    /// macOS's own "control System Events?" prompt, asked up front rather
    /// than on the Dark chip's first tap. System Events must be running
    /// for macOS to ask, so it is launched first, hidden. A denied grant
    /// only changes in the Automation pane.
    static func requestAutomation() async {
        await PermissionRequest.live(permission: .automation, status: {
            let answer = await Task.detached { AutomationPermission.systemEvents(ask: false) }.value
            return answer == .unavailable ? .needed : automationStatus(answer)
        }, prompt: {
            let systemEvents = URL(fileURLWithPath: "/System/Library/CoreServices/System Events.app")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            _ = try? await DesktopServices.automatic.openApplication(at: systemEvents, configuration: configuration)
            let answer = await Task.detached { AutomationPermission.systemEvents(ask: true) }.value
            if let pane = automationFollowUp(afterAsking: answer) { openSettingsPane(pane) }
        }, settingsURL: AutomationPermission.settingsURL).perform()
    }

    /// The pane to open once the Automation prompt has been answered: a
    /// "Don't Allow" is only undone there, and the prompt never comes twice.
    static func automationFollowUp(afterAsking answer: AutomationPermission) -> URL? {
        answer == .denied ? AutomationPermission.settingsURL : nil
    }

    /// The one location manager the prompt needs alive until it is
    /// answered; nothing ever starts updates on it.
    private static let locationManager = CLLocationManager()

    static func requestLocation() async {
        await PermissionRequest.live(permission: .location, status: {
            locationStatus(locationManager.authorizationStatus,
                           servicesEnabled: CLLocationManager.locationServicesEnabled())
        }, prompt: {
            await locationRequest.request(manager: locationManager)
        }, settingsURL: locationSettingsURL).perform()
    }

    private static let locationRequest = LocationPermissionRequest()

    static func copyLidHelperCommand() {
        let command = lidHelperCommand()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// NotificationBridge asks with `.alert/.sound/.badge` the first
    /// time a banner is due; the walkthrough asks with the same options
    /// up front instead, and deep-links to the Notifications pane once
    /// denied — the same link Settings › Alerts & Sounds shows.
    static func requestNotifications() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        switch await notificationStatus() {
        case .needed:
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        case .denied:
            DesktopServices.automatic.open(notificationsSettingsURL)
        default:
            break
        }
    }

    /// `requestFullAccessToEvents`, the call `ShelfCalendarModel` makes
    /// from its calendar button; a denied row deep-links instead.
    static func requestCalendar(reader: ShelfCalendarReader = .shared) async {
        await PermissionRequest.live(permission: .calendar, status: { calendarStatus() },
                                     prompt: { _ = await reader.requestAccess() },
                                     settingsURL: calendarSettingsURL).perform()
    }

    static func requestReminders(reader: ShelfCalendarReader = .shared) async {
        await PermissionRequest.live(permission: .reminders, status: { reminderStatus() },
                                     prompt: { _ = await reader.requestAccess(to: .reminder) },
                                     settingsURL: remindersSettingsURL).perform()
    }

    @discardableResult
    static func requestCamera() async -> SetupPermissionStatus {
        await PermissionRequest.live(permission: .camera, status: { cameraStatus() },
                                     prompt: { _ = await AVCaptureDevice.requestAccess(for: .video) },
                                     settingsURL: cameraSettingsURL).perform()
    }

    @discardableResult
    static func requestFocusStatus() async -> SetupPermissionStatus {
        await PermissionRequest.live(permission: .focusStatus, status: { focusStatus() }, prompt: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                INFocusStatusCenter.default.requestAuthorization { _ in continuation.resume() }
            }
        }, settingsURL: focusSettingsURL).perform()
    }

    static func requestBluetooth() async {
        await PermissionRequest.live(permission: .bluetooth, status: { bluetoothStatus() }, prompt: {
            await bluetoothRequest.request()
        }, settingsURL: bluetoothSettingsURL).perform()
    }

    private static let bluetoothRequest = BluetoothPermissionRequest()

    /// Core Audio exposes no public consent preflight or standalone request.
    /// The visualizer's first start asks; this button opens the owning pane.
    static func requestAudioCapture() async {
        await PermissionRequest.live(permission: .audioCapture, status: { .unknown },
                                     settingsURL: audioCaptureSettingsURL).perform()
    }

    /// `FoldCapturePermission.request()` — the Fold card's own path.
    /// Request may prompt; when it answers without granting (declined,
    /// or an already-denied entry that no longer prompts) the pane that
    /// owns the toggle opens instead.
    static func requestScreenRecording() {
        guard !FoldCapturePermission.granted else { return }
        if !FoldCapturePermission.request() {
            DesktopServices.automatic.open(FoldCapturePermission.settingsURL)
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
        let now = Date().timeIntervalSince1970
        let meters: [StatusMeter] = shown.isEmpty ? StatusItemController.sampleMeters
            : shown.prefix(StatusIconRenderer.maxMeters).map { provider in
                StatusItemController.previewMeter(for: provider, document: document, now: now)
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
