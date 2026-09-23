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

/// The Moments room of Effect Studio: every ambient cue by name, what it
/// means, when it plays, its switch where it has one, and a sketch that
/// can be played on the Screen Bar.
struct LightMomentsView: View {
    @Bindable var store: EffectStudioStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Moments").font(.title2.weight(.semibold))
                    Text("Short, content-free cues the lights layer over the agent state. Higher in the list wins when two want the light at once; all of them are clamped to 2 Hz and stand down for Quiet and low power. The sketches show each cue's shape — the monitor fits the exact frames to the event.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    ForEach(LightMoment.all) { moment in
                        MomentRow(store: store, moment: moment)
                        if moment.id != LightMoment.all.last?.id { Divider().padding(.leading, 44) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
            }
            .padding(18)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct MomentRow: View {
    @Bindable var store: EffectStudioStore
    let moment: LightMoment

    private var document: SettingsDocument { SettingsDocument(store.core.settings?.document ?? .object([:])) }
    private var isOn: Bool { moment.setting.map { document.bool(SettingsPath($0)) ?? false } ?? true }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: moment.symbol)
                .font(.system(size: 15))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(moment.name).font(.body.weight(.medium))
                Text(moment.meaning).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("\(moment.plays) · \(moment.surfaces.map(EffectInspectorPane.surfaceName).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    if let setting = moment.setting {
                        Toggle("On", isOn: Binding(
                            get: { isOn },
                            set: { on in
                                Task { try? await store.core.setSetting(SettingsPath(setting), value: .bool(on)) }
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .disabled(!store.isLive)
                        .help(isOn ? "Turn \(moment.name) off" : "Turn \(moment.name) on")
                    } else {
                        Text("Always on").font(.caption).foregroundStyle(.tertiary)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
