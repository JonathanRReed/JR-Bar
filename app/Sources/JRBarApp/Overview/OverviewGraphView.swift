import AppKit
import JRBarCore
import SwiftUI

/// The Graph pane: an Obsidian-style force-directed map of the filtered
/// roster. One card per session, satellites for sub-agent workers, a
/// pulse travelling along each edge toward whichever end is working.
/// The heavy lifting lives in `OverviewForceLayout` (pure, tested); this
/// file is the AppKit canvas that draws and the SwiftUI shell around it.
struct OverviewGraphPane: View {
    @Bindable var store: OverviewStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Incrementing asks the canvas to re-fit; `fitStamp` rides through
    /// `updateNSView` so the button needs no reference to the view.
    @ViewState private var fitStamp = 0

    var body: some View {
        OverviewGraphCanvasRepresentable(
            graph: store.graph,
            selectedID: store.selectedID,
            reduceMotion: reduceMotion,
            fitStamp: fitStamp,
            onSelect: { id in store.selectionChanged(to: [id]) },
            onOpen: { id in
                store.selectionChanged(to: [id])
                store.openSelected()
            })
        .overlay(alignment: .topLeading) {
            Text("Drag to pan · ⌘scroll or pinch to zoom · click a card for details")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(.regularMaterial, in: .capsule)
                .padding(10)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                fitStamp += 1
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .medium))
                    .padding(7)
                    .background(.regularMaterial, in: .circle)
            }
            .buttonStyle(.plain)
            .help("Fit graph to window")
            .accessibilityLabel("Fit graph to window")
            .padding(10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session graph")
    }
}

private struct OverviewGraphCanvasRepresentable: NSViewRepresentable {
    var graph: OverviewGraph
    var selectedID: String?
    var reduceMotion: Bool
    var fitStamp: Int
    var onSelect: (String) -> Void
    var onOpen: (String) -> Void

    func makeNSView(context: Context) -> OverviewGraphCanvas {
        let view = OverviewGraphCanvas()
        view.onSelect = onSelect
        view.onOpen = onOpen
        view.reduceMotion = reduceMotion
        view.selectedID = selectedID
        view.setGraph(graph)
        return view
    }

    func updateNSView(_ view: OverviewGraphCanvas, context: Context) {
        view.onSelect = onSelect
        view.onOpen = onOpen
        if view.selectedID != selectedID { view.selectedID = selectedID }
        if view.reduceMotion != reduceMotion { view.reduceMotion = reduceMotion }
        view.setGraph(graph)
        view.applyFitStamp(fitStamp)
    }
}

/// The drawable surface. Owns the transform (pan offset + zoom scale),
/// the animation clock, and all hit-testing. It draws in graph space
/// under a CTM so cards and text scale with zoom like a real map.
final class OverviewGraphCanvas: NSView {
    var onSelect: ((String) -> Void)?
    var onOpen: ((String) -> Void)?

    var selectedID: String? {
        didSet { if selectedID != oldValue { needsDisplay = true } }
    }

    /// Reduce Motion: the layout runs to its settled state synchronously,
    /// the animation clock never starts, and nothing pulses.
    var reduceMotion = false {
        didSet {
            guard reduceMotion != oldValue else { return }
            if reduceMotion {
                stopClock()
                layout.runUntilSettled()
            } else {
                startClockIfNeeded()
            }
            needsDisplay = true
        }
    }

    private(set) var graph = OverviewGraph()
    private var layout = OverviewForceLayout()
    private var scale: CGFloat = 1
    private var offset = CGPoint.zero
    private var clock: Timer?
    /// The shared animation clock in seconds; node breathing and edge
    /// pulses both read it so everything pulses on one beat.
    private var phase: Double = 0
    private var lastFitStamp = 0
    private var fitted = false
    private var hoverID: String?
    private var hoverArea: NSTrackingArea?

    // Gesture bookkeeping.
    private var downPoint: NSPoint?
    private var downNode: String?
    private var dragNode: String?
    private var lastPoint: NSPoint?
    private var moved = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    isolated deinit { clock?.invalidate() }

    // MARK: Graph feeding

    func setGraph(_ new: OverviewGraph) {
        guard new != graph else { return }
        let wasEmpty = graph.nodes.isEmpty
        graph = new
        layout.sync(with: new)
        if wasEmpty { fitted = false }
        if reduceMotion {
            layout.runUntilSettled()
        } else {
            startClockIfNeeded()
        }
        needsDisplay = true
    }

    /// The pane's fit button stamps a counter through the representable.
    func applyFitStamp(_ stamp: Int) {
        guard stamp != lastFitStamp else { return }
        lastFitStamp = stamp
        fitToView()
    }

    // MARK: Animation clock

    /// The clock earns its 60 Hz only while something can move: the
    /// layout is awake, or a working node has rings and pulses to draw.
    private var animating: Bool {
        !reduceMotion && (!layout.settled || graph.nodes.contains { $0.style == .working })
    }

    private func startClockIfNeeded() {
        guard clock == nil, !reduceMotion else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop; `assumeIsolated` just
            // lets the compiler see it.
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
    }

    private func tick() {
        phase += 1.0 / 60.0
        if !layout.settled { layout.tick() }
        needsDisplay = true
        if !animating { stopClock() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopClock() } else { startClockIfNeeded() }
    }

    // MARK: Transform

    private func toView(_ p: SIMD2<Double>) -> CGPoint {
        CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y)
    }

    private func toGraph(_ p: CGPoint) -> SIMD2<Double> {
        SIMD2(Double((p.x - offset.x) / scale), Double((p.y - offset.y) / scale))
    }

    private func zoom(by factor: CGFloat, at point: CGPoint) {
        let next = min(3.5, max(0.2, scale * factor))
        guard next != scale else { return }
        let anchor = toGraph(point)
        scale = next
        offset = CGPoint(x: point.x - anchor.x * scale, y: point.y - anchor.y * scale)
        needsDisplay = true
    }

    private func nodeRect(_ node: OverviewGraphNode, at position: SIMD2<Double>) -> CGRect {
        let size = node.cardSize
        return CGRect(x: position.x - size.width / 2, y: position.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func fitToView() {
        guard let bounds2 = layout.contentBounds(), !graph.nodes.isEmpty,
              self.bounds.width > 0, self.bounds.height > 0 else { return }
        var lo = bounds2.min, hi = bounds2.max
        // Cards are wider than their centres — pad by a card and a half.
        lo -= SIMD2(150, 90)
        hi += SIMD2(150, 90)
        let size = hi - lo
        let pad: CGFloat = 36
        let sx = (self.bounds.width - pad * 2) / CGFloat(size.x)
        let sy = (self.bounds.height - pad * 2) / CGFloat(size.y)
        scale = min(1.6, max(0.2, min(sx, sy)))
        let centre = (lo + hi) / 2
        offset = CGPoint(x: self.bounds.midX - centre.x * scale,
                         y: self.bounds.midY - centre.y * scale)
        fitted = true
        needsDisplay = true
    }

    // MARK: Hit-testing

    private func nodeID(at viewPoint: CGPoint) -> String? {
        let point = toGraph(viewPoint)
        // Last drawn wins, so test in reverse order.
        for node in graph.nodes.reversed() {
            guard let position = layout.position(of: node.id) else { continue }
            if nodeRect(node, at: position).contains(CGPoint(x: point.x, y: point.y)) {
                return node.id
            }
        }
        return nil
    }

    // MARK: Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        downPoint = point
        lastPoint = point
        moved = false
        downNode = nodeID(at: point)
        if let id = downNode {
            layout.pin(id, at: toGraph(point))
            dragNode = id
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let start = downPoint, !moved,
           hypot(point.x - start.x, point.y - start.y) > 3 {
            moved = true
        }
        guard moved else { return }
        if let id = dragNode {
            layout.movePinned(id, to: toGraph(point))
            startClockIfNeeded()
        } else if let last = lastPoint {
            offset.x += point.x - last.x
            offset.y += point.y - last.y
        }
        lastPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = dragNode { layout.unpin(id) }
        let clicked = !moved ? downNode : nil
        downPoint = nil
        downNode = nil
        dragNode = nil
        lastPoint = nil
        moved = false
        guard let id = clicked, nodeID(at: point) == id else { return }
        if event.clickCount >= 2 {
            onOpen?(id)   // double-click: the row's open-session action
        } else {
            onSelect?(id) // single click: select, like the table row
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // ⌘scroll zooms, anchored under the pointer.
            let magnitude = event.hasPreciseScrollingDeltas ? 0.012 : 0.09
            zoom(by: exp(event.scrollingDeltaY * magnitude),
                 at: convert(event.locationInWindow, from: nil))
        } else {
            // Natural panning: content follows the fingers.
            let stride: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            offset.x += event.scrollingDeltaX * stride
            offset.y -= event.scrollingDeltaY * stride
            needsDisplay = true
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }

    /// Trackpad double-tap: zoom to fit, like Preview.
    override func smartMagnify(with event: NSEvent) {
        fitToView()
    }

    override func mouseMoved(with event: NSEvent) {
        let id = nodeID(at: convert(event.locationInWindow, from: nil))
        if id != hoverID {
            hoverID = id
            needsDisplay = true
        }
        (id == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
    }

    override func mouseExited(with event: NSEvent) {
        if hoverID != nil {
            hoverID = nil
            needsDisplay = true
        }
        NSCursor.arrow.set()
    }

    override func rightMouseDown(with event: NSEvent) {
        // Right-click behaves like a click for selection so the context
        // copy below always describes the card under the pointer.
        if let id = nodeID(at: convert(event.locationInWindow, from: nil)) {
            onSelect?(id)
        }
        super.rightMouseDown(with: event)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if !fitted, !graph.nodes.isEmpty, bounds.width > 0 { fitToView() }

        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        ctx.saveGState()
        ctx.translateBy(x: offset.x, y: offset.y)
        ctx.scaleBy(x: scale, y: scale)
        drawGrid(in: ctx)
        drawEdges(in: ctx)
        for node in graph.nodes { drawNode(node, in: ctx) }
        ctx.restoreGState()
    }

    /// A faint dot lattice that pans and zooms with the graph — the
    /// graph-paper backdrop that makes the empty space legible.
    private func drawGrid(in ctx: CGContext) {
        var step = 48.0 * scale
        var unit = 48.0
        while step < 16 { unit *= 2; step *= 2 }
        while step > 64 { unit /= 2; step /= 2 }
        // Visible graph-space rect.
        let lo = toGraph(.zero)
        let hi = toGraph(CGPoint(x: bounds.maxX, y: bounds.maxY))
        NSColor.tertiaryLabelColor.withAlphaComponent(0.28).setFill()
        let radius = 1.1 / scale
        var x = (lo.x / unit).rounded(.down) * unit
        while x <= hi.x {
            var y = (lo.y / unit).rounded(.down) * unit
            while y <= hi.y {
                ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius,
                                           width: radius * 2, height: radius * 2))
                y += unit
            }
            x += unit
        }
    }

    private func drawEdges(in ctx: CGContext) {
        for edge in graph.edges {
            guard let a = layout.position(of: edge.source),
                  let b = layout.position(of: edge.target) else { continue }
            let pa = CGPoint(x: a.x, y: a.y)
            let pb = CGPoint(x: b.x, y: b.y)
            let path = NSBezierPath()
            path.move(to: pa)
            path.line(to: pb)
            path.lineCapStyle = .round
            path.lineWidth = 1.4 / scale
            NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
            path.stroke()

            guard !reduceMotion else { continue }
            // The pulse travels toward whichever end is working — the
            // direction of attention, not of parentage. Both working:
            // toward the child (the newer activity).
            let sourceWorking = graph.node(edge.source)?.style == .working
            let targetWorking = graph.node(edge.target)?.style == .working
            guard sourceWorking || targetWorking else { continue }
            let accent = ProviderStyle.style(
                for: graph.node(targetWorking ? edge.target : edge.source)?.provider ?? ""
            ).nsAccent
            for k in 0..<2 {
                var t = (phase * 0.4 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                if sourceWorking && !targetWorking { t = 1 - t }
                let dot = CGPoint(x: pa.x + (pb.x - pa.x) * CGFloat(t),
                                  y: pa.y + (pb.y - pa.y) * CGFloat(t))
                let r: CGFloat = 3.2 / scale
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 6 / scale,
                              color: accent.withAlphaComponent(0.8).cgColor)
                accent.withAlphaComponent(0.9).setFill()
                ctx.fillEllipse(in: CGRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2))
                ctx.restoreGState()
            }
        }
    }

    private func drawNode(_ node: OverviewGraphNode, in ctx: CGContext) {
        guard let position = layout.position(of: node.id) else { return }
        let rect = nodeRect(node, at: position)
        let style = ProviderStyle.style(for: node.provider)
        let selected = node.id == selectedID
        let hovered = node.id == hoverID
        let corner: CGFloat = node.isWorker ? 10 : 12

        ctx.saveGState()
        if node.style == .done || node.style == .quiet {
            ctx.setAlpha(0.55)
        }

        let card = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

        // Lift: a soft card shadow, deeper under the pointer.
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5),
                      blur: hovered ? 14 : 8,
                      color: NSColor.black.withAlphaComponent(hovered ? 0.30 : 0.18).cgColor)
        NSColor.controlBackgroundColor.setFill()
        card.fill()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        // State treatments.
        if node.style == .failed {
            NSColor.systemRed.withAlphaComponent(0.10).setFill()
            card.fill()
        }
        if node.style == .waiting {
            // The amber glow ring — same vocabulary as the rows' ask mark.
            ctx.setShadow(offset: .zero, blur: 13,
                          color: NSColor.systemOrange.withAlphaComponent(0.55).cgColor)
            card.lineWidth = 1.6 / scale
            NSColor.systemOrange.withAlphaComponent(0.85).setStroke()
            card.stroke()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }
        if node.style == .working && !reduceMotion {
            // A breathing halo just outside the card.
            let breath = 0.28 + 0.20 * sin(phase * 2 * .pi)
            let halo = NSBezierPath(roundedRect: rect.insetBy(dx: -3.5, dy: -3.5),
                                    xRadius: corner + 3.5, yRadius: corner + 3.5)
            halo.lineWidth = 1.4 / scale
            style.nsAccent.withAlphaComponent(breath).setStroke()
            halo.stroke()
        }

        // Border last among card strokes so it reads crisp at any zoom.
        card.lineWidth = (selected ? 2.0 : 1.0) / scale
        let border: NSColor
        if selected { border = .controlAccentColor }
        else if node.style == .failed { border = .systemRed.withAlphaComponent(0.8) }
        else if node.style == .waiting { border = .systemOrange.withAlphaComponent(0.9) }
        else { border = .separatorColor }
        border.setStroke()
        card.stroke()
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.07).setFill()
            card.fill()
        }

        // Provider tile.
        let tileSize: CGFloat = node.isWorker ? 20 : 30
        let tile = CGRect(x: rect.minX + (node.isWorker ? 9 : 13),
                          y: rect.midY - tileSize / 2,
                          width: tileSize, height: tileSize)
        let tilePath = NSBezierPath(roundedRect: tile,
                                    xRadius: tileSize * 0.28, yRadius: tileSize * 0.28)
        style.nsAccent.withAlphaComponent(0.18).setFill()
        tilePath.fill()
        style.nsAccent.withAlphaComponent(0.35).setStroke()
        tilePath.lineWidth = 0.5 / scale
        tilePath.stroke()
        drawGlyph(style.glyph, tint: style.nsAccent, in: tile, ctx: ctx)

        // Title + caption.
        let textX = tile.maxX + (node.isWorker ? 7 : 10)
        let markWidth: CGFloat = 20
        let truncation: NSMutableParagraphStyle = {
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byTruncatingTail
            return p
        }()
        if node.isWorker {
            let titleRect = CGRect(x: textX, y: rect.minY + 4,
                                   width: rect.maxX - textX - markWidth, height: rect.height - 8)
            (node.title as NSString).draw(in: titleRect, withAttributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: truncation,
            ])
        } else {
            let titleRect = CGRect(x: textX, y: rect.minY + 9,
                                   width: rect.maxX - textX - markWidth, height: 16)
            (node.title as NSString).draw(in: titleRect, withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: truncation,
            ])
            let captionRect = CGRect(x: textX, y: rect.minY + 28,
                                     width: rect.maxX - textX - 10, height: 14)
            (node.caption as NSString).draw(in: captionRect, withAttributes: [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: truncation,
            ])
        }

        drawStateMark(node, rect: rect, ctx: ctx)
        ctx.restoreGState()
    }

    /// The right-hand state mark: a symbol where the word would matter,
    /// a dot where it would not.
    private func drawStateMark(_ node: OverviewGraphNode, rect: CGRect, ctx: CGContext) {
        let s: CGFloat = node.isWorker ? 10 : 13
        let mark = CGRect(x: rect.maxX - s - (node.isWorker ? 8 : 11),
                          y: rect.midY - s / 2, width: s, height: s)
        switch node.style {
        case .waiting:
            drawSymbol("exclamationmark.bubble.fill", tint: .systemOrange, in: mark, ctx: ctx)
        case .failed:
            drawSymbol("xmark.octagon.fill", tint: .systemRed, in: mark, ctx: ctx)
        case .done:
            drawSymbol("checkmark.circle.fill", tint: .systemGreen, in: mark, ctx: ctx)
        case .working:
            let alpha: CGFloat = reduceMotion ? 0.9 : 0.55 + 0.35 * sin(phase * 2 * .pi)
            ProviderStyle.style(for: node.provider).nsAccent
                .withAlphaComponent(alpha).setFill()
            ctx.fillEllipse(in: mark.insetBy(dx: 2.5, dy: 2.5))
        case .quiet:
            NSColor.tertiaryLabelColor.setFill()
            ctx.fillEllipse(in: mark.insetBy(dx: 3.5, dy: 3.5))
        }
        // A pinned/live ask on a non-waiting card still gets its badge —
        // the table's attention column, shrunk to a corner mark.
        if node.attention && node.style != .waiting {
            let badge = CGRect(x: rect.maxX - 12, y: rect.minY - 4, width: 12, height: 12)
            drawSymbol("exclamationmark.bubble.fill", tint: .systemOrange, in: badge, ctx: ctx)
        }
        if node.remote {
            let badge = CGRect(x: rect.minX + 6, y: rect.minY - 5, width: 11, height: 11)
            drawSymbol("network", tint: .tertiaryLabelColor, in: badge, ctx: ctx)
        }
    }

    private func drawGlyph(_ glyph: ProviderStyle.Glyph, tint: NSColor,
                           in tile: CGRect, ctx: CGContext) {
        switch glyph {
        case .symbol(let name):
            drawSymbol(name, tint: tint, pointSize: tile.width * 0.5,
                       in: tile.insetBy(dx: tile.width * 0.22, dy: tile.width * 0.22), ctx: ctx)
        case .text(let text):
            (text as NSString).draw(in: tile, withAttributes: [
                .font: NSFont.systemFont(ofSize: tile.width * 0.56, weight: .semibold),
                .foregroundColor: tint,
                .paragraphStyle: {
                    let p = NSMutableParagraphStyle()
                    p.alignment = .center
                    return p
                }(),
            ])
        }
    }

    /// Draws an SF Symbol tinted: render template, then recolour only the
    /// pixels the glyph covered (`sourceAtop` inside a transparency
    /// layer).
    private func drawSymbol(_ name: String, tint: NSColor, pointSize: CGFloat? = nil,
                            in rect: CGRect, ctx: CGContext) {
        guard var image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        if let pointSize {
            image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)) ?? image
        }
        image.isTemplate = true
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        tint.setFill()
        rect.fill(using: .sourceAtop)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
