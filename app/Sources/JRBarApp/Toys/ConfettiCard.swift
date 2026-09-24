import AppKit
import JRBarCore
import SwiftUI

/// The card's disclosure body. Every row writes `store.state.confetti`
/// (which persists itself); "Test burst" fires with whatever is set.
struct ConfettiControlsView: View {
    let toy: ConfettiToy

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ConfettiSwatch(settings: toy.settings)
                .frame(height: 64)
                .padding(.vertical, 4)

            LabeledContent {
                Button("Test burst") { [weak toy] in
                    toy?.testBurst(providerColor: ConfettiView.toysTint)
                }
            } label: {
                SettingLabel(title: "Try it", subtitle: "Fires a burst now, with the settings below.")
            }

            Divider()
                .padding(.vertical, 4)

            SettingLabel(title: "Triggers", subtitle: "What earns a burst. The defaults are what it has always done.")

            Toggle(isOn: toy.bind(\.triggers.weeklyReset)) {
                SettingLabel(title: "Weekly reset", subtitle: "Any provider's weekly window refills.")
            }

            Toggle(isOn: toy.bind(\.triggers.sessionCompleted)) {
                SettingLabel(title: "Session completed", subtitle: "An agent finishes a run.")
            }

            Toggle(isOn: toy.bind(\.triggers.allClear)) {
                SettingLabel(title: "All caught up", subtitle: "The last open ask resolves — nothing left waiting on you.")
            }

            Toggle(isOn: toy.bind(\.triggers.codexBankedReset)) {
                SettingLabel(title: "Codex banked credits", subtitle: "The banked-credit balance grows.")
            }

            Toggle(isOn: toy.bind(\.triggers.milestones)) {
                SettingLabel(title: "Milestones", subtitle: "An Aquarium achievement or a new tank level — rare on purpose.")
            }

            if !providerChoices.isEmpty {
                Text("Every reset from")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(providerChoices, id: \.self) { id in
                    Toggle(isOn: providerBinding(id)) {
                        SettingLabel(title: ProviderStyle.style(for: id).name,
                                     subtitle: "Any window refill — the five-hour one included.")
                    }
                }
            }

            Divider()
                .padding(.vertical, 4)

            Toggle(isOn: toy.hushBinding) {
                SettingLabel(title: "Quiet the toys during Focus, quiet hours and calls",
                             subtitle: "While JR-Bar is quiet, a Focus is on or a call has the mic or camera, bursts wait and screens a fullscreen app owns are skipped. The buddy skips its completion hop, the tank saves its reward cards for later and the hinge stays silent.")
            }

            if toy.hushBinding.wrappedValue {
                Picker(selection: toy.bind(\.whenHeld)) {
                    Text("Play it smaller after").tag(ConfettiHeldBurst.later)
                    Text("Let it go").tag(ConfettiHeldBurst.drop)
                } label: {
                    SettingLabel(title: "A held burst", subtitle: "What happens once the room clears. Anything held over half an hour is let go.")
                }
                .pickerStyle(.menu)
            }

            Toggle(isOn: toy.bind(\.sound)) {
                SettingLabel(title: "Sound", subtitle: "A soft pop and rustle with the burst. Silent while JR-Bar is quiet.")
            }

            Divider()
                .padding(.vertical, 4)

            Picker(selection: toy.bind(\.landing)) {
                Text("Rest").tag(ConfettiLanding.rest)
                Text("Fall").tag(ConfettiLanding.fall)
                Text("Fade").tag(ConfettiLanding.fade)
            } label: {
                SettingLabel(title: "Landing", subtitle: "Where the pieces end up.")
            }
            .pickerStyle(.segmented)

            Text(landingNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker(selection: toy.bind(\.palette)) {
                Text("Provider").tag(ConfettiPalette.provider)
                Text("Toys tint").tag(ConfettiPalette.toys)
                Text("Rainbow").tag(ConfettiPalette.rainbow)
            } label: {
                SettingLabel(title: "Palette", subtitle: "Whose colours the burst wears.")
            }
            .pickerStyle(.menu)

            Picker(selection: toy.bind(\.shapes)) {
                Text("Mixed").tag(ConfettiShapes.mixed)
                Text("Streamers").tag(ConfettiShapes.streamers)
                Text("Flecks").tag(ConfettiShapes.flecks)
            } label: {
                SettingLabel(title: "Shapes", subtitle: "The full mix, or one note played loud.")
            }
            .pickerStyle(.menu)

            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: toy.bind(\.density), in: 0.5...2, step: 0.1)
                        .frame(width: 180)
                    ValueText(text: String(format: "%.1f×", toy.settings.density))
                }
            } label: {
                SettingLabel(title: "Density", subtitle: "How many pieces the cannon throws.")
            }

            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: toy.bind(\.duration), in: 0.7...1.5)
                        .frame(width: 180)
                    ValueText(text: String(format: "%.1f×", toy.settings.duration))
                }
            } label: {
                SettingLabel(title: "Duration", subtitle: "Stretches the whole burst — longer lingers.")
            }
        }
    }

    /// The line under the segmented picker, describing the mode that's
    /// on — it swaps with the selection, like the Fold card's provider
    /// note.
    private var landingNote: String {
        switch toy.settings.landing {
        case .rest:
            return "Streamers settle on the strip and rest there as litter until the burst fades."
        case .fall:
            return "The overlay spans the screen; pieces rain to the bottom edge and fade out."
        case .fade:
            return "Pieces dissolve mid-air — never landing, gone by three-fifths of the way down."
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

/// The card's swatch: a still handful of the burst the settings would
/// throw — its palette on its shapes, scattered on a night tile — so a
/// pick shows what it means without firing anything. Deterministic, one
/// Canvas, no clock.
struct ConfettiSwatch: View {
    let settings: ConfettiSettings

    /// Where each piece lies, as fractions of the tile, with its turn.
    private static let scatter: [(x: Double, y: Double, turn: Double, size: Double)] = (0..<52).map { i in
        func hash(_ n: Double) -> Double {
            let h = sin(n * 12.9898 + 78.233) * 43758.5453
            return h - h.rounded(.down)
        }
        let n = Double(i)
        return (x: 0.03 + 0.94 * hash(n), y: 0.14 + 0.72 * hash(n + 40),
                turn: hash(n + 80) * .pi * 2, size: 6 + 4.5 * hash(n + 120))
    }

    var body: some View {
        let palette = ConfettiView.paletteColors(settings.palette, provider: ConfettiView.toysTint)
        let backs = palette.map(ConfettiView.deeper)
        Canvas { context, size in
            for (i, spot) in Self.scatter.enumerated() {
                let shape = Self.shape(i, for: settings.shapes)
                let slot = i % palette.count
                var c = context
                c.translateBy(x: spot.x * size.width, y: spot.y * size.height)
                c.rotate(by: .radians(spot.turn))
                c.scaleBy(x: spot.size, y: spot.size * (i % 3 == 0 ? 0.55 : 1))
                c.opacity = 0.95
                ConfettiView.paint(shape, in: &c, color: i % 3 == 0 ? backs[slot] : palette[slot],
                                   rim: palette[slot].mix(with: .white, by: 0.55), size: spot.size)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.20),
                                          Color(red: 0.16, green: 0.12, blue: 0.24)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    /// The shapes setting's mix, dealt out in a fixed order.
    private static func shape(_ i: Int, for shapes: ConfettiShapes) -> ConfettiView.Shape {
        switch shapes {
        case .streamers: return .streamer
        case .flecks: return i % 2 == 0 ? .diamond : .pacDot
        case .mixed:
            let deal: [ConfettiView.Shape] = [.rect, .dot, .rect, .streamer, .rect, .dot, .diamond,
                                              .rect, .streamer, .dot, .rect, .pacDot]
            return deal[i % deal.count]
        }
    }
}
