import AppKit
import JRBarCore
import Observation
import SwiftUI

/// Notch Buddy (docs/TOYS.md): a tiny creature in the `NotchHUD` panel
/// that lives by the agent state — asleep under a nightcap when nothing
/// runs, pacing while sessions work (bouncing in place when three or
/// more work at once), waving amber while an ask is open, tumbling into
/// a slump on a failure, one hop on a completion. Reads `core.sessions`
/// only; off by default.
@MainActor
@Observable
final class NotchBuddyToy: Toy {
    let core: CoreModel
    /// The owning store; weak, the store keeps the toy.
    weak var store: ToysStore?
    /// `isOn` just flipped: the HUD shows or clears the buddy's slot.
    var onVisibilityChange: (@MainActor () -> Void)?

    /// While non-nil and in the future the buddy hops once.
    private(set) var hopUntil: Date?
    /// When the current wave began — the ask entrance and the "!" pop
    /// once from here. `mood(at:)` maintains it because the view is the
    /// only clock that ticks the mood.
    private(set) var wavingSince: Date?
    /// When the current slump began — the tumble-in rolls once from
    /// here. Same deal as `wavingSince`: `mood(at:)` maintains it.
    private(set) var slumpedSince: Date?
    /// How many asks have opened. They alternate deterministically: odd
    /// asks wave with the "!" overhead, even asks just lean in and hold
    /// your eye.
    private(set) var waveOrdinal = 0
    @ObservationIgnored private var lastDoneCount = 0

    init(core: CoreModel) {
        self.core = core
        lastDoneCount = Self.doneCount(in: core.sessions)
        observeSessions()
    }

    let id = "notch-buddy"
    let name = "Notch Buddy"
    let blurb = "A little guy in the notch who lives by what your agents are doing."
    let symbol = "face.smiling"

    var isOn: Bool {
        get { store?.state.notchBuddy.enabled ?? false }
        set {
            store?.state.notchBuddy.enabled = newValue
            onVisibilityChange?()
        }
    }

    var status: ToyStatus { isOn ? .on : .off }

    /// "dot" is the only character so far; the enum is left open.
    var controls: AnyView {
        AnyView(
            Picker(selection: character) {
                Text("Dot").tag("dot")
            } label: {
                SettingLabel(title: "Character", subtitle: "The one resident for now.")
            }
            .pickerStyle(.menu)
            .fixedSize()
        )
    }

    private var character: Binding<String> {
        Binding(get: { self.store?.state.notchBuddy.character ?? "dot" },
                set: { self.store?.state.notchBuddy.character = $0 })
    }

    // MARK: Mood

    /// What the buddy is doing, in `SessionActivity`'s precedence: a live
    /// ask outranks a failure, a failure outranks work, work outranks
    /// sleep. Three or more working sessions is a `gathering`, not a
    /// patrol. A completion hops once and then the mood falls back.
    enum Mood: String, Sendable {
        case asleep, pacing, gathering, waving, slumped, celebrating
    }

    func mood(at now: Date = Date()) -> Mood {
        let mood = reducedMood(at: now)
        if mood == .waving {
            if wavingSince == nil { wavingSince = now; waveOrdinal += 1 }
        } else if wavingSince != nil {
            wavingSince = nil
        }
        if mood == .slumped {
            if slumpedSince == nil { slumpedSince = now }
        } else if slumpedSince != nil {
            slumpedSince = nil
        }
        return mood
    }

    /// The provider the buddy wears while it paces: the one running the
    /// work when a single provider owns it, else nil — split work falls
    /// back to the plain accent. Ask, failed and hop keep their own
    /// colours regardless.
    var workingProvider: String? {
        var provider: String?
        for session in core.sessions where SessionActivity.reduce(session) == .working {
            if let provider, provider != session.provider { return nil }
            provider = session.provider
        }
        return provider
    }

    /// What the buddy is doing, in `SessionActivity`'s precedence: a live
    /// ask outranks a failure, a failure outranks work, work outranks
    /// sleep. A completion hops once and then the mood falls back.
    private func reducedMood(at now: Date) -> Mood {
        if let hopUntil, now < hopUntil { return .celebrating }
        var mood = Mood.asleep
        var working = 0
        for session in core.sessions {
            switch SessionActivity.reduce(session) {
            case .waiting: return .waving
            case .failed: mood = .slumped
            case .working:
                working += 1
                if mood == .asleep { mood = .pacing }
            case .done, .ended, .idle: break
            }
        }
        // Three or more working at once: busy is exciting, not calm.
        if mood == .pacing, working >= 3 { return .gathering }
        return mood
    }

    private static func doneCount(in sessions: [CoreSession]) -> Int {
        sessions.filter { SessionActivity.reduce($0) == .done }.count
    }

    /// Watches the session list like `AppDelegate.observeCore`: one
    /// observation per change, coalesced into a main-queue turn. A rising
    /// done count is a completion, so the buddy hops once.
    private func observeSessions() {
        withObservationTracking {
            _ = core.sessions
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let done = Self.doneCount(in: self.core.sessions)
                if done > self.lastDoneCount { self.hopUntil = Date().addingTimeInterval(1.1) }
                self.lastDoneCount = done
                self.observeSessions()
            }
        }
    }
}
