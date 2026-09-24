import AppKit
import JRBarCore
import SwiftUI

/// The Overview's Graph: a living map of the agent fleet. The providers
/// are hubs down the middle, each project a cluster to one side, every
/// main session a capsule joined to its provider by a spoke, and its
/// workers branching outward from it. The ring round each orb says the
/// state — a turning arc while working, an amber breath while it waits on
/// you, red when it failed, a green check that fades once done — and
/// sparks run along the spokes of whatever is working.
///
/// Scroll or drag to pan, pinch or ⌘-scroll to zoom, ⌘0 to fit. A click
/// inspects, a double-click opens, the arrows walk the map and Return
/// opens what they land on. Nothing here answers an agent.
struct OverviewGraphView: View {
    @Bindable var store: OverviewStore
    /// A fixed instant for the moving marks, so a render proof can show
    /// them mid-flight. Nil in the app.
    var frozenTime: TimeInterval?
    /// A hover drawn without a pointer, for render proofs. Nil in the app.
    var pinnedHover: OverviewGraphLayout.Target?

    var body: some View {
        let nodes = store.graphNodes
        let layout = OverviewGraphLayout.make(nodes)
        VStack(spacing: 0) {
            GraphHeader(store: store, nodes: nodes, layout: layout)
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
                OverviewGraphCanvas(store: store, layout: layout, nodes: nodes, frozenTime: frozenTime,
                                    pinnedHover: pinnedHover)
                    .opacity(store.isLive ? 1 : 0.6)
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

// MARK: - Header

/// Scope on the left, then a chip per state that walks the selection
/// through the sessions in it, and the gestures named on the right.
private struct GraphHeader: View {
    @Bindable var store: OverviewStore
    let nodes: [OverviewGraphNode]
    let layout: OverviewGraphLayout

    private static let tallied: [SessionActivity] = [.waiting, .failed, .working, .done, .idle, .ended]

    var body: some View {
        let counts = Dictionary(grouping: nodes, by: \.activity).mapValues(\.count)
        HStack(spacing: 12) {
            Picker("Show", selection: $store.graphScope) {
                ForEach(OverviewStore.GraphScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Active: live sessions and the last hour's finishes · Everything: every session on record")
            // The words while they fit, then the counts alone.
            ViewThatFits(in: .horizontal) {
                chips(counts, words: true)
                chips(counts, words: false)
            }
            Spacer(minLength: 8)
            // Whole or not at all: a narrow window drops the hint rather
            // than cutting it off.
            ViewThatFits(in: .horizontal) {
                Text("Scroll to pan · pinch to zoom · double-click to open")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Color.clear.frame(width: 0, height: 0)
            }
            .layoutPriority(-1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func chips(_ counts: [SessionActivity: Int], words: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(Self.tallied, id: \.self) { activity in
                if let count = counts[activity], count > 0 {
                    Button { jump(to: activity) } label: {
                        GraphStateChip(activity: activity, count: count, words: words)
                    }
                    .buttonStyle(.plain)
                    .help("Select the next \(Self.word(activity)) session")
                }
            }
        }
        .fixedSize()
    }

    /// The next session in that state after the selection, in the map's
    /// own order, round to the first again.
    private func jump(to activity: SessionActivity) {
        let byID = Dictionary(nodes.map { ($0.id, $0.activity) }, uniquingKeysWith: { first, _ in first })
        let ids = layout.order.filter { byID[$0] == activity }
        guard !ids.isEmpty else { return }
        let index = store.selectedID.flatMap { ids.firstIndex(of: $0) }
        store.selectInGraph(ids[index.map { ($0 + 1) % ids.count } ?? 0])
    }

    static func word(_ activity: SessionActivity) -> String {
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

/// "● 2 waiting": the header's count of one state, loud when the state is.
private struct GraphStateChip: View {
    let activity: SessionActivity
    let count: Int
    var words = true

    private var label: String { words ? "\(count) \(GraphHeader.word(activity))" : "\(count)" }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(activity.tint).frame(width: 7, height: 7)
            Text(label)
                .foregroundStyle(activity.wordIsLoud ? activity.tint : .secondary)
                .lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(activity.wordIsLoud ? activity.tint.opacity(0.12) : Color.primary.opacity(0.05)))
        .contentShape(Capsule())
    }
}

// MARK: - Canvas

/// How the camera is chosen: the opening view (the whole map when it
/// reads, else its readable middle), the whole map at any scale (⌘0), or
/// wherever the person put it. The first two follow the map as it grows
/// and shrinks; a pan or a zoom makes it the person's.
enum GraphFraming: Equatable {
    case opening
    case whole
    case manual(GraphCamera)
}

/// The map itself: the scene, the camera over it, and everything the
/// pointer and keyboard do to it.
struct OverviewGraphCanvas: View {
    @Bindable var store: OverviewStore
    let layout: OverviewGraphLayout
    let nodes: [OverviewGraphNode]
    var frozenTime: TimeInterval?
    var pinnedHover: OverviewGraphLayout.Target?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var framing = GraphFraming.opening
    @ViewState private var dragFrom: GraphCamera?
    @ViewState private var hovered: OverviewGraphLayout.Target?
    /// The last thing hovered, kept while the dimming fades back out.
    @ViewState private var lit: OverviewGraphLayout.Target?
    /// What is on screen and what it is settling from; nil until the
    /// first change, when the fresh layout is what shows.
    @ViewState private var shown: Shown?
    @ViewState private var previous: Shown?
    @ViewState private var generation = 0
    @ViewState private var onScreen = true
    @FocusState private var focused: Bool

    struct Shown: Equatable {
        var layout: OverviewGraphLayout
        var nodes: [String: OverviewGraphNode]
    }

    /// Main sessions whose usage the Graph reads for their captions.
    static let usageBudget = 48

    private var hover: OverviewGraphLayout.Target? { hovered ?? pinnedHover }

    var body: some View {
        let fresh = Shown(layout: layout,
                          nodes: Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
        let current = shown ?? fresh
        GeometryReader { proxy in
            let size = proxy.size
            let whole = GraphCamera.fit(current.layout.bounds, in: size, inset: 16)
            let focus = Self.focus(current)
            let view = camera(current, size: size, whole: whole, focus: focus)
            let scene = model(current)
            ZStack(alignment: .topLeading) {
                GraphScene(model: scene, camera: view, settle: Double(generation),
                           dim: hover == nil ? 0 : 1, generation: generation,
                           motion: !reduceMotion && scene.hasMovingMarks,
                           running: store.windowOpen && store.pane == .graph && onScreen,
                           frozenTime: frozenTime)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovered)
                    // Someone new waiting on a map too big to show whole:
                    // the opening view glides to them rather than jumping.
                    .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: focus)
                hoverCard(current, camera: view, size: size)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hover)
                GraphZoomControls(scale: view.scale, whole: view == whole,
                                  zoom: { factor in
                                      zoom(by: factor, about: CGPoint(x: size.width / 2, y: size.height / 2), from: view,
                                           in: current, size: size)
                                  },
                                  fit: { animate { framing = .whole } })
                    .padding(12)
                    .frame(width: size.width, height: size.height, alignment: .bottomTrailing)
                if let status = store.actionStatus {
                    GraphStatusToast(text: status, isError: store.actionIsError) { store.actionStatus = nil }
                        .padding(12)
                        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point):
                    var target = current.layout.hit(live(view).world(point))
                    if case .cluster = target { target = nil }
                    guard target != hovered else { return }
                    hovered = target
                    if target != nil { lit = target }
                case .ended:
                    hovered = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { value in
                    let from = dragFrom ?? live(view)
                    dragFrom = from
                    framing = .manual(from.panned(by: value.translation).keeping(current.layout.bounds, in: size))
                }
                .onEnded { _ in dragFrom = nil })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                doubleClick(current.layout.hit(live(view).world(value.location)), current: current, size: size)
            })
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                focused = true
                if case .node(let id)? = current.layout.hit(live(view).world(value.location)) {
                    store.selectInGraph(id)
                } else {
                    store.selectInGraph(nil)
                }
            })
            .contextMenu {
                if case .node(let id)? = hovered { menu(for: id) }
            }
            .background(GraphPointerReader { intent in
                pointer(intent, from: view, whole: whole, in: current, size: size)
            })
            .background(WindowVisibilityReader { onScreen = $0 })
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { walk(.up, in: current) }
            .onKeyPress(.downArrow) { walk(.down, in: current) }
            .onKeyPress(.leftArrow) { walk(.left, in: current) }
            .onKeyPress(.rightArrow) { walk(.right, in: current) }
            .onKeyPress(.return) {
                guard store.selected != nil else { return .ignored }
                store.openSelected()
                return .handled
            }
            .onKeyPress(.escape) {
                guard store.selectedID != nil else { return .ignored }
                store.selectInGraph(nil)
                return .handled
            }
            .onKeyPress(keys: ["+"]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                zoom(by: 1.25, about: CGPoint(x: size.width / 2, y: size.height / 2), from: view, in: current,
                     size: size)
                return .handled
            }
            .onChange(of: store.selectedID) { _, id in
                guard let id, let rect = current.layout.nodes[id]?.frame,
                      let moved = live(view).revealing(rect.insetBy(dx: -8, dy: -8), in: size) else { return }
                animate { framing = .manual(moved) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Agent graph")
            .accessibilityChildren { accessibilityNodes(current, camera: view, size: size) }
        }
        .onAppear {
            shown = fresh
            refreshUsage(fresh)
        }
        .onChange(of: fresh) { old, new in settle(to: new, from: old) }
        .onChange(of: store.now) { refreshUsage(current) }
    }

    /// The first session waiting on you, which the opening view keeps in
    /// sight.
    static func focus(_ current: Shown) -> String? {
        current.layout.order.first { current.nodes[$0]?.activity == .waiting }
    }

    /// The camera the framing asks for at this size.
    private func camera(_ current: Shown, size: CGSize, whole: GraphCamera, focus: String?) -> GraphCamera {
        switch framing {
        case .opening:
            return GraphCamera.opening(current.layout.bounds, in: size,
                                       focus: focus.flatMap { current.layout.nodes[$0]?.frame.insetBy(dx: -12, dy: -12) },
                                       inset: 16)
        case .whole: return whole
        case .manual(let camera): return camera
        }
    }

    /// The camera now: a pan or pinch between two renders must build on
    /// the last one, not on the camera the closure was drawn with.
    private func live(_ drawn: GraphCamera) -> GraphCamera {
        if case .manual(let camera) = framing { return camera }
        return drawn
    }

    // MARK: The scene's model

    private func model(_ current: Shown) -> GraphSceneModel {
        var all = current.nodes
        if let previous {
            for (id, node) in previous.nodes where all[id] == nil { all[id] = node }
        }
        let entries = Dictionary(store.roster.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var captions: [String: GraphCaption] = [:]
        var unseen: Set<String> = []
        for (id, node) in current.nodes {
            let entry = entries[id]
            if current.layout.nodes[id]?.isWorker == false { captions[id] = caption(node, entry: entry) }
            if let entry, store.showsUnseenDot(entry) { unseen.insert(id) }
        }
        var hubCaptions: [String: String] = [:]
        for hub in current.layout.hubs {
            hubCaptions[hub.id] = Self.hubCaption(hub.sessionIDs.compactMap { current.nodes[$0]?.activity })
        }
        let providers = all.mapValues(\.provider)
        return GraphSceneModel(layout: current.layout, previous: previous?.layout, nodes: all, captions: captions,
                               hubCaptions: hubCaptions, unseen: unseen, selectedID: store.selectedID,
                               lit: (hover ?? lit).map { current.layout.neighbourhood(of: $0, providers: providers) },
                               now: store.now.timeIntervalSince1970)
    }

    /// "3 sessions · 1 waiting": how many a hub feeds, and the loudest
    /// thing among them.
    static func hubCaption(_ states: [SessionActivity]) -> String {
        let count = states.count == 1 ? "1 session" : "\(states.count) sessions"
        for (activity, word) in [(SessionActivity.waiting, "waiting"), (.failed, "failed"), (.working, "working")] {
            let matching = states.filter { $0 == activity }.count
            if matching > 0 { return "\(count) · \(matching) \(word)" }
        }
        return count
    }

    /// "Working · 42m · 1.2M · $2.31": the state, how long it has been in
    /// it, and what the run has spent so far when its transcript says. A
    /// waiting session keeps to the state and the wait.
    private func caption(_ node: OverviewGraphNode, entry: CoreRosterEntry?) -> GraphCaption {
        var words = GraphCaption(word: node.activity.word)
        words.elapsed = PanelStore.elapsed(since: entry?.session.since.map { Date(timeIntervalSince1970: $0) },
                                           now: store.now)
        if node.activity != .waiting, let usage = store.sessionUsage.usage(for: node.id) {
            if usage.tokens.total > 0 { words.tokens = UsageFormat.tokens(usage.tokens.total) }
            if let cost = usage.estimatedCostUSD, cost > 0 { words.cost = UsageFormat.cost(cost) }
        }
        return words
    }

    private func refreshUsage(_ current: Shown) {
        let ids = current.layout.order.filter { current.layout.nodes[$0]?.isWorker == false }
        store.sessionUsage.refresh(ids: Array(ids.prefix(Self.usageBudget)))
    }

    // MARK: Motion

    /// A change that moves nodes settles into place from where they were;
    /// one that only changes a state shows at once.
    private func settle(to new: Shown, from old: Shown) {
        let from = shown ?? old
        guard !reduceMotion else {
            shown = new
            previous = nil
            return
        }
        // Nothing moved: show it now, and let any settle still running finish.
        guard !new.layout.placesMatch(from.layout) else {
            shown = new
            return
        }
        let next = generation + 1
        withAnimation(.smooth(duration: 0.6)) {
            previous = from
            shown = new
            generation = next
        } completion: {
            if generation == next { previous = nil }
        }
    }

    private func animate(_ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(.smooth(duration: 0.4), change) }
    }

    private func zoom(by factor: CGFloat, about point: CGPoint, from drawn: GraphCamera, in current: Shown,
                      size: CGSize) {
        let base = live(drawn)
        let zoomed = base.zoomed(by: factor, about: point).keeping(current.layout.bounds, in: size)
        animate { framing = .manual(zoomed) }
    }

    private func pointer(_ intent: GraphPointerIntent, from drawn: GraphCamera, whole: GraphCamera, in current: Shown,
                         size: CGSize) {
        let base = live(drawn)
        let bounds = current.layout.bounds
        switch intent {
        case .pan(let delta):
            framing = .manual(base.panned(by: delta).keeping(bounds, in: size))
        case .zoom(let factor, let point):
            framing = .manual(base.zoomed(by: factor, about: point).keeping(bounds, in: size))
        case .smartZoom(let point):
            // 100% about the pointer from the whole map, the whole map
            // from anywhere else.
            if abs(base.scale - whole.scale) < 0.01 {
                animate { framing = .manual(base.zoomed(by: 1 / base.scale, about: point)) }
            } else {
                animate { framing = .whole }
            }
        }
    }

    /// A double-click opens a node, frames a cluster, and shows the whole
    /// map from anywhere else.
    private func doubleClick(_ target: OverviewGraphLayout.Target?, current: Shown, size: CGSize) {
        switch target {
        case .node(let id):
            open(id)
        case .cluster(let key):
            guard let frame = current.layout.clusters.first(where: { $0.id == key })?.frame else { return }
            let framed = GraphCamera.fit(frame.insetBy(dx: -40, dy: -40), in: size)
            animate { framing = .manual(framed) }
        case .hub, nil:
            animate { framing = .whole }
        }
    }

    private func walk(_ direction: OverviewGraphLayout.Direction, in current: Shown) -> KeyPress.Result {
        let from = store.selectedID.flatMap { current.layout.nodes[$0] == nil ? nil : $0 }
        if let next = current.layout.neighbour(of: from, toward: direction) { store.selectInGraph(next) }
        return .handled
    }

    // MARK: Actions

    private func open(_ id: String) {
        store.selectInGraph(id)
        guard let entry = store.roster.first(where: { $0.id == id }), store.canOpen(entry) else { return }
        _ = Task { await store.openSession(id) }
    }

    @ViewBuilder
    private func menu(for id: String) -> some View {
        let entry = store.roster.first { $0.id == id }
        Button("Open") { open(id) }
            .disabled(entry.map { !store.canOpen($0) } ?? true)
        Button("Show in Roster") { store.showInRoster(id) }
        if let entry, entry.session.workers > 0 {
            Button("Show \(entry.session.workers) Workers in Roster") {
                store.showInRoster(id)
                store.workerFilter = id
            }
        }
    }

    // MARK: Overlays

    @ViewBuilder
    private func hoverCard(_ current: Shown, camera view: GraphCamera, size: CGSize) -> some View {
        switch hover {
        case .node(let id)?:
            if let node = current.nodes[id], let placed = current.layout.nodes[id],
               let entry = store.roster.first(where: { $0.id == id }) {
                GraphHoverCard(node: node, entry: entry, store: store)
                    .modifier(GraphCardPlacement(rect: view.screen(placed.frame), anchor: .node(placed.side), size: size))
            }
        case .hub(let provider)?:
            if let hub = current.layout.hubs.first(where: { $0.id == provider }) {
                // Under the hub's name, not over it.
                let named = hub.frame.union(hub.frame.offsetBy(dx: 0, dy: OverviewGraphLayout.Metrics.hubCaption))
                GraphHubCard(provider: provider, sessions: hub.sessionIDs.compactMap { current.nodes[$0] },
                             projects: Set(hub.sessionIDs.compactMap { current.nodes[$0]?.project }).count)
                    .modifier(GraphCardPlacement(rect: view.screen(named), anchor: .hub, size: size))
            }
        default:
            EmptyView()
        }
    }

    /// One element per node for VoiceOver, where the node is drawn.
    @ViewBuilder
    private func accessibilityNodes(_ current: Shown, camera view: GraphCamera, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(current.layout.order, id: \.self) { id in
                if let node = current.nodes[id], let placed = current.layout.nodes[id] {
                    let rect = view.screen(placed.frame)
                    Color.clear
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .accessibilityElement()
                        .accessibilityLabel("\(node.label), \(ProviderStyle.style(for: node.provider).name), \(node.activity.word)")
                        .accessibilityAddTraits(store.selectedID == id ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { store.selectInGraph(id) }
                        .accessibilityAction(named: "Open") { open(id) }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// Puts a hover card by what it describes without covering what the hover
/// lit: a node's card on its far side from the hubs when there is room,
/// else under it (or over it, near the bottom); a hub's centred under its
/// name. Always inside the window.
private struct GraphCardPlacement: ViewModifier {
    enum Anchor { case node(OverviewGraphLayout.Side), hub }

    let rect: CGRect
    let anchor: Anchor
    let size: CGSize

    static let width: CGFloat = 264

    func body(content: Content) -> some View {
        let (x, beside) = horizontal
        let (top, bottom, height) = (rect.minY, rect.maxY, size.height)
        content
            .frame(width: Self.width)
            .fixedSize(horizontal: false, vertical: true)
            .alignmentGuide(.leading) { _ in -x }
            .alignmentGuide(.top) { dimensions in
                let y: CGFloat
                if beside {
                    y = min(max(8, top - 2), height - dimensions.height - 8)
                } else if bottom + 10 + dimensions.height <= height - 8 {
                    y = bottom + 10
                } else {
                    y = max(8, top - 10 - dimensions.height)
                }
                return -y
            }
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// Where the card's left edge goes, and whether it sits beside rather
    /// than under or over.
    private var horizontal: (x: CGFloat, beside: Bool) {
        let limit = max(8, size.width - Self.width - 8)
        switch anchor {
        case .node(let side):
            let outward = side == .right ? rect.maxX + 12 : rect.minX - 12 - Self.width
            if outward >= 8, outward <= limit { return (outward, true) }
            // Under or over, flush with the node's outer end so it spills
            // toward the hubs rather than across the workers.
            return (min(max(8, side == .right ? rect.maxX - Self.width : rect.minX), limit), false)
        case .hub:
            return (min(max(8, rect.midX - Self.width / 2), limit), false)
        }
    }
}

// MARK: - Cards and controls

/// What a hover reveals: the name, who and what state, where it works,
/// what it is doing or asking, and what it has spent. Words only — the
/// Graph never answers an agent.
private struct GraphHoverCard: View {
    let node: OverviewGraphNode
    let entry: CoreRosterEntry
    let store: OverviewStore

    /// The provider tile's width, which every row's mark centres on, so
    /// all the words start on one line.
    static let mark: CGFloat = 22
    static let gutter: CGFloat = 8

    var body: some View {
        let session = entry.session
        let style = ProviderStyle.style(for: node.provider)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: Self.gutter) {
                ProviderTile(style: style, size: Self.mark)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.label).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                    Text(whereLine).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            row {
                Circle().fill(node.activity.tint).frame(width: 7, height: 7)
            } text: {
                Text(stateLine)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(node.activity.wordIsLoud ? node.activity.tint : .primary)
            }
            if let ask = session.ask {
                Text(ask.summary ?? ask.preview ?? "Waiting on you")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.orange.opacity(0.1)))
                    // The words on the card's line, the box hanging just
                    // outside it.
                    .padding(.leading, Self.mark + Self.gutter - 8)
            } else if let tool = session.tool, !tool.isEmpty {
                row("hammer", "Last tool: \(tool)")
            }
            if let spend = spendLine {
                row("chart.bar", spend)
            }
            if session.workers > 0 {
                row("person.2", session.workers == 1 ? "1 worker" : "\(session.workers) workers")
            }
            Text(store.canOpen(entry) ? "Click to inspect · double-click to open" : "On the peer Mac · click to inspect")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.leading, Self.mark + Self.gutter)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }

    /// A mark centred under the provider tile, then its words.
    private func row(@ViewBuilder icon: () -> some View, @ViewBuilder text: () -> some View) -> some View {
        HStack(spacing: Self.gutter) {
            icon().frame(width: Self.mark)
            text()
        }
    }

    private func row(_ symbol: String, _ words: String) -> some View {
        row {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
        } text: {
            Text(words).lineLimit(1)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    private var whereLine: String {
        var parts = [ProviderStyle.style(for: node.provider).name]
        if let project = node.project { parts.append(project) }
        if let head = store.workspace(for: entry)?.headLabel { parts.append(head) }
        return parts.joined(separator: " · ")
    }

    private var stateLine: String {
        let since = entry.session.since.map { Date(timeIntervalSince1970: $0) }
        return [node.activity.word, PanelStore.elapsed(since: since, now: store.now)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var spendLine: String? {
        guard let usage = store.sessionUsage.usage(for: node.id), usage.tokens.total > 0 else { return nil }
        var parts: [String] = []
        if let model = ModelName.display(usage.model) { parts.append(model) }
        parts.append("\(UsageFormat.tokens(usage.tokens.total)) tokens")
        if let cost = usage.estimatedCostUSD, cost > 0 { parts.append(UsageFormat.cost(cost)) }
        return parts.joined(separator: " · ")
    }
}

/// A hub's card: the provider, and its sessions by state.
private struct GraphHubCard: View {
    let provider: String
    let sessions: [OverviewGraphNode]
    let projects: Int

    private static let order: [SessionActivity] = [.waiting, .failed, .working, .done, .idle, .ended]

    /// "6 sessions in 3 projects".
    private var reach: String {
        let many = sessions.count == 1 ? "1 session" : "\(sessions.count) sessions"
        let across = projects == 1 ? "1 project" : "\(projects) projects"
        return many + " in " + across
    }

    var body: some View {
        let style = ProviderStyle.style(for: provider)
        let counts = Dictionary(grouping: sessions, by: \.activity).mapValues(\.count)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: GraphHoverCard.gutter) {
                ProviderTile(style: style, size: GraphHoverCard.mark)
                VStack(alignment: .leading, spacing: 1) {
                    Text(style.name).font(.system(size: 12.5, weight: .semibold))
                    Text(reach).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            // A busy provider's states wrap onto a second row, words kept.
            WrapRow {
                ForEach(Self.order, id: \.self) { activity in
                    if let count = counts[activity], count > 0 {
                        GraphStateChip(activity: activity, count: count)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }

}

/// − 85% + and fit, floating in glass at the map's corner.
private struct GraphZoomControls: View {
    let scale: CGFloat
    /// The whole map is already in view: fit has nothing to do.
    let whole: Bool
    let zoom: (CGFloat) -> Void
    let fit: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("minus", help: "Zoom out (⌘−)") { zoom(1 / 1.25) }
                .keyboardShortcut("-", modifiers: .command)
            Text("\(Int((scale * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 42)
            button("plus", help: "Zoom in (⌘+)") { zoom(1.25) }
                .keyboardShortcut("=", modifiers: .command)
            Divider().frame(height: 16).padding(.horizontal, 4)
            button("arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", help: "Zoom to fit (⌘0)", action: fit)
                .keyboardShortcut("0", modifiers: .command)
                .opacity(whole ? 0.45 : 1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: Capsule())
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The receipt for an open from the Graph ("Opened fix-ci"), or the
/// refusal in the daemon's own words.
private struct GraphStatusToast: View {
    let text: String
    let isError: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            Text(text)
                .foregroundStyle(isError ? .red : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Dismiss status")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: 360, alignment: .leading)
        .fixedSize()
        .glassEffect(.regular, in: Capsule())
    }
}
