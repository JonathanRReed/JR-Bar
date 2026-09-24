import CoreGraphics
import Foundation
import JRBarCore

/// One session on the Overview's Graph: who it is, whose worker it is,
/// which project it works in, and the state its ring shows.
struct OverviewGraphNode: Identifiable, Equatable, Sendable {
    let id: String
    let parentID: String?
    let project: String?
    let provider: String
    let activity: SessionActivity
    let label: String
    /// Epoch seconds of the last thing it did: how far a finished run's
    /// check has faded.
    let lastActive: Double

    init(id: String, parentID: String? = nil, project: String? = nil, provider: String,
         activity: SessionActivity, label: String, lastActive: Double = 0) {
        self.id = id
        self.parentID = parentID
        self.project = project
        self.provider = provider
        self.activity = activity
        self.label = label
        self.lastActive = lastActive
    }

    /// The project is the repository, so a run in one of its worktrees
    /// sits with the rest of that repository's work.
    init(_ entry: CoreRosterEntry) {
        let session = entry.session
        self.init(id: entry.id, parentID: session.parent,
                  project: AgentProject.name(of: session.cwd),
                  provider: session.provider, activity: SessionActivity.reduce(session),
                  label: session.displayLabel, lastActive: session.updatedAt ?? session.since ?? 0)
    }
}

/// Where everything on the Graph goes, in the map's own coordinates (the
/// camera scales and pans them onto the window). Pure and deterministic:
/// the same sessions always land in the same places, and a session that
/// changes state never moves — only one arriving or leaving shifts the
/// rows around it.
///
/// The providers are hubs on a centre axis. Projects are clusters to
/// either side of it, alternating right and left in name order; inside a
/// cluster each main session is a row, grouped by provider in the hubs'
/// order and then by title, and its workers branch outward from it as a
/// tidy tree. A spoke joins each main session to its provider's hub, and
/// each hub sits level with the sessions it feeds, so the spokes stay
/// short and rarely cross.
struct OverviewGraphLayout: Equatable {
    enum Side: Int, Equatable, Sendable {
        case left = -1, right = 1
        var sign: CGFloat { CGFloat(rawValue) }
    }

    struct Hub: Identifiable, Equatable {
        /// The provider id.
        let id: String
        var center: CGPoint
        /// The main sessions its spokes reach, in drawing order.
        var sessionIDs: [String]

        var frame: CGRect {
            let radius = Metrics.hubDiameter / 2
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    struct Cluster: Identifiable, Equatable {
        /// The project name, or "" for sessions with no folder.
        let id: String
        let title: String
        let side: Side
        var frame: CGRect
        var nodeIDs: [String]
        /// How many of its sessions are in each state.
        var counts: [SessionActivity: Int]
    }

    struct Placed: Equatable {
        let id: String
        var frame: CGRect
        /// 0 for a main session, 1 for its workers, 2 for theirs.
        let depth: Int
        let side: Side
        let parentID: String?

        var isWorker: Bool { depth > 0 }
        var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    }

    struct Edge: Hashable {
        let from: String
        let to: String
    }

    var hubs: [Hub] = []
    var clusters: [Cluster] = []
    var nodes: [String: Placed] = [:]
    /// Node ids in drawing order: cluster by cluster, each family depth first.
    var order: [String] = []
    /// Parent to worker.
    var edges: [Edge] = []
    /// Everything drawn, hub captions and cluster titles included.
    var bounds: CGRect = .zero

    enum Metrics {
        static let hubDiameter: CGFloat = 60
        /// The hub's name and count under its orb.
        static let hubCaption: CGFloat = 38
        static let hubPitch: CGFloat = hubDiameter + hubCaption + 20
        /// From the centre axis to a cluster's inner edge: the spokes' run.
        static let spoke: CGFloat = 176
        static let clusterPad: CGFloat = 14
        static let clusterHeader: CGFloat = 36
        static let clusterGap: CGFloat = 28
        static let session = CGSize(width: 228, height: 52)
        static let worker = CGSize(width: 156, height: 32)
        static let rowGap: CGFloat = 12
        static let workerGap: CGFloat = 8
        /// Between a node's outer end and its workers' inner ends.
        static let branch: CGFloat = 42
        static let workersPerColumn = 6
        static let columnGap: CGFloat = 12
        static let margin: CGFloat = 28
    }

    /// The Graph for these sessions.
    static func make(_ input: [OverviewGraphNode]) -> OverviewGraphLayout {
        typealias M = Metrics
        var layout = OverviewGraphLayout()
        guard !input.isEmpty else { return layout }
        let byID = Dictionary(input.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // A worker hangs off its parent; one whose parent is not on the
        // Graph is a main session of its own. A parent loop (bad data,
        // never a real tree) is rooted at its smallest id, so every member
        // of it agrees and the loop still draws.
        func isRoot(_ node: OverviewGraphNode) -> Bool {
            var path = [node]
            while let parent = path[path.count - 1].parentID, let next = byID[parent] {
                if let start = path.firstIndex(where: { $0.id == next.id }) {
                    return path[start...].min { $0.id < $1.id }?.id == node.id
                }
                path.append(next)
            }
            return path.count == 1
        }
        var children: [String: [OverviewGraphNode]] = [:]
        var roots: [OverviewGraphNode] = []
        for node in byID.values {
            if isRoot(node) {
                roots.append(node)
            } else if let parent = node.parentID {
                children[parent, default: []].append(node)
                layout.edges.append(Edge(from: parent, to: node.id))
            }
        }
        for (id, members) in children { children[id] = members.sorted(by: rowOrder) }
        layout.edges.sort { ($0.from, $0.to) < ($1.from, $1.to) }

        // Each family's footprint: its own node, then its workers' block.
        var extents: [String: CGSize] = [:]
        func extent(_ node: OverviewGraphNode, depth: Int) -> CGSize {
            let own = depth == 0 ? M.session : M.worker
            let kids = children[node.id] ?? []
            guard !kids.isEmpty else {
                extents[node.id] = own
                return own
            }
            let block: CGSize
            if kids.allSatisfy({ children[$0.id] == nil }) {
                for kid in kids { extents[kid.id] = M.worker }
                block = gridSize(count: kids.count)
            } else {
                let sizes = kids.map { extent($0, depth: depth + 1) }
                block = CGSize(width: sizes.map(\.width).max() ?? 0,
                               height: sizes.map(\.height).reduce(0, +) + CGFloat(sizes.count - 1) * M.workerGap)
            }
            let size = CGSize(width: own.width + M.branch + block.width, height: max(own.height, block.height))
            extents[node.id] = size
            return size
        }

        // Clusters by project in name order, the folderless last; they
        // alternate right and left of the axis so the map stays balanced.
        let grouped = Dictionary(grouping: roots) { $0.project ?? "" }
        let keys = grouped.keys.sorted { left, right in
            if left.isEmpty != right.isEmpty { return right.isEmpty }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
        var stacks: [(key: String, rows: [OverviewGraphNode], size: CGSize, side: Side)] = []
        for (index, key) in keys.enumerated() {
            let rows = (grouped[key] ?? []).sorted(by: rowOrder)
            let sizes = rows.map { extent($0, depth: 0) }
            let width = 2 * M.clusterPad + (sizes.map(\.width).max() ?? 0)
            let height = M.clusterHeader + M.clusterPad + sizes.map(\.height).reduce(0, +)
                + CGFloat(max(0, sizes.count - 1)) * M.rowGap
            stacks.append((key, rows, CGSize(width: width, height: height), index % 2 == 0 ? .right : .left))
        }

        // Each side's column is centred on the hubs' axis.
        var tops: [Side: CGFloat] = [:]
        for side in [Side.right, .left] {
            let column = stacks.filter { $0.side == side }
            let total = column.map(\.size.height).reduce(0, +) + CGFloat(max(0, column.count - 1)) * M.clusterGap
            tops[side] = -total / 2
        }

        // One sweep of crossing reduction: rank the providers by where
        // their sessions sit with rows in name order, then order each
        // cluster's rows by that rank, so a hub's spokes fan out to a
        // block of rows rather than threading between another hub's.
        var sums: [String: (y: CGFloat, count: CGFloat)] = [:]
        var probe = tops
        for stack in stacks {
            var y = (probe[stack.side] ?? 0) + M.clusterHeader
            for root in stack.rows {
                let height = extents[root.id]?.height ?? M.session.height
                let sum = sums[root.provider] ?? (0, 0)
                sums[root.provider] = (sum.y + y + height / 2, sum.count + 1)
                y += height + M.rowGap
            }
            probe[stack.side] = (probe[stack.side] ?? 0) + stack.size.height + M.clusterGap
        }
        let ranked = sums.keys.sorted { left, right in
            let (a, b) = (sums[left].map { $0.y / $0.count } ?? 0, sums[right].map { $0.y / $0.count } ?? 0)
            return a != b ? a < b : left < right
        }
        let rank = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1, $0) })
        for index in stacks.indices {
            stacks[index].rows.sort { a, b in
                let (left, right) = (rank[a.provider] ?? 0, rank[b.provider] ?? 0)
                return left != right ? left < right : rowOrder(a, b)
            }
        }

        for (key, rows, size, side) in stacks {
            let y = tops[side] ?? 0
            let minX = side == .right ? M.spoke : -M.spoke - size.width
            let frame = CGRect(x: minX, y: y, width: size.width, height: size.height)
            var cluster = Cluster(id: key, title: key.isEmpty ? "No folder" : key, side: side,
                                  frame: frame, nodeIDs: [], counts: [:])
            var rowY = frame.minY + M.clusterHeader
            for root in rows {
                let height = extents[root.id]?.height ?? M.session.height
                layout.placeFamily(root, depth: 0, inner: M.spoke + M.clusterPad, midY: rowY + height / 2,
                                   side: side, children: children, extents: extents, cluster: &cluster)
                rowY += height + M.rowGap
            }
            layout.clusters.append(cluster)
            tops[side] = y + size.height + M.clusterGap
        }

        layout.placeHubs(roots: roots)
        var bounds = layout.clusters.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        for hub in layout.hubs {
            bounds = bounds.union(hub.frame.insetBy(dx: -30, dy: 0)
                .union(CGRect(x: hub.center.x - 60, y: hub.frame.maxY, width: 120, height: M.hubCaption)))
        }
        layout.bounds = bounds.insetBy(dx: -M.margin, dy: -M.margin)
        return layout
    }

    /// A block of leaf workers: one column of up to six, then more
    /// columns outward.
    static func gridSize(count: Int) -> CGSize {
        typealias M = Metrics
        let columns = (count + M.workersPerColumn - 1) / M.workersPerColumn
        let rows = min(count, M.workersPerColumn)
        return CGSize(width: CGFloat(columns) * M.worker.width + CGFloat(columns - 1) * M.columnGap,
                      height: CGFloat(rows) * M.worker.height + CGFloat(rows - 1) * M.workerGap)
    }

    /// By provider, then title, then id — never by state, so a session
    /// that starts waiting stays exactly where the eye last found it.
    /// Workers keep this order; main rows take the hubs' order first.
    static func rowOrder(_ a: OverviewGraphNode, _ b: OverviewGraphNode) -> Bool {
        if a.provider != b.provider { return a.provider < b.provider }
        let titles = a.label.localizedStandardCompare(b.label)
        if titles != .orderedSame { return titles == .orderedAscending }
        return a.id < b.id
    }

    /// Places a node with its inner end `inner` points out from the axis,
    /// centred on `midY`, and its workers' block centred beside it.
    private mutating func placeFamily(_ node: OverviewGraphNode, depth: Int, inner: CGFloat, midY: CGFloat,
                                      side: Side, children: [String: [OverviewGraphNode]],
                                      extents: [String: CGSize], cluster: inout Cluster) {
        typealias M = Metrics
        let size = depth == 0 ? M.session : M.worker
        place(node, depth: depth, inner: inner, size: size, midY: midY, side: side, cluster: &cluster)
        let kids = children[node.id] ?? []
        guard !kids.isEmpty else { return }
        let next = inner + size.width + M.branch
        if kids.allSatisfy({ children[$0.id] == nil }) {
            let block = Self.gridSize(count: kids.count)
            let top = midY - block.height / 2
            for (index, kid) in kids.enumerated() {
                let column = index / M.workersPerColumn
                let row = index % M.workersPerColumn
                // A short last column centres on the others.
                let inColumn = min(M.workersPerColumn, kids.count - column * M.workersPerColumn)
                let lift = CGFloat(min(kids.count, M.workersPerColumn) - inColumn) * (M.worker.height + M.workerGap) / 2
                let y = top + lift + CGFloat(row) * (M.worker.height + M.workerGap) + M.worker.height / 2
                place(kid, depth: depth + 1, inner: next + CGFloat(column) * (M.worker.width + M.columnGap),
                      size: M.worker, midY: y, side: side, cluster: &cluster)
            }
        } else {
            let heights = kids.map { extents[$0.id]?.height ?? M.worker.height }
            var y = midY - (heights.reduce(0, +) + CGFloat(kids.count - 1) * M.workerGap) / 2
            for (kid, height) in zip(kids, heights) {
                placeFamily(kid, depth: depth + 1, inner: next, midY: y + height / 2, side: side,
                            children: children, extents: extents, cluster: &cluster)
                y += height + M.workerGap
            }
        }
    }

    private mutating func place(_ node: OverviewGraphNode, depth: Int, inner: CGFloat, size: CGSize,
                                midY: CGFloat, side: Side, cluster: inout Cluster) {
        let minX = side == .right ? inner : -inner - size.width
        nodes[node.id] = Placed(id: node.id,
                                frame: CGRect(x: minX, y: midY - size.height / 2, width: size.width, height: size.height),
                                depth: depth, side: side, parentID: depth == 0 ? nil : node.parentID)
        order.append(node.id)
        cluster.nodeIDs.append(node.id)
        cluster.counts[node.activity, default: 0] += 1
    }

    /// Each hub level with the mean of its sessions, then eased apart
    /// just enough that no two touch, the group kept where it wanted to be.
    private mutating func placeHubs(roots: [OverviewGraphNode]) {
        let providers = Dictionary(grouping: roots, by: \.provider)
        var wanted: [(id: String, y: CGFloat, sessions: [String])] = providers.map { provider, members in
            let memberIDs = Set(members.map(\.id))
            let ids = order.filter { memberIDs.contains($0) }
            let ys = ids.compactMap { nodes[$0]?.center.y }
            return (provider, ys.reduce(0, +) / CGFloat(max(1, ys.count)), ids)
        }
        wanted.sort { $0.y != $1.y ? $0.y < $1.y : $0.id < $1.id }
        var ys = wanted.map(\.y)
        for index in ys.indices.dropFirst() {
            ys[index] = max(ys[index], ys[index - 1] + Metrics.hubPitch)
        }
        let drift = (wanted.map(\.y).reduce(0, +) - ys.reduce(0, +)) / CGFloat(max(1, ys.count))
        hubs = zip(wanted, ys).map { hub, y in
            Hub(id: hub.id, center: CGPoint(x: 0, y: y + drift), sessionIDs: hub.sessions)
        }
    }

    /// Whether everything sits where it sat in `other` — a state change
    /// alters a cluster's counts but moves nothing, and needs no settle.
    func placesMatch(_ other: OverviewGraphLayout) -> Bool {
        nodes == other.nodes
            && hubs.map(\.id) == other.hubs.map(\.id) && hubs.map(\.center) == other.hubs.map(\.center)
            && clusters.map(\.id) == other.clusters.map(\.id) && clusters.map(\.frame) == other.clusters.map(\.frame)
    }

    // MARK: Reading the map

    /// What sits under a point on the map: a node before a hub, a hub
    /// before the cluster behind it.
    enum Target: Hashable, Sendable {
        case node(String)
        case hub(String)
        case cluster(String)
    }

    func hit(_ point: CGPoint) -> Target? {
        for id in order.reversed() {
            if let placed = nodes[id], placed.frame.insetBy(dx: -3, dy: -3).contains(point) { return .node(id) }
        }
        for hub in hubs {
            let dx = point.x - hub.center.x, dy = point.y - hub.center.y
            if dx * dx + dy * dy <= pow(Metrics.hubDiameter / 2 + 6, 2) { return .hub(hub.id) }
        }
        return clusters.first { $0.frame.contains(point) }.map { .cluster($0.id) }
    }

    /// What a hover lights: a node with its hub, its parents and its
    /// workers; a hub with every session it feeds and theirs; a cluster
    /// with everything in it. Hubs come back as `hub:<provider>`.
    func neighbourhood(of target: Target, providers: [String: String]) -> Set<String> {
        switch target {
        case .node(let id):
            var lit: Set<String> = [id]
            var cursor = nodes[id]
            while let parent = cursor?.parentID, !lit.contains(parent) {
                lit.insert(parent)
                cursor = nodes[parent]
            }
            let root = cursor?.id ?? id
            if let provider = providers[root] { lit.insert("hub:" + provider) }
            lit.formUnion(descendants(of: id))
            return lit
        case .hub(let provider):
            var lit: Set<String> = ["hub:" + provider]
            for id in hubs.first(where: { $0.id == provider })?.sessionIDs ?? [] {
                lit.insert(id)
                lit.formUnion(descendants(of: id))
            }
            return lit
        case .cluster(let key):
            let ids = clusters.first { $0.id == key }?.nodeIDs ?? []
            var lit = Set(ids)
            for id in ids where nodes[id]?.depth == 0 {
                if let provider = providers[id] { lit.insert("hub:" + provider) }
            }
            return lit
        }
    }

    func descendants(of id: String) -> Set<String> {
        let children = Dictionary(grouping: edges, by: \.from)
        var found: Set<String> = []
        var frontier = [id]
        while let next = frontier.popLast() {
            for edge in children[next] ?? [] where edge.to != id && found.insert(edge.to).inserted {
                frontier.append(edge.to)
            }
        }
        return found
    }

    enum Direction: Sendable { case up, down, left, right }

    /// The arrow keys' walk: the nearest node that way, favouring the
    /// straight line over the diagonal. With nothing selected the first
    /// node in drawing order starts the walk.
    func neighbour(of id: String?, toward direction: Direction) -> String? {
        guard let id, let from = nodes[id]?.center else { return order.first }
        var best: (id: String, score: CGFloat)?
        for candidate in order where candidate != id {
            guard let to = nodes[candidate]?.center else { continue }
            let dx = to.x - from.x, dy = to.y - from.y
            let (along, across): (CGFloat, CGFloat) = switch direction {
            case .up: (-dy, abs(dx))
            case .down: (dy, abs(dx))
            case .left: (-dx, abs(dy))
            case .right: (dx, abs(dy))
            }
            // Within 60° of the arrow, and actually that way.
            guard along > 4, across <= along * 1.8 else { continue }
            let score = along + across * 2.2
            if best.map({ score < $0.score }) ?? true { best = (candidate, score) }
        }
        return best?.id
    }
}

/// How the map sits in the window: points on the map times `scale`, plus
/// `offset`, are points on screen.
struct GraphCamera: Equatable, Sendable {
    var scale: CGFloat
    var offset: CGPoint

    static let minScale: CGFloat = 0.2
    static let maxScale: CGFloat = 3
    /// Fitting never blows a small graph up past this.
    static let maxFitScale: CGFloat = 1
    /// The smallest scale the Graph opens at: titles still read. A map
    /// too big to fit at it opens on its middle, and ⌘0 shows the lot.
    static let readableScale: CGFloat = 0.6

    func screen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y)
    }

    func screen(_ rect: CGRect) -> CGRect {
        CGRect(origin: screen(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }

    func world(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
    }

    /// The whole map, centred, as large as fits (and no larger than
    /// `maxFitScale`).
    static func fit(_ bounds: CGRect, in size: CGSize, inset: CGFloat = 12) -> GraphCamera {
        guard bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else {
            return GraphCamera(scale: 1, offset: CGPoint(x: size.width / 2, y: size.height / 2))
        }
        let scale = min(maxFitScale, max(minScale, min((size.width - 2 * inset) / bounds.width,
                                                       (size.height - 2 * inset) / bounds.height)))
        return GraphCamera(scale: scale, offset: CGPoint(x: size.width / 2 - bounds.midX * scale,
                                                         y: size.height / 2 - bounds.midY * scale))
    }

    /// How the Graph opens: the whole map when it fits at a readable
    /// scale, else the readable scale on the map's middle, panned just
    /// far enough to show `focus` (the first session waiting on you).
    static func opening(_ bounds: CGRect, in size: CGSize, focus: CGRect?, inset: CGFloat = 12) -> GraphCamera {
        let whole = fit(bounds, in: size, inset: inset)
        guard whole.scale < readableScale else { return whole }
        let centred = GraphCamera(scale: readableScale,
                                  offset: CGPoint(x: size.width / 2 - bounds.midX * readableScale,
                                                  y: size.height / 2 - bounds.midY * readableScale))
        guard let focus else { return centred }
        return centred.revealing(focus, in: size) ?? centred
    }

    /// Zoomed by `factor` about a point on screen, which stays put.
    func zoomed(by factor: CGFloat, about anchor: CGPoint) -> GraphCamera {
        let scale = min(Self.maxScale, max(Self.minScale, self.scale * factor))
        let pinned = world(anchor)
        return GraphCamera(scale: scale, offset: CGPoint(x: anchor.x - pinned.x * scale,
                                                         y: anchor.y - pinned.y * scale))
    }

    func panned(by delta: CGSize) -> GraphCamera {
        GraphCamera(scale: scale, offset: CGPoint(x: offset.x + delta.width, y: offset.y + delta.height))
    }

    /// Panned back just enough that some of the map — `reach` points of
    /// it — stays in the window, so a fling never loses it.
    func keeping(_ bounds: CGRect, in size: CGSize, reach: CGFloat = 96) -> GraphCamera {
        guard !bounds.isEmpty else { return self }
        let shown = screen(bounds)
        var dx: CGFloat = 0, dy: CGFloat = 0
        if shown.maxX < reach { dx = reach - shown.maxX } else if shown.minX > size.width - reach {
            dx = size.width - reach - shown.minX
        }
        if shown.maxY < reach { dy = reach - shown.maxY } else if shown.minY > size.height - reach {
            dy = size.height - reach - shown.minY
        }
        return dx == 0 && dy == 0 ? self : panned(by: CGSize(width: dx, height: dy))
    }

    /// The least pan that brings `rect` (on the map) inside the window
    /// with `margin` to spare; nil when it is already in view.
    func revealing(_ rect: CGRect, in size: CGSize, margin: CGFloat = 32) -> GraphCamera? {
        let shown = screen(rect)
        var dx: CGFloat = 0, dy: CGFloat = 0
        if shown.minX < margin { dx = margin - shown.minX } else if shown.maxX > size.width - margin {
            dx = size.width - margin - shown.maxX
        }
        if shown.minY < margin { dy = margin - shown.minY } else if shown.maxY > size.height - margin {
            dy = size.height - margin - shown.maxY
        }
        guard dx != 0 || dy != 0 else { return nil }
        return panned(by: CGSize(width: dx, height: dy))
    }
}
