import Foundation

/// The island's transient capsules — Alcove's "instant notifications".
/// One daemon event that matters (`ask_opened`, `completed`, `failed`,
/// `quota_reset`) becomes an `AlcoveNotice`: an icon, a title, a
/// subtitle, shown for a couple of seconds before the island settles
/// back to its idle face. Which kinds may raise one is the user's;
/// `AlcoveCapsuleKinds` is the per-kind switchboard `AlcoveSettings`
/// persists.
public enum AlcoveNoticeKind: String, Equatable, Sendable, CaseIterable {
    case ask
    case completed
    case failed
    case quotaReset
    /// The synthetic power capsule — no daemon event carries it; the
    /// toy's IOPS poller raises it on real battery transitions only.
    case charging

    /// The SF Symbol the capsule's leading glyph draws. The tint is the
    /// view's business (amber / green / red / the provider's accent) —
    /// core names shapes, never colours.
    public var symbol: String {
        switch self {
        case .ask: return "exclamationmark.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .quotaReset: return "arrow.clockwise.circle.fill"
        case .charging: return "bolt.fill"
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
        }
    }
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

    public init(id: String, kind: AlcoveNoticeKind, title: String, subtitle: String,
                provider: String? = nil, session: String? = nil, key: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.provider = provider
        self.session = session
        self.key = key
    }
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

        return AlcoveNotice(id: event.id, kind: kind, title: title, subtitle: subtitle,
                            provider: provider, session: event.session,
                            key: "\(kind.rawValue):\(event.session ?? provider ?? event.id)")
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
public struct AlcoveCapsuleQueue: Equatable, Sendable {
    /// Seconds a capsule holds before it steps down.
    public static let life: TimeInterval = 2.4
    /// The same kind about the same session/provider repeats inside this
    /// window are suppressed.
    public static let sameKeyCooldown: TimeInterval = 30
    /// The smallest gap between two capsules' show times.
    public static let minGap: TimeInterval = 1.2

    /// The capsule the island should be drawing (or is about to, on an
    /// `.after` verdict). The view reads the toy's copy of this.
    public private(set) var current: AlcoveNotice?
    /// The one waiting behind it; replaced, never stacked.
    public private(set) var pending: AlcoveNotice?
    /// kind+subject → when it was last accepted. Entries age out at
    /// `sameKeyCooldown`.
    public private(set) var recent: [String: Date] = [:]
    private var currentShownAt: Date?
    private var lastShownAt: Date?

    public init() {}

    @discardableResult
    public mutating func offer(_ notice: AlcoveNotice, at now: Date) -> AlcoveCapsuleVerdict {
        recent = recent.filter { now.timeIntervalSince($0.value) < Self.sameKeyCooldown }
        if let seen = recent[notice.key], now.timeIntervalSince(seen) < Self.sameKeyCooldown {
            return .suppressed
        }
        recent[notice.key] = now
        guard current == nil else {
            pending = notice
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
        pending = nil
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
        currentShownAt = nil
    }

    /// The island parked: nothing in flight survives, but `recent` does —
    /// a re-show inside the cooldown must not replay a capsule the user
    /// just saw.
    public mutating func clear() {
        current = nil
        pending = nil
        currentShownAt = nil
        lastShownAt = nil
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

    public init(title: String, artist: String? = nil, album: String? = nil,
                playing: Bool, artworkData: Data? = nil, bundleIdentifier: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.playing = playing
        self.artworkData = artworkData
        self.bundleIdentifier = bundleIdentifier
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
        return AlcoveMedia(title: title,
                           artist: string("kMRMediaRemoteNowPlayingInfoArtist"),
                           album: string("kMRMediaRemoteNowPlayingInfoAlbum"),
                           playing: isPlaying ?? (rate.map { $0 > 0 } ?? false),
                           artworkData: info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data)
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
                           bundleIdentifier: string("bundleIdentifier"))
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

    public init(hasBattery: Bool, onAC: Bool, charging: Bool,
                percent: Int?, fullyCharged: Bool) {
        self.hasBattery = hasBattery
        self.onAC = onAC
        self.charging = charging
        self.percent = percent
        self.fullyCharged = fullyCharged
    }

    /// The percent rendered for a subtitle — "· 84%" or nothing.
    public var percentText: String {
        percent.map { " · \($0)%" } ?? ""
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
}

extension AlcoveIsland {
    /// Points of idle content a Now Playing strip adds: the artwork
    /// thumbnail, a truncated "title — artist", and the visualizer bars.
    /// Fixed, like every idle content measure — the panel's frame is its
    /// drawn shape, so the width is never measured off a live label.
    public static let mediaContentWidth: CGFloat = 148
    /// The gap between the session dots and the media strip.
    public static let mediaSeparatorWidth: CGFloat = 10

    /// The idle width with Now Playing in it. The media strip rides the
    /// same capsule as the dots; when nothing is working the capsule is
    /// the strip plus the resting dot.
    public static func idleContentWidth(_ summary: AlcoveIslandSummary, media: AlcoveMedia?) -> CGFloat {
        let base = idleContentWidth(summary)
        guard media != nil else { return base }
        return base + mediaSeparatorWidth + mediaContentWidth
    }
}

extension AlcoveIslandLayout {
    /// The notification capsule's width — wide enough for a glyph and
    /// two lines of copy, still a capsule and not the card.
    public static let noticeWidth: CGFloat = 320
    /// How far below the notch the notice capsule reaches.
    public static let noticeLip: CGFloat = 40

    /// The notice face: wider than idle, deeper than idle, still hung
    /// from the notch — one window morphing, never a second panel.
    /// `ledClearance` keeps the capsule's copy below a live Screen Bar's
    /// band the same way `idleSize` keeps the dots clear.
    public static func noticeSize(slotWidth: CGFloat, notchDepth: CGFloat,
                                  ledClearance: CGFloat = 0) -> CGSize {
        guard notchDepth > 0 else { return CGSize(width: noticeWidth, height: 36) }
        return CGSize(width: max(slotWidth + 2 * shoulder, noticeWidth),
                      height: notchDepth + noticeLip + ledClearance)
    }
}
