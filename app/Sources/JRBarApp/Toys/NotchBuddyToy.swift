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
///
/// It is also a small pet: the pill is clickable (the panel only
/// ignores the mouse while a toast holds it), a tap counts as a pet and
/// cycles a trick — hop, spin, wave, blush — and while an ask is open
/// the tap does something useful too: it opens the session asking. The
/// card can name it and feed it, completed sessions land as crumbs it
/// "eats", and a day without a pat leaves it drooping.
@MainActor
@Observable
final class NotchBuddyToy: Toy {
    let core: CoreModel
    /// The owning store; weak, the store keeps the toy.
    weak var store: ToysStore?
    /// `isOn` just flipped: the HUD shows or clears the buddy's slot.
    var onVisibilityChange: (@MainActor () -> Void)?

    /// While non-nil and in the future the buddy hops once. Completions
    /// and treats both hop.
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
    /// How many taps have landed — the tricks cycle through the
    /// repertoire so repeated pats never repeat the same one twice.
    private(set) var trickOrdinal = 0
    /// Which trick is up this tap.
    private(set) var trickKind: BuddyTrick.Kind = .hop
    /// When the current trick began; the view ages it out.
    private(set) var trickStartedAt: Date?
    /// When the last treat landed — the hearts burst plays from here.
    private(set) var treatBurstAt: Date?
    /// When it last ate a completion crumb — the "+1" plays from here.
    private(set) var crumbAt: Date?
    /// -1 until the first sessions document lands: that one is the
    /// baseline — sessions already done when the app launches are
    /// history, not a feast.
    @ObservationIgnored private var lastDoneCount = -1

    init(core: CoreModel) {
        self.core = core
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

    /// The card's name field writes straight into the settings blob;
    /// blank keeps the character's own `defaultName`.
    var nameBinding: Binding<String> {
        Binding(get: { self.store?.state.notchBuddy.buddyName ?? "" },
                set: { self.store?.state.notchBuddy.buddyName = $0 })
    }

    /// Who the status line and the accessibility label name.
    var buddyName: String {
        store?.state.notchBuddy.resolvedName ?? buddyCharacter.defaultName
    }

    // MARK: Interaction

    /// A tap on the buddy. Always a pet; unless Reduce Motion is on it
    /// also cycles a trick. And it is not just a trick machine: while an
    /// ask is open the tap opens the session doing the asking — that is
    /// where the answer lives.
    func tapped(at now: Date = Date()) {
        store?.state.notchBuddy.care.pet(at: now)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            trickKind = BuddyTrick.Kind.allCases[trickOrdinal % BuddyTrick.Kind.allCases.count]
            trickOrdinal += 1
            trickStartedAt = now
        }
        // The longest-waiting ask first; an embedded ask with no
        // `openedAt` sorts as never-opened and lands last.
        if let asking = core.sessions
            .filter({ SessionActivity.reduce($0) == .waiting })
            .min(by: { ($0.ask?.openedAt ?? .infinity) < ($1.ask?.openedAt ?? .infinity) }) {
            core.openSession(asking.id)
        }
    }

    /// The card's "Give treat": fed for a while, hearts off the crown,
    /// and the hop borrowed from completions when motion is allowed.
    func giveTreat(at now: Date = Date()) {
        store?.state.notchBuddy.care.feed(at: now)
        treatBurstAt = now
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            hopUntil = now.addingTimeInterval(1.1)
        }
    }

    /// The card's friendship line under the treat button.
    var careLine: String {
        guard let care = store?.state.notchBuddy.care else { return "" }
        let pets = care.petCount == 1 ? "1 pet" : "\(care.petCount) pets"
        let crumbs = care.crumbsEaten == 1 ? "1 crumb" : "\(care.crumbsEaten) crumbs"
        switch care.mood(at: Date()) {
        case .fed: return "Blissed out — \(pets), \(crumbs)"
        case .missing: return "Misses you — \(pets), \(crumbs)"
        case .content:
            if care.petCount == 0, care.crumbsEaten == 0 {
                return "Never petted. It doesn't mind yet."
            }
            return "\(pets) · \(crumbs)"
        }
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
        /// What the buddy is called — the status line's subject.
        var name = ""
        /// How the friendship is doing — the pose's droop or blush.
        var care: BuddyCare.Mood = .content
        /// The hover line: "Pixel is watching · 3 working · 1 waiting ·
        /// Codex, Claude" — the name first, then who's on the clock.
        var statusLine = ""
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
        s.care = store?.state.notchBuddy.care.mood(at: now) ?? .content
        s.name = buddyName
        var parts: [String] = []
        if s.working > 0 { parts.append("\(s.working) working") }
        if s.waiting > 0 { parts.append("\(s.waiting) waiting") }
        if s.failed > 0 { parts.append("\(s.failed) failed") }
        if !s.providers.isEmpty { parts.append(s.providers.joined(separator: ", ")) }
        if parts.isEmpty {
            s.statusLine = s.care == .missing
                ? "\(s.name) misses you — tap it to say hi."
                : "\(s.name) is asleep."
        } else {
            s.statusLine = "\(s.name) is watching · " + parts.joined(separator: " · ")
            if s.care == .missing { s.statusLine += " · misses you" }
        }
        return s
    }

    private static func doneCount(in sessions: [CoreSession]) -> Int {
        sessions.filter { SessionActivity.reduce($0) == .done }.count
    }

    /// Watches the session list like `AppDelegate.observeCore`: one
    /// observation per change, coalesced into a main-queue turn. A rising
    /// done count is a completion, so the buddy hops once — and eats the
    /// completion as a crumb, which is as close to hunger as a menu-bar
    /// pet gets.
    private func observeSessions() {
        withObservationTracking {
            _ = core.sessions
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = Date()
                let done = Self.doneCount(in: self.core.sessions)
                if self.lastDoneCount >= 0, done > self.lastDoneCount {
                    self.hopUntil = now.addingTimeInterval(1.1)
                    self.crumbAt = now
                    self.store?.state.notchBuddy.care.eat(at: now, count: done - self.lastDoneCount)
                }
                self.lastDoneCount = done
                self.observeSessions()
            }
        }
    }
}

/// The card's disclosure body: the roster picker (a menu, like the Fold
/// card's "Render with"), a live strip — every buddy pacing in place,
/// the picked one lit, tap to choose — then the pet half: a name field
/// (blank keeps the character's own), a "Give treat" button that bursts
/// hearts over the button and the buddy alike, and the friendship line.
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

            LabeledContent {
                TextField("", text: toy.nameBinding, prompt: Text(toy.buddyCharacter.defaultName))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            } label: {
                SettingLabel(title: "Name", subtitle: "What it answers to. Blank keeps \(toy.buddyCharacter.defaultName).")
            }

            HStack(spacing: 10) {
                Button("Give treat") { toy.giveTreat() }
                    .controlSize(.small)
                    .overlay(alignment: .top) { treatHearts }
                Text(toy.careLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The treat's hearts, replayed over the button — the buddy in the
    /// notch gets its own burst from the same clock. Reads
    /// `toy.treatBurstAt` in the body so the press itself re-renders.
    private var treatHearts: some View {
        let burstAt = toy.treatBurstAt
        return TimelineView(.animation(paused: reduceMotion
                                       || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { context in
            let age = burstAt.map { context.date.timeIntervalSince($0) } ?? .infinity
            ZStack {
                if age < 0.9 {
                    ForEach(0..<3, id: \.self) { i in
                        let p = min(1, max(0, (age - Double(i) * 0.09) / 0.65))
                        Image(systemName: "heart.fill")
                            .font(.system(size: [4.5, 6.0, 5.0][i], weight: .bold))
                            .foregroundStyle(.pink)
                            .offset(x: [-7.0, 0.5, 7.0][i], y: -4 - p * 15)
                            .opacity(p <= 0 ? 0 : (p > 0.55 ? (1 - p) / 0.45 : 0.95))
                    }
                }
            }
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
                           still: reduceMotion, askCount: 0, care: .content,
                           trick: nil, treatAge: nil, crumbAge: nil)
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
