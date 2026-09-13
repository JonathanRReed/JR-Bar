import AppKit
import JRBarCore
import Observation
import SwiftUI

/// Notch Buddy (docs/TOYS.md): a tiny creature in the `NotchHUD` panel
/// that lives by the agent state — asleep when nothing runs, pacing while
/// sessions work, waving amber while an ask is open, slumped on a
/// failure, one hop on a completion. Reads `core.sessions` only; off by
/// default.
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
    /// sleep. A completion hops once and then the mood falls back.
    enum Mood: String, Sendable {
        case asleep, pacing, waving, slumped, celebrating
    }

    func mood(at now: Date = Date()) -> Mood {
        if let hopUntil, now < hopUntil { return .celebrating }
        var mood = Mood.asleep
        for session in core.sessions {
            switch SessionActivity.reduce(session) {
            case .waiting: return .waving
            case .failed: mood = .slumped
            case .working: if mood == .asleep { mood = .pacing }
            case .done, .ended, .idle: break
            }
        }
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
