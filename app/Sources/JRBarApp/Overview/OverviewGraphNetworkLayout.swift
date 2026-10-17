import CoreGraphics
import Foundation

extension OverviewGraphLayout {
    /// Provider sectors with real parent families on outward rings.
    /// Map supplies normalized topology and its deterministic cycle break.
    static func makeNetwork(_ input: [OverviewGraphNode]) -> OverviewGraphLayout {
        let map = make(input)
        var result = OverviewGraphLayout()
        result.presentation = .network
        guard !map.order.isEmpty else { return result }
        let byID = Dictionary(input.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let children = Dictionary(grouping: map.edges, by: \.from).mapValues { edges in
            edges.map(\.to).sorted { a, b in
                guard let left = byID[a], let right = byID[b] else { return a < b }
                return rowOrder(left, right)
            }
        }
        var weights: [String: Int] = [:]
        func weigh(_ id: String) -> Int {
            let leaves = (children[id] ?? []).map(weigh).reduce(0, +)
            let weight = max(1, leaves)
            weights[id] = weight
            return weight
        }
        let hubs = map.hubs.sorted { $0.id < $1.id }
        var roots: [String: [String]] = [:]
        for hub in hubs {
            roots[hub.id] = hub.sessionIDs.sorted { a, b in
                guard let left = byID[a], let right = byID[b] else { return a < b }
                if left.project != right.project { return (left.project ?? "") < (right.project ?? "") }
                return rowOrder(left, right)
            }
            for id in roots[hub.id] ?? [] { _ = weigh(id) }
        }
        let rootIDs = hubs.flatMap { roots[$0.id] ?? [] }
        let totalWeight = max(1, rootIDs.map { weights[$0] ?? 1 }.reduce(0, +))
        let fullCircle = 2 * CGFloat.pi
        var radius = max(300, CGFloat(totalWeight) * 210 / fullCircle)
        func point(_ angle: CGFloat, radius: CGFloat) -> CGPoint {
            CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
        func place(_ id: String, start: CGFloat, span: CGFloat, depth: Int) {
            let angle = start + span / 2
            let center = point(angle, radius: radius + CGFloat(depth) * 200)
            let worker = depth > 0
            let width: CGFloat = worker ? 116 : 160
            let height: CGFloat = worker ? 92 : 116
            let frame = CGRect(x: center.x - width / 2, y: center.y - 24, width: width, height: height)
            result.nodes[id] = Placed(id: id, frame: frame, depth: depth,
                                     side: center.x >= 0 ? .right : .left,
                                     parentID: map.nodes[id]?.parentID)
            result.order.append(id)
            var cursor = start
            let kids = children[id] ?? []
            let childWeight = max(1, kids.map { weights[$0] ?? 1 }.reduce(0, +))
            for child in kids {
                let childSpan = span * CGFloat(weights[child] ?? 1) / CGFloat(childWeight)
                place(child, start: cursor, span: childSpan, depth: depth + 1)
                cursor += childSpan
            }
        }
        // Wider rings resolve horizontal label collisions without changing
        // ordering or reacting to activity state. Each attempt is bounded.
        for _ in 0..<12 {
            result.nodes = [:]
            result.order = []
            result.hubs = []
            var cursor = -CGFloat.pi / 2
            for hub in hubs {
                let ids = roots[hub.id] ?? []
                let weight = ids.map { weights[$0] ?? 1 }.reduce(0, +)
                let span = fullCircle * CGFloat(weight) / CGFloat(totalWeight)
                let center = point(cursor + span / 2, radius: hubs.count == 1 ? 0 : radius - 170)
                result.hubs.append(Hub(id: hub.id, center: center, sessionIDs: ids))
                var rootCursor = cursor
                for id in ids {
                    let rootSpan = span * CGFloat(weights[id] ?? 1) / CGFloat(max(1, weight))
                    place(id, start: rootCursor, span: rootSpan, depth: 0)
                    rootCursor += rootSpan
                }
                cursor += span
            }
            let frames = result.order.compactMap { result.nodes[$0]?.frame }
            var collision = false
            for (index, frame) in frames.enumerated() {
                if frames.dropFirst(index + 1).contains(where: { frame.insetBy(dx: -6, dy: -6).intersects($0) }) {
                    collision = true
                    break
                }
            }
            if !collision { break }
            radius *= 1.2
        }
        result.edges = map.edges
        // Keep project membership for neighbourhood selection. Network
        // draws the project beside the node rather than a rectangular pane.
        result.clusters = map.clusters.map { original in
            let frames = original.nodeIDs.compactMap { result.nodes[$0]?.frame }
            let bounds = frames.reduce(CGRect.null) { $0.union($1) }
            return Cluster(id: original.id, title: original.title, side: original.side,
                           frame: bounds, nodeIDs: original.nodeIDs, counts: original.counts)
        }
        var bounds = result.nodes.values.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        for hub in result.hubs {
            bounds = bounds.union(hub.frame).union(hub.captionFrame)
        }
        result.bounds = bounds.insetBy(dx: -Metrics.margin, dy: -Metrics.margin)
        return result
    }
}
