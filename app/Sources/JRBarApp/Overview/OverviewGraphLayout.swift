import CoreGraphics
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
    /// Epoch seconds of the last thing it did — orders clusters and rows.
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

    init(_ entry: CoreRosterEntry) {
        let session = entry.session
        self.init(id: entry.id, parentID: session.parent,
                  project: OverviewFilter.projectName(of: session.cwd),
                  provider: session.provider, activity: SessionActivity.reduce(session),
                  label: session.displayLabel, lastActive: session.updatedAt ?? session.since ?? 0)
    }
}

/// Where everything on the Graph goes. Pure and deterministic: the same
/// sessions at the same width always land in the same places, so a
/// refresh that changes one state never reshuffles the picture.
///
/// Each project is a card. Inside it a main session is a large node
/// with its workers in rows beneath it, joined by an org-chart edge;
/// families flow left to right and wrap inside the card, and the cards
/// flow across the window the same way. Asking and failing work sorts
/// first — in the card and among the cards — so the eye lands on it.
struct OverviewGraphLayout: Equatable {
    struct Cluster: Identifiable, Equatable {
        /// The project name, or "" for sessions with no folder.
        let id: String
        let title: String
        var frame: CGRect
        var nodeIDs: [String]
        /// How many of its sessions are in each state.
        var counts: [SessionActivity: Int]
    }

    struct Placed: Equatable {
        let id: String
        var center: CGPoint
        let diameter: CGFloat
        let isWorker: Bool
        /// The width its caption may take.
        let captionWidth: CGFloat

        /// Where its edges to workers leave from: under the caption, so a
        /// line never crosses the name or the state it hangs from.
        var stem: CGPoint {
            CGPoint(x: center.x, y: center.y + diameter / 2
                    + (isWorker ? Metrics.workerCaption : Metrics.rootCaption) + 4)
        }
    }

    struct Edge: Hashable {
        let from: String
        let to: String
    }

    var clusters: [Cluster] = []
    var nodes: [String: Placed] = [:]
    /// Node ids in drawing order (clusters, then families, then workers).
    var order: [String] = []
    var edges: [Edge] = []
    var size: CGSize = .zero

    enum Metrics {
        static let margin: CGFloat = 20
        static let clusterGap: CGFloat = 16
        static let clusterPad: CGFloat = 16
        static let header: CGFloat = 40
        static let minClusterWidth: CGFloat = 220
        static let rootDiameter: CGFloat = 44
        static let workerDiameter: CGFloat = 28
        static let rootSlot = CGSize(width: 132, height: 44 + 8 + 30)
        static let workerSlot = CGSize(width: 78, height: 28 + 8 + 16)
        /// The caption's depth under a node's disc: two lines under a main
        /// session, one under a worker.
        static let rootCaption: CGFloat = 8 + 30
        static let workerCaption: CGFloat = 8 + 14
        static let workersPerRow = 4
        static let childGap: CGFloat = 34
        static let workerRowGap: CGFloat = 8
        static let familyGap: CGFloat = 14
        static let lineGap: CGFloat = 20
    }

    /// The Graph for these sessions at this width.
    static func make(_ input: [OverviewGraphNode], width: CGFloat) -> OverviewGraphLayout {
        typealias M = Metrics
        var layout = OverviewGraphLayout()
        guard !input.isEmpty else { return layout }
        let byID = Dictionary(input.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let nodes = Array(byID.values)

        // A worker belongs to its root ancestor's family; one whose parent
        // is not on the Graph is a family of its own. A parent loop (bad
        // data, never a real tree) is rooted at its smallest id, so every
        // member of it agrees and the loop still draws.
        func root(of node: OverviewGraphNode) -> OverviewGraphNode {
            var path = [node]
            while let parent = path[path.count - 1].parentID, let next = byID[parent] {
                if let start = path.firstIndex(where: { $0.id == next.id }) {
                    return path[start...].min { $0.id < $1.id } ?? next
                }
                path.append(next)
            }
            return path[path.count - 1]
        }
        var families: [String: [OverviewGraphNode]] = [:]
        var roots: [OverviewGraphNode] = []
        for node in nodes {
            let top = root(of: node)
            if top.id == node.id { roots.append(node) } else { families[top.id, default: []].append(node) }
        }
        for (id, members) in families { families[id] = members.sorted(by: rowOrder) }
        for node in nodes {
            if let parent = node.parentID, byID[parent] != nil, root(of: node).id != node.id {
                layout.edges.append(Edge(from: parent, to: node.id))
            }
        }
        layout.edges.sort { ($0.from, $0.to) < ($1.from, $1.to) }

        // Clusters by project, the most urgent first.
        let grouped = Dictionary(grouping: roots) { $0.project ?? "" }
        func urgency(_ key: String) -> (Int, Double) {
            let members = (grouped[key] ?? []).flatMap { [$0] + (families[$0.id] ?? []) }
            let rank = members.map(\.activity.sortRank).min() ?? .max
            let recent = members.map(\.lastActive).max() ?? 0
            return (rank, recent)
        }
        let keys = grouped.keys.sorted { left, right in
            let (a, b) = (urgency(left), urgency(right))
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 > b.1 }
            return left.localizedStandardCompare(right) == .orderedAscending
        }

        let usable = max(M.minClusterWidth, width - 2 * M.margin)
        let innerLimit = usable - 2 * M.clusterPad
        var cursor = CGPoint(x: M.margin, y: M.margin)
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for key in keys {
            let familyRoots = (grouped[key] ?? []).sorted(by: rowOrder)
            // Each family's footprint, then family lines wrapped to fit.
            let sizes = familyRoots.map { familySize(workers: families[$0.id]?.count ?? 0) }
            var lines: [[Int]] = [[]]
            var lineWidth: CGFloat = 0
            for (index, size) in sizes.enumerated() {
                let extra = (lines[lines.count - 1].isEmpty ? 0 : M.familyGap) + size.width
                if !lines[lines.count - 1].isEmpty, lineWidth + extra > innerLimit {
                    lines.append([index])
                    lineWidth = size.width
                } else {
                    lines[lines.count - 1].append(index)
                    lineWidth += extra
                }
            }
            let lineWidths = lines.map { line in
                line.reduce(0) { $0 + sizes[$1].width } + CGFloat(max(0, line.count - 1)) * M.familyGap
            }
            let lineHeights = lines.map { line in line.map { sizes[$0].height }.max() ?? 0 }
            let clusterWidth = min(usable, max(M.minClusterWidth, (lineWidths.max() ?? 0) + 2 * M.clusterPad))
            let clusterHeight = M.header + lineHeights.reduce(0, +)
                + CGFloat(max(0, lines.count - 1)) * M.lineGap + M.clusterPad

            if cursor.x > M.margin, cursor.x + clusterWidth > M.margin + usable {
                cursor = CGPoint(x: M.margin, y: cursor.y + rowHeight + M.clusterGap)
                rowHeight = 0
            }
            let frame = CGRect(origin: cursor, size: CGSize(width: clusterWidth, height: clusterHeight))
            var cluster = Cluster(id: key, title: key.isEmpty ? "No folder" : key, frame: frame,
                                  nodeIDs: [], counts: [:])

            var lineY = frame.minY + M.header
            for (lineIndex, line) in lines.enumerated() {
                // Each line centred in the card.
                var familyX = frame.minX + (clusterWidth - lineWidths[lineIndex]) / 2
                for index in line {
                    let top = familyRoots[index]
                    let size = sizes[index]
                    let rootCenter = CGPoint(x: familyX + size.width / 2, y: lineY + M.rootDiameter / 2)
                    layout.place(top, at: rootCenter, worker: false, in: &cluster)
                    let workers = families[top.id] ?? []
                    // Rows after the first sit half a slot over, so each
                    // edge reaches its node through a gap in the row above.
                    let perRow = min(workers.count, M.workersPerRow)
                    let stagger = workers.count > M.workersPerRow ? M.workerSlot.width / 2 : 0
                    let blockX = familyX + (size.width - CGFloat(perRow) * M.workerSlot.width - stagger) / 2
                    for (offset, worker) in workers.enumerated() {
                        let row = offset / M.workersPerRow
                        let column = offset % M.workersPerRow
                        let inRow = min(M.workersPerRow, workers.count - row * M.workersPerRow)
                        let x = blockX + (row % 2 == 1 ? stagger : 0)
                            + CGFloat(perRow - inRow) * M.workerSlot.width / 2
                            + CGFloat(column) * M.workerSlot.width + M.workerSlot.width / 2
                        let y = lineY + M.rootSlot.height + M.childGap
                            + CGFloat(row) * (M.workerSlot.height + M.workerRowGap)
                            + M.workerDiameter / 2
                        layout.place(worker, at: CGPoint(x: x, y: y), worker: true, in: &cluster)
                    }
                    familyX += size.width + M.familyGap
                }
                lineY += lineHeights[lineIndex] + M.lineGap
            }
            layout.clusters.append(cluster)
            cursor.x += clusterWidth + M.clusterGap
            rowHeight = max(rowHeight, clusterHeight)
            widest = max(widest, frame.maxX)
        }
        layout.size = CGSize(width: widest + M.margin, height: cursor.y + rowHeight + M.margin)
        return layout
    }

    /// A family's footprint: the root's slot, and its workers' rows under it.
    static func familySize(workers: Int) -> CGSize {
        typealias M = Metrics
        guard workers > 0 else { return M.rootSlot }
        let perRow = min(workers, M.workersPerRow)
        let rows = (workers + M.workersPerRow - 1) / M.workersPerRow
        let stagger = rows > 1 ? M.workerSlot.width / 2 : 0
        let width = max(M.rootSlot.width, CGFloat(perRow) * M.workerSlot.width + stagger)
        let height = M.rootSlot.height + M.childGap + CGFloat(rows) * M.workerSlot.height
            + CGFloat(rows - 1) * M.workerRowGap
        return CGSize(width: width, height: height)
    }

    /// Asking first, then failed, working, done…; the most recent first
    /// within a state; the id last so ties never shuffle.
    static func rowOrder(_ a: OverviewGraphNode, _ b: OverviewGraphNode) -> Bool {
        if a.activity.sortRank != b.activity.sortRank { return a.activity.sortRank < b.activity.sortRank }
        if a.lastActive != b.lastActive { return a.lastActive > b.lastActive }
        return a.id < b.id
    }

    private mutating func place(_ node: OverviewGraphNode, at center: CGPoint, worker: Bool,
                                in cluster: inout Cluster) {
        nodes[node.id] = Placed(id: node.id, center: center,
                                diameter: worker ? Metrics.workerDiameter : Metrics.rootDiameter,
                                isWorker: worker,
                                captionWidth: (worker ? Metrics.workerSlot.width : Metrics.rootSlot.width) - 8)
        order.append(node.id)
        cluster.nodeIDs.append(node.id)
        cluster.counts[node.activity, default: 0] += 1
    }
}
