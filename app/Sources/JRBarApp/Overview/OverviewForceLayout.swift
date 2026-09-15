import Foundation
import simd

/// A small deterministic force-directed layout for the session graph:
/// pairwise repulsion (spatial-grid broad phase, distance cutoff),
/// Hooke springs along the edges, and a weak pull to the origin. The
/// integrator is damped and step-capped; when the largest per-tick
/// movement stays under `epsilon` for `settleTicks` consecutive ticks the
/// simulation reports `settled` and the canvas stops its clock — an
/// idle graph costs nothing.
///
/// Pure value type with no AppKit: the tests drive `tick()` /
/// `runUntilSettled` directly.
struct OverviewForceLayout {

    /// Tunables, all in graph units (points at scale 1) and unit ticks.
    struct Parameters: Sendable, Equatable {
        /// Spring stiffness (force per point of stretch).
        var springK = 0.05
        /// Pairwise repulsion strength, scaled by both node radii.
        var repulsionK = 6.0
        /// Beyond this distance nodes ignore each other — this is also
        /// the broad-phase cell size.
        var repulsionCutoff = 720.0
        /// The most one repulsion pair may push in a tick; keeps a dense
        /// cluster from exploding on the first frames.
        var maxRepulsion = 9.0
        /// Weak centring pull so disconnected islands drift home.
        var gravity = 0.006
        /// Velocity retention per tick; lower settles faster but moves
        /// less fluidly.
        var damping = 0.80
        /// Per-tick displacement cap — the stability clamp.
        var maxStep = 16.0
        /// A tick whose largest movement is under this counts as calm.
        var epsilon = 0.08
        /// Consecutive calm ticks before `settled` goes true.
        var settleTicks = 6
        /// Spring rest lengths: sub-agent satellites sit close to their
        /// parent; any future edge kind gets the longer run.
        var satelliteRest = 150.0
        var rest = 215.0
    }

    /// One simulated body. `pinned` nodes hold position (a mouse drag)
    /// but still exert forces on their neighbours.
    struct Body: Sendable, Equatable {
        var position: SIMD2<Double>
        var velocity: SIMD2<Double> = .zero
        var radius: Double
        var pinned = false
    }

    /// An indexed spring between two bodies.
    struct Spring: Sendable, Equatable, Hashable {
        var a: Int
        var b: Int
        var rest: Double
    }

    private(set) var ids: [String] = []
    private(set) var bodies: [Body] = []
    private(set) var springs: [Spring] = []
    private(set) var index: [String: Int] = [:]
    var parameters = Parameters()

    /// The largest movement of the last `tick`; `.infinity` before the
    /// first one.
    private(set) var lastDelta = Double.infinity
    private(set) var settled = false
    private var calmTicks = 0

    init() {}

    init(graph: OverviewGraph) {
        sync(with: graph)
    }

    /// Rebuild the body/spring set from a fresh graph document while
    /// keeping the positions of surviving ids — a roster refresh then
    /// looks like the graph breathing, not a re-scatter. New workers
    /// seed next to their parent; other new nodes join the spiral.
    mutating func sync(with graph: OverviewGraph) {
        let oldBodies = bodies
        let oldIndex = index
        var newBodies: [Body] = []
        var newIndex: [String: Int] = [:]
        newBodies.reserveCapacity(graph.nodes.count)
        for (i, node) in graph.nodes.enumerated() {
            let radius = Self.radius(of: node)
            if let oi = oldIndex[node.id], oi < oldBodies.count {
                var body = oldBodies[oi]
                body.radius = radius
                newBodies.append(body)
            } else {
                newBodies.append(Body(position: Self.seed(index: i), radius: radius))
            }
            newIndex[node.id] = i
        }
        // Second pass: a worker that just appeared blooms beside its
        // parent instead of crossing the canvas from the seed spiral.
        for (i, node) in graph.nodes.enumerated() {
            guard oldIndex[node.id] == nil,
                  let parent = node.parentID,
                  let pi = newIndex[parent], pi != i else { continue }
            newBodies[i].position = newBodies[pi].position + Self.seed(index: i) * 0.4
        }
        ids = graph.nodes.map(\.id)
        index = newIndex
        bodies = newBodies
        springs = graph.edges.compactMap { edge in
            guard let a = newIndex[edge.source], let b = newIndex[edge.target], a != b else { return nil }
            return Spring(a: a, b: b,
                          rest: edge.kind == .subagent ? parameters.satelliteRest : parameters.rest)
        }
        wake()
    }

    static func radius(of node: OverviewGraphNode) -> Double {
        let size = node.cardSize
        // Half the card diagonal — the repulsion's sense of "how much
        // room this card needs".
        return (size.width * size.width + size.height * size.height).squareRoot() / 2
    }

    /// Deterministic start positions: a golden-angle spiral, so a fresh
    /// graph always blossoms the same way and tests see stable results.
    static func seed(index i: Int) -> SIMD2<Double> {
        let angle = Double(i) * 2.399963229728653
        let r = 46.0 * Double(i).squareRoot()
        return SIMD2(cos(angle) * r, sin(angle) * r)
    }

    // MARK: Simulation

    /// One integration step. Returns the largest displacement, which is
    /// also what the sleep test reads.
    @discardableResult
    mutating func tick() -> Double {
        guard !bodies.isEmpty else {
            lastDelta = 0
            settled = true
            return 0
        }
        var forces = [SIMD2<Double>](repeating: .zero, count: bodies.count)
        applyRepulsion(into: &forces)
        for spring in springs {
            let delta = bodies[spring.b].position - bodies[spring.a].position
            let dist = max(simd_length(delta), 1)
            let pull = (delta / dist) * (parameters.springK * (dist - spring.rest))
            forces[spring.a] += pull
            forces[spring.b] -= pull
        }
        for (i, body) in bodies.enumerated() where !body.pinned {
            forces[i] -= body.position * parameters.gravity
        }
        var maxMove = 0.0
        for i in bodies.indices {
            guard !bodies[i].pinned else {
                bodies[i].velocity = .zero
                continue
            }
            var velocity = (bodies[i].velocity + forces[i]) * parameters.damping
            let speed = simd_length(velocity)
            if speed > parameters.maxStep {
                velocity *= parameters.maxStep / speed
            }
            bodies[i].velocity = velocity
            bodies[i].position += velocity
            maxMove = max(maxMove, min(speed, parameters.maxStep))
        }
        lastDelta = maxMove
        if maxMove < parameters.epsilon {
            calmTicks += 1
        } else {
            calmTicks = 0
        }
        if calmTicks >= parameters.settleTicks { settled = true }
        return maxMove
    }

    /// Steps until `settled` or the tick budget runs out; returns the
    /// ticks spent. The canvas uses this for Reduce Motion (a static
    /// layout that just appears) and the tests use it to prove the
    /// engine terminates.
    @discardableResult
    mutating func runUntilSettled(maxTicks: Int = 800) -> Int {
        var spent = 0
        while !settled && spent < maxTicks {
            tick()
            spent += 1
        }
        return spent
    }

    /// Repulsion through a uniform grid: each body only feels the 3×3
    /// cells around it, so a wide roster stays cheap.
    private func applyRepulsion(into forces: inout [SIMD2<Double>]) {
        let cutoff = parameters.repulsionCutoff
        var grid: [SIMD2<Int>: [Int]] = [:]
        grid.reserveCapacity(bodies.count)
        for (i, body) in bodies.enumerated() {
            grid[Self.cell(of: body.position, size: cutoff), default: []].append(i)
        }
        for i in bodies.indices {
            let origin = bodies[i].position
            let cell = Self.cell(of: origin, size: cutoff)
            for dx in -1...1 {
                for dy in -1...1 {
                    guard let members = grid[cell &+ SIMD2(dx, dy)] else { continue }
                    for j in members where j != i {
                        let delta = origin - bodies[j].position
                        let dist = simd_length(delta)
                        guard dist <= cutoff else { continue }
                        let push = parameters.repulsionK * bodies[i].radius * bodies[j].radius
                            / max(dist * dist, 36)
                        let direction = dist > 0.5 ? delta / dist : Self.separation(i, j)
                        forces[i] += direction * min(push, parameters.maxRepulsion)
                    }
                }
            }
        }
    }

    /// Two bodies on the exact same point still need a push direction —
    /// a deterministic one, so the layout never depends on a dice roll.
    private static func separation(_ i: Int, _ j: Int) -> SIMD2<Double> {
        let angle = Double(i &* 7919 &+ j &* 104729) * 0.0174533
        return SIMD2(cos(angle), sin(angle))
    }

    private static func cell(of p: SIMD2<Double>, size: Double) -> SIMD2<Int> {
        SIMD2(Int((p.x / size).rounded(.down)), Int((p.y / size).rounded(.down)))
    }

    // MARK: Interaction

    /// Wake the simulation after a drag, a graph change, a resize.
    mutating func wake() {
        settled = false
        calmTicks = 0
        lastDelta = .infinity
    }

    mutating func pin(_ id: String, at point: SIMD2<Double>) {
        guard let i = index[id] else { return }
        bodies[i].pinned = true
        bodies[i].position = point
        bodies[i].velocity = .zero
        wake()
    }

    mutating func movePinned(_ id: String, to point: SIMD2<Double>) {
        guard let i = index[id], bodies[i].pinned else { return }
        bodies[i].position = point
        wake()
    }

    mutating func unpin(_ id: String) {
        guard let i = index[id] else { return }
        bodies[i].pinned = false
        wake()
    }

    func position(of id: String) -> SIMD2<Double>? {
        index[id].map { bodies[$0].position }
    }

    /// The graph-space bounds the cards occupy — what "fit to view"
    /// frames.
    func contentBounds() -> (min: SIMD2<Double>, max: SIMD2<Double>)? {
        guard let first = bodies.first else { return nil }
        var lo = first.position
        var hi = first.position
        for (i, body) in bodies.enumerated() {
            lo = simd_min(lo, body.position)
            hi = simd_max(hi, body.position)
            _ = i
        }
        return (lo, hi)
    }
}
