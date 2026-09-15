import Foundation
import JRBarCore

/// The Overview content pane's mode: the sortable roster table or the
/// session graph. `OverviewViewModePreference` holds the user's explicit
/// pick; absent one the store derives the default from liveness.
enum OverviewViewMode: String, Codable, Sendable, CaseIterable {
    case list
    case graph

    var label: String { self == .list ? "List" : "Graph" }
    var symbol: String {
        self == .list ? "list.bullet" : "point.3.filled.connected.trianglepath.dotted"
    }
}

/// The explicit List/Graph pick, persisted next to the saved filters
/// under the `overview.*` defaults family (`overview.viewMode`). Like the
/// saved views it is view state only — nothing else reads it.
enum OverviewViewModePreference {
    static let key = "overview.viewMode"

    static func load(defaults: UserDefaults = .standard) -> OverviewViewMode? {
        defaults.string(forKey: key).flatMap(OverviewViewMode.init(rawValue:))
    }

    static func save(_ mode: OverviewViewMode?, defaults: UserDefaults = .standard) {
        if let mode { defaults.set(mode.rawValue, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// What a graph card looks like — the styling enum the roster's
/// `SessionActivity` words map onto. Fewer cases than the activity enum
/// because the card only distinguishes what the eye must act on:
/// something pulsing, something waiting, something broken, something
/// done, and everything quiet.
enum OverviewNodeStyle: String, Sendable, Equatable {
    /// Live work: the card breathes and edges pulse toward it.
    case working
    /// An open ask: the amber glow ring, same colour the rows shout in.
    case waiting
    /// Terminal failure: red tint.
    case failed
    /// A finished run: dimmed with a check.
    case done
    /// Ended or idle: dimmed, no mark — present but not asking for eyes.
    case quiet

    init(activity: SessionActivity) {
        switch activity {
        case .working: self = .working
        case .waiting: self = .waiting
        case .failed: self = .failed
        case .done: self = .done
        case .ended, .idle: self = .quiet
        }
    }
}

/// One card on the canvas. `parentID` is set only when the parent row is
/// itself in the filtered set — a worker whose parent the cut hides is a
/// standalone node, never an edge to nowhere.
struct OverviewGraphNode: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    /// The same one-line "what is it doing" the table's activity column
    /// shows (`CoreSession.activityCaption`) — one derivation, one story.
    var caption: String
    var provider: String
    /// `kind == "worker"`: renders as the smaller satellite card.
    var isWorker: Bool
    var parentID: String?
    var remote: Bool
    /// Pinned or carrying a live ask — the orange badge the table's
    /// attention column draws.
    var attention: Bool
    var style: OverviewNodeStyle

    /// Card size in graph units; the layout reads radii from this.
    var cardSize: (width: Double, height: Double) {
        isWorker ? (136, 40) : (190, 56)
    }
}

/// A drawn link. Today the roster offers one kind — parent session → its
/// sub-agent worker — but the kind travels so a future edge (e.g. an
/// observed hand-off) lands without a model change.
struct OverviewGraphEdge: Hashable, Sendable {
    enum Kind: String, Sendable {
        case subagent
    }
    /// The parent session id.
    var source: String
    /// The worker session id.
    var target: String
    var kind: Kind = .subagent
}

/// The node/edge document the canvas draws, built from the SAME filtered
/// row list the table shows so the two panes can never disagree (S7.1).
/// Pure data — no AppKit — so the tests exercise it directly.
struct OverviewGraph: Equatable, Sendable {
    var nodes: [OverviewGraphNode] = []
    var edges: [OverviewGraphEdge] = []
    private(set) var index: [String: Int] = [:]

    init() {}

    init(nodes: [OverviewGraphNode], edges: [OverviewGraphEdge]) {
        self.nodes = nodes
        self.edges = edges
        index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
    }

    var isEmpty: Bool { nodes.isEmpty }

    func node(_ id: String) -> OverviewGraphNode? {
        index[id].map { nodes[$0] }
    }

    /// Build the graph over an already-filtered roster cut. Ordering
    /// follows the row order the caller passes, which keeps the layout's
    /// seeding deterministic.
    static func build(from rows: [CoreRosterEntry]) -> OverviewGraph {
        let present = Set(rows.map(\.id))
        var nodes: [OverviewGraphNode] = []
        var edges: [OverviewGraphEdge] = []
        nodes.reserveCapacity(rows.count)
        for entry in rows {
            let session = entry.session
            // The daemon's own vocabulary: `kind == "worker"` marks a
            // sub-agent; `parent` names the session that spawned it.
            let isWorker = session.kind == "worker"
            let parent = session.parent.flatMap { present.contains($0) ? $0 : nil }
            nodes.append(OverviewGraphNode(
                id: session.id,
                title: session.label ?? session.shortId ?? "Session",
                caption: session.activityCaption,
                provider: session.provider,
                isWorker: isWorker,
                parentID: parent,
                remote: session.remote,
                attention: entry.pinned || session.ask != nil,
                style: OverviewNodeStyle(activity: SessionActivity.reduce(session))))
            if let parent {
                edges.append(OverviewGraphEdge(source: parent, target: session.id, kind: .subagent))
            }
        }
        return OverviewGraph(nodes: nodes, edges: edges)
    }
}

extension CoreSession {
    /// The one-line "what is it doing" — the roster's Current activity
    /// column and the graph card's caption share this so the panes can
    /// never tell two stories about one session.
    var activityCaption: String {
        if let ask { return ask.summary ?? "Waiting on you" }
        if let message, !message.isEmpty { return message }
        if let event { return event }
        if let tool { return tool }
        return mode?.replacingOccurrences(of: "_", with: " ") ?? "—"
    }
}
