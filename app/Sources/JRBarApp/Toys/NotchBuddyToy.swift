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
    /// once from here. `summary(at:)` maintains it because the view is
    /// the only clock that ticks the mood.
    private(set) var wavingSince: Date?
    /// When the current slump began — the tumble-in rolls once from
    /// here. Same deal as `wavingSince`: `summary(at:)` maintains it.
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

    /// Everything the HUD reads off the session list in one tick — the
    /// pose, the badge counts, the tints and the hover line — so a tick
    /// pays for a single pass over `core.sessions` and the pieces can
    /// never disagree with each other.
    struct BuddySummary {
        /// The pose: a live ask outranks a failure, a failure outranks
        /// work, work outranks sleep; three or more working is a
        /// `gathering`, and a completion's hop overrides it all.
        var mood = Mood.asleep
        /// Sessions doing work — the feet badge's number once it's plural.
        var working = 0
        /// Asks open right now — the "!" wears the count past one.
        var waiting = 0
        /// Failed runs in the list — the slump and the "failed" count.
        var failed = 0
        /// The provider running the most working sessions — the badge's
        /// tint. A split house still answers, and the tie breaks on the
        /// provider id so the pick can't flicker between ticks.
        var dominantProvider: String?
        /// The one provider running all the work, nil when two or more
        /// share it — the pacing tint falls back to the accent there.
        /// Ask, failed and hop keep their own colours regardless.
        var workingProvider: String?
        /// The provider display names on the clock, in session order —
        /// the hover line's tail.
        var providers: [String] = []
        /// The hover line: "3 working · 1 waiting · Codex, Claude" —
        /// the counts first, then who's on the clock.
        var statusLine = "Nobody's running — it's asleep."
    }

    /// One pass over `core.sessions`: the mood, the counts, the tints
    /// and the hover line all fall out of the same
    /// `SessionActivity.reduce` calls. Also maintains the wave & slump
    /// clocks the one-off effects play from — the view's tick is the
    /// only clock that drives them.
    func summary(at now: Date = Date()) -> BuddySummary {
        var s = BuddySummary()
        var tally: [String: Int] = [:]
        var soleProvider: String?
        var splitWork = false
        for session in core.sessions {
            let activity = SessionActivity.reduce(session)
            switch activity {
            case .working:
                s.working += 1
                tally[session.provider, default: 0] += 1
                if let soleProvider, soleProvider != session.provider {
                    splitWork = true
                } else if soleProvider == nil {
                    soleProvider = session.provider
                }
            case .waiting: s.waiting += 1
            case .failed: s.failed += 1
            case .done, .ended, .idle: break
            }
            switch activity {
            case .working, .waiting, .failed:
                let name = ProviderStyle.style(for: session.provider).name
                if !s.providers.contains(name) { s.providers.append(name) }
            case .done, .ended, .idle: break
            }
        }
        s.dominantProvider = tally.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
        s.workingProvider = splitWork ? nil : soleProvider
        if s.waiting > 0 { s.mood = .waving }
        else if s.failed > 0 { s.mood = .slumped }
        // Three or more working at once: busy is exciting, not calm.
        else if s.working >= 3 { s.mood = .gathering }
        else if s.working > 0 { s.mood = .pacing }
        if let hopUntil, now < hopUntil { s.mood = .celebrating }
        if s.mood == .waving {
            if wavingSince == nil { wavingSince = now; waveOrdinal += 1 }
        } else if wavingSince != nil {
            wavingSince = nil
        }
        if s.mood == .slumped {
            if slumpedSince == nil { slumpedSince = now }
        } else if slumpedSince != nil {
            slumpedSince = nil
        }
        var parts: [String] = []
        if s.working > 0 { parts.append("\(s.working) working") }
        if s.waiting > 0 { parts.append("\(s.waiting) waiting") }
        if s.failed > 0 { parts.append("\(s.failed) failed") }
        if !s.providers.isEmpty { parts.append(s.providers.joined(separator: ", ")) }
        if !parts.isEmpty { s.statusLine = parts.joined(separator: " · ") }
        return s
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
    /// patrol pose. Reduce Motion stills the strip — pose stays — and
    /// the paused schedule keeps a stilled strip from ticking at all.
    private var roster: some View {
        TimelineView(.animation(paused: reduceMotion
                                || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { context in
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
