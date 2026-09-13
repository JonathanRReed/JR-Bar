import AppKit
import JRBarCore
import Observation
import SwiftUI

/// Screen Bar Screensaver (docs/TOYS.md): when the strip has sat idle
/// past a delay, the daemon plays one library effect instead of only
/// going dark. Everything on this card is a daemon setting written
/// through `SettingsStore` (`idle_screensaver_*`); the live
/// playing/waiting/off line is the daemon's own `state.ambient`
/// fact, and the effect picker rides the same `list_effects` catalog
/// the Effect Studio fetches — fetched once, refetched only when
/// `catalog_generation` moves.
@MainActor
@Observable
final class ScreensaverToy: Toy {
    let settings: SettingsStore
    /// The catalog's effects, for the picker. Empty until the first
    /// `list_effects` reply lands; the picker still shows the stored
    /// id so a saved choice never looks lost.
    private(set) var effects: [EffectDefinition] = []
    /// The daemon's message when a peek is refused; nil when the last
    /// one took (or none has run).
    private(set) var peekNote: String?
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var wasLive = false
    @ObservationIgnored private var seenGeneration: Int?

    init(settings: SettingsStore) {
        self.settings = settings
        observeCore()
    }

    /// `SettingsStore` already owns the `CoreModel` the daemon writes
    /// through; the toy reads live state and the effect list off it.
    private var core: CoreModel { settings.core }

    let id = "screensaver"
    let name = "Screen Bar Screensaver"
    let blurb = "When you've been gone a while, the bar plays something instead of just going dark."
    let symbol = "sparkles.tv"

    /// The card's switch is the daemon setting itself.
    var isOn: Bool {
        get { settings.document.bool(SettingsPath("idle_screensaver_enabled")) ?? false }
        set { settings.set("idle_screensaver_enabled", .bool(newValue)) }
    }

    /// The picked effect id, or nil when the document carries null.
    private var pickedEffect: String? {
        settings.document.string(SettingsPath("idle_screensaver_effect"))
    }

    /// `state.ambient.screensaver` — nil on a daemon that predates it.
    private var fact: CoreScreensaverStatus? {
        core.state?.ambient?.screensaver
    }

    private var afterMinutes: Int {
        if let seconds = fact?.afterSeconds, seconds > 0 { return seconds / 60 }
        return settings.document.int(SettingsPath("idle_screensaver_after_minutes")) ?? 20
    }

    private var waitingText: String {
        "waiting · idle \(Int((fact?.idleSeconds ?? 0) / 60))m of \(afterMinutes)m"
    }

    /// The picked effect's catalog entry — nil until `list_effects`
    /// lands, or when the saved id is not in this build's library.
    private var pickedDefinition: EffectDefinition? {
        guard let picked = pickedEffect else { return nil }
        return effects.first(where: { $0.id == picked })
    }

    /// The LEDS program the daemon plays for the pick at its defaults —
    /// the catalog's own render (`list_effects`' `preview.program`), so
    /// the band below is what the bar will actually play.
    private var previewProgram: String? {
        guard let program = pickedDefinition?.preview?.program
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !program.isEmpty else { return nil }
        return program
    }

    /// The LED count the band renders at: the connected strip's real
    /// count so the preview matches the hardware, 8 otherwise.
    private var previewLedCount: Int {
        let leds = core.devices.first(where: { $0.kind == "pro" && $0.isPresent })?.leds ?? 8
        return min(24, max(2, leds))
    }

    /// The daemon is playing the effect right now — on the delay or on a
    /// peek ("peeking" is the same light, the owner asked for it).
    private var playing: Bool {
        fact?.state == "playing" || fact?.state == "peeking"
    }

    var status: ToyStatus {
        guard isOn else { return .off }
        guard pickedEffect != nil else { return .unavailable("Pick an effect first") }
        switch fact?.state {
        case "playing", "peeking": return .on
        case "waiting": return .paused(waitingText)
        default: return .off
        }
    }

    var controls: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 4) {
                Provided(settings, "idle_screensaver_effect") {
                    LabeledContent {
                        let current = self.pickedEffect ?? ""
                        Picker(selection: self.settings.optionalString("idle_screensaver_effect", nilToken: "")) {
                            Text("None").tag("")
                            if !current.isEmpty, !self.effects.contains(where: { $0.id == current }) {
                                Text(current).tag(current)
                            }
                            ForEach(self.effects) { effect in
                                Text(effect.label).tag(effect.id)
                            }
                        } label: {
                            EmptyView()
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    } label: {
                        SettingLabel(title: "Effect",
                                     subtitle: "What plays once the delay is up. From the same library as the Effect Studio.")
                    }
                }
                SettingSlider(settings, "After",
                              subtitle: "How long the bar sits idle first, in minutes.",
                              path: "idle_screensaver_after_minutes",
                              in: 5...1440, step: 5, default: 20) { "\(Int($0)) min" }
                // What was picked, playing live — the catalog's own
                // render, so this band IS what the bar will play. No
                // program in the catalog → no dead strip, just no row.
                if let program = self.previewProgram {
                    LEDStripPreview(program: program,
                                    ledCount: self.previewLedCount,
                                    style: .band,
                                    dotSize: 10,
                                    cornerRadius: 8)
                        .padding(.vertical, 2)
                }
                LabeledContent {
                    Text(factText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } label: {
                    SettingLabel(title: "Right now", subtitle: "What the daemon is doing, live.")
                }
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 2) {
                        Button(self.playing ? "Playing…" : "Play it now") { self.peek() }
                            .controlSize(.small)
                            .disabled(self.playing || self.pickedEffect == nil || !self.core.isLive)
                        if let note = self.peekNote {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                } label: {
                    SettingLabel(title: "Try it",
                                 subtitle: "Plays the picked effect on the strip & bar for a few seconds, then hands back.")
                }
            }
        )
    }

    /// `screensaver_peek`: the daemon stages the picked effect on the
    /// real surfaces for a few seconds; the "Right now" fact carries the
    /// rest. A refusal keeps the daemon's own words, shown small.
    private func peek() {
        peekNote = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.core.screensaverPeek()
                if !reply.ok {
                    self.peekNote = reply.error?.message ?? reply.error?.code ?? "The daemon refused"
                }
            } catch {
                self.peekNote = "Couldn't reach the daemon"
            }
        }
    }

    private var factText: String {
        switch fact?.state {
        case "playing":
            if let picked = pickedEffect, let label = effects.first(where: { $0.id == picked })?.label {
                return "playing \(label)"
            }
            return "playing"
        case "peeking":
            if let label = pickedDefinition?.label {
                return "peeking · playing \(label)"
            }
            return "peeking"
        case "waiting": return waitingText
        case "off": return "off"
        default: return "the daemon hasn't said yet"
        }
    }

    // MARK: Catalog

    private func observeCore() {
        guard !observing else { return }
        observing = true
        track()
    }

    /// The same watch EffectStudioStore keeps: reload on connect and on
    /// every `catalog_generation` move, so a pack install shows up here
    /// without a second polling loop.
    private func track() {
        withObservationTracking {
            _ = core.isLive
            _ = core.state?.catalogGeneration
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let generation = self.core.state?.catalogGeneration
                if self.core.isLive, (!self.wasLive || generation != self.seenGeneration) {
                    self.seenGeneration = generation
                    self.reload()
                }
                self.wasLive = self.core.isLive
                self.track()
            }
        }
    }

    private func reload() {
        guard core.isLive, !loading else { return }
        loading = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.loading = false }
            if let catalog = try? await self.core.listEffects() {
                self.effects = catalog.effects
            }
        }
    }
}
