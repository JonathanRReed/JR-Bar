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
        let base = "The current line and the next under the track, swept in time. "
            + "Looks the song up on LRCLIB (title, artist, album, length — nothing else) "
            + "and remembers the answer. Off, nothing is sent."
        let settings = settings
        guard settings.lyrics, !settings.lyricsConsented else { return base }
        return base + " Waiting for your yes: the card offers it once under the track."
    }
}

/// The card's disclosure body. Every toggle writes `store.state.notch`
/// (which persists itself) except the provider picker, which goes
/// through `setProvider` so the swap can park our island and open theirs.
struct NotchControlsView: View {
    let toy: NotchToy

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: toy.providerBinding) {
                Text("JR-Bar").tag(NotchProvider.jrbar)
                Text("Alcove").tag(NotchProvider.alcove)
                Text("Boring Notch").tag(NotchProvider.boringNotch)
            } label: {
                SettingLabel(title: "Render with",
                             subtitle: "Let Alcove or Boring Notch draw the island instead.")
            }
            .pickerStyle(.menu)
            .fixedSize()

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
            Toggle(isOn: toy.bind(\.islandEnabled)) {
                SettingLabel(title: "Show the island",
                             subtitle: toy.earsDrawn
                                ? "The housing under the notch — hover or click it for the card. The Screen Bar's ears are drawing the HUD beside it, so the island itself stays bare."
                                : "The housing under the notch: working agents in the left shoulder, asks or the track in the right. Hover or click it for the card.")
            }
            Toggle(isOn: toy.bind(\.simulateNotch)) {
                SettingLabel(title: "Simulate notch",
                             subtitle: "On a display with no hardware notch, the island hugs the top as a synthetic housing instead of floating as a pill.")
            }
            Toggle(isOn: toy.bind(\.expandOnHover)) {
                SettingLabel(title: "Card on hover",
                             subtitle: "A pointer resting on the notch or an ear grows the card — a third of a second arriving down from the menu bar, a touch quicker straight onto the island. Off, only a click or a pull opens it.")
            }
            Toggle(isOn: toy.bind(\.hapticTick)) {
                SettingLabel(title: "Haptic tick",
                             subtitle: "A soft trackpad tap as the island grows open. Nothing happens on a Mac without haptics.")
            }
            Toggle(isOn: toy.bind(\.pullGestures)) {
                SettingLabel(title: "Pull & swipe gestures",
                             subtitle: "Pull the island down (or spread two fingers) to open it; push up or squeeze to fold it. ⌘-drag sideways on the notch sets a timer.")
            }
            Toggle(isOn: toy.bind(\.showUsage)) {
                SettingLabel(title: "Usage meters",
                             subtitle: "Per-provider quota bars inside the card.")
            }
            Toggle(isOn: toy.bind(\.capsuleNotifications)) {
                SettingLabel(title: "Event capsules",
                             subtitle: "The island briefly morphs into a notice when an ask opens, a run ends or a quota resets.")
            }
            if toy.settings.capsuleNotifications {
                Toggle(isOn: toy.bind(\.capsuleKinds.ask)) {
                    SettingLabel(title: "Asks", subtitle: "A session opens a question.")
                }
                Toggle(isOn: toy.bind(\.capsuleKinds.completed)) {
                    SettingLabel(title: "Completions", subtitle: "An agent finishes a run.")
                }
                Toggle(isOn: toy.bind(\.capsuleKinds.failed)) {
                    SettingLabel(title: "Failures", subtitle: "A session stops on an error.")
                }
                Toggle(isOn: toy.bind(\.capsuleKinds.quotaReset)) {
                    SettingLabel(title: "Quota resets", subtitle: "A provider's usage window refills.")
                }
                Toggle(isOn: toy.bind(\.capsuleKinds.charging)) {
                    SettingLabel(title: "Power", subtitle: "Plugging in, switching to battery, fully charged.")
                }
                Toggle(isOn: toy.bind(\.holdNewsWhileQuiet)) {
                    SettingLabel(title: "Hold news while quiet",
                                 subtitle: "During a Focus or a quiet mode, finished runs and quota resets wait and come back as one summary when it ends. Asks and failures still show.")
                }
            }
            Toggle(isOn: Binding(
                get: { toy.sensorIndicatorsEnabled },
                set: { toy.sensorIndicatorsEnabled = $0 })) {
                SettingLabel(title: "Mic & camera indicators",
                             subtitle: toy.sensorsDrawable
                                ? "The right shoulder carries a green dot while a camera is rolling, an orange one while a microphone is live — the same dots macOS puts beside Control Center. Read-only: JR-Bar listens for the system saying they started; it never opens the mic or camera itself."
                                : "The Screen Bar's ears are drawing the notch's shoulders, so the island has no room for the dots.")
            }
            Toggle(isOn: toy.bind(\.mediaEnabled)) {
                SettingLabel(title: "Now Playing",
                             subtitle: toy.earsDrawn
                                ? "The card carries the track and transport buttons. (The island's own strip is off while the Screen Bar's ears draw.)"
                                : "The right shoulder carries the track when nothing needs a hand; the card gains transport buttons.")
            }
            if toy.settings.mediaEnabled {
                Toggle(isOn: toy.bind(\.audioVisualizer)) {
                    SettingLabel(title: "Audio visualizer (reacts to what's playing)",
                                 subtitle: "Six live bands on the media row, tapped from the playing app's own audio — asks for the system-audio permission once. Off or denied keeps the decorative animation.")
                }
                Toggle(isOn: toy.lyricsBinding) {
                    SettingLabel(title: "Synced lyrics", subtitle: toy.lyricsSubtitle)
                }
            }
            Toggle(isOn: toy.bind(\.mediaHUD)) {
                SettingLabel(title: "Volume & brightness capsules",
                             subtitle: "The level keys grow the level out of the notch as one continuous fill, with the device the sound is going to — the Alcove HUD. The key still does its job; we only draw it. While it shows, scroll over it to fine-tune the volume or brightness.")
            }
            if toy.settings.mediaHUD {
                Stepper(value: toy.bind(\.hudDuration),
                        in: NotchSettings.hudDurationRange, step: 0.5) {
                    SettingLabel(title: "Show for \(toy.settings.hudDuration.formatted(.number.precision(.fractionLength(0...1)))) s",
                                 subtitle: "How long a level and a system notice hold at the notch.")
                }
                .padding(.leading, 28)
                Toggle(isOn: toy.bind(\.replaceSystemHUD)) {
                    SettingLabel(title: "Replace the system volume & brightness overlay",
                                 subtitle: "The volume and brightness keys get our capsule instead of Apple's — needs the Accessibility permission. Changes made from Control Center still show Apple's overlay; JR-Bar never touches OSDUIHelper.")
                }
            }
            Toggle(isOn: toy.bind(\.timerLights)) {
                SettingLabel(title: "Timers flash the lights",
                             subtitle: "A timer coming due breathes the SidePulse strips orange three times, then the live light returns. Only with a strip connected, and never while the Mac is quiet.")
            }
            Toggle(isOn: toy.bind(\.shelfShakeToSummon)) {
                SettingLabel(title: "Shake to summon the shelf",
                             subtitle: "While dragging files, shake the pointer and the card opens under the notch as a drop target.")
            }
            if let settings = toy.store?.settings {
                // The same switch as General's, where a shelf person
                // looks for it: beside the other way to summon the shelf.
                Toggle(isOn: Binding(get: { settings.shelfHotkeyEnabled },
                                     set: { settings.shelfHotkeyEnabled = $0 })) {
                    SettingLabel(title: "Shelf hotkey",
                                 subtitle: settings.shelfHotkeyRegistrationFailed
                                    ? "⌃⌥D is taken by another app."
                                    : "⌃⌥D opens or folds the card from any app. Anything you copied waits there as a Paste chip.")
                }
            }
            Toggle(isOn: toy.bind(\.alerts)) {
                SettingLabel(title: "System alerts",
                             subtitle: "A Focus mode, a Bluetooth device joining or leaving, Caps Lock and displays speak in the island, one at a time with the agents' news. Headphones the Screen Bar's ear already names stay quiet here.")
            }
            Toggle(isOn: toy.bind(\.soundEffects)) {
                SettingLabel(title: "Capsule tick",
                             subtitle: "A quiet sound when a capsule shows.")
            }
            Toggle(isOn: toy.bind(\.weather)) {
                SettingLabel(title: "Weather",
                             subtitle: "Conditions, today's high and low and rain in the next two hours — keyless Open-Meteo for the city below.")
            }
            if toy.settings.weather {
                TextField("City, e.g. London", text: toy.bind(\.weatherCity))
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .padding(.leading, 28)
                Toggle(isOn: toy.bind(\.weatherUseIPLocation)) {
                    SettingLabel(title: "Locate by IP when no city is set",
                                 subtitle: "Sends your IP address to ipapi.co for a city-level guess. Off, an empty city just means no weather row.")
                }
                .padding(.leading, 28)
            }
            Toggle(isOn: toy.calendarBinding) {
                SettingLabel(title: "Calendar",
                             subtitle: Self.accessNote(SetupModel.calendarStatus(), app: "Calendar",
                                                       granted: "The next three events in the card, the first with Join."))
            }
            if toy.settings.calendar {
                Toggle(isOn: toy.bind(\.meetingAlerts)) {
                    SettingLabel(title: "Meeting heads-up",
                                 subtitle: "Two minutes before an event with a join link, the island says so with Join (and the Mirror, when it is on). While the meeting runs, finished runs wait like in a Focus. Reads the calendar in the background, on this Mac only.")
                }
                .padding(.leading, 28)
            }
            Toggle(isOn: toy.remindersBinding) {
                SettingLabel(title: "Reminders",
                             subtitle: Self.accessNote(SetupModel.reminderStatus(), app: "Reminders",
                                                       granted: "What's due by tomorrow, with a check-off circle that writes back."))
            }
            Toggle(isOn: toy.bind(\.mirror)) {
                SettingLabel(title: "Mirror",
                             subtitle: "A quick look through the camera — boring.notch's Mirror, on demand: ⌥-click the notch, or the camera button in the card. It is never a standing row; the lens closes when the card folds away. The camera's consent is asked the first time it opens.")
            }
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
        HStack(spacing: 8) {
            Text(installed ? "\(name) is installed" : "\(name) isn't installed")
                .font(.callout)
                .foregroundStyle(.secondary)
            if installed {
                Button("Open \(name)") { toy.openExternal() }
            } else {
                Link("Get \(name)", destination: link)
                    .font(.callout)
            }
        }
    }
}
