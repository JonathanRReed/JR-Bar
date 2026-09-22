import AppKit
import JRBarCore
import SwiftUI

// MARK: - The mark (pure)

/// A live agent session as the Dock and the switcher see it: which
/// provider, what it is doing, the ask it holds, and the app that hosts
/// its terminal. Built from the daemon's `CoreSession`; nothing here is
/// fetched — the Dock reads the same `state.sessions` the panel does.
struct DockAgentMark: Equatable, Identifiable {
    let sessionID: String
    let provider: String
    let providerName: String
    /// The panel's own label for the session — the type-ahead searches it.
    let label: String
    let cwd: String?
    /// `JR-Bar/app` — the panel's two-component tail, searched too.
    let cwdTail: String?
    let activity: SessionActivity
    /// The panel's humanised hook fact ("running Bash") for a working
    /// row; nil otherwise.
    let fact: String?
    let ask: CoreAsk?
    /// The bundle ids the session's window can live in — the terminal
    /// the daemon saw (`terminal.bundle_id`) and the IDE it came from
    /// (`origin.bundle_id`).
    let hosts: Set<String>
    let tty: String?

    var id: String { sessionID }

    /// An agent blocked on you — the "needs you" lane and the amber ring.
    var isWaiting: Bool { activity == .waiting }
    /// Waiting or working: the rows a close or quit must not kill on a
    /// single mis-press.
    var isLive: Bool { activity == .waiting || activity == .working }

    /// One line of what the agent is doing, for the zoom pane and the
    /// preview card: "Waiting on you", "running Bash", "Idle".
    var statusLine: String {
        if isWaiting {
            if let summary = ask?.summary.flatMap({ SessionRow.shortFact($0, limit: 60) }) {
                return summary
            }
            return SessionActivity.waiting.word
        }
        return fact ?? activity.word
    }

    /// The live, local, main sessions worth a mark: waiting, working or
    /// idle. Finished, ended and failed rows are history — they would
    /// only steal a cwd claim from the live run beside them — and a
    /// worker shares its parent's window (its label never titles one,
    /// its cwd would collide with the parent's). A remote row has no
    /// window on this Mac; a row with no host bundle has nowhere to look.
    static func marks(from sessions: [CoreSession], asks: [CoreAsk] = []) -> [DockAgentMark] {
        sessions.compactMap { session in
            guard !session.isRemote, !session.isSubagent else { return nil }
            let activity = SessionActivity.reduce(session)
            guard [.waiting, .working, .idle].contains(activity) else { return nil }
            var hosts = Set<String>()
            if let id = session.terminal?.bundleId, !id.isEmpty { hosts.insert(id) }
            if let id = session.origin?.bundleId, !id.isEmpty { hosts.insert(id) }
            guard !hosts.isEmpty else { return nil }
            return DockAgentMark(
                sessionID: session.id,
                provider: session.provider,
                providerName: session.providerName,
                label: session.displayLabel,
                cwd: session.cwd,
                cwdTail: session.cwd.map { SessionRow.tail(of: $0) },
                activity: activity,
                fact: SessionRow.activityFact(session: session, activity: activity),
                // The pinned ask carries the episode id an answer pins to;
                // an embedded one learns its session here, as the panel's
                // rows do, so Approve / Deny know whom they answer.
                ask: asks.first { $0.session == session.id } ?? session.ask.map { ask in
                    var ask = ask
                    ask.session = session.id
                    return ask
                },
                hosts: hosts,
                tty: session.terminal?.tty)
        }
    }

    /// The mark's colour — the provider accent the panel and the lights
    /// already use for this agent.
    var accent: Color { ProviderStyle.style(for: provider).accent }

    /// Lower first: the switcher's lane and the header count read it.
    var urgency: Int {
        switch activity {
        case .waiting: return 0
        case .working: return 1
        default: return 2
        }
    }
}

// MARK: - The match (pure, tested)

/// Which window hosts which agent session — the no-guess rule
/// `DockEnhanceMath.matchResult` applies to thumbnails, applied to the
/// daemon's sessions. A window *claims* a session when its title carries
/// something only that session would put there: the tty (Terminal and
/// iTerm can title with it), the session's own label (Claude Code and
/// Codex title the terminal with their topic), the full working
/// directory, or its last component. A pair matches only when the
/// window is the session's sole claimant at its strongest evidence AND
/// no other session claims that window as strongly. Two Ghostty windows
/// both titled `JR-Bar` get no mark; one does.
enum DockAgentMatch {
    /// One window a session could live in — a switcher row or a
    /// preview card, reduced to what the match reads.
    struct Candidate: Equatable {
        /// The caller's stable key (a switcher item id, a card id).
        let key: String
        /// The owning app's bundle id; nil is never a host.
        let bundleID: String?
        let title: String
    }

    /// How strongly a title names a session. Higher wins; a tie between
    /// two windows is ambiguity, never a coin flip.
    enum Evidence: Int, Comparable {
        case cwdLeaf = 1
        case cwdPath = 2
        case label = 3
        case tty = 4

        static func < (lhs: Evidence, rhs: Evidence) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The shortest needle a title may be searched for — "ai" or "x"
    /// inside a terminal title is noise, not evidence.
    static let minimumNeedle = 3

    /// The strongest evidence `title` carries for `mark`, or nil.
    static func evidence(title: String, for mark: DockAgentMark) -> Evidence? {
        let haystack = title.lowercased()
        guard !haystack.isEmpty else { return nil }
        if let tty = mark.tty.map(ttyName), tty.count >= minimumNeedle,
           containsToken(haystack, tty.lowercased()) {
            return .tty
        }
        let label = mark.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let leaf = mark.cwd.map { leafName(of: $0).lowercased() }
        // A label the daemon fell back to (the cwd's leaf, the provider's
        // own name) says nothing a cwd claim doesn't — it must not
        // outrank one.
        if label.count >= minimumNeedle, label != leaf,
           label != mark.providerName.lowercased(),
           containsToken(haystack, label) {
            return .label
        }
        if let cwd = mark.cwd, !cwd.isEmpty {
            for form in pathForms(cwd) where form.count >= minimumNeedle
                && containsToken(haystack, form.lowercased()) {
                return .cwdPath
            }
            if let leaf, leaf.count >= minimumNeedle, containsToken(haystack, leaf) {
                return .cwdLeaf
            }
        }
        return nil
    }

    /// candidate key → the one session it hosts. Only exclusive pairs
    /// survive: see the type's comment for the rule.
    static func match(marks: [DockAgentMark], candidates: [Candidate]) -> [String: DockAgentMark] {
        // Every (session, window, evidence) claim, host-filtered.
        var claims: [(mark: Int, window: Int, evidence: Evidence)] = []
        for (m, mark) in marks.enumerated() {
            for (w, candidate) in candidates.enumerated() {
                guard let bundle = candidate.bundleID, mark.hosts.contains(bundle),
                      let evidence = evidence(title: candidate.title, for: mark) else { continue }
                claims.append((m, w, evidence))
            }
        }
        var result: [String: DockAgentMark] = [:]
        for m in marks.indices {
            let mine = claims.filter { $0.mark == m }
            guard let best = mine.map(\.evidence).max() else { continue }
            let top = mine.filter { $0.evidence == best }
            // The session's sole strongest claimant…
            guard top.count == 1 else { continue }
            let window = top[0].window
            // …and nobody else's claim on that window is as strong.
            let rivals = claims.filter { $0.window == window && $0.mark != m && $0.evidence >= best }
            guard rivals.isEmpty else { continue }
            result[candidates[window].key] = marks[m]
        }
        return result
    }

    /// session id → candidate key: the locator's direction.
    static func windows(for marks: [DockAgentMark], candidates: [Candidate]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, mark) in match(marks: marks, candidates: candidates) { out[mark.sessionID] = key }
        return out
    }

    /// The header's line for a previewed app: "1 agent waiting",
    /// "2 agents working" — the most urgent state's count only, so a
    /// header never grows a sentence. nil with no live mark.
    static func headerSummary(_ marks: [DockAgentMark]) -> String? {
        let waiting = marks.filter(\.isWaiting).count
        if waiting > 0 { return waiting == 1 ? "1 agent waiting" : "\(waiting) agents waiting" }
        let working = marks.filter { $0.activity == .working }.count
        if working > 0 { return working == 1 ? "1 agent working" : "\(working) agents working" }
        return nil
    }

    // MARK: Text helpers

    /// `/dev/ttys003` → `ttys003`.
    static func ttyName(_ tty: String) -> String {
        tty.split(separator: "/").last.map(String.init) ?? tty
    }

    static func leafName(of path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    /// The ways a terminal writes a directory into its title: the full
    /// path and the home-collapsed `~/…` form.
    static func pathForms(_ path: String, home: String = NSHomeDirectory()) -> [String] {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        var forms = [trimmed]
        if trimmed.hasPrefix(home + "/") { forms.append("~" + trimmed.dropFirst(home.count)) }
        return forms
    }

    /// `needle` inside `haystack` on token boundaries: `JR-Bar` does not
    /// claim a window titled `JR-Bar-old`, `app` not one titled `apple`.
    static func containsToken(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let before = range.lowerBound == haystack.startIndex
                ? nil : haystack[haystack.index(before: range.lowerBound)]
            let after = range.upperBound == haystack.endIndex ? nil : haystack[range.upperBound]
            if !isWordCharacter(before), !isWordCharacter(after) { return true }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return false
    }

    private static func isWordCharacter(_ c: Character?) -> Bool {
        guard let c else { return false }
        return c.isLetter || c.isNumber || c == "-" || c == "_"
    }
}

// MARK: - The second press (pure, tested)

/// The guard on verbs that would kill a live agent: ⌘W or ⌘Q in the
/// switcher, × or Quit on a preview, a ⌘-right-click quit. The first
/// press only arms (the caller rings the card in the provider's colour
/// and says what a second press will do); the same press again within
/// `window` goes through. Anything else — another verb, another row, a
/// pause — starts over, so a stray double-tap on the wrong card never
/// confirms the first.
struct DockAgentGuard {
    static let window: TimeInterval = 2

    private(set) var armedKey: String?
    private var armedAt: TimeInterval = 0

    /// True when the verb may run now. `guarded` false (nothing live
    /// there) always runs and disarms.
    mutating func confirm(_ key: String, guarded: Bool, now: TimeInterval) -> Bool {
        guard guarded else {
            armedKey = nil
            return true
        }
        if armedKey == key, now - armedAt <= Self.window {
            armedKey = nil
            return true
        }
        armedKey = key
        armedAt = now
        return false
    }

    func isArmed(_ key: String, now: TimeInterval) -> Bool {
        armedKey == key && now - armedAt <= Self.window
    }

    mutating func reset() { armedKey = nil }

    /// The line the armed card shows: "Claude is waiting on you here —
    /// ⌘W again to close".
    static func note(for mark: DockAgentMark, again: String) -> String {
        let state = mark.isWaiting ? "waiting on you" : "working"
        return "\(mark.providerName) is \(state) here — \(again)"
    }
}

// MARK: - The mark on screen

/// The agent mark a card or switcher entry draws — a provider-coloured
/// dot, never a word. Waiting fills it and adds a hairline so it reads
/// on any still; working is the quiet outline.
struct DockAgentDot: View {
    let mark: DockAgentMark
    var size: CGFloat = 9

    var body: some View {
        Group {
            if mark.isWaiting {
                Circle()
                    .fill(mark.accent)
                    .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1))
            } else {
                Circle()
                    .strokeBorder(mark.accent, lineWidth: 1.5)
                    .background(Circle().fill(.black.opacity(0.25)))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(mark.providerName): \(mark.statusLine)")
    }
}
