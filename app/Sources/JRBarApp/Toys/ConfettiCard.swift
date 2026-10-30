import AppKit
import JRBarCore
import JRBarUI
import SwiftUI

/// The card's disclosure body, in three runs: Look (a live preview, Try
/// it, where it comes from, how big, whose colours, what shapes, where
/// it lands — and Amount and Hang time under Adjust), When (the
/// triggers), and Manners (the room, the sound, the screens). Every row
/// writes `store.state.confetti`, which persists itself.
struct ConfettiControlsView: View {
    let toy: ConfettiToy

    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.lg) {
            ConfettiLookSection(toy: toy)
            ConfettiWhenSection(toy: toy)
            ConfettiMannersSection(toy: toy)
        }
    }
}

/// What a burst looks like, with the preview on top.
private struct ConfettiLookSection: View {
    let toy: ConfettiToy

    var body: some View {
        SettingGroup("Preview") {
            ConfettiPreviewTile(toy: toy)
                .equatable()
                .frame(height: 132)
                .padding(.vertical, 4)

            LabeledContent {
                Button("Test burst") { [weak toy] in
                    toy?.testBurst()
                }
            } label: {
                SettingLabel(title: "Try it",
                    subtitle: "Play a burst now with these settings and the focused session's color.")
            }
        }
        SettingGroup("Appearance") {
            Picker(selection: toy.bind(\.origin)) {
                Text("Notch").tag(ConfettiOrigin.notch)
                Text("Icon").tag(ConfettiOrigin.icon)
                Text("Corners").tag(ConfettiOrigin.corners)
                Text("Rain").tag(ConfettiOrigin.rain)
            } label: {
                SettingLabel(title: "Origin", subtitle: originNote)
            }
            .pickerStyle(.segmented)

            Picker(selection: toy.bind(\.intensity)) {
                Text("Subtle").tag(ConfettiIntensity.subtle)
                Text("Standard").tag(ConfettiIntensity.standard)
                Text("Big").tag(ConfettiIntensity.big)
            } label: {
                SettingLabel(title: "Size", subtitle: "About 90, 180 or 300 pieces on a laptop screen; Big fires twice.")
            }
            .pickerStyle(.segmented)

            ConfettiPalettePicker(toy: toy)

            Picker(selection: toy.bind(\.shapes)) {
                Text("Mixed").tag(ConfettiShapes.mixed)
                Text("Streamers").tag(ConfettiShapes.streamers)
                Text("Flecks").tag(ConfettiShapes.flecks)
                Text("Glyphs").tag(ConfettiShapes.glyphs)
                Text("Stars").tag(ConfettiShapes.stars)
            } label: {
                SettingLabel(title: "Shapes", subtitle: "Choose paper, ribbons, stars or provider symbols.")
            }
            .pickerStyle(.menu)

            Picker(selection: toy.bind(\.landing)) {
                Text("Rest").tag(ConfettiLanding.rest)
                Text("Fall").tag(ConfettiLanding.fall)
                Text("Fade").tag(ConfettiLanding.fade)
            } label: {
                SettingLabel(title: "Landing", subtitle: landingNote)
            }
            .pickerStyle(.segmented)

            Toggle(isOn: toy.bind(\.seasonal)) {
                SettingLabel(title: "Seasonal",
                    subtitle: "Use holiday colors and shapes on the matching dates.")
            }
        }
        SettingsGroup { ConfettiAdjustDisclosure(toy: toy) }
    }

    private var originNote: String {
        switch toy.settings.origin {
        case .notch: return "From below the notch, or the top center on a screen without one."
        case .icon: return "Out from under JR-Bar's menu-bar icon; other screens use the notch."
        case .corners: return "Two cannons at the bottom corners, crossing over the middle."
        case .rain: return "A gentle shower from the top edge."
        }
    }

    private var landingNote: String {
        switch toy.settings.landing {
        case .rest: return "Pieces land on the tops of your windows and the Dock, rest a moment, then fade."
        case .fall: return "A quick shower off the bottom of the screen, done in about four seconds."
        case .fade: return "Pieces dissolve in the air, gone by just past halfway down."
        }
    }
}

/// Whose colours the burst wears.
private struct ConfettiPalettePicker: View {
    let toy: ConfettiToy

    var body: some View {
        Picker(selection: toy.bind(\.palette)) {
            Text("Provider").tag(ConfettiPalette.provider)
            Text("Toys tint").tag(ConfettiPalette.toys)
            Text("Everyone working").tag(ConfettiPalette.everyone)
            Divider()
            Text("Party").tag(ConfettiPalette.party)
            Text("Gold").tag(ConfettiPalette.gold)
            Text("Pastel").tag(ConfettiPalette.pastel)
            Text("Mono").tag(ConfettiPalette.mono)
        } label: {
            SettingLabel(title: "Palette", subtitle: note)
        }
        .pickerStyle(.menu)
    }

    private var note: String {
        switch toy.settings.palette {
        case .provider: return "The provider's colour with white and gold, and its glyph among the pieces."
        case .toys: return "The Toys page's pink, whoever it's for."
        case .everyone: return "Every provider working right now, each in its own colour and glyph."
        case .party: return "Bright and many-coloured."
        case .gold: return "Gold, champagne and white for milestones."
        case .pastel: return "Soft pinks, mints and blues."
        case .mono: return "The provider's colour alone, deep to pale."
        }
    }
}

/// Adjust, folded like any `DisclosureRow` — and opened by a Settings
/// search that lands on Amount or Hang time, so the row it named is
/// there to see, not folded away inside the card it opened. It opens
/// once per search: fold it, fold the card and open the card again, and
/// it stays as you left it.
struct ConfettiAdjustDisclosure: View {
    let toy: ConfettiToy
    @ViewState private var expanded = false

    /// The rows it holds, by their search titles.
    static let rows: Set<String> = ["Amount", "Hang time"]

    /// Whether a search result is one of the rows under Adjust.
    static func opens(for hit: SettingsSearchEntry?, card: String) -> Bool {
        guard let hit, hit.card == card else { return false }
        return rows.contains(hit.title)
    }

    /// Whether Settings' reveal number `request` opens Adjust on `toy`'s
    /// card: one the card hasn't acted on yet, for one of Adjust's rows.
    /// Every reveal seen is noted on the toy, which outlives the folded
    /// card, so a card opened again later doesn't read the same search
    /// hit as new.
    static func take(_ request: Int?, hit: SettingsSearchEntry?, on toy: ConfettiToy) -> Bool {
        guard let request, request != toy.adjustReveal else { return false }
        toy.adjustReveal = request
        return opens(for: hit, card: toy.id)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ConfettiAdjustRows(toy: toy)
        } label: {
            SettingsMoreOptionsLabel(subtitle: "How many pieces, and how long they hang in the air.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: toy.store?.settings.revealRequest, initial: true) { _, request in
            if Self.take(request, hit: toy.store?.settings.searchHit, on: toy) { expanded = true }
        }
    }
}

/// Amount and Hang time, folded under Adjust.
private struct ConfettiAdjustRows: View {
    let toy: ConfettiToy

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: toy.bind(\.density), in: 0.5...2, step: 0.1)
                    .frame(width: 180)
                ValueText(text: String(format: "%.1f×", toy.settings.density))
            }
        } label: {
            SettingLabel(title: "Amount", subtitle: "Fine-tunes the Size: fewer or more pieces.")
        }

        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: toy.bind(\.duration), in: 0.7...1.5)
                    .frame(width: 180)
                ValueText(text: String(format: "%.1f×", toy.settings.duration))
            }
        } label: {
            SettingLabel(title: "Hang time", subtitle: "How slowly pieces fall and how long they rest.")
        }
    }
}

/// What earns a burst.
private struct ConfettiWhenSection: View {
    let toy: ConfettiToy

    var body: some View {
        SettingGroup("Celebrate") {

            Toggle(isOn: toy.bind(\.triggers.quotaReset)) {
                SettingLabel(title: "Quota resets", subtitle: "A connected provider's quota window refills.")
            }

            Toggle(isOn: toy.bind(\.triggers.sessionCompleted)) {
                SettingLabel(title: "Session completed", subtitle: "An agent finishes a run.")
            }

            Toggle(isOn: toy.bind(\.triggers.allClear)) {
                SettingLabel(title: "All caught up", subtitle: "The last open ask is resolved.")
            }

            Toggle(isOn: toy.bind(\.triggers.codexBankedReset)) {
                SettingLabel(title: "Codex banked credits", subtitle: "The banked-credit balance grows.")
            }

            Toggle(isOn: toy.bind(\.triggers.milestones)) {
                SettingLabel(title: "Milestones", subtitle: "An Aquarium achievement or a new tank level.")
            }

            if !toy.settings.triggers.quotaReset, !providerChoices.isEmpty {
                Text("Every reset from")
                    .jrbarType(.callout)
                    .foregroundStyle(.secondary)
                ForEach(providerChoices, id: \.self) { id in
                    Toggle(isOn: providerBinding(id)) {
                        SettingLabel(title: ProviderStyle.style(for: id).name,
                            subtitle: "Any quota window refill, including the five-hour window.")
                    }
                }
            }

            Toggle(isOn: toy.bind(\.momentStyles)) {
                SettingLabel(title: "Moment styles",
                    subtitle: "A milestone bursts gold and big from the corners; All caught up is a gentle rain.")
            }
        }
    }

    /// The per-provider reset picker: the providers the daemon currently
    /// reports a quota source for — the only ones that can ever emit a
    /// `quota_reset` — plus any picked id the list no longer carries,
    /// so a provider that went quiet keeps its checkbox.
    private var providerChoices: [String] {
        var ids = Set(toy.settings.triggers.perProviderReset)
        for provider in toy.store?.core.usage ?? [] where provider.quotaSource {
            ids.insert(provider.id)
        }
        return ids.sorted { ProviderStyle.style(for: $0).name < ProviderStyle.style(for: $1).name }
    }

    /// Set membership as a binding — one row's tick adds or drops the id.
    /// Stored lowercase: `eventFire` lowercases the event's provider, so
    /// a mixed-case id must never land in the set.
    private func providerBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { toy.settings.triggers.perProviderReset.contains(id.lowercased()) },
            set: { on in
                var picked = toy.store?.state.confetti.triggers.perProviderReset ?? []
                if on { picked.insert(id.lowercased()) } else { picked.remove(id.lowercased()) }
                toy.store?.state.confetti.triggers.perProviderReset = picked
            })
    }
}

/// How the burst minds the room.
private struct ConfettiMannersSection: View {
    let toy: ConfettiToy

    var body: some View {
        SettingGroup("Quiet and sound") {

            Toggle(isOn: toy.hushBinding) {
                SettingLabel(title: "Quiet the toys during Focus, quiet hours and calls",
                    subtitle: "Hold celebrations during Focus, quiet hours and calls. Also quiets the buddy, tank and lid sounds.")
            }

            if toy.hushBinding.wrappedValue {
                Picker(selection: toy.bind(\.whenHeld)) {
                    Text("Play smaller later").tag(ConfettiHeldBurst.later)
                    Text("Skip").tag(ConfettiHeldBurst.drop)
                } label: {
                    SettingLabel(title: "A held burst", subtitle: "What happens once the room clears. Anything held over half an hour is let go.")
                }
                .pickerStyle(.segmented)
            }

            Toggle(isOn: toy.bind(\.sound)) {
                SettingLabel(title: "Sound",
                    subtitle:
                        "A soft pop and rustle with the burst, at Settings › Alerts & Sounds' volume and on its device. Silent while JR-Bar is quiet."
                )
            }

            LabeledContent {
                Picker("Screens", selection: toy.bind(\.screens)) {
                    Text("Every screen").tag(ConfettiScreens.all)
                    Text("Main only").tag(ConfettiScreens.main)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            } label: {
                SettingLabel(title: "Screens", subtitle: "Choose where bursts appear. Full-screen apps keep their screens while quiet-toys is on.")
            }
        }
    }
}

/// The card's preview: the top middle of the screen at half size —
/// menu bar, notch and desktop — with the burst the settings would
/// throw, in the focused session's colours. It plays one burst (30 fps,
/// about two seconds) whenever a pick changes or the pointer comes over
/// it, then holds still on a frame mid-air. The card above it re-reads
/// the daemon's state with every document, but the tile is only redrawn
/// when what it shows changes (`==`), so an open card that's only being
/// read doesn't rebuild the burst.
struct ConfettiPreviewTile: View {
    let settings: ConfettiSettings
    let shot: ConfettiShot
    var everyone: [(id: String, color: Color)] = []
    /// Render proofs can select either pose without changing the Mac's setting.
    var reduceMotionOverride: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How big the screen is drawn in the tile.
    static let scale = 0.5

    /// The frame the tile holds still on.
    static let restingFrame = 0.7
    /// How long one replay runs.
    static let replay = 2.2

    nonisolated static func clock(replaying: Bool, reduceMotion: Bool, power: PowerPolicy = .normal)
        -> (interval: TimeInterval, paused: Bool, flash: Bool) {
        let flash = reduceMotion || power.pauses(occluded: false)
        return (power.interval(1.0 / 30), !replaying || flash, flash)
    }

    @ViewState private var started: Date?
    @ViewState private var seed: UInt64 = 7
    @ViewState private var marks = ConfettiMarks()

    var body: some View {
        let plan = ConfettiToy.plan(settings, shot: shot, densityScale: 1, everyone: everyone, season: nil)
        let burst = ConfettiBurst(stage: Self.stage, recipe: plan.recipe, seed: seed)
        let clock = Self.clock(replaying: started != nil, reduceMotion: reduceMotionOverride ?? reduceMotion,
                               power: PowerConditions.shared.policy)
        TimelineView(.animation(minimumInterval: clock.interval, paused: clock.paused)) { context in
            let time = clock.flash ? ConfettiView.flashLife / 2 : frameTime(at: context.date)
            ZStack(alignment: .top) {
                ConfettiPreviewDesk(part: .desk)
                ConfettiView(burst: burst, look: plan.look, flash: clock.flash, marks: marks, scale: Self.scale,
                             frozen: time)
                // The notch is a hole in the screen: it goes over the burst.
                ConfettiPreviewDesk(part: .notch)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: JRBarTokens.Radius.group, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JRBarTokens.Radius.group, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .onHover { inside in if inside { play() } }
        .onChange(of: settings) { play() }
        .accessibilityHidden(true)
    }

    /// The top of the reference screen: the preview's world.
    static let stage: ConfettiStage = {
        var stage = ConfettiStage.reference
        stage.icon = CGRect(x: 1270, y: 4, width: 26, height: 24)
        return stage
    }()

    private func play() {
        seed &+= 1
        started = Date()
    }

    private func frameTime(at now: Date) -> Double {
        guard let started else { return Self.restingFrame }
        let elapsed = now.timeIntervalSince(started)
        if elapsed >= Self.replay {
            DispatchQueue.main.async {
                if self.started == started { self.started = nil }
            }
            return Self.restingFrame
        }
        return elapsed
    }
}

extension ConfettiPreviewTile: Equatable {
    /// The tile as the card shows it: the stored settings, the focused
    /// session's colour and whoever is working now.
    init(toy: ConfettiToy) {
        self.init(settings: toy.settings, shot: toy.shot(for: toy.store?.focusedProvider()),
                  everyone: toy.workingProviders())
    }

    /// The same picture: the same settings, the same burst colour and
    /// glyph, and the same working providers in the same colours.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.settings == b.settings && a.shot == b.shot
            && a.reduceMotionOverride == b.reduceMotionOverride
            && a.everyone.map(\.id) == b.everyone.map(\.id)
            && a.everyone.map(\.color) == b.everyone.map(\.color)
    }
}

/// The preview's screen, in two parts: the desktop under the burst (a
/// night gradient and the menu bar) and the notch over it.
private struct ConfettiPreviewDesk: View {
    enum Part { case desk, notch }
    let part: Part

    var body: some View {
        GeometryReader { proxy in
            let fit = ConfettiPreviewTile.scale
            ZStack(alignment: .top) {
                if part == .desk {
                    LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.22),
                                            Color(red: 0.24, green: 0.17, blue: 0.32)],
                                   startPoint: .top, endPoint: .bottom)
                    Rectangle().fill(Color.black.opacity(0.28)).frame(height: 32 * fit)
                } else {
                    UnevenRoundedRectangle(bottomLeadingRadius: 8 * fit, bottomTrailingRadius: 8 * fit,
                                           style: .continuous)
                        .fill(.black)
                        .frame(width: 185 * fit, height: 32 * fit)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }
}
