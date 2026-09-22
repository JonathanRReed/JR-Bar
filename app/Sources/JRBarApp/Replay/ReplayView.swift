import SwiftUI
import JRBarCore

/// Read-only replay of the daemon's retained event journal (S7.4/T39).
/// The Replay badge and the journal's coverage are always on screen,
/// live attention is a separate labeled indicator, and there are no
/// mutation controls — this surface renders history, it never re-fires
/// it.
struct ReplayView: View {
    @Bindable var store: ReplayStore

    var body: some View {
        VStack(spacing: 0) {
            replayBanner
            Divider()
            if store.events.isEmpty && !store.loading {
                OverviewEmptyState(
                    symbol: "clock.arrow.circlepath",
                    title: store.isLive ? "No retained events" : "Monitor not connected",
                    text: store.isLive
                        ? "The journal holds events the daemon published this run; none yet."
                        : "The event journal lives in the monitor. It appears when the socket is live.")
            } else {
                List(store.events.reversed()) { event in
                    row(event)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .font(.system(size: 13))
        // No `.task` load: `ReplayWindowController.show()` owns the open
        // read — a second one here double-fetched the journal on every
        // open. While the window is up, live frames re-load it
        // (throttled) through `ReplayStore`, so the list can't go stale
        // behind the daemon's own stream.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Re-read the journal")
                .accessibilityLabel("Refresh replay")
            }
        }
    }

    /// The persistent Replay badge: on every replayed surface, always.
    private var replayBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("REPLAY", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.orange.opacity(0.18), in: .capsule)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Replay: historical events")
                Text("Historical events — nothing here acts.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                // Live attention is a separate, clearly labeled
                // indicator — never implied by the replayed rows.
                if store.liveAttention > 0 {
                    Label("\(store.liveAttention) need you now — live",
                          systemImage: "exclamationmark.bubble")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.red)
                }
            }
            HStack(spacing: 12) {
                if let loadedAt = store.loadedAt {
                    Text("Loaded \(loadedAt, style: .time)")
                }
                Text("Journal: \(store.retained) retained" +
                     (store.dropped > 0 ? " · \(store.dropped) dropped" : ""))
                if store.resyncRequired {
                    Text("Resync required" + (store.resyncReason.map { " (\($0))" } ?? ""))
                        .foregroundStyle(.orange)
                }
                if let error = store.error {
                    Text(error).foregroundStyle(.red).lineLimit(1)
                }
            }
            .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func row(_ event: CoreEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.at.map { Self.clock.string(from: Date(timeIntervalSince1970: $0)) } ?? "—")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.quaternary)
                .frame(width: 64, alignment: .leading)
            Image(systemName: symbol(event))
                .font(.system(size: 10))
                .foregroundStyle(tint(event))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(event.kind).font(.system(size: 11, weight: .medium))
                    if let provider = event.provider {
                        Text(provider).font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                if let text = event.label ?? event.detail ?? event.message {
                    Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if let session = event.session {
                Text(session).font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.quaternary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func symbol(_ event: CoreEvent) -> String {
        switch event.kind {
        case "ask_opened": return "questionmark.bubble"
        case "ask_resolved": return "checkmark.bubble"
        case let kind where kind.contains("complet"): return "checkmark.circle"
        case let kind where kind.contains("fail") || kind.contains("error"): return "xmark.octagon"
        case let kind where kind.contains("quota"): return "gauge"
        default: return "circle"
        }
    }

    private func tint(_ event: CoreEvent) -> Color {
        switch event.kind {
        case let kind where kind.contains("fail") || kind.contains("error"): return .red
        case "ask_opened": return .orange
        default: return .secondary
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
}
