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

    /// What the queue reported evicting — the closure is `@Sendable`, and
    /// the queue calls it synchronously inside the mutating call.
    private final class Evictions: @unchecked Sendable {
        var ids: [String] = []
    }

    @Test("a waiting notice a newer one pushes out of the slot is reported, not dropped")
    func evictionReported() {
        var q = AlcoveCapsuleQueue()
        let seen = Evictions()
        q.onEvict = { seen.ids.append($0.id) }
        _ = q.offer(notice(.failed, key: "failed:a", id: "1"), at: t0)
        #expect(q.offer(notice(.device, key: "toast:x", id: "2"), at: t0) == .queued)
        #expect(seen.ids.isEmpty, "queuing into an empty slot displaces nothing")
        #expect(q.offer(notice(.completed, key: "completed:c", id: "3"), at: t0 + 1) == .queued)
        #expect(seen.ids == ["2"], ".queued promised the island would say it — the lapse is heard")

        // Stepping down, dismissing and parking are not displacements.
        _ = q.finish(at: t0 + AlcoveCapsuleQueue.life)
        _ = q.offer(notice(.failed, key: "failed:d", id: "4"), at: t0 + 10)
        q.cancel(at: t0 + 11)
        _ = q.offer(notice(.failed, key: "failed:e", id: "5"), at: t0 + 12)
        _ = q.offer(notice(.completed, key: "completed:f", id: "6"), at: t0 + 12)
        q.clear()
        #expect(seen.ids == ["2"])
    }

    @Test("a waiting notice already past its staleness goes quietly; a waiting ask never goes stale")
    func staleEvictionIsQuiet() {
        var q = AlcoveCapsuleQueue()
        let seen = Evictions()
        q.onEvict = { seen.ids.append($0.id) }
        _ = q.offer(notice(.ask, key: "ask:a", id: "1"), at: t0)
        _ = q.offer(notice(.device, key: "toast:x", id: "2"), at: t0)
        let late = t0 + AlcoveCapsuleQueue.pendingStaleAfter + 1
        _ = q.offer(notice(.completed, key: "completed:c", id: "3"), at: late)
        #expect(seen.ids.isEmpty, "history by now — `finish` would have dropped it too")
        _ = q.offer(notice(.ask, key: "ask:b", id: "4"), at: late)
        #expect(seen.ids == ["3"], "a fresh one is reported")
        _ = q.offer(notice(.ask, key: "ask:c", id: "5"), at: late + AlcoveCapsuleQueue.pendingStaleAfter + 1)
        #expect(seen.ids == ["3", "4"], "an ask is never history")
    }

    @Test("a waiting announcement its own next state replaces goes quietly — the older half is no longer true")
    func supersededGoesQuietly() {
        var q = AlcoveCapsuleQueue()
        let seen = Evictions()
        q.onEvict = { seen.ids.append($0.id) }
        _ = q.offer(notice(.failed, key: "failed:a", id: "1"), at: t0)
        _ = q.offer(notice(.device, key: "device:AirPods:on", id: "2"), at: t0)
        #expect(q.offer(notice(.device, key: "device:AirPods:off", id: "3"), at: t0 + 1) == .queued)
        #expect(q.pending?.id == "3")
        #expect(seen.ids.isEmpty, "\"AirPods · Connected\" is not said as they disconnect")
        _ = q.offer(notice(.focus, key: "focus:on", id: "4"), at: t0 + 2)
        #expect(seen.ids == ["3"], "another subject's news still reports the displaced one")
        _ = q.offer(notice(.focus, key: "focus:off", id: "5"), at: t0 + 3)
        #expect(seen.ids == ["3"])
        _ = q.offer(notice(.completed, key: "completed:c", id: "6"), at: t0 + 4)
        #expect(seen.ids == ["3", "5"])
        #expect(AlcoveCapsuleQueue.subject(of: "device:Magic Keyboard:off") == "device:Magic Keyboard")
        #expect(AlcoveCapsuleQueue.subject(of: "toast:Sound on") == "toast:Sound on",
                "only a trailing state word is stripped")
        #expect(AlcoveCapsuleQueue.subject(of: "display:on") == AlcoveCapsuleQueue.subject(of: "display:off"))
    }

    @Test("a takeover parking the shown ask reports the notice it pushed out")
    func takeoverEvictionReported() {
        var q = AlcoveCapsuleQueue()
        let seen = Evictions()
        q.onEvict = { seen.ids.append($0.id) }
        var shown = notice(.ask, key: "ask:s1", id: "1")
        shown.session = "s1"
        var escalated = notice(.ask, key: "ask:s2", id: "3")
        escalated.session = "s2"
        _ = q.offer(shown, at: t0)
        _ = q.offer(notice(.failed, key: "failed:b", id: "2"), at: t0)
        q.takeOver(escalated, at: t0 + 1)
        #expect(q.current?.id == "3")
        #expect(q.pending?.id == "1", "the shown ask keeps its place behind the takeover")
        #expect(seen.ids == ["2"])
    }

    @Test("the queue's equality is its line, not who listens to it")
    func equalityIgnoresListener() {
        var listening = AlcoveCapsuleQueue()
        listening.onEvict = { _ in }
        #expect(listening == AlcoveCapsuleQueue())
        _ = listening.offer(notice(.failed, key: "failed:a", id: "1"), at: t0)
        #expect(listening != AlcoveCapsuleQueue())
    }

    @Test("the Mac's announcements are the kinds that wait in the line")
    func macAnnouncements() {
        #expect(AlcoveNoticeKind.allCases.filter(\.isMacAnnouncement) == [.focus, .device, .display])
        #expect(!AlcoveNoticeKind.allCases.contains { $0.isMacAnnouncement && $0.isFeedback })
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

    @Test("a live Screen Bar's strip seats under each face; the notice keeps above its housing")
    func screenBarClearance() {
        // The resting capsule is exactly the notch's depth — the band
        // hangs below it.
        #expect(NotchIslandLayout.idleSize(slotWidth: 185, notchDepth: 32,
                                           leftShoulder: 34, rightShoulder: 12).height == 32)
        // Bare, the notice is the notch plus one line's lip.
        #expect(NotchIslandLayout.noticeSize(slotWidth: 185, notchDepth: 32).height
                == 32 + NotchIslandLayout.noticeLip)
        #expect(NotchIslandLayout.noticeLip == 22)
        // Under the bar the tray ends at the bezel (`wingEarDrop` is
        // zero) and owes nothing above the line, but the strip's housing
        // climbs over the island's bottom corners. At the standard 8 pt
        // corner that is 32 + 16 of line room + the ~12.6 pt climb,
        // rounded up: 61, where the bare 54 put the housing's top edge
        // through the line's caps.
        #expect(NotchIslandLayout.noticeSize(slotWidth: 185, notchDepth: 32,
                                             underHousing: 8).height == 61)
        // No notch, no band — a floating pill never grows.
        #expect(NotchIslandLayout.noticeSize(slotWidth: 0, notchDepth: 0, underHousing: 8)
                == CGSize(width: 240, height: 22))
        #expect(NotchIslandLayout.floatingSize(contentWidth: 20).height == 24)
    }

    @Test("under a live Screen Bar the notice line's room clears the housing at every corner")
    func noticeClearsTheHousing() {
        // The room holds the 11.5 pt line box (13.5 pt) and the kind's
        // 11 pt glyph (14 pt).
        #expect(NotchIslandLayout.noticeLineRoom >= 14)
        let room = NotchIslandLayout.noticeLineRoom
        // Every corner the Notch profile's slider allows, on a 14"/16"
        // MacBook Pro's 32 pt notch and a deeper one.
        for depth: CGFloat in [32, 37.5] {
            for rest in stride(from: CGFloat(0), through: 16, by: 1) {
                let size = NotchIslandLayout.noticeSize(slotWidth: 185, notchDepth: depth,
                                                        underHousing: rest)
                let climb = NotchIslandLayout.housingClimb(size: size, notchDepth: depth,
                                                           restingRadius: rest)
                // The climb is the housing's: the silhouette's corner at
                // this height, never under its lip.
                #expect(climb >= NotchSilhouetteGeometry.radius(size: size, notchDepth: depth,
                                                                restingRadius: rest))
                #expect(climb >= NotchIslandLayout.housingLip)
                #expect(size.height - climb - depth >= room, "corner \(rest), depth \(depth)")
                // And no deeper than it has to be: a point shorter and
                // the housing reaches the line.
                let shorter = CGSize(width: size.width, height: size.height - 1)
                let shorterClimb = NotchIslandLayout.housingClimb(size: shorter, notchDepth: depth,
                                                                  restingRadius: rest)
                #expect(shorter.height - shorterClimb - depth < room, "corner \(rest), depth \(depth)")
            }
        }
        // No notch, no housing to climb.
        #expect(NotchIslandLayout.housingClimb(size: CGSize(width: 240, height: 22),
                                               notchDepth: 0, restingRadius: 8) == 0)
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

extension AlcoveEventsTests {
    @Test("a playing track's playhead advances with the clock; paused stays put; duration clamps")
    func liveElapsed() {
        let stamp = Date().timeIntervalSinceReferenceDate - 10
        let playing = AlcoveMedia(title: "A", playing: true, duration: 200,
                                  elapsed: 30, timestamp: stamp)
        let advanced = playing.liveElapsed()
        #expect(advanced != nil && advanced! > 39.5 && advanced! < 40.5,
                "10 s of wall clock on a playing track moves the playhead ~10 s")
        let paused = AlcoveMedia(title: "A", playing: false, duration: 200,
                                 elapsed: 30, timestamp: stamp)
        #expect(paused.liveElapsed() == 30, "a paused playhead does not drift")
        // A source that names no playhead draws no slider — 0:00 would lie.
        #expect(AlcoveMedia(title: "A", playing: true).liveElapsed() == nil)
        // The drift can never overshoot the track's end.
        let done = AlcoveMedia(title: "A", playing: true, duration: 35,
                               elapsed: 30, timestamp: stamp)
        #expect(done.liveElapsed() == 35)
        // A missing timestamp can't advance — the sample is all we have.
        let timeless = AlcoveMedia(title: "A", playing: true, duration: 200,
                                   elapsed: 30, timestamp: nil)
        #expect(timeless.liveElapsed() == 30)
    }

    @Test("the now-playing dict's elapsed/duration/timestamp reduce through summarize")
    func summarizeTimes() {
        let stamp = Date().timeIntervalSinceReferenceDate - 5
        let media = AlcoveMedia.summarize([
            "kMRMediaRemoteNowPlayingInfoTitle": "Papillon",
            "kMRMediaRemoteNowPlayingInfoPlaybackRate": NSNumber(value: 1),
            "kMRMediaRemoteNowPlayingInfoDuration": NSNumber(value: 210.5),
            "kMRMediaRemoteNowPlayingInfoElapsedTime": NSNumber(value: 12.0),
            "kMRMediaRemoteNowPlayingInfoTimestamp": NSNumber(value: stamp),
        ])
        #expect(media?.duration == 210.5)
        #expect(media?.elapsed == 12)
        #expect(media?.timestamp == stamp)
        // A zero duration is no duration — the slider hides rather than
        // divide by nothing.
        let noLen = AlcoveMedia.summarize([
            "kMRMediaRemoteNowPlayingInfoTitle": "Papillon",
            "kMRMediaRemoteNowPlayingInfoDuration": NSNumber(value: 0),
        ])
        #expect(noLen?.duration == nil)
    }
}
