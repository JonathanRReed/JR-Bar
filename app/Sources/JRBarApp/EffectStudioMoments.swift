import JRBarCore
import JRBarLEDS
import SwiftUI

/// One ambient moment the lights can play: the daemon's finite cues
/// (`ambient_effect_dispatch.AmbientEffectFamily`), which it plans from
/// hook events and layers over the base light by priority. They carry no
/// content — no names, no text — and every one passes the 2 Hz clamp.
///
/// Until now they had no names anywhere in the app, so nobody could say
/// what a "baton" or an "ember" was. The sketch is the cue's shape in
/// its own colours (`AmbientSemanticColors`) at typical timings — the
/// daemon's planner picks the exact frames per event.
struct LightMoment: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String
    /// What it means, one line.
    let meaning: String
    /// When the daemon plays it.
    let plays: String
    let surfaces: [String]
    /// `AMBIENT_EFFECT_PRIORITY`: when two want the light, the higher wins.
    let priority: Int
    /// The setting that switches it on, for the opt-in ones; nil for the
    /// cues that are always part of the light language.
    let setting: String?
    let sketch: String
    var sketchLedCount: Int = 8

    /// `AmbientSemanticColors`, the palette every cue is drawn in.
    enum Palette {
        static let ask = "#FF3A00"
        static let notification = "#34C759"
        static let handoff = "#A45CFF"
        static let work = "#00E5FF"
        static let completion = "#00FF66"
        static let recovery = "#12E3B0"
        static let environment = "#FFB340"
        static let idle = "#8B93A7"
    }

    /// Every moment, loudest first — the order the daemon layers them.
    static let all: [LightMoment] = [
        LightMoment(
            id: "dot_binary_heartbeat", name: "Dot heartbeat", symbol: "circle.grid.2x1",
            meaning: "The Dot's own two-LED code: the first LED is the loudest state (a double pulse for an ask, steady for a failure), the second a marker you choose.",
            plays: "On a Dot in the Status role.",
            surfaces: ["sidepulse_dot"], priority: 1_100, setting: nil,
            sketch: "0:\(Palette.ask) 1:\(Palette.notification) 300ms none\n0:#000000 1:\(Palette.notification) 300ms none\n"
                + "0:\(Palette.ask) 1:\(Palette.notification) 300ms none\n0:#000000 1:\(Palette.notification) 900ms none\nrepeat",
            sketchLedCount: 2),
        LightMoment(
            id: "ask_heartbeat", name: "Ask heartbeat", symbol: "heart",
            meaning: "A double beat in the ask colour. Asks that arrive together beat in step instead of against each other.",
            plays: "While an ask is open.",
            surfaces: ["screen_bar", "sidepulse_pro", "sidepulse_dot"], priority: 1_000, setting: nil,
            sketch: "\(Palette.ask) 250ms none\noff 250ms none\n\(Palette.ask) 250ms none\noff 1250ms none\nrepeat"),
        LightMoment(
            id: "glance_light", name: "Glance light", symbol: "eye",
            meaning: "A small light that waits for you — a finish or a notice you have not seen yet.",
            plays: "Until the news is seen (an unseen finish for up to fifteen minutes).",
            surfaces: ["screen_bar", "sidepulse_pro", "sidepulse_dot"], priority: 900, setting: nil,
            sketch: "off\n3:\(Palette.notification) 350ms none\n3:#000000 4:\(Palette.notification) 350ms none\noff 900ms none\nrepeat"),
        LightMoment(
            id: "handoff_baton", name: "Handoff baton", symbol: "arrow.left.arrow.right",
            meaning: "One agent handed work to another: a purple baton runs the length of the strip.",
            plays: "When one agent finishes and another starts on the same task or project moments later.",
            surfaces: ["screen_bar", "sidepulse_pro"], priority: 780, setting: nil,
            sketch: "off\n0:\(Palette.handoff) 300ms none\n0:#000000 4:\(Palette.handoff) 300ms none\n4:#000000 7:\(Palette.handoff) 300ms none\noff 900ms none\nrepeat"),
        LightMoment(
            id: "firefly_completion", name: "Firefly", symbol: "sparkle",
            meaning: "A green spark drifts out of the finishing agent's own stretch of the strip and fades.",
            plays: "When a session finishes.",
            surfaces: ["screen_bar", "sidepulse_pro"], priority: 740, setting: nil,
            sketch: "off\n2:#00FF66 300ms none\n2:#000000 3:#00C851 300ms none\n3:#000000 4:#00993D 300ms none\n4:#000000 5:#005924 300ms none\noff 900ms none\nrepeat"),
        LightMoment(
            id: "completion_meniscus", name: "Meniscus", symbol: "drop",
            meaning: "A ripple swells out from the band's centre and settles, like a drop meeting its brim.",
            plays: "When a finish goes unseen. Screen Bar only.",
            surfaces: ["screen_bar"], priority: 730, setting: nil,
            sketch: "#000000 #000000 #000000 #00FF66 #00FF66 #000000 #000000 #000000 200ms none\n"
                + "#000000 #000000 #00C851 #00C851 #00C851 #00C851 #000000 #000000 250ms none\n"
                + "#000000 #007A30 #007A30 #007A30 #007A30 #007A30 #007A30 #000000 300ms none\noff 900ms none\nrepeat"),
        LightMoment(
            id: "milestone_odometer", name: "Milestone", symbol: "flag.checkered",
            meaning: "Three rising steps of green when finished sessions cross a milestone.",
            plays: "When the exact completion count reaches one of your milestones.",
            surfaces: ["screen_bar", "sidepulse_pro"], priority: 720, setting: "milestone_odometer_enabled",
            sketch: "#005924 300ms none\n#00A541 300ms none\n#00FF66 500ms none\noff 900ms none\nrepeat"),
        LightMoment(
            id: "courtesy_signature", name: "Courtesy signature", symbol: "hand.wave",
            meaning: "A brief pattern of dots whose shape, not only its colour, says what happened — without asking anything of you.",
            plays: "For low-stakes events; a device on Asks only never shows it.",
            surfaces: ["screen_bar", "sidepulse_pro", "sidepulse_dot"], priority: 660, setting: nil,
            sketch: "2:\(Palette.notification) 5:\(Palette.notification) 200ms none\noff 250ms none\n2:\(Palette.notification) 5:\(Palette.notification) 200ms none\noff 1100ms none\nrepeat"),
        LightMoment(
            id: "recovery_grace", name: "Recovery grace note", symbol: "arrow.uturn.up",
            meaning: "A teal note crosses the strip: a source that had gone quiet is reporting again.",
            plays: "When a recovery is confirmed.",
            surfaces: ["screen_bar", "sidepulse_pro"], priority: 620, setting: nil,
            sketch: "off\n0:\(Palette.recovery) 400ms none\n0:#000000 4:\(Palette.recovery) 400ms none\n4:#000000 7:\(Palette.recovery) 400ms none\noff 900ms none\nrepeat"),
        LightMoment(
            id: "fleet_arrival_departure", name: "Arrival and departure", symbol: "desktopcomputer",
            meaning: "One end of the strip blinks amber once as a peer Mac joins or leaves.",
            plays: "When a remote peer's arrival or departure has settled.",
            surfaces: ["screen_bar", "sidepulse_pro"], priority: 520, setting: nil,
            sketch: "0:\(Palette.environment) 500ms none\n0:#000000 500ms none\noff 1000ms none\nrepeat"),
        LightMoment(
            id: "turn_length_ember", name: "Turn-length ember", symbol: "flame",
            meaning: "A long turn glows a little warmer as it ages, in four broad bands — its age, never its progress.",
            plays: "While a turn runs long.",
            surfaces: ["screen_bar", "sidepulse_pro"], priority: 320, setting: nil,
            sketch: "#00282C 1500ms cosine\n#00737F 1500ms cosine\nrepeat"),
        LightMoment(
            id: "rainstick_idle", name: "Rainstick", symbol: "drop.degreesign",
            meaning: "One dim grey pixel steps along the strip every thirty seconds: JR-Bar is alive and nothing needs you.",
            plays: "While nothing else owns the strip, if you turn it on.",
            surfaces: ["screen_bar", "sidepulse_pro"], priority: 100, setting: "rainstick_idle_enabled",
            sketch: LightingPreviewPrograms.rainstick()),
    ]
}

/// One cue as the monitor's `list_cues` reports it: whether it is on,
/// what switches it, and for the milestone odometer where the count
/// stands. A monitor without the command answers `unknown_command`, and
/// the room keeps the switches it always had.
struct LightCueState: Decodable, Equatable {
    let id: String
    let enabled: Bool
    let defaultEnabled: Bool?
    let setting: String?
    /// Milestone odometer only: completions counted since the monitor
    /// started, and the next step above them (nil past the last).
    let count: Int?
    let nextStep: Int?

    enum CodingKeys: String, CodingKey {
        case id, enabled, setting, count
        case defaultEnabled = "default_enabled"
        case nextStep = "next_step"
    }

    init(id: String, enabled: Bool, defaultEnabled: Bool? = nil, setting: String? = nil,
         count: Int? = nil, nextStep: Int? = nil) {
        self.id = id
        self.enabled = enabled
        self.defaultEnabled = defaultEnabled
        self.setting = setting
        self.count = count
        self.nextStep = nextStep
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        defaultEnabled = try c.decodeIfPresent(Bool.self, forKey: .defaultEnabled)
        setting = try c.decodeIfPresent(String.self, forKey: .setting)
        count = try? c.decodeIfPresent(Int.self, forKey: .count)
        nextStep = try? c.decodeIfPresent(Int.self, forKey: .nextStep)
    }
}

/// `list_cues` / `set_cue` replies: `{cues: [...]}` (with `generation`
/// on a set).
struct LightCueList: Decodable {
    let cues: [LightCueState]
}

/// What a moment's switch is: the monitor's own cue switch when it lists
/// the cue, the older opt-in setting when it does not, else nothing to
/// switch (the Dot's heartbeat is a display, not a cue).
enum MomentSwitch: Equatable {
    case cue(LightCueState)
    case setting(String)
    case always

    static func of(_ moment: LightMoment, cues: [String: LightCueState]?) -> MomentSwitch {
        if let cue = cues?[moment.id] { return .cue(cue) }
        if let setting = moment.setting { return .setting(setting) }
        return .always
    }

    /// "37 finished · next at 50", "120 finished · past the last step".
    static func milestoneLine(_ cue: LightCueState) -> String? {
        guard let count = cue.count else { return nil }
        let finished = "\(count) finished since the monitor started"
        guard let next = cue.nextStep else { return finished + " · past the last step" }
        return finished + " · next at \(next)"
    }
}

/// The Moments room of Effect Studio: every ambient cue by name, what it
/// means, when it plays, its switch where it has one, and a sketch that
/// can be played on the Screen Bar.
struct LightMomentsView: View {
    @Bindable var store: EffectStudioStore
    /// The monitor's cue switches by id; nil until `list_cues` answers
    /// (and for good on a monitor without it).
    @ViewState private var cues: [String: LightCueState]?

    var body: some View {
        SnapshotScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Moments").font(.title2.weight(.semibold))
                    Text("Short, content-free cues the lights layer over the agent state. Higher in the list wins when two want the light at once; all of them are clamped to 2 Hz and stand down for Quiet and low power. The sketches show each cue's shape — the monitor fits the exact frames to the event.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    ForEach(LightMoment.all) { moment in
                        MomentRow(store: store, moment: moment, control: MomentSwitch.of(moment, cues: cues)) { enabled in
                            setCue(moment.id, enabled: enabled)
                        }
                        if moment.id != LightMoment.all.last?.id { Divider().padding(.leading, 56) }
                    }
                }
                .windowCard(padding: 0)
                LidMomentsSection(store: store)
                FinishMomentsSection(store: store)
            }
            .padding(WindowMetrics.margin)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // The settings generation moves when a cue is switched from
        // anywhere; the list follows it.
        .task(id: "\(store.isLive)-\(store.core.settings?.generation ?? 0)") { await loadCues() }
    }

    private func loadCues() async {
        guard store.isLive else { return }
        do {
            let list = try await store.core.request("list_cues", as: LightCueList.self)
            cues = Dictionary(list.cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            // unknown_command: an older monitor. The rows keep the
            // switches they always had.
            cues = nil
        }
    }

    private func setCue(_ id: String, enabled: Bool) {
        Task {
            do {
                let list = try await store.core.request("set_cue", args: ["id": .string(id), "enabled": .bool(enabled)],
                                                        as: LightCueList.self)
                cues = Dictionary(list.cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            } catch {
                store.fail("Cue not changed: \(EffectStudioStore.describe(error))")
            }
        }
    }
}

private struct MomentRow: View {
    @Bindable var store: EffectStudioStore
    let moment: LightMoment
    let control: MomentSwitch
    let setCue: (Bool) -> Void

    private var document: SettingsDocument { SettingsDocument(store.core.settings?.document ?? .object([:])) }
    private var isOn: Bool {
        switch control {
        case .cue(let cue): return cue.enabled
        case .setting(let setting): return document.bool(SettingsPath(setting)) ?? false
        case .always: return true
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: moment.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((isOn ? Color.accentColor : Color.secondary).opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(moment.name).font(.body.weight(.medium))
                Text(moment.meaning).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("\(moment.plays) · \(moment.surfaces.map(EffectInspectorPane.surfaceName).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .cue(let cue) = control, let line = MomentSwitch.milestoneLine(cue) {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                LEDStripPreview(program: moment.sketch, ledCount: moment.sketchLedCount,
                                style: moment.sketchLedCount == 2 ? .dots : .band,
                                dotSize: moment.sketchLedCount == 2 ? 10 : 7, spacing: 6)
                    .frame(width: moment.sketchLedCount == 2 ? 70 : 150)
                    .opacity(isOn ? 1 : 0.4)
                    .accessibilityLabel("\(moment.name) sketch")
                HStack(spacing: 8) {
                    if control == .always {
                        Text("Always on").font(.caption).foregroundStyle(.tertiary)
                    } else {
                        Toggle("On", isOn: Binding(get: { isOn }, set: { on in apply(on) }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            .disabled(!store.isLive)
                            .help(isOn ? "Turn \(moment.name) off" : "Turn \(moment.name) on")
                    }
                    if moment.surfaces.contains("screen_bar") {
                        Button {
                            store.playMomentSketch(moment)
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!store.isLive)
                        .help("Play the sketch on the Screen Bar for a few seconds")
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// The switch moved: through the monitor's cue switch when it has
    /// one, else the cue's own opt-in setting.
    private func apply(_ on: Bool) {
        switch control {
        case .cue: setCue(on)
        case .setting(let setting):
            Task { try? await store.core.setSetting(SettingsPath(setting), value: .bool(on)) }
        case .always: break
        }
    }
}

extension EffectStudioStore {
    /// Plays a moment's sketch on the Screen Bar — on-screen light, so no
    /// hardware consent — through the same compiler clamp as everything.
    func playMomentSketch(_ moment: LightMoment) {
        guard let compiled = LEDSPresentationCompiler.compileProgram(moment.sketch, ledCount: 8)?.result.program else {
            fail("The \(moment.name) sketch did not compile")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.core.previewProgramNow(surface: "screen_bar", program: compiled, seconds: 6)
                if reply.ok { self.show(status: "Playing \(moment.name) on the Screen Bar") }
                else { self.fail(reply.error?.message ?? "Play refused") }
            } catch {
                self.fail("Play failed: \(Self.describe(error))")
            }
        }
    }
}

// MARK: - Lid and finish

/// One lid look as `list_lid_presets` reports it: the program the Pro plays
/// and the one the Dot plays (the Iris looks are drawn for each), and the
/// value `set_setting` takes to pick it.
struct LidLook: Decodable, Identifiable, Equatable {
    let name: String
    let durationSeconds: Double
    let shape: String?
    let program: String
    let dotProgram: String
    let setting: JSONValue
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, shape, program, setting
        case durationSeconds = "duration_seconds"
        case dotProgram = "dot_program"
    }
}

/// One lid transition: what it is called, the setting that holds its look,
/// which look plays now (nil for a custom program), and every look offered.
struct LidTransition: Decodable, Identifiable, Equatable {
    let kind: String
    let label: String
    let path: String
    let current: String?
    let shipped: Bool
    let presets: [LidLook]
    var id: String { kind }

    /// "Hello", "As shipped", "Custom program".
    var currentName: String { current ?? (shipped ? "As shipped" : "Custom program") }
}

struct LidTransitionList: Decodable {
    let kinds: [LidTransition]
}

/// Effect Studio › Moments › Lid: the four lid transitions, each with its
/// looks as thumbnails. A thumbnail picks the look (it is written to the
/// transition's setting); the play button runs the picked look on the
/// strip and the Dot exactly as a lid change would. Iris is upstream
/// SidePulse's lid-open and lid-close, drawn for each device.
struct LidMomentsSection: View {
    @Bindable var store: EffectStudioStore
    /// What to show before the monitor answers (a render proof's data).
    var seed: [LidTransition] = []
    @ViewState private var transitions: [LidTransition] = []
    @ViewState private var unsupported = false

    private var shown: [LidTransition] { transitions.isEmpty ? seed : transitions }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MomentsSectionHeader(title: "Lid",
                                 detail: "What the strip and the Dot play when the lid opens or closes, with and without agents running. Iris opens from the middle out and closes from the edges in, drawn for each device.")
            if unsupported {
                Text("This monitor does not list lid looks yet.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(shown) { transition in
                        LidTransitionRow(store: store, transition: transition) { look in pick(look, for: transition) }
                        if transition.id != shown.last?.id { Divider().padding(.leading, 14) }
                    }
                }
                .windowCard(padding: 0)
            }
        }
        .task(id: "\(store.isLive)-\(store.core.settings?.generation ?? 0)") { await load() }
    }

    private func load() async {
        guard store.isLive else { return }
        do {
            transitions = try await store.core.request("list_lid_presets", as: LidTransitionList.self).kinds
            unsupported = false
        } catch {
            unsupported = transitions.isEmpty
        }
    }

    private func pick(_ look: LidLook, for transition: LidTransition) {
        Task {
            do {
                let reply = try await store.core.setSetting(SettingsPath(transition.path), value: look.setting)
                if reply.ok {
                    store.show(status: "\(transition.label): \(look.name)")
                } else {
                    store.fail(reply.error?.message ?? "Lid look not changed")
                }
            } catch {
                store.fail("Lid look not changed: \(EffectStudioStore.describe(error))")
            }
        }
    }
}

private struct LidTransitionRow: View {
    @Bindable var store: EffectStudioStore
    let transition: LidTransition
    let pick: (LidLook) -> Void

    private var playing: LidLook? {
        transition.presets.first { $0.name == transition.current }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(transition.label).font(.body.weight(.medium))
                Text(transition.currentName).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    play()
                } label: {
                    Label("Play on strip", systemImage: "play.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(!store.isLive || playing == nil)
                .help(playing.map { "Play \($0.name) on the strip and the Dot" } ?? "Pick a look to play it")
            }
            // Five looks fit the room's width side by side; they wrap
            // onto a second line rather than scroll out of sight.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { thumbnails }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) { thumbnails(transition.presets.prefix(3)) }
                    HStack(spacing: 10) { thumbnails(transition.presets.dropFirst(3)) }
                }
            }
            .padding(.vertical, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var thumbnails: some View { thumbnails(transition.presets[...]) }

    private func thumbnails(_ looks: ArraySlice<LidLook>) -> some View {
        ForEach(Array(looks)) { look in
            LidLookThumbnail(look: look, selected: look.name == transition.current) { pick(look) }
        }
    }

    private func play() {
        guard let look = playing else { return }
        let run: @MainActor () -> Void = { [store, transition] in
            Task {
                do {
                    _ = try await store.core.request("play_lid_preset",
                                                     args: ["kind": .string(transition.kind), "name": .string(look.name)],
                                                     as: JSONValue.self)
                    store.show(status: "Playing \(look.name) on the strip")
                } catch {
                    store.fail("Play failed: \(EffectStudioStore.describe(error))")
                }
            }
        }
        if store.hardwareConsent {
            run()
        } else {
            store.pendingHardwarePlay = run
            store.askingConsent = true
        }
    }
}

/// A look's thumbnail: its program looping on a small strip, the Dot's
/// two-LED form beside Iris looks, and its name under it. The picked one
/// carries the accent ring.
private struct LidLookThumbnail: View {
    let look: LidLook
    let selected: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    LEDStripPreview(program: look.program, ledCount: 8, style: .dots, dotSize: 6, spacing: 4)
                        .frame(width: 96)
                    if look.shape != nil {
                        LEDStripPreview(program: look.dotProgram, ledCount: 2, style: .dots, dotSize: 6, spacing: 4)
                            .frame(width: 34)
                    }
                }
                Text(look.name).font(.caption).foregroundStyle(selected ? .primary : .secondary)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(look.name)\(selected ? ", picked" : "")")
        .help("Use \(look.name) (\(String(format: "%.1f", look.durationSeconds)) s)")
    }
}

/// `list_finish_looks`: the done celebration's looks, drawn in the done
/// colour for the Pro and the Dot, and the one in use.
struct FinishLookList: Decodable {
    struct Look: Decodable, Identifiable, Equatable {
        let style: String
        let label: String
        let program: String
        let dotProgram: String
        var id: String { style }

        enum CodingKeys: String, CodingKey {
            case style, label, program
            case dotProgram = "dot_program"
        }
    }

    let current: String
    let enabled: Bool
    let looks: [Look]
}

/// Effect Studio › Moments › Finish: how a finished session is celebrated
/// -- the shipped bloom, Land (a light falls to the far end, gathering
/// speed, and splashes: "it arrived") or Ripple (one ring out from the
/// middle). Picking one writes `colors.done_celebration_style`; the play
/// button shows it on the Screen Bar.
struct FinishMomentsSection: View {
    @Bindable var store: EffectStudioStore
    /// What to show before the monitor answers (a render proof's data).
    var seed: FinishLookList? = nil
    @ViewState private var loaded: FinishLookList?

    private var list: FinishLookList? { loaded ?? seed }

    static let meanings: [String: String] = [
        "bloom": "A spark crosses the strip, then it blooms in the done colour and fades.",
        "land": "A light falls to the far end, faster and faster, and lands with a splash.",
        "ripple": "One ring runs out from the middle, dimming as it goes.",
    ]

    var body: some View {
        if let list {
            VStack(alignment: .leading, spacing: 8) {
                MomentsSectionHeader(title: "Finish",
                                     detail: list.enabled
                                        ? "How the lights celebrate a session that finishes. It plays once and goes dark."
                                        : "How the lights celebrate a finish, once Settings › Lighting › Celebrate completions is on.")
                VStack(spacing: 0) {
                    ForEach(list.looks) { look in
                        finishRow(look, picked: look.style == list.current)
                        if look.id != list.looks.last?.id { Divider().padding(.leading, 14) }
                    }
                }
                .windowCard(padding: 0)
                .opacity(list.enabled ? 1 : 0.55)
            }
        } else {
            EmptyView()
                .task(id: "\(store.isLive)-\(store.core.settings?.generation ?? 0)") { await load() }
        }
    }

    private func finishRow(_ look: FinishLookList.Look, picked: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(picked ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(look.label).font(.body.weight(.medium))
                Text(Self.meanings[look.style] ?? "").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            LEDStripPreview(program: look.program, ledCount: 8, style: .band, dotSize: 7, spacing: 6)
                .frame(width: 150)
            Button {
                store.playFinish(look)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!store.isLive)
            .help("Play \(look.label) on the Screen Bar")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { pick(look) }
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
    }

    private func load() async {
        guard store.isLive else { return }
        loaded = try? await store.core.request("list_finish_looks", as: FinishLookList.self)
    }

    private func pick(_ look: FinishLookList.Look) {
        Task {
            do {
                let reply = try await store.core.setSetting("colors.done_celebration_style", value: .string(look.style))
                guard reply.ok else { store.fail(reply.error?.message ?? "Finish not changed"); return }
                loaded = try? await store.core.request("list_finish_looks", as: FinishLookList.self)
            } catch {
                store.fail("Finish not changed: \(EffectStudioStore.describe(error))")
            }
        }
    }
}

/// A Moments section's title and its one-line explanation.
private struct MomentsSectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }
}

extension EffectStudioStore {
    /// Plays a finish look on the Screen Bar -- on-screen light, so no
    /// hardware consent -- through the same compiler clamp as everything.
    func playFinish(_ look: FinishLookList.Look) {
        guard let compiled = LEDSPresentationCompiler.compileProgram(look.program, ledCount: 8)?.result.program else {
            fail("The \(look.label) finish did not compile")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.core.previewProgramNow(surface: "screen_bar", program: compiled, seconds: 5)
                if reply.ok { self.show(status: "Playing \(look.label) on the Screen Bar") }
                else { self.fail(reply.error?.message ?? "Play refused") }
            } catch {
                self.fail("Play failed: \(Self.describe(error))")
            }
        }
    }
}

