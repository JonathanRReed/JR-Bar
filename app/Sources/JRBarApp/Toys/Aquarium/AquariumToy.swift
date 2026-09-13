import AppKit
import JRBarCore
import Observation
import SwiftUI

/// Aquarium (docs/TOYS.md): every live session is a fish in a resizable
/// window — provider colour, label under it, swims at its own pace. An
/// ask brings the fish up to bob with a bubble, a failed run sinks
/// grey, a completion drifts off the edge. Reads `core.sessions` only;
/// the timeline pauses while the window is covered. Off by default.
@MainActor
@Observable
final class AquariumToy: Toy {
    let core: CoreModel
    /// The owning store; weak, the store keeps the toy.
    weak var store: ToysStore?

    /// The tank's current fish: `AquariumModel.reduce` applied to
    /// `core.sessions` whenever it changes. The view integrates motion
    /// from the frame clock, so this list only moves with the sessions.
    private(set) var fish: [Fish] = []

    /// The window is covered or hidden; the view pauses its timeline.
    var windowOccluded = false

    @ObservationIgnored private var windowController: AquariumWindowController?

    init(core: CoreModel, store: ToysStore) {
        self.core = core
        self.store = store
        refreshFish()
        observeSessions()
        // Left on at quit: the tank comes back at launch, without
        // stealing focus for it.
        if isOn { present(activate: false) }
    }

    let id = "aquarium"
    let name = "Aquarium"
    let blurb = "Every session is a fish. Asks come up for air."
    let symbol = "fish.fill"

    var isOn: Bool {
        get { store?.state.aquarium.enabled ?? false }
        set {
            store?.state.aquarium.enabled = newValue
            if newValue {
                present(activate: true)
            } else {
                windowController?.close()
            }
        }
    }

    var status: ToyStatus { isOn ? .on : .off }

    var controls: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: showLabels) {
                    SettingLabel(title: "Show labels", subtitle: "The session's name under its fish.")
                }
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: density, in: 0.25...2)
                            .frame(width: 180)
                        ValueText(text: String(format: "%.2f×", density.wrappedValue))
                    }
                } label: {
                    SettingLabel(title: "Density", subtitle: "How much plankton & bubbles the tank draws.")
                }
                LabeledContent {
                    Button("Fill screen") { self.fillScreen() }
                } label: {
                    SettingLabel(title: "Fill screen", subtitle: "The tank covers the whole screen. Esc leaves.")
                }
                LabeledContent {
                    Text(fact)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } label: {
                    SettingLabel(title: "In the tank")
                }
            }
        )
    }

    /// "4 fish · 1 at the surface" / "Nothing swimming yet" — a fact,
    /// like the status chip.
    private var fact: String {
        let now = Date()
        let live = fish.filter { !$0.isRetired(at: now) }
        guard !live.isEmpty else { return "Nothing swimming yet" }
        var parts = ["\(live.count) fish"]
        let surface = live.filter { $0.state == .surfacing }.count
        if surface > 0 { parts.append("\(surface) at the surface") }
        return parts.joined(separator: " · ")
    }

    private var showLabels: Binding<Bool> {
        Binding(get: { self.store?.state.aquarium.showLabels ?? true },
                set: { self.store?.state.aquarium.showLabels = $0 })
    }

    private var density: Binding<Double> {
        Binding(get: { self.store?.state.aquarium.density ?? 1 },
                set: { self.store?.state.aquarium.density = $0 })
    }

    // MARK: Window

    /// "Fill screen" opens the tank first when the toy is off — the
    /// button is a reason to look, not a trapdoor.
    func fillScreen() {
        if !isOn { isOn = true }
        windowController?.fillScreen()
    }

    private func present(activate: Bool) {
        let controller = windowController ?? AquariumWindowController(toy: self)
        windowController = controller
        controller.show(activate: activate)
    }

    /// The window's close button routes back through the store, so the
    /// card's toggle and the tank can never disagree.
    func windowDidClose() {
        windowController = nil
        windowOccluded = false
        store?.state.aquarium.enabled = false
    }

    // MARK: Fish

    private func refreshFish() {
        fish = AquariumModel.reduce(sessions: core.sessions, previous: fish, now: Date())
    }

    /// Watches the session list like `NotchBuddyToy`: one observation
    /// per change, coalesced into a main-queue turn.
    private func observeSessions() {
        withObservationTracking {
            _ = core.sessions
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshFish()
                self.observeSessions()
            }
        }
    }
}
