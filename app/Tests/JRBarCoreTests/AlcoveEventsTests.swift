import Foundation
import Testing
@testable import JRBarCore

/// The island's transient capsules and Now Playing: which events earn a
/// notice, how the queue suppresses and promotes them, and how
/// MediaRemote's now-playing dictionary reduces to the strip the idle
/// capsule draws. Pure — no notch required.
@Suite("Alcove events")
struct AlcoveEventsTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func event(_ kind: String, id: String = "e1", session: String? = "claude:session:abc",
                       label: String? = nil, provider: String? = nil, detail: String? = nil,
                       lane: String? = nil) -> CoreEvent {
        CoreEvent(id: id, kind: kind, session: session, label: label,
                  provider: provider, detail: detail, lane: lane)
    }

    private func notice(_ kind: AlcoveNoticeKind, key: String = "ask:s1", id: String = "e1") -> AlcoveNotice {
        AlcoveNotice(id: id, kind: kind, title: "Claude · thing", subtitle: kind.verb, key: key)
    }

    // MARK: Notice shaping

    @Test("the four kinds the island speaks each become a notice")
    func noticeKinds() {
        let session = CoreSession(id: "claude:session:abc", provider: "claude",
                                  label: "Claude rename-the-fish")
        let all = AlcoveCapsuleKinds()
        let ask = AlcoveEventPolicy.notice(for: event("ask_opened"), session: session, kinds: all)
        #expect(ask?.kind == .ask)
        #expect(ask?.title == "Claude · rename-the-fish")
        #expect(ask?.subtitle == "needs you")
        #expect(ask?.key == "ask:claude:session:abc")
        #expect(AlcoveEventPolicy.notice(for: event("completed"), session: session, kinds: all)?.kind == .completed)
        #expect(AlcoveEventPolicy.notice(for: event("failed"), session: session, kinds: all)?.kind == .failed)
        #expect(AlcoveEventPolicy.notice(for: event("quota_reset", provider: "claude", lane: "weekly"),
                                       session: nil, kinds: all)?.kind == .quotaReset)
    }

    @Test("the ask's summary outranks the plain verb, and a kind switched off shows nothing")
    func noticeDetail() {
        let session = CoreSession(id: "claude:session:abc", provider: "claude",
                                  label: "rename-the-fish",
                                  ask: CoreAsk(kind: "permission", summary: "Run: rm -rf build"))
        let ask = AlcoveEventPolicy.notice(for: event("ask_opened"), session: session,
                                           kinds: AlcoveCapsuleKinds())
        #expect(ask?.subtitle == "Run: rm -rf build")
        var kinds = AlcoveCapsuleKinds()
        kinds.ask = false
        #expect(AlcoveEventPolicy.notice(for: event("ask_opened"), session: session, kinds: kinds) == nil)
        #expect(AlcoveEventPolicy.notice(for: event("peer_arrived"), session: session,
                                       kinds: AlcoveCapsuleKinds()) == nil)
        #expect(AlcoveEventPolicy.notice(for: event("ask_resolved"), session: session,
                                       kinds: AlcoveCapsuleKinds()) == nil,
                "taking a question away is not news")
    }

    @Test("a quota reset names the provider; a session event falls back through label then provider")
    func noticeTitles() {
        let all = AlcoveCapsuleKinds()
        let reset = AlcoveEventPolicy.notice(for: event("quota_reset", session: nil,
                                                        provider: "codex", detail: "Weekly refilled"),
                                             session: nil, kinds: all)
        #expect(reset?.title == "Codex")
        #expect(reset?.subtitle == "Weekly refilled")
        #expect(reset?.key == "quotaReset:codex")
        // No session row and no label: the provider name stands alone.
        let orphan = AlcoveEventPolicy.notice(for: event("failed", session: nil, provider: "pi"),
                                              session: nil, kinds: all)
        #expect(orphan?.title == "Pi")
    }

    // MARK: Queue

    @Test("a lone notice shows now; a second queues; a third replaces it — newest wins")
    func queueOrder() {
        var q = AlcoveCapsuleQueue()
        #expect(q.offer(notice(.ask, key: "ask:a", id: "1"), at: t0) == .now)
        #expect(q.offer(notice(.failed, key: "failed:b", id: "2"), at: t0) == .queued)
        #expect(q.pending?.id == "2")
        #expect(q.offer(notice(.completed, key: "completed:c", id: "3"), at: t0) == .queued)
        #expect(q.pending?.id == "3", "the waiting slot is one deep: newest wins")
        let next = q.finish(at: t0 + AlcoveCapsuleQueue.life)
        #expect(next == .now(notice(.completed, key: "completed:c", id: "3")))
        #expect(q.current?.id == "3")
        #expect(q.finish(at: t0 + 5) == .idle)
        #expect(q.current == nil)
    }

    @Test("the same kind about the same session inside 30 s is strobe, not news")
    func suppression() {
        var q = AlcoveCapsuleQueue()
        #expect(q.offer(notice(.ask, key: "ask:s1"), at: t0) == .now)
        _ = q.finish(at: t0 + AlcoveCapsuleQueue.life)
        // Same key again right away: suppressed — and the gap would have
        // queued it anyway, so the cooldown is what did the work.
        let later = t0 + AlcoveCapsuleQueue.life + 5
        #expect(q.offer(notice(.ask, key: "ask:s1"), at: later) == .suppressed)
        // A different session's ask is a different story.
        #expect(q.offer(notice(.ask, key: "ask:s2", id: "e2"), at: later) == .now)
        // Past the cooldown the same key is news again.
        _ = q.finish(at: later + AlcoveCapsuleQueue.life)
        let after = later + AlcoveCapsuleQueue.sameKeyCooldown + 1
        #expect(q.offer(notice(.ask, key: "ask:s1", id: "e3"), at: after) == .now)
    }

    @Test("a capsule dismissed early still leaves the minimum gap before the next")
    func minGap() {
        var q = AlcoveCapsuleQueue()
        _ = q.offer(notice(.ask, key: "ask:a", id: "1"), at: t0)
        _ = q.offer(notice(.failed, key: "failed:b", id: "2"), at: t0 + 0.2)
        // Swiped away after 0.4 s: the queued one waits out the 1.2 s gap.
        let next = q.finish(at: t0 + 0.4)
        guard case .after(let delay, let promoted) = next else {
            Issue.record("expected .after, got \(next)")
            return
        }
        #expect(promoted.id == "2")
        #expect(abs(delay - (AlcoveCapsuleQueue.minGap - 0.4)) < 0.001)
        // And once it has run its life, an empty queue idles.
        #expect(q.finish(at: t0 + 0.4 + delay + AlcoveCapsuleQueue.life) == .idle)
    }

    @Test("a held-over offer during the gap is queued behind the deferred capsule")
    func offerDuringGap() {
        var q = AlcoveCapsuleQueue()
        _ = q.offer(notice(.ask, key: "ask:a", id: "1"), at: t0)
        _ = q.finish(at: t0 + 0.3)                    // early end, nothing waiting
        // A fresh notice lands inside the gap: it waits out the gap.
        let verdict = q.offer(notice(.failed, key: "failed:b", id: "2"), at: t0 + 0.5)
        guard case .after = verdict else {
            Issue.record("expected .after, got \(verdict)")
            return
        }
        #expect(q.current?.id == "2")
        // One more while it waits: queued, not shown.
        #expect(q.offer(notice(.completed, key: "completed:c", id: "3"), at: t0 + 0.6) == .queued)
    }

    @Test("cancel drops the waiting capsule too; clear keeps the cooldown memory")
    func cancelAndClear() {
        var q = AlcoveCapsuleQueue()
        _ = q.offer(notice(.ask, key: "ask:a", id: "1"), at: t0)
        _ = q.offer(notice(.failed, key: "failed:b", id: "2"), at: t0 + 0.2)
        q.cancel(at: t0 + 0.4)
        #expect(q.current == nil && q.pending == nil)
        q.clear()
        // The parked island forgot the capsules, not what it just showed.
        #expect(q.offer(notice(.ask, key: "ask:a", id: "1x"), at: t0 + 1) == .suppressed)
    }

    // MARK: Media

    @Test("a now-playing dict with no title is nothing; the rate says paused")
    func mediaSummarize() {
        #expect(AlcoveMedia.summarize([:]) == nil)
        #expect(AlcoveMedia.summarize(["kMRMediaRemoteNowPlayingInfoTitle": "   "]) == nil)
        let media = AlcoveMedia.summarize([
            "kMRMediaRemoteNowPlayingInfoTitle": "Papillon",
            "kMRMediaRemoteNowPlayingInfoArtist": "The Editors",
            "kMRMediaRemoteNowPlayingInfoPlaybackRate": NSNumber(value: 1.0),
            "kMRMediaRemoteNowPlayingInfoArtworkData": Data([0x89, 0x50]),
        ])
        #expect(media?.title == "Papillon")
        #expect(media?.artist == "The Editors")
        #expect(media?.playing == true)
        #expect(media?.artworkData == Data([0x89, 0x50]))
        #expect(media?.displayLine == "Papillon — The Editors")
        let paused = AlcoveMedia.summarize(
            ["kMRMediaRemoteNowPlayingInfoTitle": "Papillon",
             "kMRMediaRemoteNowPlayingInfoPlaybackRate": NSNumber(value: 0.0)])
        #expect(paused?.playing == false)
        // The app's is-playing answer beats a missing rate; no signal at
        // all reads as paused.
        let forced = AlcoveMedia.summarize(["kMRMediaRemoteNowPlayingInfoTitle": "Papillon"],
                                           isPlaying: true)
        #expect(forced?.playing == true)
        #expect(AlcoveMedia.summarize(["kMRMediaRemoteNowPlayingInfoTitle": "Papillon"])?.playing == false)
        #expect(forced?.displayLine == "Papillon", "no artist — just the title")
    }

    @Test("the adapter's JSON line reduces like the info dict it stands in for")
    func adapterSummarize() {
        #expect(AlcoveMedia.summarize(adapter: [:]) == nil)
        #expect(AlcoveMedia.summarize(adapter: ["artist": "The Editors"]) == nil,
                "a payload with no title is still nothing")
        let media = AlcoveMedia.summarize(adapter: [
            "title": "Papillon",
            "artist": "The Editors",
            "playing": true,
            "bundleIdentifier": "com.apple.Music",
            "artworkData": Data([0x89, 0x50]).base64EncodedString(),
        ])
        #expect(media?.title == "Papillon")
        #expect(media?.artist == "The Editors")
        #expect(media?.playing == true)
        #expect(media?.bundleIdentifier == "com.apple.Music")
        #expect(media?.artworkData == Data([0x89, 0x50]))
        // Garbage artwork base64 is shrugged off, not fatal.
        #expect(AlcoveMedia.summarize(adapter: ["title": "Papillon",
                                              "artworkData": "%%%"])?.artworkData == nil)
    }

    @Test("Music's playerInfo payload carries the strip when MediaRemote reads are gated")
    func musicPlayerInfoSummarize() {
        #expect(AlcoveMedia.summarize(musicPlayerInfo: [:]) == nil)
        #expect(AlcoveMedia.summarize(musicPlayerInfo: ["Player State": "Stopped",
                                                       "Name": "Papillon"]) == nil,
                "a stopped player holds no track")
        let media = AlcoveMedia.summarize(musicPlayerInfo: [
            "Name": "Papillon", "Artist": "The Editors", "Player State": "Playing"])
        #expect(media?.title == "Papillon")
        #expect(media?.playing == true)
        #expect(media?.bundleIdentifier == "com.apple.Music")
        #expect(AlcoveMedia.summarize(musicPlayerInfo: ["Name": "Papillon",
                                                       "Player State": "Paused"])?.playing == false)
    }

    // MARK: Power

    private func battery(onAC: Bool, charging: Bool, percent: Int = 80,
                         fullyCharged: Bool = false) -> AlcovePowerState {
        AlcovePowerState(hasBattery: true, onAC: onAC, charging: charging,
                         percent: percent, fullyCharged: fullyCharged)
    }

    @Test("power transitions speak; baselines and drift stay silent")
    func powerNotice() {
        let all = AlcoveCapsuleKinds()
        let onBattery = battery(onAC: false, charging: false)
        // The first reading is a baseline, and a desktop has no battery.
        #expect(AlcovePower.notice(from: nil, to: onBattery, id: "p1", kinds: all) == nil)
        #expect(AlcovePower.notice(from: onBattery,
                                 to: AlcovePowerState(hasBattery: false, onAC: false, charging: false,
                                                      percent: nil, fullyCharged: false),
                                 id: "p1b", kinds: all) == nil)
        // Unplugged.
        let unplug = AlcovePower.notice(from: battery(onAC: true, charging: true),
                                      to: onBattery, id: "p2", kinds: all)
        #expect(unplug?.kind == .charging)
        #expect(unplug?.subtitle == "On battery · 80%")
        #expect(unplug?.key == AlcovePower.noticeKey)
        // Plugged in and charging.
        #expect(AlcovePower.notice(from: onBattery, to: battery(onAC: true, charging: true),
                                   id: "p3", kinds: all)?.subtitle == "Charging · 80%")
        // On AC but not charging — a held limit is still a transition.
        #expect(AlcovePower.notice(from: onBattery, to: battery(onAC: true, charging: false),
                                   id: "p4", kinds: all)?.subtitle == "On AC power · 80%")
        // Full.
        #expect(AlcovePower.notice(from: battery(onAC: true, charging: true, percent: 99),
                                   to: battery(onAC: true, charging: false, percent: 100,
                                               fullyCharged: true),
                                   id: "p5", kinds: all)?.subtitle == "Fully charged")
        // Percent drift alone is not news, and neither is an unchanged read.
        #expect(AlcovePower.notice(from: onBattery, to: battery(onAC: false, charging: false, percent: 79),
                                   id: "p6", kinds: all) == nil)
        #expect(AlcovePower.notice(from: onBattery, to: onBattery, id: "p7", kinds: all) == nil)
        // The kind switched off silences it.
        var kinds = AlcoveCapsuleKinds()
        kinds.charging = false
        #expect(AlcovePower.notice(from: onBattery, to: battery(onAC: true, charging: true),
                                   id: "p8", kinds: kinds) == nil)
    }

    // MARK: Layout

    @Test("the notice capsule is one line wide and one lip deep, still hung from the notch")
    func noticeSize() {
        let size = NotchIslandLayout.noticeSize(slotWidth: 185, notchDepth: 32)
        #expect(size.width == 185 + 2 * NotchIslandLayout.noticeShoulder)
        #expect(size.height == 32 + NotchIslandLayout.noticeLip)
        // A huge slot keeps its shoulders.
        #expect(NotchIslandLayout.noticeSize(slotWidth: 400, notchDepth: 32).width == 500)
        // A tiny slot keeps the shoulder cap too — the capsule never
        // outgrows notch-plus-wings, it just truncates its line.
        #expect(NotchIslandLayout.noticeSize(slotWidth: 60, notchDepth: 32).width
                == 60 + 2 * NotchIslandLayout.noticeShoulder)
        // Notch-less: a floating one-line pill.
        #expect(NotchIslandLayout.noticeSize(slotWidth: 0, notchDepth: 0)
                == CGSize(width: 240, height: 22))
    }

    @Test("media adds its fixed strip width to the idle content")
    func idleMediaWidth() {
        var s = NotchIslandSummary()
        s.working = 2
        s.workingProviders = ["claude", "codex"]
        let base = NotchIsland.idleContentWidth(s)
        let media = AlcoveMedia(title: "Papillon", playing: true)
        #expect(NotchIsland.idleContentWidth(s, media: media)
                == base + NotchIsland.mediaSeparatorWidth + NotchIsland.mediaContentWidth)
        #expect(NotchIsland.idleContentWidth(s, media: nil) == base)
    }

    @Test("a live Screen Bar's band drops the notice face; idle tucks into the notch")
    func ledClearance() {
        let c = NotchIslandLayout.ledBandClearance
        // The resting capsule is exactly the notch's depth — the band
        // hangs below it, so no clearance is owed.
        #expect(NotchIslandLayout.idleSize(slotWidth: 185, notchDepth: 32,
                                           contentWidth: 20).height == 32)
        #expect(NotchIslandLayout.noticeSize(slotWidth: 185, notchDepth: 32,
                                             ledClearance: c).height
                == 32 + NotchIslandLayout.noticeLip + c)
        // No notch, no band — a floating pill never grows.
        #expect(NotchIslandLayout.idleSize(slotWidth: 0, notchDepth: 0, contentWidth: 20).height == 24)
    }

    @Test("the new settings default on and decode tolerantly")
    func settingsDecode() throws {
        let s = try JSONDecoder().decode(NotchSettings.self, from: Data("{}".utf8))
        #expect(s.capsuleNotifications == true)
        #expect(s.mediaEnabled == true)
        #expect(s.capsuleKinds == AlcoveCapsuleKinds())
        let off = try JSONDecoder().decode(NotchSettings.self, from: Data(
            #"{"capsuleNotifications": false, "mediaEnabled": false, "capsuleKinds": {"failed": false, "ask": 7}}"#.utf8))
        #expect(off.capsuleNotifications == false)
        #expect(off.mediaEnabled == false)
        #expect(off.capsuleKinds.failed == false)
        #expect(off.capsuleKinds.ask == true, "a mistyped leaf falls back to its default")
        var state = ToysState()
        state.notch.capsuleKinds.quotaReset = false
        state.notch.capsuleKinds.charging = false
        let decoded = try JSONDecoder().decode(ToysState.self, from: JSONEncoder().encode(state))
        #expect(decoded.notch.capsuleKinds.quotaReset == false)
        #expect(decoded.notch.capsuleKinds.charging == false)
    }
}
