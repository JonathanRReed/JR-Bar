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

    var status: ToyStatus {
        guard isOn else { return .off }
        guard pickedEffect != nil else { return .unavailable("Pick an effect first") }
        switch fact?.state {
        case "playing": return .on
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
                LabeledContent {
                    Text(factText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } label: {
                    SettingLabel(title: "Right now", subtitle: "What the daemon is doing, live.")
                }
            }
        )
    }

    private var factText: String {
        switch fact?.state {
        case "playing":
            if let picked = pickedEffect, let label = effects.first(where: { $0.id == picked })?.label {
                return "playing \(label)"
            }
            return "playing"
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
