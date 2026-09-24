import AppKit
import JRBarCore
import SwiftUI

/// The words under a session's title: its state, then how long and what
/// the run has cost so far when the transcript says.
struct GraphCaption: Equatable {
    let word: String
    let detail: String
}

/// Everything the scene draws that does not move with the camera: the
/// layout on screen, the one it is settling from, each node's data and
/// words, and what the pointer and the selection light.
struct GraphSceneModel {
    var layout: OverviewGraphLayout
    /// The layout it is settling from, while nodes arrive or leave.
    var previous: OverviewGraphLayout?
    /// Every node drawn, the leaving ones included.
    var nodes: [String: OverviewGraphNode]
    var captions: [String: GraphCaption]
    /// "6 sessions · 3 working" under each hub.
    var hubCaptions: [String: String]
    var unseen: Set<String>
    var selectedID: String?
    /// What a hover lights (node ids and `hub:<provider>`); nil lights all.
    var lit: Set<String>?
    /// Epoch seconds: how far a finished run's check has faded.
    var now: Double

    /// Only a working or waiting mark moves, so only those sit under the
    /// timeline; the rest draw once per change.
    static func moves(_ activity: SessionActivity) -> Bool {
        activity == .working || activity == .waiting
    }

    var hasMovingMarks: Bool {
        layout.order.contains { nodes[$0].map { Self.moves($0.activity) } ?? false }
    }

    /// The hubs and clusters to draw: the layout's, and any that left with
    /// the latest change and are still fading out.
    var hubsDrawn: [OverviewGraphLayout.Hub] {
        let kept = Set(layout.hubs.map(\.id))
        return layout.hubs + (previous?.hubs.filter { !kept.contains($0.id) } ?? [])
    }

    var clustersDrawn: [OverviewGraphLayout.Cluster] {
        let kept = Set(layout.clusters.map(\.id))
        return layout.clusters + (previous?.clusters.filter { !kept.contains($0.id) } ?? [])
    }

    /// Each provider's accent, parsed once per update rather than per frame.
    var accents: [String: Color] {
        var accents: [String: Color] = [:]
        for node in nodes.values where accents[node.provider] == nil {
            accents[node.provider] = ProviderStyle.style(for: node.provider).accent
        }
        return accents
    }
}

/// The Graph's drawing, at the camera's scale and offset. Animatable, so
/// a fit, a zoom and the settle after nodes arrive or leave all glide:
/// SwiftUI interpolates the camera, the settle and the hover's dimming,
/// and the canvases redraw each step.
///
/// Two layers. The still canvas holds the backdrop, clusters, edges, hubs
/// and nodes and redraws only when something changes; the moving canvas
/// holds the particles, the working arcs and the waiting glow, and a
/// timeline drives it only while something works or waits and the window
/// is on screen.
struct GraphScene: View, Animatable {
    let model: GraphSceneModel
    var camera: GraphCamera
    /// Counts up to `generation` as the latest change settles.
    var settle: Double
    /// 0 with nothing hovered, 1 with the hovered neighbourhood lit.
    var dim: Double
    let generation: Int
    /// Whether the moving layer exists: something works or waits and
    /// Reduce Motion is off. Without it the still layer draws their
    /// resting forms.
    let motion: Bool
    /// Whether its timeline runs: the window is on screen.
    let running: Bool
    /// A fixed instant for the moving layer, for render proofs.
    let frozenTime: TimeInterval?
    @Environment(\.colorScheme) private var colorScheme

    nonisolated var animatableData: AnimatablePair<AnimatablePair<Double, Double>,
                                                   AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get {
            AnimatablePair(AnimatablePair(settle, dim),
                           AnimatablePair(camera.scale, AnimatablePair(camera.offset.x, camera.offset.y)))
        }
        set {
            settle = newValue.first.first
            dim = newValue.first.second
            camera = GraphCamera(scale: newValue.second.first,
                                 offset: CGPoint(x: newValue.second.second.first, y: newValue.second.second.second))
        }
    }

    private var progress: Double { min(1, max(0, 1 - (Double(generation) - settle))) }

    var body: some View {
        let painter = GraphPainter(model: model, accents: model.accents, camera: camera, progress: progress,
                                   dim: dim, dark: colorScheme == .dark, motion: motion)
        ZStack {
            Canvas { context, size in
                painter.drawStill(&context, size: size)
            } symbols: {
                ForEach(Array(model.nodes.values)) { node in
                    GraphNodeLabel(node: node, caption: model.captions[node.id],
                                   side: painter.nodeSide(node.id), worker: painter.isWorker(node.id))
                        .tag("label." + node.id)
                }
                ForEach(model.hubsDrawn) { hub in
                    GraphHubCaption(provider: hub.id, detail: model.hubCaptions[hub.id] ?? "")
                        .tag("hub." + hub.id)
                }
                ForEach(model.clustersDrawn) { cluster in
                    GraphClusterTitle(cluster: cluster).tag("cluster." + cluster.id)
                }
                ForEach(GraphGlyph.all(for: model), id: \.self) { glyph in
                    glyph.view.tag(glyph.tag)
                }
            }
            if motion {
                if let frozenTime {
                    Canvas { context, _ in painter.drawMoving(&context, time: frozenTime) }
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { timeline in
                        Canvas { context, _ in
                            painter.drawMoving(&context, time: timeline.date.timeIntervalSinceReferenceDate)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Painter

/// The drawing code, a value the canvases capture: positions resolved
/// through the settle, colours through the palette, and one method per
/// layer.
private struct GraphPainter {
    typealias Layout = OverviewGraphLayout
    let model: GraphSceneModel
    let accents: [String: Color]
    let camera: GraphCamera
    let progress: Double
    let dim: Double
    let dark: Bool
    let motion: Bool

    private var settling: Bool { progress < 1 && model.previous != nil }

    // MARK: Where things are

    func nodeSide(_ id: String) -> Layout.Side {
        model.layout.nodes[id]?.side ?? model.previous?.nodes[id]?.side ?? .right
    }

    func isWorker(_ id: String) -> Bool {
        (model.layout.nodes[id] ?? model.previous?.nodes[id])?.isWorker ?? false
    }

    /// A node's frame through the settle, and how present it is: one that
    /// is arriving grows in and fades up, one that is leaving fades out.
    func frame(of id: String) -> (rect: CGRect, alpha: Double)? {
        let now = model.layout.nodes[id]?.frame
        guard settling else { return now.map { ($0, 1) } }
        let before = model.previous?.nodes[id]?.frame
        switch (before, now) {
        case let (before?, now?): return (Self.mix(before, now, progress), 1)
        case let (nil, now?):
            let grow = 0.9 + 0.1 * progress
            return (now.insetBy(dx: now.width * (1 - grow) / 2, dy: now.height * (1 - grow) / 2), progress)
        case let (before?, nil): return (before, 1 - progress)
        case (nil, nil): return nil
        }
    }

    /// A hub's centre through the settle: one arriving fades up, one
    /// leaving fades out where it stood.
    func hubCenter(_ hub: Layout.Hub) -> (point: CGPoint, alpha: Double) {
        guard settling else { return (hub.center, 1) }
        let before = model.previous?.hubs.first { $0.id == hub.id }
        guard model.layout.hubs.contains(where: { $0.id == hub.id }) else { return (hub.center, 1 - progress) }
        guard let before else { return (hub.center, progress) }
        return (Self.mix(before.center, hub.center, progress), 1)
    }

    func clusterFrame(_ cluster: Layout.Cluster) -> (rect: CGRect, alpha: Double) {
        guard settling else { return (cluster.frame, 1) }
        let before = model.previous?.clusters.first { $0.id == cluster.id }
        guard model.layout.clusters.contains(where: { $0.id == cluster.id }) else { return (cluster.frame, 1 - progress) }
        guard let before else { return (cluster.frame, progress) }
        return (Self.mix(before.frame, cluster.frame, progress), 1)
    }

    /// A hub's spokes: to the sessions it feeds now, and while settling to
    /// the ones that just left, fading with them.
    func spokeIDs(_ hub: Layout.Hub) -> [String] {
        guard settling, let before = model.previous?.hubs.first(where: { $0.id == hub.id }) else { return hub.sessionIDs }
        return hub.sessionIDs + before.sessionIDs.filter { model.layout.nodes[$0] == nil && !hub.sessionIDs.contains($0) }
    }

    /// Nodes that left with the latest change, still fading out.
    var leavingIDs: [String] {
        guard settling, let previous = model.previous else { return [] }
        return previous.order.filter { model.layout.nodes[$0] == nil }
    }

    static func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

    static func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: mix(a.x, b.x, t), y: mix(a.y, b.y, t))
    }

    static func mix(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        CGRect(x: mix(a.minX, b.minX, t), y: mix(a.minY, b.minY, t),
               width: mix(a.width, b.width, t), height: mix(a.height, b.height, t))
    }

    /// How brightly a node, hub (`hub:<provider>`) or edge draws under a hover.
    func light(_ key: String) -> Double {
        guard let lit = model.lit, !lit.contains(key) else { return 1 }
        return 1 - 0.74 * dim
    }

    func providerColor(_ provider: String) -> Color { accents[provider] ?? .gray }

    /// A finished run's check fades over its first hour, never to nothing.
    func doneFade(_ node: OverviewGraphNode) -> Double {
        guard node.activity == .done else { return 1 }
        let age = max(0, model.now - node.lastActive)
        return 1 - min(1, age / 3_600) * 0.55
    }

    /// Idle and ended nodes sit back; everything else stands forward.
    func presence(_ node: OverviewGraphNode) -> Double {
        switch node.activity {
        case .idle: 0.62
        case .ended: 0.5
        case .done: 0.72 + 0.28 * doneFade(node)
        default: 1
        }
    }

    // MARK: Geometry

    static func orb(in rect: CGRect, side: Layout.Side, worker: Bool) -> (center: CGPoint, radius: CGFloat) {
        let radius: CGFloat = worker ? 12 : 18
        let inset: CGFloat = worker ? 5 : 9
        let x = side == .right ? rect.minX + inset + radius : rect.maxX - inset - radius
        return (CGPoint(x: x, y: rect.midY), radius)
    }

    static func capsule(_ rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: rect.height / 2, style: .continuous)
    }

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// A horizontal S from one port to another.
    static func bezier(_ start: CGPoint, _ end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        let pull = (end.x - start.x) * 0.5
        path.addCurve(to: end, control1: CGPoint(x: start.x + pull, y: start.y),
                      control2: CGPoint(x: end.x - pull, y: end.y))
        return path
    }

    static func point(on start: CGPoint, _ end: CGPoint, at t: CGFloat) -> CGPoint {
        let pull = (end.x - start.x) * 0.5
        let c1 = CGPoint(x: start.x + pull, y: start.y), c2 = CGPoint(x: end.x - pull, y: end.y)
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * start.x + b * c1.x + c * c2.x + d * end.x,
                       y: a * start.y + b * c1.y + c * c2.y + d * end.y)
    }

    /// The part of the map inside the window, with room for glows.
    func visibleWorld(_ size: CGSize) -> CGRect {
        let origin = camera.world(CGPoint.zero)
        return CGRect(x: origin.x, y: origin.y, width: size.width / camera.scale, height: size.height / camera.scale)
            .insetBy(dx: -60, dy: -60)
    }

    /// A hairline that stays a hairline at any zoom.
    var hairline: CGFloat { 0.75 / camera.scale }

    // MARK: Palette

    var backdropTop: Color { dark ? Color(red: 0.118, green: 0.12, blue: 0.135) : Color(red: 0.972, green: 0.974, blue: 0.982) }
    var backdropBottom: Color { dark ? Color(red: 0.082, green: 0.084, blue: 0.096) : Color(red: 0.94, green: 0.943, blue: 0.955) }
    var capsuleTop: Color { dark ? Color(red: 0.2, green: 0.203, blue: 0.222) : .white }
    var capsuleBottom: Color { dark ? Color(red: 0.16, green: 0.162, blue: 0.178) : Color(red: 0.985, green: 0.986, blue: 0.99) }
    var capsuleStroke: Color { dark ? .white.opacity(0.1) : .black.opacity(0.085) }
    var capsuleShine: Color { dark ? .white.opacity(0.13) : .white }
    var shadow: Color { dark ? .black.opacity(0.4) : Color(red: 0.1, green: 0.12, blue: 0.2).opacity(0.07) }
    var clusterFill: Color { dark ? .white.opacity(0.03) : .white.opacity(0.55) }
    var clusterStroke: Color { dark ? .white.opacity(0.075) : .black.opacity(0.065) }
    var working: Color { SessionActivity.working.tint }

    /// The end of an edge in the state it feeds: amber for an ask, red
    /// for a failure, the provider's own colour otherwise.
    func edgeEnd(_ activity: SessionActivity, accent: Color) -> Color {
        switch activity {
        case .waiting: .orange
        case .failed: .red
        case .done: .green
        default: accent
        }
    }

    /// An edge's weight and brightness: how active the node it feeds is.
    static func edgeWeight(_ activity: SessionActivity) -> (width: CGFloat, alpha: Double) {
        switch activity {
        case .working: (2.2, 0.8)
        case .waiting: (2.2, 0.85)
        case .failed: (1.5, 0.55)
        case .done: (1.3, 0.42)
        case .idle: (1.1, 0.3)
        case .ended: (1, 0.2)
        }
    }

    // MARK: Still layer

    func drawStill(_ context: inout GraphicsContext, size: CGSize) {
        drawBackdrop(&context, size: size)
        var world = context
        world.translateBy(x: camera.offset.x, y: camera.offset.y)
        world.scaleBy(x: camera.scale, y: camera.scale)
        let visible = visibleWorld(size)
        drawClusters(&world, visible: visible)
        drawSpokes(&world)
        drawFamilies(&world)
        drawHubs(&world)
        for id in model.layout.order + leavingIDs {
            drawNode(&world, id: id, visible: visible)
        }
    }

    private func drawBackdrop(_ context: inout GraphicsContext, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        context.fill(Path(bounds), with: .linearGradient(Gradient(colors: [backdropTop, backdropBottom]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        // A soft light where the hubs are, so the map has a heart.
        let heart = camera.screen(CGPoint.zero)
        let reach = max(size.width, size.height) * 0.6
        let glow = dark ? Color.white.opacity(0.045) : Color.white.opacity(0.9)
        context.fill(Path(bounds), with: .radialGradient(Gradient(colors: [glow, glow.opacity(0)]),
                                                         center: heart, startRadius: 0, endRadius: reach))
        // A dot grid that pans and zooms with the map, thinned out when
        // zoomed far out and doubled up when zoomed far in: one tiled fill,
        // however many dots.
        var step = GraphDots.tile * camera.scale
        while step < 16 { step *= 2 }
        while step > 44 { step /= 2 }
        let origin = CGPoint(x: camera.offset.x.truncatingRemainder(dividingBy: step) - step,
                             y: camera.offset.y.truncatingRemainder(dividingBy: step) - step)
        context.fill(Path(bounds), with: .tiledImage(dark ? GraphDots.dark : GraphDots.light, origin: origin,
                                                     scale: step / GraphDots.tile))
    }

    private func drawClusters(_ context: inout GraphicsContext, visible: CGRect) {
        for cluster in model.clustersDrawn {
            let (rect, alpha) = clusterFrame(cluster)
            guard rect.intersects(visible) else { continue }
            var c = context
            c.opacity = alpha * light("cluster:" + cluster.id)
            let waiting = (cluster.counts[.waiting] ?? 0) > 0
            // The halo: a soft pool of light under the cluster, then its
            // pane, a hairline, and its title. Someone waiting inside
            // warms all three a little.
            let halo = rect.insetBy(dx: -rect.width * 0.1, dy: -rect.height * 0.16)
            let haloColor = waiting ? Color.orange.opacity(dark ? 0.07 : 0.06)
                : (dark ? Color.white.opacity(0.03) : Color.white.opacity(0.85))
            var pool = c
            pool.translateBy(x: halo.midX, y: halo.midY)
            pool.scaleBy(x: 1, y: halo.height / halo.width)
            let reach = halo.width / 2
            pool.fill(Self.circle(.zero, reach), with: .radialGradient(
                Gradient(colors: [haloColor, haloColor.opacity(0)]),
                center: .zero, startRadius: reach * 0.35, endRadius: reach))
            let pane = Path(roundedRect: rect, cornerRadius: 24, style: .continuous)
            c.fill(pane, with: .color(clusterFill))
            if waiting { c.fill(pane, with: .color(.orange.opacity(dark ? 0.03 : 0.025))) }
            c.stroke(pane, with: .color(waiting ? Color.orange.opacity(0.3) : clusterStroke), lineWidth: hairline)
            if let title = c.resolveSymbol(id: "cluster." + cluster.id) {
                drawLabel(&c, title, in: CGRect(x: rect.minX + 16, y: rect.minY + 9, width: rect.width - 32, height: 20))
            }
        }
    }

    /// Map labels — cluster titles and hub names — never shrink below
    /// readable: zoomed far out they hold their size on screen while the
    /// map shrinks under them.
    private func drawLabel(_ context: inout GraphicsContext, _ symbol: GraphicsContext.ResolvedSymbol, in rect: CGRect,
                           anchor: UnitPoint = .topLeading) {
        let grow = min(2.6, max(1, 0.72 / camera.scale))
        guard grow > 1 else {
            context.draw(symbol, in: rect)
            return
        }
        var c = context
        let pivot = CGPoint(x: rect.minX + rect.width * anchor.x, y: rect.minY + rect.height * anchor.y)
        c.translateBy(x: pivot.x, y: pivot.y)
        c.scaleBy(x: grow, y: grow)
        c.draw(symbol, in: CGRect(x: -rect.width * anchor.x, y: -rect.height * anchor.y,
                                  width: rect.width, height: rect.height))
    }

    private func drawSpokes(_ context: inout GraphicsContext) {
        for hub in model.hubsDrawn {
            let (center, hubAlpha) = hubCenter(hub)
            let accent = providerColor(hub.id)
            for id in spokeIDs(hub) {
                guard let node = model.nodes[id], let (rect, alpha) = frame(of: id) else { continue }
                let side = nodeSide(id)
                let start = CGPoint(x: center.x + side.sign * Layout.Metrics.hubDiameter / 2, y: center.y)
                let end = CGPoint(x: side == .right ? rect.minX : rect.maxX, y: rect.midY)
                let lit = min(light(id), light("hub:" + hub.id))
                strokeEdge(&context, from: start, to: end, start: accent, activity: node.activity,
                           alpha: min(alpha, hubAlpha) * lit * doneFade(node))
            }
        }
    }

    private func drawFamilies(_ context: inout GraphicsContext) {
        for edge in model.layout.edges {
            guard let parent = model.nodes[edge.from], let child = model.nodes[edge.to],
                  let (from, fromAlpha) = frame(of: edge.from), let (to, toAlpha) = frame(of: edge.to) else { continue }
            let side = nodeSide(edge.to)
            let start = CGPoint(x: side == .right ? from.maxX : from.minX, y: from.midY)
            let end = CGPoint(x: side == .right ? to.minX : to.maxX, y: to.midY)
            let lit = min(light(edge.from), light(edge.to))
            strokeEdge(&context, from: start, to: end, start: providerColor(parent.provider), activity: child.activity,
                       alpha: min(fromAlpha, toAlpha) * lit * doneFade(child))
        }
    }

    /// One edge: a gradient from the colour it leaves in to the state it
    /// feeds, as heavy and as bright as that state is active, with a
    /// soft glow under a working one.
    private func strokeEdge(_ context: inout GraphicsContext, from start: CGPoint, to end: CGPoint, start color: Color,
                            activity: SessionActivity, alpha: Double) {
        guard alpha > 0.01 else { return }
        let path = Self.bezier(start, end)
        let (width, bright) = Self.edgeWeight(activity)
        let tail = edgeEnd(activity, accent: color)
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [color.opacity(bright * alpha * 0.7), tail.opacity(bright * alpha)]),
            startPoint: start, endPoint: end)
        if activity == .working || activity == .waiting {
            context.stroke(path, with: .linearGradient(
                Gradient(colors: [color.opacity(0.1 * alpha), tail.opacity(0.16 * alpha)]),
                startPoint: start, endPoint: end), style: StrokeStyle(lineWidth: width * 3.2, lineCap: .round))
        }
        let dash: [CGFloat] = activity == .ended ? [3, 4] : []
        context.stroke(path, with: shading, style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
    }

    private func drawHubs(_ context: inout GraphicsContext) {
        for hub in model.hubsDrawn {
            let (center, alpha) = hubCenter(hub)
            var c = context
            c.opacity = alpha * light("hub:" + hub.id)
            let accent = providerColor(hub.id)
            let radius = Layout.Metrics.hubDiameter / 2
            // A halo of its own colour, a hairline orbit, then the orb: a
            // lit top, a deeper rim, and a glassy highlight.
            c.fill(Self.circle(center, radius * 2.1), with: .radialGradient(
                Gradient(colors: [accent.opacity(dark ? 0.3 : 0.2), accent.opacity(0)]),
                center: center, startRadius: radius * 0.6, endRadius: radius * 2.1))
            c.stroke(Self.circle(center, radius + 7), with: .color(accent.opacity(0.25)), lineWidth: hairline * 1.2)
            let orb = Self.circle(center, radius)
            c.fill(orb, with: .radialGradient(
                Gradient(colors: [accent.mix(with: .white, by: 0.35), accent, accent.mix(with: .black, by: 0.22)]),
                center: CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.45),
                startRadius: 0, endRadius: radius * 1.5))
            let shine = CGRect(x: center.x - radius * 0.62, y: center.y - radius * 0.9,
                               width: radius * 1.24, height: radius * 0.8)
            c.fill(Path(ellipseIn: shine), with: .linearGradient(
                Gradient(colors: [.white.opacity(0.5), .white.opacity(0)]),
                startPoint: CGPoint(x: shine.midX, y: shine.minY), endPoint: CGPoint(x: shine.midX, y: shine.maxY)))
            c.stroke(orb, with: .color(.white.opacity(dark ? 0.22 : 0.35)), lineWidth: hairline)
            if let glyph = c.resolveSymbol(id: GraphGlyph(provider: hub.id, tier: .hub, solid: true).tag) {
                c.draw(glyph, at: center)
            }
            if let caption = c.resolveSymbol(id: "hub." + hub.id) {
                drawLabel(&c, caption, in: CGRect(x: center.x - 80, y: center.y + radius + 9, width: 160, height: 30),
                          anchor: .top)
            }
        }
    }

    private func drawNode(_ context: inout GraphicsContext, id: String, visible: CGRect) {
        guard let node = model.nodes[id], let (rect, alpha) = frame(of: id), rect.intersects(visible) else { return }
        let side = nodeSide(id)
        let worker = isWorker(id)
        let accent = providerColor(node.provider)
        let lit = light(id)
        var c = context
        c.opacity = alpha * lit * presence(node)
        let body = Self.capsule(rect)

        // Lift: two soft layers of shadow under the capsule.
        c.fill(Self.capsule(rect.offsetBy(dx: 0, dy: 3).insetBy(dx: -2, dy: -1)), with: .color(shadow.opacity(0.55)))
        c.fill(Self.capsule(rect.offsetBy(dx: 0, dy: 1)), with: .color(shadow))
        c.fill(body, with: .linearGradient(Gradient(colors: [capsuleTop, capsuleBottom]),
                                           startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                           endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        switch node.activity {
        case .waiting:
            c.fill(body, with: .color(.orange.opacity(dark ? 0.1 : 0.07)))
            c.stroke(body, with: .color(.orange.opacity(0.6)), lineWidth: hairline * 1.6)
            if !motion { strokeGlow(&c, rect: rect, strength: 0.6) }
        case .failed:
            c.fill(body, with: .color(.red.opacity(dark ? 0.08 : 0.04)))
            c.stroke(body, with: .color(.red.opacity(0.4)), lineWidth: hairline * 1.3)
        default:
            c.stroke(body, with: .color(capsuleStroke), lineWidth: hairline)
        }
        // The glass's top edge catches the light.
        if dark {
            var shine = Path()
            let r = rect.height / 2
            shine.addArc(center: CGPoint(x: rect.minX + r, y: rect.midY), radius: r - 0.5,
                         startAngle: .degrees(200), endAngle: .degrees(270), clockwise: false)
            shine.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY + 0.5))
            shine.addArc(center: CGPoint(x: rect.maxX - r, y: rect.midY), radius: r - 0.5,
                         startAngle: .degrees(270), endAngle: .degrees(340), clockwise: false)
            c.stroke(shine, with: .color(capsuleShine), lineWidth: hairline)
        }

        let (center, radius) = Self.orb(in: rect, side: side, worker: worker)
        drawOrb(&c, center: center, radius: radius, accent: accent, node: node, worker: worker)
        drawRing(&c, center: center, radius: radius, node: node, worker: worker)

        // Zoomed far out a node keeps its shape and state and drops its
        // words, which could not be read there anyway.
        if camera.scale >= (worker ? 0.5 : 0.4), let label = c.resolveSymbol(id: "label." + id) {
            let size = GraphNodeLabel.size(worker: worker)
            let gap: CGFloat = worker ? 8 : 11
            let x = side == .right ? center.x + radius + gap : center.x - radius - gap - size.width
            c.draw(label, in: CGRect(x: x, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        }
        if model.unseen.contains(id) {
            let dot = CGPoint(x: side == .right ? rect.minX + 6 : rect.maxX - 6, y: rect.minY + 6)
            c.fill(Self.circle(dot, 3.5), with: .color(capsuleTop))
            c.fill(Self.circle(dot, 2.6), with: .color(Color(nsColor: UnseenDot.fill)))
        }
        if model.selectedID == id {
            var ring = context
            ring.opacity = alpha * max(0.45, lit)
            let outline = Path(roundedRect: rect.insetBy(dx: -4, dy: -4), cornerRadius: rect.height / 2 + 4,
                               style: .continuous)
            ring.stroke(outline, with: .color(.accentColor.opacity(0.25)), lineWidth: 6)
            ring.stroke(outline, with: .color(.accentColor), lineWidth: 2)
        }
    }

    /// The provider's orb: solid and lit while the run is alive (working
    /// or waiting), a pale tint of its colour once it is not.
    private func drawOrb(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat, accent: Color,
                         node: OverviewGraphNode, worker: Bool) {
        let alive = GraphSceneModel.moves(node.activity)
        let orb = Self.circle(center, radius)
        if alive {
            context.fill(orb, with: .radialGradient(
                Gradient(colors: [accent.mix(with: .white, by: 0.3), accent, accent.mix(with: .black, by: 0.18)]),
                center: CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.45),
                startRadius: 0, endRadius: radius * 1.5))
            let shine = CGRect(x: center.x - radius * 0.6, y: center.y - radius * 0.88,
                               width: radius * 1.2, height: radius * 0.75)
            context.fill(Path(ellipseIn: shine), with: .linearGradient(
                Gradient(colors: [.white.opacity(0.45), .white.opacity(0)]),
                startPoint: CGPoint(x: shine.midX, y: shine.minY), endPoint: CGPoint(x: shine.midX, y: shine.maxY)))
        } else {
            context.fill(orb, with: .color(accent.opacity(dark ? 0.2 : 0.14)))
            context.stroke(orb, with: .color(accent.opacity(0.28)), lineWidth: hairline)
        }
        let glyph = GraphGlyph(provider: node.provider, tier: worker ? .worker : .session, solid: alive)
        if let symbol = context.resolveSymbol(id: glyph.tag) {
            context.draw(symbol, at: center)
        }
    }

    /// The state ring round the orb. Working's turning arc and waiting's
    /// breath live on the moving layer; here they get their tracks, or
    /// their resting forms when nothing moves.
    private func drawRing(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat,
                          node: OverviewGraphNode, worker: Bool) {
        let ring = radius + (worker ? 3 : 4)
        let width: CGFloat = worker ? 1.8 : 2.3
        let path = Self.circle(center, ring)
        switch node.activity {
        case .working:
            context.stroke(path, with: .color(working.opacity(0.2)), lineWidth: width)
            if !motion {
                var arc = Path()
                arc.addArc(center: center, radius: ring, startAngle: .degrees(-90), endAngle: .degrees(40),
                           clockwise: false)
                context.stroke(arc, with: .color(working), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        case .waiting:
            context.stroke(path, with: .color(.orange), lineWidth: width)
        case .failed:
            context.stroke(path, with: .color(.red), lineWidth: width)
            drawBadge(&context, center: center, ring: ring, worker: worker, color: .red, check: false, alpha: 1)
        case .done:
            let fade = doneFade(node)
            context.stroke(path, with: .color(.green.opacity(0.8 * fade)), lineWidth: width - 0.4)
            drawBadge(&context, center: center, ring: ring, worker: worker, color: .green, check: true, alpha: fade)
        case .idle:
            context.stroke(path, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
        case .ended:
            context.stroke(path, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [2, 2.5]))
        }
    }

    /// A small disc on the ring, top-trailing: a check once done, a cross
    /// once failed.
    private func drawBadge(_ context: inout GraphicsContext, center: CGPoint, ring: CGFloat, worker: Bool,
                           color: Color, check: Bool, alpha: Double) {
        let size: CGFloat = worker ? 10 : 13
        let angle = -Double.pi / 4
        let at = CGPoint(x: center.x + ring * CGFloat(cos(angle)), y: center.y + ring * CGFloat(sin(angle)))
        var c = context
        c.opacity *= alpha
        c.fill(Self.circle(at, size / 2 + 1.5), with: .color(capsuleTop))
        c.fill(Self.circle(at, size / 2), with: .color(color))
        var mark = Path()
        let s = size * 0.22
        if check {
            mark.move(to: CGPoint(x: at.x - s * 1.1, y: at.y + s * 0.05))
            mark.addLine(to: CGPoint(x: at.x - s * 0.25, y: at.y + s * 0.85))
            mark.addLine(to: CGPoint(x: at.x + s * 1.15, y: at.y - s * 0.8))
        } else {
            mark.move(to: CGPoint(x: at.x - s, y: at.y - s))
            mark.addLine(to: CGPoint(x: at.x + s, y: at.y + s))
            mark.move(to: CGPoint(x: at.x + s, y: at.y - s))
            mark.addLine(to: CGPoint(x: at.x - s, y: at.y + s))
        }
        c.stroke(mark, with: .color(.white), style: StrokeStyle(lineWidth: size * 0.14, lineCap: .round, lineJoin: .round))
    }

    /// The amber glow round a capsule that waits on you, outside its edge
    /// so it never washes over the words.
    private func strokeGlow(_ context: inout GraphicsContext, rect: CGRect, strength: Double) {
        for (spread, opacity) in [(9.0, 0.07), (5.0, 0.13), (2.5, 0.22)] as [(CGFloat, Double)] {
            let halo = rect.insetBy(dx: -spread / 2 - 1, dy: -spread / 2 - 1)
            context.stroke(Path(roundedRect: halo, cornerRadius: halo.height / 2, style: .continuous),
                           with: .color(.orange.opacity(opacity * strength * 1.6)), lineWidth: spread)
        }
    }

    // MARK: Moving layer

    func drawMoving(_ context: inout GraphicsContext, time: TimeInterval) {
        var world = context
        world.translateBy(x: camera.offset.x, y: camera.offset.y)
        world.scaleBy(x: camera.scale, y: camera.scale)

        // Work flowing out along the spokes and down to the workers.
        var sparks = world
        if dark { sparks.blendMode = .plusLighter }
        for hub in model.layout.hubs {
            let (center, hubAlpha) = hubCenter(hub)
            let accent = providerColor(hub.id)
            for id in hub.sessionIDs where model.nodes[id]?.activity == .working {
                guard let (rect, alpha) = frame(of: id) else { continue }
                let side = nodeSide(id)
                let start = CGPoint(x: center.x + side.sign * Layout.Metrics.hubDiameter / 2, y: center.y)
                let end = CGPoint(x: side == .right ? rect.minX : rect.maxX, y: rect.midY)
                drawSparks(&sparks, from: start, to: end, color: accent, seed: id,
                           alpha: min(alpha, hubAlpha) * min(light(id), light("hub:" + hub.id)), time: time)
            }
        }
        for edge in model.layout.edges where model.nodes[edge.to]?.activity == .working {
            guard let parent = model.nodes[edge.from],
                  let (from, fromAlpha) = frame(of: edge.from), let (to, toAlpha) = frame(of: edge.to) else { continue }
            let side = nodeSide(edge.to)
            let start = CGPoint(x: side == .right ? from.maxX : from.minX, y: from.midY)
            let end = CGPoint(x: side == .right ? to.minX : to.maxX, y: to.midY)
            drawSparks(&sparks, from: start, to: end, color: providerColor(parent.provider), seed: edge.to,
                       alpha: min(fromAlpha, toAlpha) * min(light(edge.from), light(edge.to)), time: time)
        }

        // A hub whose work is running sends out a slow ring now and then.
        for hub in model.layout.hubs where hub.sessionIDs.contains(where: { model.nodes[$0]?.activity == .working }) {
            let (center, alpha) = hubCenter(hub)
            let cycle = (time + Double(Self.seed(hub.id)) * 0.37) / 3.2
            let phase = CGFloat(cycle.truncatingRemainder(dividingBy: 1))
            let radius = Layout.Metrics.hubDiameter / 2 + 7 + phase * 22
            let strength = 0.4 * Double(1 - phase) * alpha * light("hub:" + hub.id)
            world.stroke(Self.circle(center, radius), with: .color(providerColor(hub.id).opacity(strength)),
                         lineWidth: 1.4 * (1 - phase) + 0.3)
        }

        for id in model.layout.order {
            guard let node = model.nodes[id], GraphSceneModel.moves(node.activity),
                  let (rect, alpha) = frame(of: id) else { continue }
            var c = world
            c.opacity = alpha * light(id)
            let worker = isWorker(id)
            let (center, radius) = Self.orb(in: rect, side: nodeSide(id), worker: worker)
            if node.activity == .working {
                // A comet: the head, then two fading lengths of tail.
                let ring = radius + (worker ? 3 : 4)
                let width: CGFloat = worker ? 1.8 : 2.3
                let head = (time * 280 + Double(Self.seed(id) % 360)).truncatingRemainder(dividingBy: 360)
                for (length, opacity) in [(150.0, 0.18), (95.0, 0.45), (45.0, 1.0)] {
                    var arc = Path()
                    arc.addArc(center: center, radius: ring, startAngle: .degrees(head - length),
                               endAngle: .degrees(head), clockwise: false)
                    c.stroke(arc, with: .color(working.opacity(opacity)),
                             style: StrokeStyle(lineWidth: width, lineCap: .round))
                }
            } else {
                // Waiting on you: a slow amber breath the eye finds first.
                let breath = 0.5 - 0.5 * cos(time * 2 * .pi / 2.4)
                strokeGlow(&c, rect: rect, strength: 0.45 + 0.55 * breath)
            }
        }
    }

    /// Three sparks running the length of an edge, brightest mid-flight.
    private func drawSparks(_ context: inout GraphicsContext, from start: CGPoint, to end: CGPoint, color: Color,
                            seed: String, alpha: Double, time: TimeInterval) {
        guard alpha > 0.02 else { return }
        let length = hypot(end.x - start.x, end.y - start.y) * 1.12
        let period = max(1.2, Double(length) / 70)
        let offset = Double(Self.seed(seed) % 1000) / 1000
        let count = length > 180 ? 3 : 2
        for index in 0..<count {
            let t = (time / period + offset + Double(index) / Double(count)).truncatingRemainder(dividingBy: 1)
            let at = Self.point(on: start, end, at: CGFloat(t))
            let strength = sin(Double.pi * t) * alpha
            context.fill(Self.circle(at, 6), with: .color(color.opacity((dark ? 0.24 : 0.16) * strength)))
            context.fill(Self.circle(at, 2.4), with: .color(color.opacity(strength)))
            if dark { context.fill(Self.circle(at, 1.1), with: .color(.white.opacity(0.85 * strength))) }
        }
    }

    /// A stable small number per id, so each edge and arc keeps its own phase.
    static func seed(_ id: String) -> Int {
        id.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    }
}

/// One dot of the backdrop's grid, centred in a tile the canvas repeats.
enum GraphDots {
    static let tile: CGFloat = 24

    static let light = image(NSColor.black.withAlphaComponent(0.1))
    static let dark = image(NSColor.white.withAlphaComponent(0.085))

    private static func image(_ color: NSColor) -> Image {
        let size = NSSize(width: tile, height: tile)
        let dot = NSImage(size: size, flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: size.width / 2 - 0.85, y: size.height / 2 - 0.85,
                                        width: 1.7, height: 1.7)).fill()
            return true
        }
        return Image(nsImage: dot)
    }
}

// MARK: - Symbols

/// A provider's glyph at one of three sizes, white on a lit orb or in
/// its own colour on a pale one — drawn once, stamped wherever it appears.
struct GraphGlyph: Hashable {
    enum Tier: Hashable { case hub, session, worker }
    let provider: String
    let tier: Tier
    let solid: Bool

    var tag: String { "glyph.\(provider).\(tier).\(solid)" }

    static func all(for model: GraphSceneModel) -> [GraphGlyph] {
        var glyphs: Set<GraphGlyph> = Set(model.hubsDrawn.map { GraphGlyph(provider: $0.id, tier: .hub, solid: true) })
        for node in model.nodes.values {
            let worker = (model.layout.nodes[node.id] ?? model.previous?.nodes[node.id])?.isWorker ?? false
            glyphs.insert(GraphGlyph(provider: node.provider, tier: worker ? .worker : .session,
                                     solid: GraphSceneModel.moves(node.activity)))
        }
        return glyphs.sorted { $0.tag < $1.tag }
    }

    @ViewBuilder
    var view: some View {
        let style = ProviderStyle.style(for: provider)
        let size: CGFloat = switch tier {
        case .hub: 25
        case .session: 15
        case .worker: 10.5
        }
        let color = solid ? Color.white : style.accent
        Group {
            switch style.glyph {
            case .symbol(let name):
                Image(systemName: name).font(.system(size: size, weight: .bold))
            case .text(let text):
                Text(text).font(.system(size: size * 1.15, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(color)
        .shadow(color: solid ? .black.opacity(0.18) : .clear, radius: 0.5, y: 0.5)
        .frame(width: size * 2, height: size * 2)
    }
}

/// A node's words: its title, and under a session's its state line.
struct GraphNodeLabel: View {
    let node: OverviewGraphNode
    let caption: GraphCaption?
    let side: OverviewGraphLayout.Side
    let worker: Bool

    static func size(worker: Bool) -> CGSize {
        worker ? CGSize(width: 116, height: 30) : CGSize(width: 160, height: 44)
    }

    private var line: Text {
        guard let caption else { return Text(verbatim: "") }
        let word = Text(caption.word).foregroundStyle(node.activity.wordColor)
        guard !caption.detail.isEmpty else { return word }
        return Text("\(word)\(Text(verbatim: " · " + caption.detail).foregroundStyle(.secondary))")
    }

    var body: some View {
        let size = Self.size(worker: worker)
        let alignment: HorizontalAlignment = side == .right ? .leading : .trailing
        VStack(alignment: alignment, spacing: 2) {
            Text(node.label)
                .font(.system(size: worker ? 11 : 12.5, weight: worker ? .medium : .semibold))
                .foregroundStyle(.primary)
            if !worker, caption != nil {
                line.font(.system(size: 10.5)).monospacedDigit()
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: size.width, height: size.height, alignment: side == .right ? .leading : .trailing)
    }
}

/// A hub's name and what it is running.
struct GraphHubCaption: View {
    let provider: String
    let detail: String

    var body: some View {
        VStack(spacing: 1) {
            Text(ProviderStyle.style(for: provider).name)
                .font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(width: 160, height: 30)
    }
}

/// A cluster's title: its folder, its name, how many sessions, and a dot
/// per state inside it — one compact run from the corner, so it can hold
/// its size on screen when the map is zoomed far out.
struct GraphClusterTitle: View {
    let cluster: OverviewGraphLayout.Cluster

    private static let order: [SessionActivity] = [.waiting, .failed, .working, .done, .idle, .ended]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: cluster.id.isEmpty ? "questionmark.folder" : "folder.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Text(cluster.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(cluster.nodeIDs.count)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            HStack(spacing: 3) {
                ForEach(Self.order, id: \.self) { activity in
                    if (cluster.counts[activity] ?? 0) > 0 {
                        Circle().fill(activity.tint.opacity(activity == .ended ? 0.5 : 1))
                            .frame(width: 5.5, height: 5.5)
                    }
                }
            }
            .padding(.leading, 2)
        }
        .frame(width: max(40, cluster.frame.width - 32), height: 20, alignment: .leading)
    }
}
