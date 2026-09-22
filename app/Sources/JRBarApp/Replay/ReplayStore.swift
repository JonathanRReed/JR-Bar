import Foundation
import JRBarCore
import Observation

/// The Replay surface's store (S7.4/T39): a read-only view over the
/// daemon's retained event journal. `replay_events` returns the journal
/// in wire order (oldest→newest); the view displays newest first.
/// Nothing here mutates — replay is fetch-and-render only, and the
/// journal's own coverage (`retained`/`dropped`) travels with it.
@MainActor @Observable
final class ReplayStore {
    private let core: CoreModel

    var events: [CoreEvent] = []
    var retained = 0
    var dropped = 0
    var stream: String?
    var resyncRequired = false
    var resyncReason: String?
    var loading = false
    var error: String?
    var loadedAt: Date?

    /// Whether the window is up — the controller sets it. Live frames
    /// keep an open window fresh (throttled, below); closed, the next
    /// `show()` loads anyway.
    var isOpen = false

    /// The slowest pace live frames may re-read the journal while the
    /// window watches.
    private static let liveReloadInterval: TimeInterval = 5
    @ObservationIgnored private var lastLoadAt = Date.distantPast
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(core: CoreModel) {
        self.core = core
        observeFrames()
    }

    /// Live attention stays a separate, labeled fact — the replay list
    /// never substitutes for the needs-me count happening right now.
    var liveAttention: Int { core.state?.asks.count ?? 0 }
    var isLive: Bool { core.isLive }

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        lastLoadAt = Date()
        do {
            // 512 is the journal's own bound; one call gets the whole
            // retained stream.
            let page = try await core.replayEvents(limit: 512)
            events = page.events
            retained = page.retained
            dropped = page.dropped
            stream = page.stream
            resyncRequired = page.resyncRequired
            resyncReason = page.reason
            loadedAt = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Watches `core.lastEvent` like the toys watch sessions: one
    /// observation per frame, coalesced into a main-queue turn.
    private func observeFrames() {
        withObservationTracking {
            _ = core.lastEvent?.id
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.noteFrame()
                self.observeFrames()
            }
        }
    }

    /// A daemon event landed — the journal the window renders is
    /// already stale. While it's open, reload now when the interval
    /// allows, else once when it opens up; a busy daemon gets one
    /// queued refresh, not one per frame.
    private func noteFrame() {
        guard isOpen, core.isLive, reloadTask == nil else { return }
        let wait = Self.liveReloadInterval - Date().timeIntervalSince(lastLoadAt)
        reloadTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled else { return }
            self.reloadTask = nil
            await self.load()
        }
    }
}
