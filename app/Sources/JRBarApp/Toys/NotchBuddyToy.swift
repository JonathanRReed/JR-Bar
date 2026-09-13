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

    var controls: AnyView {
        AnyView(BuddyControlsView(toy: self))
    }

    /// The roster pick, resolved through the settings' fallback — a file
    /// from a newer build keeps its string and reads as Dot here.
    var buddyCharacter: BuddyCharacter {
        store?.state.notchBuddy.resolvedCharacter ?? .dot
    }

    /// A binding into `store.state.notchBuddy.character` as the enum;
    /// the file keeps the raw string.
    var characterBinding: Binding<BuddyCharacter> {
        Binding(get: { self.buddyCharacter },
                set: { self.store?.state.notchBuddy.character = $0.rawValue })
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

    /// Live counts, reduced exactly the way the mood is — the badge and
    /// the "!" read these, so they can never disagree with the pose.
    private var activityCounts: (working: Int, waiting: Int, failed: Int) {
        var working = 0, waiting = 0, failed = 0
        for session in core.sessions {
            switch SessionActivity.reduce(session) {
            case .working: working += 1
            case .waiting: waiting += 1
            case .failed: failed += 1
            case .done, .ended, .idle: break
            }
        }
        return (working, waiting, failed)
    }

    /// Sessions doing work — the feet badge's number once it's plural.
    var workingCount: Int { activityCounts.working }
    /// Asks open right now — the "!" wears the count past one.
    var waitingCount: Int { activityCounts.waiting }

    /// The provider running the most working sessions — the badge's
    /// tint. Unlike `workingProvider` a split house still answers.
    var dominantProvider: String? {
        var tally: [String: Int] = [:]
        for session in core.sessions where SessionActivity.reduce(session) == .working {
            tally[session.provider, default: 0] += 1
        }
        return tally.max(by: { $0.value < $1.value })?.key
    }

    /// The hover line: "3 working · 1 waiting · Codex, Claude" — the
    /// counts first, then who's on the clock. Reads `core.sessions`
    /// only; the daemon is never asked for anything extra.
    var statusLine: String {
        let counts = activityCounts
        var parts: [String] = []
        if counts.working > 0 { parts.append("\(counts.working) working") }
        if counts.waiting > 0 { parts.append("\(counts.waiting) waiting") }
        if counts.failed > 0 { parts.append("\(counts.failed) failed") }
        var names: [String] = []
        for session in core.sessions {
            switch SessionActivity.reduce(session) {
            case .working, .waiting, .failed:
                let name = ProviderStyle.style(for: session.provider).name
                if !names.contains(name) { names.append(name) }
            case .done, .ended, .idle: break
            }
        }
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        return parts.isEmpty ? "Nobody's running — it's asleep." : parts.joined(separator: " · ")
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

/// The card's disclosure body: the roster picker (a menu, like the Fold
/// card's "Render with") plus a live strip — every buddy pacing in
/// place, the picked one lit, tap to choose.
private struct BuddyControlsView: View {
    let toy: NotchBuddyToy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: toy.characterBinding) {
                ForEach(BuddyCharacter.allCases, id: \.self) { c in
                    Text(c.displayName).tag(c)
                }
            } label: {
                SettingLabel(title: "Character", subtitle: "Who lives in your notch.")
            }
            .pickerStyle(.menu)
            .fixedSize()

            roster
        }
    }

    /// One cell per character, all on the same clock, all in the idle
    /// patrol pose. Reduce Motion stills the strip — pose stays.
    private var roster: some View {
        TimelineView(.animation) { context in
            HStack(spacing: 5) {
                ForEach(BuddyCharacter.allCases, id: \.self) { c in
                    cell(c, at: context.date)
                }
            }
        }
    }

    private func cell(_ c: BuddyCharacter, at now: Date) -> some View {
        let selected = toy.characterBinding.wrappedValue == c
        return BuddyFigure(character: c, mood: .pacing, tint: .accentColor,
                           phase: now.timeIntervalSince1970, hopProgress: nil,
                           waveAge: nil, slumpAge: nil, leans: false,
                           still: reduceMotion, askCount: 0)
            .frame(width: 18, height: 18)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onTapGesture { toy.characterBinding.wrappedValue = c }
            .help("\(c.displayName) — \(c.blurb)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(c.displayName)\(selected ? ", selected" : "")")
    }
}
