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
                    calendar.sync(enabled: on && card.pinned)
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
                    reminders.sync(enabled: on && card.pinned)
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
            + "Looks the song up on LRCLIB (title, artist, album, length — nothing else) "
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
            Picker(selection: toy.providerBinding) {
                Text("JR-Bar").tag(NotchProvider.jrbar)
                Text("Alcove").tag(NotchProvider.alcove)
                Text("Boring Notch").tag(NotchProvider.boringNotch)
            } label: {
                SettingLabel(title: "Render with",
                             subtitle: "Let Alcove or Boring Notch draw the island instead.")
            }
            .pickerStyle(.menu)
            .padding(.vertical, SettingsMetrics.rowPadding)
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
            islandRows
            capsuleRows
            mediaRows
            glanceRows
            shelfRows
            sensorRows
        case .alcove:
            if let settings = toy.store?.settings {
                SettingToggle(settings, "Follow Alcove's capsule",
                              subtitle: "The Screen Bar matches the capsule's width while Alcove draws the notch. It never runs while JR-Bar draws it.",
                              path: "screen_bar_follow_alcove", default: true)
            }
            LabeledContent {
                Text(toy.capsuleFact)
                    .font(.callout)
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
        CardSectionHeader("Island")
        Toggle(isOn: toy.bind(\.islandEnabled)) {
            SettingLabel(title: "Show the island",
                         subtitle: toy.earsDrawn
                            ? "The housing under the notch. The Screen Bar's ears draw the HUD beside it, so the island itself stays bare."
                            : "The housing under the notch — working agents on the left, asks or the track on the right. Hover or click it for the card.")
        }
        Toggle(isOn: toy.bind(\.simulateNotch)) {
            SettingLabel(title: "Simulate notch",
                         subtitle: "On a display without a notch, the island hugs the top edge instead of floating as a pill.")
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
                Text("Where the pointer is").tag(NotchDisplay.pointer)
            } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
        } label: {
            SettingLabel(title: "Display",
                         subtitle: "Where the island and the Screen Bar live. Where the pointer is moves them when you change Space or plug in a screen, never as the pointer wanders.")
        }
        Toggle(isOn: toy.bind(\.hapticTick)) {
            SettingLabel(title: "Haptic tick",
                         subtitle: "A soft trackpad tap as the island opens, on a Mac with haptics.")
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
        CardSectionHeader("Capsules")
        Toggle(isOn: toy.bind(\.capsuleNotifications)) {
            SettingLabel(title: "Event capsules",
                         subtitle: "The island briefly becomes a notice when an ask opens, a run ends or a quota resets.")
        }
        if toy.settings.capsuleNotifications {
            CardSubrows {
                FlowLayout {
                    Toggle("Asks", isOn: toy.bind(\.capsuleKinds.ask))
                        .help("A session opens a question.")
                    Toggle("Completions", isOn: toy.bind(\.capsuleKinds.completed))
                        .help("An agent finishes a run.")
                    Toggle("Failures", isOn: toy.bind(\.capsuleKinds.failed))
                        .help("A session stops on an error.")
                    Toggle("Quota resets", isOn: toy.bind(\.capsuleKinds.quotaReset))
                        .help("A provider's usage window refills.")
                    Toggle("Power", isOn: toy.bind(\.capsuleKinds.charging))
                        .help("Plugging in, switching to battery, fully charged.")
                }
                .toggleStyle(ChipToggleStyle())
                .padding(.vertical, SettingsMetrics.s)
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
                                 subtitle: "The keys get our capsule instead of Apple's; needs Accessibility. Changes from Control Center still show Apple's, and JR-Bar never touches OSDUIHelper.")
                }
            }
        }
        Toggle(isOn: toy.bind(\.soundEffects)) {
            SettingLabel(title: "Capsule tick",
                         subtitle: "A quiet sound when a capsule shows.")
        }
    }

    @ViewBuilder
    private var mediaRows: some View {
        CardSectionHeader("Media")
        Toggle(isOn: toy.bind(\.mediaEnabled)) {
            SettingLabel(title: "Now Playing",
                         subtitle: toy.earsDrawn
                            ? "Transport buttons in the card. The island's own strip rests while the Screen Bar's ears draw."
                            : "The track in the right shoulder when nothing needs a hand, and transport buttons in the card.")
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
        CardSectionHeader("Glances")
        Toggle(isOn: toy.bind(\.weather)) {
            SettingLabel(title: "Weather",
                         subtitle: "Conditions, today's high and low and rain in the next two hours, from keyless Open-Meteo for the city below.")
        }
        if toy.settings.weather {
            CardSubrows {
                LabeledContent {
                    TextField("City", text: toy.bind(\.weatherCity), prompt: Text("e.g. London"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                } label: {
                    SettingLabel(title: "City")
                }
                Toggle(isOn: toy.bind(\.weatherUseIPLocation)) {
                    SettingLabel(title: "Locate by IP when no city is set",
                                 subtitle: "Sends your IP address to ipapi.co for a city-level guess. Off, an empty city just means no weather row.")
                }
            }
        }
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
        CardSectionHeader("Shelf & timers")
        Toggle(isOn: toy.bind(\.shelfEnabled)) {
            SettingLabel(title: "Shelf",
                         subtitle: "Files dropped on the notch wait on the card's second page. Off, the card keeps only the day, the timers and the switches, and a drop goes to a session row or nowhere.")
        }
        if toy.settings.shelfEnabled {
            CardSubrows {
                shelfSubrows
            }
        }
        if let settings = toy.store?.settings {
            // The same switch as General's, where a shelf person
            // looks for it: beside the other way to summon the shelf.
            Toggle(isOn: Binding(get: { settings.shelfHotkeyEnabled },
                                 set: { settings.shelfHotkeyEnabled = $0 })) {
                SettingLabel(title: "Shelf hotkey", subtitle: shelfHotkeyNote(settings))
            }
        }
        Toggle(isOn: toy.bind(\.timerLights)) {
            SettingLabel(title: "Timers flash the lights",
                         subtitle: "A timer coming due breathes the SidePulse strips orange three times — only with a strip connected, and never while the Mac is quiet.")
        }
    }

    /// The shelf's own rows: how files leave it, where new ones land, and
    /// the shake — its sensitivity, the apps it never answers over, and
    /// stepping aside for a shelf app that owns the same gesture.
    @ViewBuilder
    private var shelfSubrows: some View {
        LabeledContent {
            Picker(selection: toy.bind(\.shelfDragOut)) {
                Text("Copy (⌘ moves)").tag(ShelfDragOut.copy)
                Text("Move").tag(ShelfDragOut.move)
            } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
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
        CardSectionHeader("Camera & microphone")
        Toggle(isOn: Binding(
            get: { toy.sensorIndicatorsEnabled },
            set: { toy.sensorIndicatorsEnabled = $0 })) {
            SettingLabel(title: "Mic & camera indicators",
                         subtitle: toy.sensorsDrawable
                            ? "A green dot in the right shoulder while a camera rolls, an orange one while a microphone is live — macOS's own dots. Read-only: JR-Bar listens for the system saying they started and never opens either itself."
                            : "The Screen Bar's ears are drawing the notch's shoulders, so the island has no room for the dots.")
        }
        Toggle(isOn: toy.bind(\.mirror)) {
            SettingLabel(title: "Mirror",
                         subtitle: "A quick look through the camera: ⌥-click the notch, or the camera button in the card. Never a standing row — the lens closes when the card folds, and macOS asks for the camera the first time.")
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
        case .denied, .unavailable:
            return "\(app) access is off — turning this on opens System Settings, or allow it in Setup."
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
            externalNote(installed: toy.alcoveURL != nil, name: "Alcove",
                         link: URL(string: "https://tryalcove.com")!)
        case .boringNotch:
            externalNote(installed: toy.boringNotchURL != nil, name: "Boring Notch",
                         link: URL(string: "https://github.com/TheBoredTeam/boring.notch")!)
        }
    }

    private func externalNote(installed: Bool, name: String, link: URL) -> some View {
        HStack(spacing: SettingsMetrics.s) {
            CardNote(installed ? "\(name) is installed and draws the island." : "\(name) isn't installed.",
                     symbol: installed ? "checkmark.circle.fill" : "arrow.down.circle",
                     tint: installed ? .green : .secondary)
            Spacer(minLength: SettingsMetrics.s)
            if installed {
                Button("Open \(name)") { toy.openExternal() }
                    .controlSize(.small)
            } else {
                Link("Get \(name)", destination: link)
                    .font(.subheadline)
            }
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
                        .font(.callout)
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
    /// id's last word ("com.apple.iWork.Keynote" → "Keynote").
    static func name(of bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}
