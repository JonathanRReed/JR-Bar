import JRBarUI
import AppKit
import JRBarCore
import Observation
import SwiftUI

extension NotchToy {
    // MARK: Controls

    /// A binding into `store.state.notch`; the store's `didSet`
    /// debounces the write.
    func bind<T>(_ keyPath: WritableKeyPath<NotchSettings, T>) -> Binding<T> {
        Binding(
            get: { self.store?.state.notch[keyPath: keyPath] ?? NotchSettings()[keyPath: keyPath] },
            set: { self.store?.state.notch[keyPath: keyPath] = $0 })
    }

    var providerBinding: Binding<NotchProvider> {
        Binding(
            get: { self.settings.provider },
            set: { self.setProvider($0) })
    }

    /// The Calendar switch. Turning it on is the explicit ask the card's
    /// old "Show calendar" button made — through Setup's own request
    /// path (a denied Mac deep-links to System Settings instead) — and
    /// a pinned card re-reads on the spot.
    var calendarBinding: Binding<Bool> {
        Binding(
            get: { self.settings.calendar },
            set: { on in
                self.store?.state.notch.calendar = on
                let calendar = self.cardModel.calendar
                let card = self.cardModel
                Task { @MainActor in
                    if on { await SetupModel.requestCalendar() }
                    calendar.sync(enabled: self.settings.calendar && card.pinned)
                }
            })
    }

    /// The Synced lyrics switch. Turning it on here, beside the words
    /// that name LRCLIB, is the consent as well.
    var lyricsBinding: Binding<Bool> {
        Binding(
            get: { self.settings.lyrics },
            set: { on in
                self.store?.state.notch.lyrics = on
                if on { self.store?.state.notch.lyricsConsented = true }
            })
    }

    /// A card's lyrics follow the switch and its consent — the island's
    /// card and the glass card alike. The card's one-line offer shows
    /// only while the switch is on and the yes is missing.
    func wireLyrics(_ lyrics: LyricsStore) {
        lyrics.enabled = { [weak self] in self?.settings.lyricsAllowed ?? false }
        lyrics.offersConsent = { [weak self] in
            guard let settings = self?.settings else { return false }
            return settings.lyrics && !settings.lyricsConsented
        }
        lyrics.consent = { [weak self] in self?.store?.state.notch.lyricsConsented = true }
    }

    /// The Reminders switch — the same ask-on-enable as `calendarBinding`.
    var remindersBinding: Binding<Bool> {
        Binding(
            get: { self.settings.reminders },
            set: { on in
                self.store?.state.notch.reminders = on
                let reminders = self.cardModel.reminders
                let card = self.cardModel
                Task { @MainActor in
                    if on { await SetupModel.requestReminders() }
                    reminders.sync(enabled: self.settings.reminders && card.pinned)
                }
            })
    }

    /// What the follower sees — the Capsule row under the Alcove provider.
    var capsuleFact: String {
        _ = workspaceVersion
        guard alcoveURL != nil else { return "not installed" }
        guard isAlcoveRunning else { return "Alcove isn't running" }
        if let capsule = store?.alcoveCapsule { return "following: \(Int(capsule.width.rounded())) pt wide" }
        return "running, no capsule seen"
    }

    var controls: AnyView {
        AnyView(NotchControlsView(toy: self))
    }

    /// The lyrics row's subtitle names the third party it asks, and says
    /// so while a switch left on from before still waits for its yes.
    var lyricsSubtitle: String {
        let base = "The current and next line under the track, in time. "
            + "Looks up the song on LRCLIB using its title, artist, album and length, "
            + "and remembers the answer. Off, nothing is sent."
        let settings = settings
        guard settings.lyrics, !settings.lyricsConsented else { return base }
        return base + " Waiting for your yes: the card offers it once under the track."
    }
}

/// The card's disclosure body, in named runs — the island, its
/// capsules, media, glances, the shelf, the sensors — with each switch's
/// dependent rows on an inset panel under it. Every toggle writes
/// `store.state.notch` (which persists itself) except the provider
/// picker, which goes through `setProvider` so the swap can park our
/// island and open theirs.
struct NotchControlsView: View {
    let toy: NotchToy

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NotchRendererPicker(selection: toy.providerBinding, alcoveInstalled: toy.alcoveURL != nil,
                                boringNotchInstalled: toy.boringNotchURL != nil)
            // Another island running beside ours: say so, offer the pick.
            RivalGuardView(role: .notch,
                           active: toy.settings.enabled && toy.settings.provider == .jrbar,
                           handOver: { toy.handOver(to: $0) })

            providerNote
            providerControls
        }
    }

    /// The rows that belong to whoever renders: ours get the island's
    /// knobs, Alcove's keep the capsule-following that already existed,
    /// Boring Notch's get nothing — there is nothing of ours to set.
    @ViewBuilder
    private var providerControls: some View {
        switch toy.settings.provider {
        case .jrbar:
            SettingGroup("Island") { islandRows }
            SettingGroup("Shelf") { shelfRows }
            SettingsFeatureMoreOptions(id: toy.id, subtitle: "Gestures, notices, media, glances, shelf behavior and camera options.") {
                SettingGroup("Gestures and display") { islandOptionsRows }
                SettingGroup("Capsules and timers") { capsuleRows }
                SettingGroup("Media") { mediaRows }
                SettingGroup("Glances") { glanceRows }
                if toy.settings.shelfEnabled {
                    SettingGroup("Shelf behavior") { shelfSubrows }
                }
                SettingGroup("Camera and microphone") { sensorRows }
            }
        case .alcove:
            if let settings = toy.store?.settings {
                SettingsNavigationRow(SettingsHome.followAlcove.linkTitle) { settings.revealHome(.followAlcove) }
            }
            LabeledContent {
                Text(toy.capsuleFact)
                    .jrbarType(.callout)
                    .foregroundStyle(.secondary)
            } label: {
                SettingLabel(title: "Capsule", subtitle: "What the follower sees right now.")
            }
        case .boringNotch:
            EmptyView()
        }
    }

    @ViewBuilder
    private var islandRows: some View {
        Toggle(isOn: toy.bind(\.islandEnabled)) {
            SettingLabel(title: "Show the island",
                         subtitle: toy.earsDrawn
                            ? "Show the housing below the notch. The Screen Bar supplies status on either side."
                            : "Show working agents, asks and the current track below the notch. Hover or click to open the card.")
        }
        Toggle(isOn: toy.bind(\.expandOnHover)) {
            SettingLabel(title: "Card on hover",
                         subtitle: "Rest the pointer on the notch or an ear and the card grows. Off, only a click or a pull opens it.")
        }
        if toy.settings.expandOnHover {
            CardSubrows {
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: toy.bind(\.hoverOpenDelay), in: NotchSettings.hoverOpenDelayRange)
                            .frame(width: 140)
                        ValueText(text: Self.delayText(toy.settings.hoverOpenDelay))
                    }
                } label: {
                    SettingLabel(title: "Open after",
                                 subtitle: "How long the pointer rests on the notch before the card grows. Arriving from the menu bar still waits a third of a second.")
                }
            }
        }
        LabeledContent {
            Picker(selection: toy.bind(\.notchDisplay)) {
                Text("Built-in").tag(NotchDisplay.builtIn)
                Text("Main display").tag(NotchDisplay.main)
                Text("Pointer").tag(NotchDisplay.pointer)
            } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
        } label: {
            SettingLabel(title: "Display",
                         subtitle: "Where the island and the Screen Bar live. Where the pointer is moves them when you change Space or plug in a screen, never as the pointer wanders.")
        }
    }

    @ViewBuilder
    private var islandOptionsRows: some View {
        Toggle(isOn: toy.bind(\.simulateNotch)) {
            SettingLabel(title: "Simulate notch",
                         subtitle: "On a display without a notch, the island hugs the top edge instead of floating as a pill.")
        }
        Toggle(isOn: toy.bind(\.hapticTick)) {
            SettingLabel(title: "Haptic tick",
                         subtitle: "A soft trackpad tap as the island opens, as a swipe turns the card's page and as a swipe or pinch folds it. Only when your hand did it, never when news arrives.")
        }
        Toggle(isOn: toy.bind(\.pullGestures)) {
            SettingLabel(title: "Pull & swipe gestures",
                         subtitle: "Pull down or spread two fingers to open; push up or squeeze to fold. ⌘-drag sideways on the notch sets a timer.")
        }
        Toggle(isOn: toy.bind(\.showUsage)) {
            SettingLabel(title: "Usage meters",
                         subtitle: "Per-provider quota bars inside the card.")
        }
    }

    @ViewBuilder
    private var capsuleRows: some View {
        Toggle(isOn: toy.bind(\.capsuleNotifications)) {
            SettingLabel(title: "Event capsules",
                         subtitle: "The island briefly becomes a notice when an ask opens, a run ends or a quota resets.")
        }
        if toy.settings.capsuleNotifications {
            CardSubrows {
                Toggle(isOn: toy.bind(\.capsuleKinds.ask)) {
                    SettingLabel(title: "Ask capsules", subtitle: "Show a notice when a session asks you a question.")
                }
                Toggle(isOn: toy.bind(\.capsuleKinds.completed)) {
                    SettingLabel(title: "Completion capsules", subtitle: "Show a notice when an agent finishes a run.")
                }
                Toggle(isOn: toy.bind(\.capsuleKinds.failed)) {
                    SettingLabel(title: "Failure capsules", subtitle: "Show a notice when a session stops on an error.")
                }
                Toggle(isOn: toy.bind(\.capsuleKinds.quotaReset)) {
                    SettingLabel(title: "Quota reset capsules", subtitle: "Show a notice when a provider's usage window refills.")
                }
                Toggle(isOn: toy.bind(\.capsuleKinds.charging)) {
                    SettingLabel(title: "Power capsules", subtitle: "Show charger, battery and fully charged notices.")
                }
                Toggle(isOn: toy.bind(\.holdNewsWhileQuiet)) {
                    SettingLabel(title: "Hold news while quiet",
                                 subtitle: "In a Focus or a quiet mode, finished runs and quota resets wait and arrive as one summary when it ends. Asks and failures still show.")
                }
            }
        }
        Toggle(isOn: toy.bind(\.alerts)) {
            SettingLabel(title: "System alerts",
                         subtitle: "Focus changes, Bluetooth devices, Caps Lock and displays, spoken in the island one at a time. Headphones the Screen Bar's ear already names stay quiet here.")
        }
        Toggle(isOn: toy.bind(\.mediaHUD)) {
            SettingLabel(title: "Volume & brightness capsules",
                         subtitle: "The level keys grow one continuous fill out of the notch, naming where the sound goes. The key still does its job; scroll over the capsule to fine-tune.")
        }
        if toy.settings.mediaHUD {
            // A HUD app not already named as a second island above.
            RivalGuardView(role: .hud, active: toy.settings.enabled, rivals: hudOnlyRivals)
            CardSubrows {
                LabeledContent {
                    HStack(spacing: SettingsMetrics.s) {
                        ValueText(text: hudDuration, width: 40)
                        Stepper("Hold for", value: toy.bind(\.hudDuration),
                                in: NotchSettings.hudDurationRange, step: 0.5)
                            .labelsHidden()
                    }
                } label: {
                    SettingLabel(title: "Hold for",
                                 subtitle: "How long a level or a system notice stays at the notch.")
                }
                Toggle(isOn: toy.bind(\.replaceSystemHUD)) {
                    SettingLabel(title: "Replace the system volume & brightness overlay",
                                 subtitle: "Use JR-Bar's overlay for volume and brightness keys. Requires Accessibility. Control Center changes still use Apple's overlay.")
                }
            }
        }
        Toggle(isOn: toy.bind(\.soundEffects)) {
            SettingLabel(title: "Capsule tick",
                         subtitle: "A quiet sound when a capsule shows.")
        }
        Toggle(isOn: toy.bind(\.timerLights)) {
            SettingLabel(title: "Timers flash the lights",
                         subtitle: "Flash a connected SidePulse strip orange when a timer ends. Respects quiet mode.")
        }
    }

    @ViewBuilder
    private var mediaRows: some View {
        Toggle(isOn: toy.bind(\.mediaEnabled)) {
            SettingLabel(title: "Now Playing",
                         subtitle: toy.earsDrawn
                            ? "Show playback controls in the card. The Screen Bar already shows the track beside the notch."
                            : "Show the current track beside the notch and playback controls in the card.")
        }
        if toy.settings.mediaEnabled {
            CardSubrows {
                Toggle(isOn: toy.bind(\.audioVisualizer)) {
                    SettingLabel(title: "Audio visualizer (reacts to what's playing)",
                                 subtitle: "Six live bands from the playing app's own audio. Asks for system-audio access once; off or denied keeps the decorative motion.")
                }
                Toggle(isOn: toy.lyricsBinding) {
                    SettingLabel(title: "Synced lyrics", subtitle: toy.lyricsSubtitle)
                }
            }
        }
    }

    @ViewBuilder
    private var glanceRows: some View {
        Toggle(isOn: toy.calendarBinding) {
            SettingLabel(title: "Calendar",
                         subtitle: Self.accessNote(SetupModel.calendarStatus(), app: "Calendar",
                                                   granted: "The next three events in the card, the first with Join."))
        }
        if toy.settings.calendar {
            CardSubrows {
                Toggle(isOn: toy.bind(\.meetingAlerts)) {
                    SettingLabel(title: "Meeting heads-up",
                                 subtitle: "Two minutes before an event with a join link, the island offers Join (and the Mirror, when it is on); finished runs wait while it runs. Reads the calendar on this Mac only.")
                }
            }
        }
        Toggle(isOn: toy.remindersBinding) {
            SettingLabel(title: "Reminders",
                         subtitle: Self.accessNote(SetupModel.reminderStatus(), app: "Reminders",
                                                   granted: "What's due by tomorrow, with a check-off circle that writes back."))
        }
    }

    /// The HUD apps running that are not also notch apps — those have
    /// their own note under the picker already.
    private var hudOnlyRivals: [UtilityRivals.Rival] {
        _ = UtilityRivalsWatch.shared.version
        return UtilityRivals.running(for: .hud).filter { !$0.roles.contains(.notch) }
    }

    @ViewBuilder
    private var shelfRows: some View {
        Toggle(isOn: toy.bind(\.shelfEnabled)) {
            SettingLabel(title: "Shelf",
                         subtitle: "Keep files dropped on the notch on the card's second page. Off leaves the day, timers and switches available.")
        }
        if let settings = toy.store?.settings {
            // The key itself is set on Shortcuts, its one home; this row
            // says what it does and links there, beside the other way to
            // summon the shelf.
            LabeledContent {
                Button("Open Shortcuts") { settings.revealHome(.hotkeys, titled: "Open the shelf") }
                    .buttonStyle(.link)
            } label: {
                SettingLabel(title: "Shelf hotkey", subtitle: shelfHotkeyNote(settings) + " Change it on Shortcuts.")
            }
        }
    }

    /// The shelf's own rows: how files leave it, where new ones land, and
    /// the shake — its sensitivity, the apps it never answers over, and
    /// stepping aside for a shelf app that owns the same gesture.
    @ViewBuilder
    private var shelfSubrows: some View {
        LabeledContent {
            Picker(selection: toy.bind(\.shelfDragOut)) {
                Text("Copy").tag(ShelfDragOut.copy)
                Text("Move").tag(ShelfDragOut.move)
            } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
        } label: {
            SettingLabel(title: "Dragging a file out",
                         subtitle: "Copy leaves the original where it is, even on the same disk; hold ⌘ as you start the drag to move it instead.")
        }
        Toggle(isOn: toy.bind(\.shelfRemoveAfterDragOut)) {
            SettingLabel(title: "Remove after dragging out",
                         subtitle: "A file dropped somewhere else leaves the shelf. Rearranging the shelf never removes anything.")
        }
        Toggle(isOn: toy.bind(\.shelfNewestFirst)) {
            SettingLabel(title: "Newest first",
                         subtitle: "New files join the front of the shelf instead of the end.")
        }
        Toggle(isOn: toy.bind(\.shelfShakeToSummon)) {
            SettingLabel(title: "Shake to summon the shelf",
                         subtitle: "Shake the pointer while dragging files and the card opens under the notch as a drop target.")
        }
        if toy.settings.shelfShakeToSummon {
            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: toy.bind(\.shelfShakeSensitivity), in: 0...1)
                        .frame(width: 140)
                    ValueText(text: shakeWord)
                }
            } label: {
                SettingLabel(title: "Shake sensitivity",
                             subtitle: "Higher takes fewer, shorter swings; lower needs a firmer shake.")
            }
            ShelfShakeExclusionsRow(toy: toy)
            Toggle(isOn: toy.bind(\.shelfYieldToRivals)) {
                SettingLabel(title: "Step aside for other shelf apps",
                             subtitle: "While Dropover, Yoink or Dropzone runs, a shake is theirs, so one shake never opens two shelves. Dropping on the notch still works.")
            }
            // Only while JR-Bar's own shake is live: a Notch that is off,
            // or drawn by Alcove or Boring Notch, has no shake to step aside.
            RivalGuardView(role: .shelfGesture, active: shakeYieldLive)
        }
    }

    /// The hotkey's line: taken, or what it opens — the Paste chip only
    /// while the shelf is on to hold what was copied.
    private func shelfHotkeyNote(_ settings: SettingsStore) -> String {
        if settings.shelfHotkeyRegistrationFailed { return "⌃⌥D is taken by another app." }
        let opens = "⌃⌥D opens or folds the card from any app"
        guard toy.settings.shelfEnabled else { return opens + "." }
        return opens + "; anything you copied waits there as a Paste chip."
    }

    /// Whether the shake-yield note has anything to say: the Notch on and
    /// drawn by JR-Bar, and the step-aside switch on.
    private var shakeYieldLive: Bool {
        let settings = toy.settings
        return settings.enabled && settings.provider == .jrbar && settings.shelfYieldToRivals
    }

    /// "Firm", "Normal", "Easy" — the sensitivity in a word.
    private var shakeWord: String {
        switch toy.settings.shelfShakeSensitivity {
        case ..<0.34: return "Firm"
        case ..<0.67: return "Normal"
        default: return "Easy"
        }
    }

    @ViewBuilder
    private var sensorRows: some View {
        Toggle(isOn: Binding(
            get: { toy.sensorIndicatorsEnabled },
            set: { toy.sensorIndicatorsEnabled = $0 })) {
            SettingLabel(title: "Mic & camera indicators",
                         subtitle: toy.sensorsDrawable
                            ? "Show when the camera or microphone is in use. These indicators never open either device."
                            : "Turn off Notch wings in Devices to show these indicators beside the notch.")
        }
        Toggle(isOn: toy.bind(\.mirror)) {
            SettingLabel(title: "Mirror",
                         subtitle: "Open the camera with Option-click or the card's camera button. macOS asks on first use; the camera closes with the card.")
        }
    }

    /// "At once", "0.12 s", "0.5 s": the hover delay, to the hundredth.
    static func delayText(_ seconds: Double) -> String {
        let hundredths = Int((seconds * 100).rounded())
        guard hundredths > 0 else { return "At once" }
        return (Double(hundredths) / 100).formatted(.number.precision(.fractionLength(0...2))) + " s"
    }

    /// "2 s", "1.5 s": the level capsule's hold.
    private var hudDuration: String {
        "\(toy.settings.hudDuration.formatted(.number.precision(.fractionLength(0...1)))) s"
    }

    /// A glance switch's subtitle: what it shows once access exists, or
    /// the honest word on why it can't yet — the card itself never asks.
    private static func accessNote(_ status: SetupPermissionStatus, app: String,
                                   granted: String) -> String {
        switch status {
        case .granted: return granted
        case .writeOnly:
            return "Full access is needed. Turn on to open System Settings."
        case .denied, .restricted, .unavailable:
            return "\(app) access is off. Turn this on to open System Settings, or allow it in Setup."
        default:
            return "Turning this on asks for \(app) access once; Setup has the same row."
        }
    }

    /// What the chosen external renderer is doing — installed and
    /// launched, or a link to get it.
    @ViewBuilder
    private var providerNote: some View {
        switch toy.settings.provider {
        case .jrbar:
            EmptyView()
        case .alcove:
            externalNote(installed: toy.alcoveURL != nil, running: toy.isAlcoveRunning, name: "Alcove",
                         link: URL(string: "https://tryalcove.com")!)
        case .boringNotch:
            externalNote(installed: toy.boringNotchURL != nil, running: toy.isBoringNotchRunning, name: "Boring Notch",
                         link: URL(string: "https://github.com/TheBoredTeam/boring.notch")!)
        }
    }

    private func externalNote(installed: Bool, running: Bool, name: String, link: URL) -> some View {
        NotchExternalProviderNote(installed: installed, running: running, name: name,
                                  link: link, open: { toy.openExternal() })
    }
}

struct NotchRendererPicker: View {
    @Binding var selection: NotchProvider
    let alcoveInstalled: Bool
    let boringNotchInstalled: Bool

    var body: some View {
        Picker(selection: $selection) {
            Text("JR-Bar").tag(NotchProvider.jrbar)
            ExternalProviderOption(name: "Alcove", value: NotchProvider.alcove, installed: alcoveInstalled)
            ExternalProviderOption(name: "Boring Notch", value: NotchProvider.boringNotch, installed: boringNotchInstalled)
        } label: {
            SettingLabel(title: "Render with", subtitle: "Choosing another app opens it and parks JR-Bar's island.")
        }
        .pickerStyle(.menu)
        .padding(.vertical, SettingsMetrics.rowPadding)
    }
}

struct NotchExternalProviderNote: View {
    let installed: Bool
    let running: Bool
    let name: String
    let link: URL
    let open: () -> Void

    static func text(installed: Bool, running: Bool, name: String) -> String {
        guard installed else { return "\(name) isn't installed." }
        return running ? "\(name) is running and draws the island." : "\(name) isn't running. Open it to draw the island."
    }

    var body: some View {
        StatusBanner(Self.text(installed: installed, running: running, name: name)) {
            if installed { Button("Open \(name)", action: open) }
            else { Link("Get \(name)", destination: link) }
        }
    }
}

/// The shake's exclusion list: the apps a shake never summons the shelf
/// over — a drawing app, where a quick back-and-forth drag is the work.
/// Added from the running apps, removed with the chip's ×.
struct ShelfShakeExclusionsRow: View {
    let toy: NotchToy

    var body: some View {
        let excluded = toy.settings.shelfShakeExcludedBundleIDs
        VStack(alignment: .leading, spacing: 0) {
            LabeledContent {
                Menu("Add App") {
                    ForEach(Self.candidates(excluding: excluded), id: \.id) { app in
                        Button(app.name) { set(excluded + [app.id]) }
                    }
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
            } label: {
                SettingLabel(title: "Never summon over",
                             subtitle: excluded.isEmpty
                                ? "Apps where a shake while dragging is your own work, not a call for the shelf."
                                : "A shake over these apps leaves the shelf down.")
            }
            if !excluded.isEmpty {
                FlowLayout {
                    ForEach(excluded, id: \.self) { id in
                        HStack(spacing: 4) {
                            Text(Self.name(of: id))
                            Button {
                                set(excluded.filter { $0 != id })
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Stop excluding \(Self.name(of: id))")
                        }
                        .jrbarType(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                .padding(.top, SettingsMetrics.xs)
                .padding(.bottom, SettingsMetrics.s)
            }
        }
    }

    private func set(_ ids: [String]) {
        var seen = Set<String>()
        toy.store?.state.notch.shelfShakeExcludedBundleIDs = ids.filter { seen.insert($0).inserted }
    }

    /// The regular apps running now, by name, minus those already listed.
    /// The index's `policy` is read at launch, so an app that changed its
    /// activation policy mid-run lists under the policy it launched with —
    /// the same read the Dock card's own list makes.
    static func candidates(excluding excluded: [String]) -> [(id: String, name: String)] {
        let apps = RunningApps.shared.apps.compactMap { app -> (id: String, name: String)? in
            guard app.policy == .regular, let id = app.bundleID,
                  !excluded.contains(id), id != Bundle.main.bundleIdentifier else { return nil }
            return (id, app.name ?? id)
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// An app's own name for a bundle id when it is installed, else the
    /// id's last word ("com.apple.iWork.Keynote" → "Keynote"). Read once
    /// per id and kept: a row asks for it on every body pass, and each ask
    /// is a Launch Services lookup and a file-system name.
    static func name(of bundleID: String) -> String {
        AppDisplayNames.shared.name(of: bundleID)
    }
}

/// App names by bundle id, resolved once. The lookup — Launch Services for
/// the bundle, the file system for its display name — is the same every
/// time, and a card row asks for it on every redraw.
final class AppDisplayNames: @unchecked Sendable {
    static let shared = AppDisplayNames()

    private let lock = NSLock()
    private var known: [String: String] = [:]
    /// How a name is worked out; the tests count the lookups.
    private let resolve: @Sendable (String) -> String

    init(resolve: @escaping @Sendable (String) -> String = AppDisplayNames.lookUp) {
        self.resolve = resolve
    }

    func name(of bundleID: String) -> String {
        lock.lock()
        if let cached = known[bundleID] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let found = resolve(bundleID)
        lock.lock()
        known[bundleID] = found
        lock.unlock()
        return found
    }

    @Sendable static func lookUp(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        }
        return url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ".app", with: "")
    }
}
