import Foundation

/// The island's transient capsules — Alcove's "instant notifications".
/// One daemon event that matters (`ask_opened`, `completed`, `failed`,
/// `quota_reset`) becomes an `AlcoveNotice`: an icon, a title, a
/// subtitle, shown for a couple of seconds before the island settles
/// back to its idle face. An ask is the exception: it holds the island
/// until it is answered, opened or swiped away. Which kinds may raise
/// one is the user's; `AlcoveCapsuleKinds` is the per-kind switchboard
/// `NotchSettings` persists.
///
/// The Mac's own announcements ride the same queue as kinds of their
/// own — a level key's answer, a Focus turning on, a device joining or
/// leaving, Caps Lock, a display arriving, a shelf timer coming due —
/// so one announcer owns the top of the screen and the cooldown and
/// priority rules police them all.
public enum AlcoveNoticeKind: String, Equatable, Sendable, CaseIterable {
    case ask
    case completed
    case failed
    case quotaReset
    /// The synthetic power capsule — no daemon event carries it; the
    /// toy's IOPS poller raises it on real battery transitions only.
    case charging
    /// A volume, brightness or keyboard-backlight key's answer: the
    /// level as one continuous fill. Feedback, not news — it overlays
    /// the island at once rather than waiting its turn.
    case level
    /// A Focus mode turning on or off.
    case focus
    /// A Bluetooth device connecting or disconnecting.
    case device
    /// Caps Lock flipping — feedback for the key just pressed.
    case capsLock
    /// A display arriving or leaving.
    case display
    /// A shelf timer came due.
    case timer
    /// A meeting with a join link is about to start — the calendar's
    /// heads-up, with Join (and the Mirror, for a last look).
    case meeting

    /// The SF Symbol the capsule's leading glyph draws. The tint is the
    /// view's business (amber / green / red / the provider's accent) —
    /// core names shapes, never colours. A notice may carry a `glyph`
    /// of its own (the Focus mode's, the device's) over this default.
    public var symbol: String {
        switch self {
        case .ask: return "exclamationmark.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .quotaReset: return "arrow.clockwise.circle.fill"
        case .charging: return "bolt.fill"
        case .level: return "speaker.wave.2.fill"
        case .focus: return "moon.fill"
        case .device: return "headphones"
        case .capsLock: return "capslock.fill"
        case .display: return "display"
        case .timer: return "timer"
        case .meeting: return "video.fill"
        }
    }

    /// The small second line under the title.
    public var verb: String {
        switch self {
        case .ask: return "needs you"
        case .completed: return "finished"
        case .failed: return "failed"
        case .quotaReset: return "quota reset"
        case .charging: return "power changed"
        case .level: return "level"
        case .focus: return "Focus changed"
        case .device: return "connected"
        case .capsLock: return "Caps Lock"
        case .display: return "display changed"
        case .timer: return "done"
        case .meeting: return "starting soon"
        }
    }

    /// How long a shown capsule of this kind holds before it steps
    /// down. nil is latched: an ask stays until it is answered, opened,
    /// swiped away or resolved elsewhere — the island is where the
    /// answer happens, so the question must still be there when the
    /// person looks up. A timer holds longer than news: it was set to
    /// be noticed.
    public var life: TimeInterval? {
        switch self {
        case .ask: return nil
        case .level, .capsLock: return AlcoveCapsuleQueue.feedbackLife
        case .timer: return AlcoveCapsuleQueue.timerLife
        case .meeting: return AlcoveCapsuleQueue.meetingLife
        case .completed, .failed, .quotaReset, .charging, .focus, .device, .display:
            return AlcoveCapsuleQueue.life
        }
    }

    /// Feedback for a key the person just pressed: it answers at once
    /// as the queue's overlay — never waiting behind news, never
    /// spending a cooldown — and a repeat press updates it in place.
    public var isFeedback: Bool { self == .level || self == .capsLock }

    /// The Mac's own announcements that wait in the line like news — a
    /// Focus, a device (the app's toasts ride this kind too), a display.
    /// `NotchHUD` offers them to the island and hangs its glass pill for
    /// any the island will not say, then or after the waiting slot gave
    /// them up. Feedback never waits, and the rest are the agents' news
    /// or the island's own.
    public var isMacAnnouncement: Bool { self == .focus || self == .device || self == .display }
}

/// One capsule's worth of copy, fully resolved: the view is a renderer,
/// so the title ("Claude · rename-the-fish") and subtitle ("needs you")
/// are built here, next to the event.
public struct AlcoveNotice: Equatable, Sendable, Identifiable {
    /// The event's id — unique per firing, so back-to-back capsules for
    /// the same session still animate in as new.
    public var id: String
    public var kind: AlcoveNoticeKind
    public var title: String
    public var subtitle: String
    /// The provider behind the event, for the glyph's accent when the
    /// kind has no colour of its own (quota_reset).
    public var provider: String?
    /// The session the capsule is about, when the event named one.
    public var session: String?
    /// The suppression identity: kind plus the session (or provider, for
    /// provider-scoped resets). A repeat inside the cooldown is strobe,
    /// not news.
    public var key: String
    /// The ask an ask capsule answers, as the event saw it — its
    /// `request` pins the answer to this episode, so a click can never
    /// approve whatever replaced it. Whether the buttons may show is
    /// read off the live ask (`NotchAskVerbs`); this snapshot carries
    /// the pin and the summary.
    public var ask: CoreAsk?
    /// A glyph of the notice's own over `kind.symbol` — the Focus
    /// mode's, the output device's, the display's.
    public var glyph: String?
    /// A level notice's reading, 0…1 — drawn as one continuous fill.
    public var fraction: Double?
    /// A level notice for a muted output: the slashed speaker and a
    /// dimmed fill.
    public var muted: Bool
    /// The ask reached the `takeover` tier: the island grows into the
    /// ask card and holds it until the person acts.
    public var takeover: Bool

    public init(id: String, kind: AlcoveNoticeKind, title: String, subtitle: String,
                provider: String? = nil, session: String? = nil, key: String,
                ask: CoreAsk? = nil, glyph: String? = nil, fraction: Double? = nil,
                muted: Bool = false, takeover: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.provider = provider
        self.session = session
        self.key = key
        self.ask = ask
        self.glyph = glyph
        self.fraction = fraction
        self.muted = muted
        self.takeover = takeover
    }

    /// The glyph the capsule draws.
    public var symbol: String { glyph ?? kind.symbol }
}

/// Which event kinds may raise a capsule — all on by default, since the
/// capsule is the island's job and each kind is already rare.
public struct AlcoveCapsuleKinds: Codable, Equatable, Sendable {
    public var ask: Bool
    public var completed: Bool
    public var failed: Bool
    public var quotaReset: Bool
    /// The synthetic power capsules (charger in/out, on battery, full).
    public var charging: Bool

    public init(ask: Bool = true, completed: Bool = true, failed: Bool = true,
                quotaReset: Bool = true, charging: Bool = true) {
        self.ask = ask
        self.completed = completed
        self.failed = failed
        self.quotaReset = quotaReset
        self.charging = charging
    }

    public func isOn(_ kind: AlcoveNoticeKind) -> Bool {
        switch kind {
        case .ask: return ask
        case .completed: return completed
        case .failed: return failed
        case .quotaReset: return quotaReset
        case .charging: return charging
        // The Mac's own announcements keep their switches on the notch
        // settings (`alerts`, `mediaHUD`), checked where they are
        // raised; a timer is the person's own ask to be told.
        // A meeting's heads-up has its own switch (`meetingAlerts`).
        case .level, .focus, .device, .capsLock, .display, .timer, .meeting: return true
        }
    }

    private enum CodingKeys: String, CodingKey {
        case ask, completed, failed, quotaReset, charging
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ask = (try? c.decodeIfPresent(Bool.self, forKey: .ask)) ?? true
        completed = (try? c.decodeIfPresent(Bool.self, forKey: .completed)) ?? true
        failed = (try? c.decodeIfPresent(Bool.self, forKey: .failed)) ?? true
        quotaReset = (try? c.decodeIfPresent(Bool.self, forKey: .quotaReset)) ?? true
        charging = (try? c.decodeIfPresent(Bool.self, forKey: .charging)) ?? true
    }
}

/// Event → notice, the same shape `EventPolicy.delivery` uses: read the
/// kind, resolve the session's label the way the notifications do, and
/// say nil for everything the island does not speak. `session` is the
/// caller's lookup of `event.session` against the applied state — an
/// event whose row is gone still capsulises on its own label.
public enum AlcoveEventPolicy {
    /// The kinds the island turns into capsules. `ask_resolved` is
    /// deliberately absent: taking a question away is not news, and the
    /// ask's own row already leaves the card.
    public static func notice(for event: CoreEvent, session: CoreSession?,
                              kinds: AlcoveCapsuleKinds) -> AlcoveNotice? {
        let kind: AlcoveNoticeKind
        switch event.kind {
        case "ask_opened": kind = .ask
        case "completed": kind = .completed
        case "failed": kind = .failed
        case "quota_reset": kind = .quotaReset
        default: return nil
        }
        guard kinds.isOn(kind) else { return nil }

        let provider = event.provider ?? session?.provider
        let providerName = provider.map { SessionLabel.providerName($0) }
        let label = event.label.flatMap { $0.isEmpty ? nil : $0 }
            ?? session?.displayLabel
            ?? providerName

        let title: String
        let subtitle: String
        if kind == .quotaReset {
            // No session, no label worth showing — the provider IS the
            // story, and the detail names the window that refilled.
            title = providerName ?? "Quota"
            subtitle = event.detail.flatMap { $0.isEmpty ? nil : $0 } ?? kind.verb
        } else {
            // "Claude · rename-the-fish" — unless the label IS the
            // provider name (a sessionless event, an unlabelled row),
            // where the join would only say it twice.
            if let providerName, let label,
               label.lowercased() != providerName.lowercased() {
                title = "\(providerName) · \(label)"
            } else {
                title = label ?? providerName ?? "Agent"
            }
            subtitle = event.detail.flatMap { $0.isEmpty ? nil : $0 }
                ?? (kind == .ask ? session?.ask?.summary : nil)
                ?? kind.verb
        }

        // An ask's identity is its episode: once one is answered, the
        // session's next request is news, not a repeat inside the
        // cooldown — so the pin joins the key when the event names one.
        var key = "\(kind.rawValue):\(event.session ?? provider ?? event.id)"
        if kind == .ask, let request = event.request, !request.isEmpty { key += "|\(request)" }
        return AlcoveNotice(id: event.id, kind: kind, title: title, subtitle: subtitle,
                            provider: provider, session: event.session, key: key,
                            ask: kind == .ask ? askSnapshot(for: event, session: session) : nil)
    }

    /// The ask an `ask_opened` capsule answers: the session's ask when
    /// the state already carries it, else one built from the event. The
    /// event's `request` is the pin either way — it names the episode
    /// this capsule is about, and the daemon refuses `stale_request`
    /// rather than approve whatever replaced it.
    static func askSnapshot(for event: CoreEvent, session: CoreSession?) -> CoreAsk {
        var ask = session?.ask ?? CoreAsk(summary: event.detail)
        ask.session = event.session
        if let request = event.request { ask.request = request }
        if ask.summary?.isEmpty != false, let detail = event.detail, !detail.isEmpty {
            ask.summary = detail
        }
        return ask
    }
}

/// What offering a notice did. The toy draws `queue.current` on `.now`,
/// after the gap on `.after`, and does nothing for the other two — the
/// queue has already recorded the notice either way.
public enum AlcoveCapsuleVerdict: Equatable, Sendable {
    /// Nothing is showing and the gap has passed: draw it now.
    case now
    /// Nothing is showing, but the last capsule ended too recently —
    /// draw it after this delay.
    case after(TimeInterval)
    /// A capsule is up; this one waits. At most one waits — newest wins.
    case queued
    /// Same kind and subject inside the cooldown: strobe, dropped.
    case suppressed
}

/// What `finish` decided about the next capsule.
public enum AlcoveCapsuleNext: Equatable, Sendable {
    /// The queue is empty — the island returns to idle.
    case idle
    case now(AlcoveNotice)
    /// The next capsule is already `current`; the delay is only the gap
    /// since the one that just ended started showing.
    case after(TimeInterval, AlcoveNotice)
}

/// The capsule pipeline, pure so a burst of asks can be tested without a
/// notch: one showing, at most one waiting (a second pending replaces
/// the first — the newest news wins), a 30 s cooldown per kind+subject,
/// and a minimum gap so successive capsules never strobe the notch.
/// The toy owns the timers; this owns the decisions.
///
/// Two slots sit beside the line. The overlay is feedback for a key the
/// person just pressed (a level, Caps Lock): it answers at once over
/// whatever transient face is up and never touches the line — but it
/// never covers a latched ask, whose buttons are the reason the island
/// is open. And a takeover jumps the line: the escalated ask becomes
/// the shown capsule, a waiting ask keeps its place behind it.
public struct AlcoveCapsuleQueue: Equatable, Sendable {
    /// Seconds a capsule holds before it steps down.
    public static let life: TimeInterval = 2.4
    /// Seconds a key's feedback holds — the system HUD's own beat.
    public static let feedbackLife: TimeInterval = 2.0
    /// Seconds a due timer's capsule holds: it was set to be noticed.
    public static let timerLife: TimeInterval = 8
    /// A meeting's heads-up holds long enough to reach Join from across
    /// the desk; the card's calendar row keeps Join after it steps down.
    public static let meetingLife: TimeInterval = 30
    /// The same kind about the same session/provider repeats inside this
    /// window are suppressed.
    public static let sameKeyCooldown: TimeInterval = 30
    /// The smallest gap between two capsules' show times.
    public static let minGap: TimeInterval = 1.2
    /// A waiting capsule this old is history, not news: it is dropped
    /// when its turn comes rather than shown late. A latched ask can
    /// hold the island for minutes, and "finished" from three minutes
    /// ago would only mislead — the card's rows already tell it. An ask
    /// never goes stale here; the toy checks it is still open instead.
    public static let pendingStaleAfter: TimeInterval = 30

    /// The capsule the island should be drawing (or is about to, on an
    /// `.after` verdict). The view reads the toy's copy of this.
    public private(set) var current: AlcoveNotice?
    /// The one waiting behind it; replaced, never stacked.
    public private(set) var pending: AlcoveNotice?
    /// Feedback drawn over the current face — see `present`.
    public private(set) var overlay: AlcoveNotice?
    /// kind+subject → when it was last accepted. Entries age out at
    /// `sameKeyCooldown`.
    public private(set) var recent: [String: Date] = [:]
    private var currentShownAt: Date?
    private var lastShownAt: Date?
    private var pendingAt: Date?
    /// Told about a waiting notice a newer one pushed out of the slot —
    /// an `offer` of the same or a higher rank, or a takeover parking
    /// the shown ask there. `.queued` promised the island would say it,
    /// so the owner hears when that promise lapses and can say it some
    /// other way. A waiting notice already past `pendingStaleAfter` is
    /// history and goes quietly, as `finish` would have dropped it, and
    /// so does one its own subject's next state replaced (`wait`).
    /// Resolved asks, a dismissal and a parked island are the person's
    /// or the island's own doing, not displacements, and report nothing.
    public var onEvict: (@Sendable (AlcoveNotice) -> Void)?

    public init() {}

    /// The line's state, not who is listening to it.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.current == rhs.current && lhs.pending == rhs.pending && lhs.overlay == rhs.overlay
            && lhs.recent == rhs.recent && lhs.currentShownAt == rhs.currentShownAt
            && lhs.lastShownAt == rhs.lastShownAt && lhs.pendingAt == rhs.pendingAt
            && lhs.held == rhs.held
    }

    /// Put `notice` in the waiting slot, reporting whatever it displaces
    /// — unless the newcomer is the same subject's next state. The Mac's
    /// announcements come as on/off pairs ("AirPods · Connected", then
    /// "Disconnected"); the older half is no longer true, and saying it
    /// now would say something false.
    private mutating func wait(_ notice: AlcoveNotice, at now: Date) {
        if let displaced = pending, displaced.id != notice.id,
           Self.subject(of: displaced.key) != Self.subject(of: notice.key) {
            let fresh = displaced.kind == .ask
                || pendingAt.map { now.timeIntervalSince($0) < Self.pendingStaleAfter } ?? true
            if fresh { onEvict?(displaced) }
        }
        pending = notice
        pendingAt = now
    }

    /// A notice key without its state: `device:AirPods:on` and
    /// `device:AirPods:off` are one subject. Every other key is its own.
    static func subject(of key: String) -> Substring {
        for state in [":on", ":off"] where key.hasSuffix(state) {
            return key.dropLast(state.count)
        }
        return key[...]
    }

    @discardableResult
    public mutating func offer(_ notice: AlcoveNotice, at now: Date) -> AlcoveCapsuleVerdict {
        recent = recent.filter { now.timeIntervalSince($0.value) < Self.sameKeyCooldown }
        if let seen = recent[notice.key], now.timeIntervalSince(seen) < Self.sameKeyCooldown {
            return .suppressed
        }
        recent[notice.key] = now
        guard current == nil else {
            wait(notice, at: now)
            return .queued
        }
        current = notice
        if let last = lastShownAt {
            let gap = now.timeIntervalSince(last)
            if gap < Self.minGap {
                currentShownAt = last.addingTimeInterval(Self.minGap)
                return .after(Self.minGap - gap)
            }
        }
        currentShownAt = now
        return .now
    }

    /// The shown capsule's run ended — held its `life`, or the toy let it
    /// go. Promotes the waiting one; the `.after` gap keeps a swipe-away
    /// from making the next capsule appear instantly on its heels.
    @discardableResult
    public mutating func finish(at now: Date) -> AlcoveCapsuleNext {
        guard current != nil else { return .idle }
        let shownAt = currentShownAt ?? now
        lastShownAt = shownAt
        current = nil
        currentShownAt = nil
        guard let next = pending else { return .idle }
        let waitedSince = pendingAt
        pending = nil
        pendingAt = nil
        if next.kind != .ask, let waitedSince,
           now.timeIntervalSince(waitedSince) >= Self.pendingStaleAfter {
            return .idle
        }
        current = next
        let elapsed = now.timeIntervalSince(shownAt)
        guard elapsed < Self.minGap else {
            currentShownAt = now
            return .now(next)
        }
        let delay = Self.minGap - elapsed
        currentShownAt = shownAt.addingTimeInterval(Self.minGap)
        return .after(delay, next)
    }

    /// The user flicked the island away: drop the shown capsule AND the
    /// waiting one. `finish` promotes; `cancel` clears — a dismiss is a
    /// "stop", not a "next".
    public mutating func cancel(at now: Date) {
        if let shownAt = currentShownAt { lastShownAt = shownAt }
        current = nil
        pending = nil
        pendingAt = nil
        currentShownAt = nil
    }

    /// The island parked: nothing in flight survives, but `recent` does —
    /// a re-show inside the cooldown must not replay a capsule the user
    /// just saw.
    public mutating func clear() {
        current = nil
        pending = nil
        pendingAt = nil
        overlay = nil
        currentShownAt = nil
        lastShownAt = nil
    }

    // MARK: Asks

    /// An ask was answered here or resolved elsewhere. A waiting capsule
    /// about it is dropped on the spot; the answer says whether the
    /// shown one is it — the toy then finishes that one, promoting
    /// whatever waits. `request` narrows the match to one episode when
    /// both sides name it: a resolution only closes its own ask.
    public mutating func resolveAsk(session: String, request: String?) -> Bool {
        func matches(_ notice: AlcoveNotice) -> Bool {
            guard notice.kind == .ask, notice.session == session else { return false }
            guard let request, let pinned = notice.ask?.request else { return true }
            return pinned == request
        }
        if let pending, matches(pending) {
            self.pending = nil
            pendingAt = nil
        }
        return current.map(matches) ?? false
    }

    /// The ask escalated to the takeover tier. The capsule already
    /// showing that ask grows in place; any other face steps aside — an
    /// ask that was up keeps its place in the waiting slot, ambient news
    /// is dropped (the card's rows still tell it). The takeover shows
    /// now, past the gap and the cooldown: it is the loudest thing the
    /// person allowed, and it holds until they act.
    public mutating func takeOver(_ notice: AlcoveNotice, at now: Date) {
        overlay = nil
        if var shown = current, shown.kind == .ask, shown.session == notice.session {
            shown.takeover = true
            current = shown
            return
        }
        if let shown = current, shown.kind == .ask {
            wait(shown, at: now)
        }
        var escalated = notice
        escalated.takeover = true
        current = escalated
        currentShownAt = now
        recent[escalated.key] = now
    }

    /// The takeover stood down (the asking pane came to the front): the
    /// shown ask shrinks back to its capsule and keeps holding.
    public mutating func releaseTakeover() {
        guard var shown = current, shown.takeover else { return }
        shown.takeover = false
        current = shown
    }

    // MARK: Quiet hold

    /// News held while the Mac is quiet (a Focus, a quiet mode) — kept
    /// in arrival order, bounded, replayed as one summary afterwards.
    public private(set) var held: [AlcoveNotice] = []
    public static let heldLimit = 50

    /// The kinds a quiet stretch holds back: news about work that went
    /// fine. Asks, failures, timers and the Mac's own announcements
    /// still speak — those are the things a person in a Focus still
    /// wants to know now.
    public static func holdsWhileQuiet(_ kind: AlcoveNoticeKind) -> Bool {
        kind == .completed || kind == .quotaReset
    }

    /// The quiet stretch `state.focus` describes, by the name a summary
    /// says it in — nil when nothing quiet is in effect. The daemon
    /// writes `mode: "off"` (never null, never "normal") for that, and
    /// names the source `focus` (a macOS Focus synced in), `override`
    /// (the quiet menu) or `schedule`. A Focus goes by its own name when
    /// the Mac's watcher knew it ("Work"), else plain "Focus".
    public static func quietContext(mode: String?, source: String?,
                                    focusName: String? = nil) -> String? {
        let mode = mode?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard !mode.isEmpty, mode != "off", mode != "normal" else { return nil }
        switch source?.lowercased() {
        case "focus":
            if let focusName, !focusName.isEmpty { return focusName }
            return "Focus"
        case "schedule": return "quiet hours"
        default: return "quiet mode"
        }
    }

    /// Hold `notice` for the summary instead of showing it. False when
    /// the kind is not one a quiet stretch holds.
    @discardableResult
    public mutating func hold(_ notice: AlcoveNotice) -> Bool {
        guard Self.holdsWhileQuiet(notice.kind) else { return false }
        held.append(notice)
        if held.count > Self.heldLimit { held.removeFirst(held.count - Self.heldLimit) }
        return true
    }

    /// The quiet stretch ended: everything held becomes one notice —
    /// "3 finished · 1 quota reset", titled with where the person was
    /// ("While you were in Work") — and the hold empties. nil when
    /// nothing was held.
    public mutating func releaseHeld(id: String, during context: String?) -> AlcoveNotice? {
        guard !held.isEmpty else { return nil }
        defer { held.removeAll() }
        return Self.summary(of: held, id: id, during: context)
    }

    public static func summary(of held: [AlcoveNotice], id: String,
                               during context: String?) -> AlcoveNotice? {
        let finished = held.filter { $0.kind == .completed }.count
        let resets = held.filter { $0.kind == .quotaReset }.count
        guard finished + resets > 0 else { return nil }
        var parts: [String] = []
        if finished > 0 { parts.append("\(finished) finished") }
        if resets > 0 { parts.append(resets == 1 ? "1 quota reset" : "\(resets) quota resets") }
        let title = context.map { "While you were in \($0)" } ?? "While you were away"
        // One finished run keeps its session, so a tap opens it.
        let single = held.count == 1 ? held.first?.session : nil
        return AlcoveNotice(id: id, kind: finished > 0 ? .completed : .quotaReset,
                            title: title, subtitle: parts.joined(separator: " · "),
                            provider: held.count == 1 ? held.first?.provider : nil,
                            session: single, key: "held:\(id)")
    }

    // MARK: Feedback

    /// Whether key feedback may draw over the island now: nothing is
    /// latched there. A shown or promoted ask keeps its face — its
    /// buttons are why the island is open — and feedback goes to the
    /// fallback pill instead.
    public var acceptsOverlay: Bool {
        guard let current else { return true }
        return current.kind.life != nil
    }

    /// A key's answer: drawn at once over the current face, replacing
    /// any feedback already up (a held volume key updates in place). No
    /// cooldown, no line, no gap — the person just pressed the key.
    /// False when the notice is not feedback or a latched ask holds the
    /// island.
    @discardableResult
    public mutating func present(_ notice: AlcoveNotice) -> Bool {
        guard notice.kind.isFeedback, acceptsOverlay else { return false }
        overlay = notice
        return true
    }

    /// The feedback's beat ended — the face under it shows again.
    public mutating func endOverlay() {
        overlay = nil
    }
}

/// What's playing, reduced to what the island draws: the title it must
/// have to exist, the artist, whether the visualizer bars may animate,
/// and the artwork bytes. `summarize` reads MediaRemote's now-playing
/// dictionary — whose keys are the constants' own names — so the app
/// side stays a thin dlopen shim.
public struct AlcoveMedia: Equatable, Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    public var playing: Bool
    /// `kMRMediaRemoteNowPlayingInfoArtworkData`, a PNG/JPEG payload.
    public var artworkData: Data?
    /// The now-playing app's bundle id when the source named one — the
    /// adapter reports it; the raw info dict does not carry it.
    public var bundleIdentifier: String?
    /// Track length in seconds — `kMRMediaRemoteNowPlayingInfoDuration`.
    public var duration: Double?
    /// The playhead at `timestamp` — `kMRMediaRemoteNowPlayingInfoElapsedTime`.
    public var elapsed: Double?
    /// When `elapsed` was true, as CFAbsoluteTime —
    /// `kMRMediaRemoteNowPlayingInfoTimestamp`. With `playing` it lets
    /// the playhead advance between pushes without a per-second line.
    public var timestamp: Double?

    public init(title: String, artist: String? = nil, album: String? = nil,
                playing: Bool, artworkData: Data? = nil, bundleIdentifier: String? = nil,
                duration: Double? = nil, elapsed: Double? = nil, timestamp: Double? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.playing = playing
        self.artworkData = artworkData
        self.bundleIdentifier = bundleIdentifier
        self.duration = duration
        self.elapsed = elapsed
        self.timestamp = timestamp
    }

    /// The playhead as of `date`: the sampled `elapsed` advanced by
    /// wall-clock drift while playing (rate ≈ 1 — MediaRemote reports
    /// the nominal speed for scrub-rate players, which overstates a
    /// slowed stream less than a dead playhead would understate it).
    /// nil when the source never named a playhead — the slider stays
    /// hidden rather than sit at 0:00 lying.
    public func liveElapsed(at date: Date = Date()) -> Double? {
        guard let elapsed else { return nil }
        var value = elapsed
        if playing, let timestamp, timestamp > 0 {
            value += max(0, date.timeIntervalSinceReferenceDate - timestamp)
        }
        if let duration, duration > 0 { value = min(value, duration) }
        return max(0, value)
    }

    /// "Title — Artist" for the idle strip; the title alone when the
    /// source named no artist.
    public var displayLine: String {
        if let artist, !artist.isEmpty { return "\(title) — \(artist)" }
        return title
    }

    /// nil when the info names no title — an empty now-playing dict is a
    /// player stopping, not a track. `isPlaying` is the caller's
    /// `MRMediaRemoteGetNowPlayingApplicationIsPlaying` answer when it
    /// has one; the info's playback rate is the fallback, and no signal
    /// at all reads as paused — still bars are the honest default.
    public static func summarize(_ info: [String: Any], isPlaying: Bool? = nil) -> AlcoveMedia? {
        func string(_ key: String) -> String? {
            guard let raw = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return raw
        }
        guard let title = string("kMRMediaRemoteNowPlayingInfoTitle") else { return nil }
        let rate = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue
        func seconds(_ key: String) -> Double? {
            guard let value = (info[key] as? NSNumber)?.doubleValue, value > 0 else { return nil }
            return value
        }
        let timestamp = (info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date)?
            .timeIntervalSinceReferenceDate
            ?? (info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? NSNumber)?.doubleValue
        return AlcoveMedia(title: title,
                           artist: string("kMRMediaRemoteNowPlayingInfoArtist"),
                           album: string("kMRMediaRemoteNowPlayingInfoAlbum"),
                           playing: isPlaying ?? (rate.map { $0 > 0 } ?? false),
                           artworkData: info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
                           duration: seconds("kMRMediaRemoteNowPlayingInfoDuration"),
                           elapsed: (info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?
                               .doubleValue,
                           timestamp: timestamp)
    }

    /// The perl adapter's line — the same now-playing dictionary, already
    /// reduced by the helper inside the entitled process to plain keys:
    /// `title` / `artist` / `album` / `playing` / `bundleIdentifier` /
    /// `artworkData` (base64). nil without a title, the same contract.
    public static func summarize(adapter payload: [String: Any]) -> AlcoveMedia? {
        func string(_ key: String) -> String? {
            guard let raw = (payload[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return raw
        }
        guard let title = string("title") else { return nil }
        return AlcoveMedia(title: title,
                           artist: string("artist"),
                           album: string("album"),
                           playing: (payload["playing"] as? Bool) ?? false,
                           artworkData: (payload["artworkData"] as? String).flatMap { Data(base64Encoded: $0) },
                           bundleIdentifier: string("bundleIdentifier"),
                           duration: (payload["duration"] as? NSNumber)?.doubleValue,
                           elapsed: (payload["elapsed"] as? NSNumber)?.doubleValue,
                           timestamp: (payload["timestamp"] as? NSNumber)?.doubleValue)
    }

    /// Music's own `com.apple.Music.playerInfo` distributed payload —
    /// `Name` / `Artist` / `Album` / `Player State` ("Playing"). Music
    /// posts it even on macOS releases where MediaRemote reads are
    /// gated, so it is the fallback that keeps the strip honest there.
    /// nil without a `Name`, or when the state says `Stopped`.
    public static func summarize(musicPlayerInfo payload: [String: Any]) -> AlcoveMedia? {
        func string(_ key: String) -> String? {
            guard let raw = (payload[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return raw
        }
        if let state = string("Player State"), state == "Stopped" { return nil }
        guard let title = string("Name") else { return nil }
        return AlcoveMedia(title: title,
                           artist: string("Artist"),
                           album: string("Album"),
                           playing: string("Player State") == "Playing",
                           bundleIdentifier: "com.apple.Music")
    }
}

/// One reading of the machine's power sources, reduced by the toy's IOPS
/// poll to what a transition notice needs. `hasBattery` false is a
/// desktop — nothing in it can ever change.
public struct AlcovePowerState: Equatable, Sendable {
    public var hasBattery: Bool
    /// External power connected (`Power Source State` == "AC Power").
    public var onAC: Bool
    /// `Is Charging` — distinct from `onAC`: a full battery on AC isn't
    /// charging, and a drained one on a weak adapter can sit on AC
    /// without gaining.
    public var charging: Bool
    /// `Current Capacity`, a percent for internal batteries.
    public var percent: Int?
    /// `Is Charged`, or full on AC.
    public var fullyCharged: Bool
    /// The system's own estimate in minutes: to empty on battery
    /// (`IOPSGetTimeRemainingEstimate`), to full while charging (`Time
    /// to Full Charge`). nil while macOS is still working it out.
    public var minutesRemaining: Int?

    public init(hasBattery: Bool, onAC: Bool, charging: Bool,
                percent: Int?, fullyCharged: Bool, minutesRemaining: Int? = nil) {
        self.hasBattery = hasBattery
        self.onAC = onAC
        self.charging = charging
        self.percent = percent
        self.fullyCharged = fullyCharged
        self.minutesRemaining = minutesRemaining
    }

    /// The percent rendered for a subtitle — "· 84%" or nothing.
    public var percentText: String {
        percent.map { " · \($0)%" } ?? ""
    }

    /// The battery glyph for the charge it actually holds — a bolt while
    /// charging, else the nearest quarter — never a fixed half battery.
    public var symbol: String {
        if charging { return "battery.100percent.bolt" }
        guard let percent else { return "battery.50percent" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// "1h 50m", "35m" — nil without an estimate.
    public var remainingText: String? {
        guard let minutes = minutesRemaining, minutes > 0 else { return nil }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// Everything but the estimate — the part a transition is about.
    /// The estimate moves on nearly every read and is never news.
    public var withoutEstimate: AlcovePowerState {
        var copy = self
        copy.minutesRemaining = nil
        return copy
    }
}

/// Battery transitions → a synthetic `.charging` capsule. Only real
/// transitions speak: the caller's first reading is a baseline and earns
/// nothing, a percent-only drift earns nothing, and a machine without a
/// battery is silent by construction.
public enum AlcovePower {
    /// The suppression key is constant — a plug/unplug flicker inside the
    /// queue's cooldown is strobe, not news.
    public static let noticeKey = "charging:power"

    /// The notice a transition earns, or nil. `id` is the caller's (the
    /// toy mints a UUID; tests pass a pin).
    public static func notice(from old: AlcovePowerState?, to new: AlcovePowerState,
                              id: String, kinds: AlcoveCapsuleKinds) -> AlcoveNotice? {
        guard let old, new.hasBattery, kinds.isOn(.charging) else { return nil }
        guard old != new else { return nil }
        // A battery appearing or disappearing entirely isn't worth a
        // capsule either way — only a state the user caused speaks.
        guard old.hasBattery else { return nil }
        let percent = new.percentText
        let subtitle: String
        if new.fullyCharged, !old.fullyCharged {
            subtitle = "Fully charged"
        } else if new.charging, !old.charging {
            subtitle = "Charging\(percent)"
        } else if new.onAC, !old.onAC {
            // On AC but not charging (held charge limit, weak adapter).
            subtitle = "On AC power\(percent)"
        } else if !new.onAC, old.onAC {
            subtitle = "On battery\(percent)"
        } else if new.charging != old.charging {
            subtitle = new.charging ? "Charging\(percent)" : "Not charging\(percent)"
        } else {
            return nil   // percent drift, time-to-full — not news
        }
        return AlcoveNotice(id: id, kind: .charging, title: "Power",
                            subtitle: subtitle, key: noticeKey)
    }

    /// The charge below which a battery running agents is worth a word.
    public static let lowThreshold = 20
    public static let lowKey = "charging:low"

    /// The one power notice only JR-Bar can give: the battery crossing
    /// under `lowThreshold` on battery while agents are working — will
    /// the long run survive unplugged? Silent with no agents working,
    /// on AC, or on any read that did not cross.
    public static func lowBatteryNotice(from old: AlcovePowerState, to new: AlcovePowerState,
                                        working: Int, id: String) -> AlcoveNotice? {
        guard working > 0, new.hasBattery, !new.onAC,
              let before = old.percent, let now = new.percent,
              before >= lowThreshold, now < lowThreshold else { return nil }
        var parts = ["\(now)%"]
        if let left = new.remainingText { parts.append("~\(left) left") }
        parts.append(working == 1 ? "1 agent working" : "\(working) agents working")
        return AlcoveNotice(id: id, kind: .charging, title: "Battery low",
                            subtitle: parts.joined(separator: " · "), key: lowKey,
                            glyph: "battery.25percent")
    }

    /// The card's battery line, agent-aware: "41% · ~1h 50m left · 3
    /// agents working · held awake" on battery; "84% · Charging · full
    /// in 35m" plugged in. The agent half only speaks while agents work.
    public static func batteryLine(_ state: AlcovePowerState, working: Int,
                                   heldAwake: Bool) -> String {
        var parts: [String] = []
        if let percent = state.percent { parts.append("\(percent)%") }
        if state.fullyCharged {
            parts.append("Charged")
        } else if state.charging {
            parts.append("Charging")
            if let left = state.remainingText { parts.append("full in \(left)") }
        } else if state.onAC {
            parts.append("On AC")
        } else {
            parts.append(state.remainingText.map { "~\($0) left" } ?? "On battery")
        }
        if working > 0 {
            parts.append(working == 1 ? "1 agent working" : "\(working) agents working")
        }
        if heldAwake { parts.append("held awake") }
        return parts.joined(separator: " · ")
    }
}

extension NotchIsland {
    /// Points of idle content a Now Playing strip adds: the artwork
    /// thumbnail, a truncated "title — artist", and the visualizer bars.
    /// Fixed, like every idle content measure — the panel's frame is its
    /// drawn shape, so the width is never measured off a live label.
    public static let mediaContentWidth: CGFloat = 148
    /// The gap between the session dots and the media strip.
    public static let mediaSeparatorWidth: CGFloat = 10

    /// The idle width with Now Playing and the privacy dots in it. The
    /// media strip and the sensor dots ride the same capsule as the
    /// provider dots; when nothing is working the capsule is the strip
    /// plus the resting dot.
    public static func idleContentWidth(_ summary: NotchIslandSummary, media: AlcoveMedia?,
                                        sensors: NotchSensorState = NotchSensorState()) -> CGFloat {
        var width = idleContentWidth(summary)
        if media != nil { width += mediaSeparatorWidth + mediaContentWidth }
        let dots = sensorDotsWidth(sensors)
        if dots > 0 { width += sensorSeparatorWidth + dots }
        return width
    }
}

extension NotchIslandLayout {
    /// Points the notice capsule reaches past each side of the notch
    /// slot — room for the glyph and one line of copy.
    public static let noticeShoulder: CGFloat = 50
    public static let noticeMinWidth: CGFloat = 240
    /// How far below the notch the bare notice capsule reaches — one
    /// line's worth of lip.
    public static let noticeLip: CGFloat = 22
    /// The clear room the notice line keeps between the bezel and a live
    /// Screen Bar's housing: the 11.5 pt line box (13.5 pt) or the
    /// kind's 11 pt glyph (14 pt), plus a point of air each side.
    public static let noticeLineRoom: CGFloat = 16
    /// The least black the Screen Bar's housing keeps above its strip —
    /// `ScreenBarGeometry.coupledLip` is this, so the island measures
    /// the same housing the bar draws.
    public static let housingLip: CGFloat = 4

    /// The notice face: a one-line capsule — the kind's glyph and the
    /// "Claude · rename-the-fish needs you" line — a touch wider and
    /// deeper than idle, still hung from the notch. Bare, it is the
    /// notch plus one line's lip. Under a live Screen Bar's housing
    /// (`restingRadius` is the island's resting corner) it is the notch,
    /// the line's room and the housing's climb over the island's bottom
    /// corners: a bare 22 pt lip left about half the line's cap height
    /// under the bar's black at the standard 8 pt corner, nearly all of
    /// it at a 16 pt one. The climb grows with the height, at most about
    /// half a point a point, so stepping up a point at a time clears the
    /// room in a few steps. The width is exactly the slot plus its
    /// shoulders — never more: a minimum that could outgrow
    /// notch-plus-wings would read as a panel, not the notch speaking.
    /// Notch-less screens get the fixed floating pill.
    public static func noticeSize(slotWidth: CGFloat, notchDepth: CGFloat,
                                  underHousing restingRadius: CGFloat? = nil) -> CGSize {
        let width = slotWidth > 0 ? slotWidth + 2 * noticeShoulder : noticeMinWidth
        guard notchDepth > 0, let restingRadius else {
            return CGSize(width: width, height: notchDepth + noticeLip)
        }
        let room = notchDepth + noticeLineRoom
        func climb(_ height: CGFloat) -> CGFloat {
            housingClimb(size: CGSize(width: width, height: height),
                         notchDepth: notchDepth, restingRadius: restingRadius)
        }
        var height = (room + climb(room)).rounded(.up)
        while height - climb(height) < room { height += 1 }
        return CGSize(width: width, height: height)
    }

    /// Points of a live Screen Bar's housing that lie over the foot of
    /// an island of `size` (`ScreenBarGeometry.coupledBand`): the
    /// housing runs up behind the island's bottom corners — the
    /// silhouette's radius at that size — and never less than its
    /// `housingLip`. The bar's panel is above the island's, so island
    /// content inside that band is drawn over by solid black.
    public static func housingClimb(size: CGSize, notchDepth: CGFloat,
                                    restingRadius: CGFloat) -> CGFloat {
        guard notchDepth > 0 else { return 0 }
        let radius = NotchSilhouetteGeometry.radius(size: size, notchDepth: notchDepth,
                                                    restingRadius: restingRadius)
        return min(max(0, size.height), max(housingLip, radius))
    }
}
