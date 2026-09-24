import JRBarCore
import SwiftUI

/// The Overview's Graph: every session as a node, grouped into one card
/// per project, workers in rows under the session that spawned them and
/// joined to it by an edge. The ring says the state — a turning arc while
/// working, an amber pulse while it waits on you, red when it failed,
/// green once done — and the badge repeats it for a glance. A click
/// inspects, a double-click opens, and nothing here answers an agent.
struct OverviewGraphView: View {
    @Bindable var store: OverviewStore

    var body: some View {
        let nodes = store.graphNodes
        VStack(spacing: 0) {
            GraphHeader(store: store, nodes: nodes)
            if !store.isLive, !store.roster.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal.circle").foregroundStyle(.orange)
                    Text("Monitor not connected — showing the last roster it reported.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(.orange.opacity(0.07))
            }
            Divider()
            if nodes.isEmpty {
                emptyState
            } else {
                GeometryReader { proxy in
                    let layout = OverviewGraphLayout.make(nodes, width: proxy.size.width)
                    ScrollView([.vertical, .horizontal]) {
                        OverviewGraphCanvas(store: store, layout: layout, nodes: nodes)
                            .frame(width: max(layout.size.width, proxy.size.width),
                                   height: max(layout.size.height, proxy.size.height),
                                   alignment: .topLeading)
                    }
                    .opacity(store.isLive ? 1 : 0.6)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !store.isLive, store.roster.isEmpty {
            OverviewEmptyState(symbol: "bolt.horizontal.circle", title: "Monitor not connected",
                               text: "The graph draws the monitor's roster. It fills in as soon as the socket is live.")
        } else if store.graphScope == .active {
            OverviewEmptyState(symbol: "point.3.connected.trianglepath.dotted", title: "Nothing running",
                               text: store.search.isEmpty
                                   ? "Sessions appear here while they work, wait on you or fail, and for an hour after they finish."
                                   : "No live session matches the search.",
                               actionTitle: store.roster.isEmpty ? nil : "Show everything on record",
                               action: { store.graphScope = .everything })
        } else {
            OverviewEmptyState(symbol: "tray", title: store.roster.isEmpty ? "Nothing on record" : "Nothing matches",
                               text: store.roster.isEmpty
                                   ? "The monitor has no sessions on record yet."
                                   : "No session matches the search.")
        }
    }

}

// MARK: - Canvas

/// The drawing itself, at the size the layout asked for: the backdrop,
/// the project cards, the ink, the nodes and the hover card.
struct OverviewGraphCanvas: View {
    @Bindable var store: OverviewStore
    let layout: OverviewGraphLayout
    let nodes: [OverviewGraphNode]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hoveredID: String?

    var body: some View {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let entries = Dictionary(store.roster.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let moving = nodes.contains { $0.activity == .working || $0.activity == .waiting }
        let animating = moving && !reduceMotion && store.windowOpen && store.pane == .graph
        return ZStack(alignment: .topLeading) {
            GraphBackdrop()
                .contentShape(Rectangle())
                .onTapGesture { store.selectInGraph(nil) }
            ForEach(layout.clusters) { cluster in
                GraphClusterCard(cluster: cluster)
                    .frame(width: cluster.frame.width, height: cluster.frame.height)
                    .offset(x: cluster.frame.minX, y: cluster.frame.minY)
                    .onTapGesture { store.selectInGraph(nil) }
            }
            // Two layers: the still ink redraws only when the graph
            // changes; the timeline redraws just the working and waiting
            // marks, however long the record behind them.
            GraphInk(layout: layout, nodes: byID, selectedID: store.selectedID, hoveredID: hoveredID,
                     time: 0, still: reduceMotion, layer: .still)
                .allowsHitTesting(false)
            if moving {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animating)) { timeline in
                    GraphInk(layout: layout, nodes: byID, selectedID: store.selectedID, hoveredID: hoveredID,
                             time: animating ? timeline.date.timeIntervalSinceReferenceDate : 0,
                             still: reduceMotion, layer: .moving)
                }
                .allowsHitTesting(false)
            }
            ForEach(layout.order, id: \.self) { id in
                if let node = byID[id], let placed = layout.nodes[id] {
                    GraphNodeView(node: node, placed: placed, store: store,
                                  since: entries[id]?.session.since.map { Date(timeIntervalSince1970: $0) },
                                  unseen: entries[id].map(store.showsUnseenDot) ?? false,
                                  selected: store.selectedID == id, hovered: hoveredID == id)
                        .position(placed.center)
                        .onHover { inside in
                            if inside { hoveredID = id } else if hoveredID == id { hoveredID = nil }
                        }
                        .gesture(TapGesture(count: 2).onEnded { open(id, entry: entries[id]) })
                        .simultaneousGesture(TapGesture().onEnded { store.selectInGraph(id) })
                        .contextMenu { menu(for: id, entry: entries[id]) }
                        .accessibilityAction { store.selectInGraph(id) }
                        .accessibilityAction(named: "Open") { open(id, entry: entries[id]) }
                }
            }
            if let id = hoveredID, let node = byID[id], let placed = layout.nodes[id], let entry = entries[id] {
                GraphHoverCard(node: node, entry: entry, store: store)
                    .fixedSize()
                    .alignmentGuide(.leading) { _ in
                        -Self.cardX(for: placed, in: layout.size.width)
                    }
                    .alignmentGuide(.top) { _ in -(placed.center.y - placed.diameter / 2 - 4) }
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredID)
    }

    /// The hover card sits right of its node, or left when the right edge
    /// is too close. Pure arithmetic, so the nonisolated alignment-guide
    /// closure can call it.
    nonisolated static func cardX(for placed: OverviewGraphLayout.Placed, in width: CGFloat) -> CGFloat {
        let right = placed.center.x + placed.diameter / 2 + 12
        return right + 250 > width ? max(8, placed.center.x - placed.diameter / 2 - 262) : right
    }

    private func open(_ id: String, entry: CoreRosterEntry?) {
        store.selectInGraph(id)
        guard let entry, store.canOpen(entry) else { return }
        Task { await store.openSession(id) }
    }

    @ViewBuilder
    private func menu(for id: String, entry: CoreRosterEntry?) -> some View {
        Button("Open") { open(id, entry: entry) }
            .disabled(entry.map { !store.canOpen($0) } ?? true)
        Button("Show in Roster") { store.showInRoster(id) }
        if let entry, entry.session.workers > 0 {
            Button("Show \(entry.session.workers) Workers in Roster") {
                store.showInRoster(id)
                store.workerFilter = id
            }
        }
    }
}


// MARK: - Header

/// Scope on the left, the state tally in the middle, the gestures named
/// on the right.
private struct GraphHeader: View {
    @Bindable var store: OverviewStore
    let nodes: [OverviewGraphNode]

    private static let tallied: [SessionActivity] = [.waiting, .failed, .working, .done, .idle]

    var body: some View {
        let counts = Dictionary(grouping: nodes, by: \.activity).mapValues(\.count)
        HStack(spacing: 14) {
            Picker("Show", selection: $store.graphScope) {
                ForEach(OverviewStore.GraphScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Active: live sessions and the last hour's finishes · Everything: every session on record")
            HStack(spacing: 12) {
                ForEach(Self.tallied, id: \.self) { activity in
                    if let count = counts[activity], count > 0 {
                        HStack(spacing: 5) {
                            Circle().fill(activity.tint).frame(width: 7, height: 7)
                            Text("\(count) \(Self.word(activity))")
                                .foregroundStyle(activity.wordIsLoud ? activity.tint : .secondary)
                        }
                    }
                }
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            Spacer(minLength: 8)
            Text("Click to inspect · double-click to open")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private static func word(_ activity: SessionActivity) -> String {
        switch activity {
        case .waiting: "waiting"
        case .failed: "failed"
        case .working: "working"
        case .done: "done"
        case .idle: "idle"
        case .ended: "ended"
        }
    }
}

// MARK: - Backdrop and cards

/// A faint dot grid — enough texture to read as a canvas, never enough
/// to compete with the nodes.
private struct GraphBackdrop: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 18
            var dots = Path()
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                    x += spacing
                }
                y += spacing
            }
            context.fill(dots, with: .color(.primary.opacity(0.07)))
        }
    }
}

/// One project's card: its name, how many sessions, and a dot per state.
private struct GraphClusterCard: View {
    let cluster: OverviewGraphLayout.Cluster

    private var waiting: Bool { (cluster.counts[.waiting] ?? 0) > 0 }
    private static let order: [SessionActivity] = [.waiting, .failed, .working, .done, .idle, .ended]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: cluster.id.isEmpty ? "questionmark.folder" : "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(cluster.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(cluster.nodeIDs.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.primary.opacity(0.07)))
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    ForEach(Self.order, id: \.self) { activity in
                        if (cluster.counts[activity] ?? 0) > 0 {
                            Circle().fill(activity.tint.opacity(activity == .ended ? 0.5 : 1))
                                .frame(width: 6, height: 6)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: OverviewGraphLayout.Metrics.header - 6)
            Spacer(minLength: 0)
        }
        .background(shape.fill(.primary.opacity(0.035)))
        .background(shape.fill(.background.opacity(0.6)))
        .overlay(shape.strokeBorder(waiting ? Color.orange.opacity(0.45) : Color.primary.opacity(0.09),
                                    lineWidth: waiting ? 1 : 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(cluster.title), \(cluster.nodeIDs.count) sessions")
    }
}

// MARK: - Ink: edges and rings

/// Which of the Graph's two ink layers draws a mark. Only a working or
/// waiting mark moves, so only those sit under the 30 fps timeline; the
/// rest draw once per change.
enum GraphInkLayer: Equatable, Sendable {
    case still, moving

    /// A node's ring: the working comet and the waiting pulse move.
    static func ring(_ activity: SessionActivity) -> GraphInkLayer {
        activity == .working || activity == .waiting ? .moving : .still
    }

    /// A worker's drop: only a working one marches.
    static func drop(_ activity: SessionActivity) -> GraphInkLayer {
        activity == .working ? .moving : .still
    }
}

/// The edges from a session to its workers and each node's state ring,
/// in one Canvas per layer. The still layer holds the trunks, buses and
/// quiet drops and rings; the moving layer holds the working and waiting
/// marks, and a timeline drives it only while something works or waits
/// and the window is on screen. A selection ring rides with its node's.
private struct GraphInk: View {
    let layout: OverviewGraphLayout
    let nodes: [String: OverviewGraphNode]
    let selectedID: String?
    let hoveredID: String?
    let time: TimeInterval
    let still: Bool
    let layer: GraphInkLayer

    var body: some View {
        Canvas { context, _ in
            // Edges family by family: one trunk and bus per parent, one
            // drop per worker in its state's colour.
            let families = Dictionary(grouping: layout.edges, by: \.from)
            for parentID in families.keys.sorted() {
                guard let parent = layout.nodes[parentID] else { continue }
                let children = (families[parentID] ?? []).compactMap { edge -> (OverviewGraphLayout.Placed, SessionActivity)? in
                    guard let placed = layout.nodes[edge.to], let node = nodes[edge.to] else { return nil }
                    return (placed, node.activity)
                }
                if layer == .moving, !children.contains(where: { GraphInkLayer.drop($0.1) == .moving }) { continue }
                drawFamily(&context, parent: parent, children: children)
            }
            for id in layout.order {
                guard let placed = layout.nodes[id], let node = nodes[id] else { continue }
                guard GraphInkLayer.ring(node.activity) == layer else { continue }
                drawRing(&context, placed: placed, activity: node.activity,
                         selected: id == selectedID, hovered: id == hoveredID)
            }
        }
    }

    /// An org-chart family: a trunk down from under the parent's caption,
    /// a bus across, and a drop into each worker. Rows after the first sit
    /// in the gaps of the row above, so their drops pass between nodes.
    private func drawFamily(_ context: inout GraphicsContext, parent: OverviewGraphLayout.Placed,
                            children: [(OverviewGraphLayout.Placed, SessionActivity)]) {
        let stem = parent.stem
        let tops = children.map { CGPoint(x: $0.0.center.x, y: $0.0.center.y - $0.0.diameter / 2 - 4) }
        guard let firstTop = tops.map(\.y).min(), firstTop - stem.y > 12 else {
            // A worker's own workers can share its row: a plain curve.
            for (index, child) in children.enumerated() where GraphInkLayer.drop(child.1) == layer {
                var path = Path()
                path.move(to: stem)
                let end = tops[index]
                path.addCurve(to: end, control1: CGPoint(x: stem.x, y: stem.y + 24),
                              control2: CGPoint(x: end.x, y: end.y - 24))
                strokeDrop(&context, path, activity: child.1)
            }
            return
        }
        let busY = stem.y + min(14, (firstTop - stem.y) / 2)
        let radius = min(7, busY - stem.y)
        let xs = tops.map(\.x)
        let left = min(xs.min() ?? stem.x, stem.x)
        let right = max(xs.max() ?? stem.x, stem.x)
        // The outermost drops turn off the bus on a rounded corner.
        let leftCorner = left < stem.x - radius
        let rightCorner = right > stem.x + radius

        if layer == .still {
            var bus = Path()
            bus.move(to: stem)
            bus.addLine(to: CGPoint(x: stem.x, y: busY))
            bus.move(to: CGPoint(x: left + (leftCorner ? radius : 0), y: busY))
            bus.addLine(to: CGPoint(x: right - (rightCorner ? radius : 0), y: busY))
            context.stroke(bus, with: .color(.secondary.opacity(0.4)),
                           style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }

        for (index, child) in children.enumerated() where GraphInkLayer.drop(child.1) == layer {
            let top = tops[index]
            var drop = Path()
            if leftCorner, top.x == left {
                drop.move(to: CGPoint(x: left + radius, y: busY))
                drop.addQuadCurve(to: CGPoint(x: left, y: busY + radius), control: CGPoint(x: left, y: busY))
            } else if rightCorner, top.x == right {
                drop.move(to: CGPoint(x: right - radius, y: busY))
                drop.addQuadCurve(to: CGPoint(x: right, y: busY + radius), control: CGPoint(x: right, y: busY))
            } else {
                drop.move(to: CGPoint(x: top.x, y: busY))
            }
            drop.addLine(to: top)
            strokeDrop(&context, drop, activity: child.1)
        }
    }

    /// A worker's line in its state: marching dashes while it works, amber
    /// while it waits on you, red once it failed, a quiet grey otherwise.
    private func strokeDrop(_ context: inout GraphicsContext, _ path: Path, activity: SessionActivity) {
        switch activity {
        case .working:
            context.stroke(path, with: .color(.accentColor.opacity(0.2)), lineWidth: 3)
            context.stroke(path, with: .color(.accentColor.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 6],
                                              dashPhase: still ? 0 : -time * 20))
        case .waiting:
            context.stroke(path, with: .color(.orange.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        case .failed:
            context.stroke(path, with: .color(.red.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
        default:
            context.stroke(path, with: .color(.secondary.opacity(0.4)),
                           style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
        }
    }

    private func drawRing(_ context: inout GraphicsContext, placed: OverviewGraphLayout.Placed,
                          activity: SessionActivity, selected: Bool, hovered: Bool) {
        let scale: CGFloat = hovered ? 1.08 : 1
        let radius = placed.diameter / 2 * scale + (placed.isWorker ? 3 : 4)
        let center = placed.center
        func circle(_ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }
        let width: CGFloat = placed.isWorker ? 2 : 2.5
        switch activity {
        case .working:
            context.stroke(circle(radius), with: .color(.accentColor.opacity(0.16)), lineWidth: width)
            // A comet: the head, then two fading lengths of tail.
            let head = still ? -90.0 : (time * 300).truncatingRemainder(dividingBy: 360) - 90
            for (length, opacity) in [(110.0, 0.2), (70.0, 0.45), (36.0, 1.0)] {
                var arc = Path()
                arc.addArc(center: center, radius: radius, startAngle: .degrees(head - length),
                           endAngle: .degrees(head), clockwise: false)
                context.stroke(arc, with: .color(.accentColor.opacity(opacity)),
                               style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        case .waiting:
            context.stroke(circle(radius), with: .color(.orange), lineWidth: width)
            if !still {
                let pulse = (time / 1.6).truncatingRemainder(dividingBy: 1)
                context.stroke(circle(radius + 2 + CGFloat(pulse) * 9),
                               with: .color(.orange.opacity(0.5 * (1 - pulse))), lineWidth: 1.5)
            }
        case .failed:
            context.stroke(circle(radius), with: .color(.red), lineWidth: width)
        case .done:
            context.stroke(circle(radius), with: .color(.green.opacity(0.75)), lineWidth: width - 0.5)
        case .idle:
            context.stroke(circle(radius), with: .color(.secondary.opacity(0.4)), lineWidth: 1)
        case .ended:
            context.stroke(circle(radius), with: .color(.secondary.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
        if selected {
            context.stroke(circle(radius + 5), with: .color(.accentColor), lineWidth: 2)
        }
    }
}

// MARK: - Nodes

/// A node's body: the provider's glyph on a tinted disc, a state badge,
/// and its caption hung underneath without moving the disc's centre.
private struct GraphNodeView: View {
    let node: OverviewGraphNode
    let placed: OverviewGraphLayout.Placed
    let store: OverviewStore
    /// When the session's current state began — a main session's caption
    /// counts from it; a worker keeps its name only.
    let since: Date?
    let unseen: Bool
    let selected: Bool
    let hovered: Bool

    private var style: ProviderStyle { ProviderStyle.style(for: node.provider) }
    private var finished: Bool { node.activity == .done || node.activity == .ended }

    var body: some View {
        let diameter = placed.diameter
        ZStack {
            Circle().fill(style.accent.opacity(finished ? 0.09 : 0.17))
            Circle().strokeBorder(style.accent.opacity(0.3), lineWidth: 0.5)
            glyph(size: diameter * 0.46)
                .opacity(finished ? 0.6 : 1)
        }
        .frame(width: diameter, height: diameter)
        .background(Circle().fill(.background))
        .overlay(alignment: .topTrailing) { badge(diameter: diameter) }
        .overlay(alignment: .topLeading) {
            if unseen { UnseenDot().offset(x: -1, y: 1).help("Finished since you last looked") }
        }
        .overlay(alignment: .top) { captionView.offset(y: diameter + 8) }
        .scaleEffect(hovered ? 1.08 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
        .contentShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(node.label), \(style.name), \(node.activity.word)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func glyph(size: CGFloat) -> some View {
        switch style.glyph {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(style.accent)
        case .text(let text):
            Text(text)
                .font(.system(size: size * 1.1, weight: .semibold, design: .rounded))
                .foregroundStyle(style.accent)
        }
    }

    @ViewBuilder
    private func badge(diameter: CGFloat) -> some View {
        let size: CGFloat = placed.isWorker ? 12 : 15
        let symbol: String? = switch node.activity {
        case .waiting: "exclamationmark"
        case .failed: "xmark"
        case .done: "checkmark"
        default: nil
        }
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: size * 0.55, weight: .black))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(node.activity.tint))
                .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                .offset(x: size * 0.3, y: -size * 0.3)
        }
    }

    private var captionView: some View {
        VStack(spacing: 1) {
            Text(node.label)
                .font(.system(size: placed.isWorker ? 10 : 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(finished ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if !placed.isWorker {
                GraphCaptionLine(store: store, activity: node.activity, since: since)
            }
        }
        .frame(width: placed.captionWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Working · 12m" under a main session. The only part of a node that
/// reads the store's clock, so each second redraws captions, not the
/// whole graph.
private struct GraphCaptionLine: View {
    let store: OverviewStore
    let activity: SessionActivity
    let since: Date?

    var body: some View {
        Text([activity.word, PanelStore.elapsed(since: since, now: store.now)]
            .compactMap { $0 }.joined(separator: " · "))
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(activity.wordColor)
            .lineLimit(1)
    }
}

/// What a hover reveals: the name, who and what state, where it works,
/// and what it is doing or asking.
private struct GraphHoverCard: View {
    let node: OverviewGraphNode
    let entry: CoreRosterEntry
    let store: OverviewStore

    var body: some View {
        let session = entry.session
        let style = ProviderStyle.style(for: node.provider)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ProviderTile(style: style, size: 16)
                Text(node.label).font(.system(size: 12, weight: .semibold)).lineLimit(2)
            }
            HStack(spacing: 5) {
                Circle().fill(node.activity.tint).frame(width: 6, height: 6)
                Text([node.activity.word,
                      PanelStore.elapsed(since: session.since.map { Date(timeIntervalSince1970: $0) }, now: store.now)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(node.activity.wordIsLoud ? node.activity.tint : .secondary)
            }
            .font(.system(size: 11))
            if let project = node.project {
                Label(project + (store.workspace(for: entry)?.headLabel.map { " · \($0)" } ?? ""),
                      systemImage: "folder")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let ask = session.ask {
                Text(ask.summary ?? ask.preview ?? "Waiting on you")
                    .font(.system(size: 10)).foregroundStyle(.orange).lineLimit(3)
            } else if let doing = Self.doing(session) {
                Text(doing).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            if session.workers > 0 {
                Text(session.workers == 1 ? "1 worker" : "\(session.workers) workers")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(width: 238, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    /// "Running Bash" from the hook's last word, when it names a tool.
    static func doing(_ session: CoreSession) -> String? {
        if let tool = session.tool, !tool.isEmpty { return "Last tool: \(tool)" }
        return nil
    }
}
