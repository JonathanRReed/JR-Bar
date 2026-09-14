import Foundation
import JRBarCore

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

    init(core: CoreModel) {
        self.core = core
    }

    /// Live attention stays a separate, labeled fact — the replay list
    /// never substitutes for the needs-me count happening right now.
    var liveAttention: Int { core.state?.asks.count ?? 0 }
    var isLive: Bool { core.isLive }

    func load() async {
        loading = true
        defer { loading = false }
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
}
