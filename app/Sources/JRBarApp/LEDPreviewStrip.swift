import AppKit
import JRBarCore
import JRBarLEDS
import QuartzCore
import SwiftUI

/// Parsed programs for the previews, keyed by text and LED count, so a view
/// that re-renders thirty times a second never re-parses.
@MainActor
enum LEDPreviewSamplers {
    private static var cache: [String: LEDSSampler] = [:]
    private static var order: [String] = []
    private static let limit = 96

    static func sampler(for program: String, ledCount: Int) -> LEDSSampler? {
        let key = "\(ledCount)|\(program)"
        if let hit = cache[key] { return hit }
        // Everything shown goes through the presentation-safety compiler,
        // exactly like the Screen Bar: a 3 Hz strobe never reaches the preview.
        guard let (parsed, _) = LEDSPresentationCompiler.compileProgram(program, ledCount: ledCount) else { return nil }
        let sampler = LEDSSampler(program: parsed, ledCount: ledCount)
        cache[key] = sampler
        order.append(key)
        if order.count > limit, let oldest = order.first {
            order.removeFirst()
            cache[oldest] = nil
        }
        return sampler
    }
}

private struct LEDPreviewsHeldKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Every LED preview below holds the frame it shows: the window they
    /// sit in is covered, minimised or on another Space.
    var ledPreviewsHeld: Bool {
        get { self[LEDPreviewsHeldKey.self] }
        set { self[LEDPreviewsHeldKey.self] = newValue }
    }
}

/// A live rendering of a LEDS program: a row of glowing dots (the strip)
/// or one blended band (the Screen Bar).
///
/// The dots are Core Animation layers the strip recolours itself, from
/// its own 30 Hz display link, so SwiftUI sees a still view: a moving
/// preview never lays the Settings form out again. The link runs only
/// while the strip is in a window on a screen and that window is
/// visible — not while it is covered, minimised or on another Space —
/// and never for a static program, a `paused` preview, while the window
/// holds its previews (`ledPreviewsHeld`) or under Reduce Motion. A
/// paused preview and Reduce Motion show the program's brightest moment
/// instead of a black start. A render proof's still (`renderSnapshot`,
/// for `ImageRenderer`) draws the same frame in SwiftUI.
struct LEDStripPreview: View {
    enum Style { case dots, band }

    let program: String
    var ledCount: Int = 8
    var style: Style = .dots
    var dotSize: CGFloat = 14
    var spacing: CGFloat = 8
    /// Finite programs start over after they end (plus a short rest).
    var loops: Bool = true
    var paused: Bool = false
    var showsBackground: Bool = true
    var cornerRadius: CGFloat = 9
    /// Seconds into the program at which this preview starts, so a grid of
    /// previews does not breathe in lockstep.
    var phase: TimeInterval = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ledPreviewsHeld) private var held
    @Environment(\.renderSnapshot) private var snapshot

    private var sampler: LEDSSampler? { LEDPreviewSamplers.sampler(for: program, ledCount: ledCount) }

    /// The (dotSize, spacing) a dots-style strip needs to show `ledCount`
    /// LEDs inside `width` points: the asked sizes when the row already
    /// fits, shrunk in proportion when it would overflow — a wide
    /// device's preview keeps every LED on screen instead of clipping
    /// its ends or spilling over the neighbour column.
    static func dotMetrics(ledCount: Int, width: CGFloat, dotSize: CGFloat, spacing: CGFloat, padded: Bool) -> (dotSize: CGFloat, spacing: CGFloat) {
        let n = max(1, CGFloat(ledCount))
        guard dotSize > 0, width > 0 else { return (dotSize, spacing) }
        // The dots card pads each side by dotSize × 0.9 when it shows.
        let units = n + (n - 1) * (spacing / dotSize) + (padded ? 1.8 : 0)
        let fitted = width / units
        guard fitted < dotSize else { return (dotSize, spacing) }
        return (max(2, fitted), max(1, spacing * fitted / dotSize))
    }

    /// What the layers draw, and what a change to redraws.
    private var layerConfig: LEDStripLayerView.Config {
        LEDStripLayerView.Config(program: program, ledCount: ledCount, style: style, dotSize: dotSize,
                                 spacing: spacing, loops: loops, paused: paused, phase: phase)
    }

    var body: some View {
        let sampler = self.sampler
        staged
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sampler == nil ? "Program refused" : "LED preview")
    }

    /// The strip on its stage: the same padding and plate for the
    /// layers and for a still.
    @ViewBuilder
    private var staged: some View {
        switch style {
        case .dots:
            strip
                .padding(.horizontal, showsBackground ? dotSize * 0.9 : 0)
                .padding(.vertical, showsBackground ? dotSize * 0.7 : 0)
                .frame(maxWidth: showsBackground ? .infinity : nil)
                .background {
                    if showsBackground { LEDStage(cornerRadius: cornerRadius) }
                }
        case .band:
            strip
                .frame(height: dotSize)
                .padding(showsBackground ? dotSize * 0.6 : 0)
                .background {
                    if showsBackground { LEDStage(cornerRadius: cornerRadius) }
                }
        }
    }

    @ViewBuilder
    private var strip: some View {
        if snapshot {
            // `ImageRenderer` draws no AppKit view: the still is the
            // program's first frame (or its brightest, when still), in
            // SwiftUI.
            let colors = LEDStripFrames.colors(sampler: sampler, ledCount: ledCount, elapsed: phase,
                                               still: paused || reduceMotion, loops: loops)
            LEDStripStill(colors: colors, style: style, dotSize: dotSize, spacing: spacing)
        } else {
            // The layers ride over a clear stand-in of the shapes' size:
            // an AppKit view brings text baselines of its own, and a row
            // aligned on baselines would line the strip up by them.
            let count = sampler?.ledCount ?? max(0, ledCount)
            let row = LEDStripLayerView.Config.dotsSize(count: count, dotSize: dotSize, spacing: spacing)
            Color.clear
                .frame(width: style == .dots ? row.width : nil, height: style == .dots ? row.height : nil)
                .overlay {
                    LEDStripLayers(config: layerConfig, held: held, reduceMotion: reduceMotion)
                }
        }
    }
}

/// The colours a preview shows, shared by the layers and the SwiftUI
/// still.
enum LEDStripFrames {
    /// The colours `elapsed` seconds into the program (its phase
    /// included). A still preview shows the brightest instant of the
    /// first cycle, so a breathe is not shown at its floor; a finite
    /// program that `loops` starts over after it ends, plus a short
    /// rest. A refused program is a row of dull red.
    static func colors(sampler: LEDSSampler?, ledCount: Int, elapsed: TimeInterval, still: Bool, loops: Bool) -> [RGB] {
        guard let sampler else { return Array(repeating: RGB(r: 0.35, g: 0.05, b: 0.05), count: max(0, ledCount)) }
        var t = elapsed
        if still {
            t = brightestInstant(sampler)
        } else if loops, sampler.cycleDuration == nil, let ends = sampler.motionEndsAt, ends > 0 {
            t = t.truncatingRemainder(dividingBy: ends + 0.8)
        }
        return sampler.colors(at: t)
    }

    /// The brightest of twelve instants across the first cycle, or the
    /// start for a program with no motion.
    static func brightestInstant(_ sampler: LEDSSampler) -> TimeInterval {
        let span = sampler.cycleDuration ?? sampler.motionEndsAt ?? 0
        guard span > 0 else { return 0 }
        var best = 0.0, bestLevel = -1.0
        for k in 0..<12 {
            let probe = span * Double(k) / 12
            let level = sampler.colors(at: probe).map(\.maxChannel).reduce(0, +)
            if level > bestLevel { bestLevel = level; best = probe }
        }
        return best
    }
}

/// One frame of the strip drawn by SwiftUI: the still a render proof
/// takes, where `ImageRenderer` cannot draw the layers. The same glow,
/// rim and band the layers draw.
private struct LEDStripStill: View {
    let colors: [RGB]
    let style: LEDStripPreview.Style
    let dotSize: CGFloat
    let spacing: CGFloat

    var body: some View {
        switch style {
        case .dots:
            HStack(spacing: spacing) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, rgb in
                    let color = Color(red: rgb.r, green: rgb.g, blue: rgb.b)
                    Circle()
                        .fill(color)
                        .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
                        .shadow(color: color.opacity(0.75 * rgb.maxChannel), radius: dotSize * 0.45)
                        .frame(width: dotSize, height: dotSize)
                }
            }
        case .band:
            let stops = colors.enumerated().map { index, rgb in
                Gradient.Stop(color: Color(red: rgb.r, green: rgb.g, blue: rgb.b),
                              location: colors.count > 1 ? CGFloat(index) / CGFloat(colors.count - 1) : 0.5)
            }
            let glow = colors.map(\.maxChannel).max() ?? 0
            let middle = colors.isEmpty ? RGB.black : colors[colors.count / 2]
            Capsule()
                .fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: Color(red: middle.r, green: middle.g, blue: middle.b).opacity(0.6 * glow),
                        radius: dotSize * 0.4)
        }
    }
}

/// The strip's layers in the SwiftUI tree: a fixed-size row of dots, or
/// a band as wide as it is offered (a capsule's sizing).
private struct LEDStripLayers: NSViewRepresentable {
    let config: LEDStripLayerView.Config
    let held: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> LEDStripLayerView {
        LEDStripLayerView(config: config, held: held, reduceMotion: reduceMotion)
    }

    func updateNSView(_ view: LEDStripLayerView, context: Context) {
        view.update(config: config, held: held, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ view: LEDStripLayerView, coordinator: ()) {
        view.stopAnimating()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LEDStripLayerView, context: Context) -> CGSize? {
        switch config.style {
        case .dots:
            return LEDStripLayerView.Config.dotsSize(count: nsView.drawnCount, dotSize: config.dotSize,
                                                     spacing: config.spacing)
        case .band:
            return CGSize(width: proposal.width ?? 10, height: proposal.height ?? config.dotSize)
        }
    }
}

/// The strip itself: one layer per LED — a dot with its rim and its own
/// glow — or, for the band, one gradient capsule over a layer that
/// casts the middle LED's glow. SwiftUI lays it out once; the view
/// recolours its layers from its own display link at 30 Hz and asks
/// SwiftUI for nothing.
///
/// The link runs only while it has work that someone can see (see
/// `animates`), and `renderFrame(at:)` takes the time, so tests and
/// the performance harness step it by hand.
@MainActor
final class LEDStripLayerView: NSView {
    struct Config: Equatable {
        var program: String
        var ledCount: Int
        var style: LEDStripPreview.Style
        var dotSize: CGFloat
        var spacing: CGFloat
        var loops: Bool
        var paused: Bool
        var phase: TimeInterval

        /// The dots' row: `count` LEDs at `dotSize`, `spacing` apart.
        static func dotsSize(count: Int, dotSize: CGFloat, spacing: CGFloat) -> CGSize {
            let n = CGFloat(max(0, count))
            return CGSize(width: max(0, n * dotSize + (n - 1) * spacing), height: dotSize)
        }
    }

    /// The frame rate the previews play at: plenty for a preview, a
    /// quarter of a ProMotion display's.
    static let framesPerSecond: Float = 30

    /// Whether the link should run. Pure, for the tests.
    static func animates(inWindow: Bool, onScreen: Bool, windowVisible: Bool, held: Bool,
                         reduceMotion: Bool, paused: Bool, moving: Bool) -> Bool {
        inWindow && onScreen && windowVisible && !held && !reduceMotion && !paused && moving
    }

    private(set) var config: Config
    private(set) var held: Bool
    private(set) var reduceMotion: Bool
    private var sampler: LEDSSampler?
    /// When the program started, in `CACurrentMediaTime` seconds; a new
    /// program starts from its beginning.
    private var origin: TimeInterval
    private var link: CADisplayLink?
    private let linkTarget = LEDStripLinkTarget()
    private var windowObservers: [NSObjectProtocol] = []
    private var dotLayers: [CALayer] = []
    private let bandGlow = CALayer()
    private let bandLayer = CAGradientLayer()
    /// The colours on the layers now.
    private(set) var shownColors: [RGB] = []
    /// Frames drawn since the view was made.
    private(set) var framesDrawn = 0

    /// True while the display link is running.
    var isAnimating: Bool { link != nil }

    /// How many LEDs the strip draws: the sampler's count — a count the
    /// firmware has no layout for plays as eight — or one dull red dot
    /// per LED for a refused program.
    var drawnCount: Int { sampler?.ledCount ?? max(0, config.ledCount) }

    init(config: Config, held: Bool, reduceMotion: Bool, now: TimeInterval = CACurrentMediaTime()) {
        self.config = config
        self.held = held
        self.reduceMotion = reduceMotion
        self.origin = now
        super.init(frame: CGRect(x: 0, y: 0, width: 10, height: config.dotSize))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(false)
        linkTarget.view = self
        sampler = LEDPreviewSamplers.sampler(for: config.program, ledCount: config.ledCount)
        buildLayers()
        renderFrame(at: now)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    /// Clicks go to whatever the strip sits in (a picker row, a library
    /// row): the dots are a picture.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// SwiftUI's side changed: a new program starts from its beginning,
    /// a new shape rebuilds the layers, and the link follows.
    func update(config newConfig: Config, held newHeld: Bool, reduceMotion newReduceMotion: Bool,
                now: TimeInterval = CACurrentMediaTime()) {
        let old = config
        let wasStill = old.paused || reduceMotion
        config = newConfig
        held = newHeld
        reduceMotion = newReduceMotion
        if old.program != newConfig.program || old.ledCount != newConfig.ledCount {
            sampler = LEDPreviewSamplers.sampler(for: newConfig.program, ledCount: newConfig.ledCount)
            origin = now
        }
        if old.style != newConfig.style || old.ledCount != newConfig.ledCount
            || old.dotSize != newConfig.dotSize || old.spacing != newConfig.spacing {
            buildLayers()
            needsLayout = true
        }
        // A held strip keeps the frame it shows; only a new program or
        // shape, or a change between moving and still, redraws it here.
        if old != newConfig || wasStill != (newConfig.paused || newReduceMotion) { renderFrame(at: now) }
        refreshAnimating()
    }

    // MARK: Frames

    /// Recolours the layers for host time `time` (`CACurrentMediaTime`
    /// seconds): the program `time - origin + phase` seconds in.
    func renderFrame(at time: TimeInterval) {
        let colors = LEDStripFrames.colors(sampler: sampler, ledCount: config.ledCount,
                                           elapsed: time - origin + config.phase,
                                           still: config.paused || reduceMotion, loops: config.loops)
        apply(colors)
    }

    /// The layers' animatable properties the strip sets every frame, and
    /// their geometry: set straight, never eased — a preview frame is a
    /// frame, and an implicit animation per dot per frame is work.
    private static let stillActions: [String: any CAAction] = [
        "backgroundColor": NSNull(), "shadowColor": NSNull(), "shadowOpacity": NSNull(),
        "colors": NSNull(), "locations": NSNull(), "bounds": NSNull(), "position": NSNull(),
        "frame": NSNull(), "shadowPath": NSNull(), "cornerRadius": NSNull(), "contentsScale": NSNull(),
    ]

    private func apply(_ colors: [RGB]) {
        framesDrawn += 1
        guard colors != shownColors else { return }
        let previous = shownColors
        shownColors = colors
        switch config.style {
        case .dots:
            if dotLayers.count != colors.count { buildLayers() }
            let compare = previous.count == colors.count
            for (index, rgb) in colors.enumerated() where index < dotLayers.count {
                // Most frames move a few LEDs; the rest keep their layer.
                if compare && previous[index] == rgb { continue }
                let dot = dotLayers[index]
                dot.backgroundColor = Self.cgColor(rgb)
                // The glow's strength rides in its colour's alpha: one
                // property a frame, not two.
                dot.shadowColor = Self.cgColor(rgb, alpha: 0.75 * Self.clamped(rgb.maxChannel))
            }
        case .band:
            let stops = colors.isEmpty ? [RGB.black] : colors
            // A gradient needs two stops; one colour is a flat band.
            let shown = stops.count == 1 ? [stops[0], stops[0]] : stops
            bandLayer.colors = shown.map { Self.cgColor($0) }
            bandLayer.locations = shown.indices.map { NSNumber(value: Double($0) / Double(shown.count - 1)) }
            let middle = stops[stops.count / 2]
            let glow = stops.map(\.maxChannel).max() ?? 0
            let middleColor = Self.cgColor(middle)
            bandGlow.shadowColor = middleColor
            bandGlow.backgroundColor = middleColor
            bandGlow.shadowOpacity = Float(0.6 * Self.clamped(glow))
        }
    }

    private static func clamped(_ value: Double) -> Double { min(1, max(0, value.isFinite ? value : 0)) }

    private static func cgColor(_ rgb: RGB, alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: clamped(rgb.r), green: clamped(rgb.g), blue: clamped(rgb.b), alpha: alpha)
    }

    // MARK: Layers

    private func buildLayers() {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayers.forEach { $0.removeFromSuperlayer() }
        dotLayers = []
        bandGlow.removeFromSuperlayer()
        bandLayer.removeFromSuperlayer()
        shownColors = []
        let rim = CGColor(gray: 1, alpha: 0.10)
        switch config.style {
        case .dots:
            for _ in 0..<drawnCount {
                let dot = CALayer()
                dot.actions = Self.stillActions
                dot.borderColor = rim
                dot.borderWidth = 0.5
                dot.shadowOffset = .zero
                dot.shadowOpacity = 1
                dot.shadowRadius = config.dotSize * 0.45
                root.addSublayer(dot)
                dotLayers.append(dot)
            }
        case .band:
            bandGlow.actions = Self.stillActions
            bandLayer.actions = Self.stillActions
            bandGlow.shadowOffset = .zero
            bandGlow.shadowRadius = config.dotSize * 0.4
            bandLayer.startPoint = CGPoint(x: 0, y: 0.5)
            bandLayer.endPoint = CGPoint(x: 1, y: 0.5)
            bandLayer.borderColor = CGColor(gray: 1, alpha: 0.12)
            bandLayer.borderWidth = 0.5
            bandLayer.masksToBounds = true
            root.addSublayer(bandGlow)
            root.addSublayer(bandLayer)
        }
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        switch config.style {
        case .dots:
            let size = config.dotSize
            let y = (bounds.height - size) / 2
            for (index, dot) in dotLayers.enumerated() {
                dot.frame = CGRect(x: CGFloat(index) * (size + config.spacing), y: y, width: size, height: size)
                dot.cornerRadius = size / 2
                dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)
                dot.contentsScale = scale
            }
        case .band:
            // The glow layer sits a point inside the band, so its fill
            // never shows past the gradient; its shadow is the band's
            // whole capsule. (A layer with a shadow path and no fill
            // draws no shadow in an offscreen still.)
            let radius = bounds.height / 2
            let inset = min(1, bounds.height / 4)
            bandGlow.frame = bounds.insetBy(dx: inset, dy: inset)
            bandGlow.cornerRadius = max(0, radius - inset)
            let capsule = CGRect(origin: .zero, size: bounds.size).offsetBy(dx: -inset, dy: -inset)
            bandGlow.shadowPath = CGPath(roundedRect: capsule, cornerWidth: radius, cornerHeight: radius, transform: nil)
            bandLayer.frame = bounds
            bandLayer.cornerRadius = radius
            bandLayer.contentsScale = scale
        }
        CATransaction.commit()
    }

    // MARK: The link

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObservers()
        if let window {
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification,
                         NSWindow.willCloseNotification] {
                windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshAnimating() }
                })
            }
        }
        needsLayout = true
        refreshAnimating()
    }

    /// Starts or stops the link to match `animates`. In a window with no
    /// screen — a still taken off screen — the strip shows its brightest
    /// instant, a fair picture of what it plays, rather than the black
    /// first frame many programs start from.
    func refreshAnimating() {
        let window = self.window
        if let window, window.screen == nil, !held {
            let still = LEDStripFrames.colors(sampler: sampler, ledCount: config.ledCount, elapsed: 0,
                                              still: true, loops: config.loops)
            apply(still)
        }
        let wanted = Self.animates(inWindow: window != nil, onScreen: window?.screen != nil,
                                   windowVisible: window?.occlusionState.contains(.visible) ?? false,
                                   held: held, reduceMotion: reduceMotion, paused: config.paused,
                                   moving: !(sampler?.isStatic ?? true))
        if wanted, link == nil {
            let link = displayLink(target: linkTarget, selector: #selector(LEDStripLinkTarget.tick(_:)))
            let fps = Self.framesPerSecond
            link.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !wanted, let link {
            link.invalidate()
            self.link = nil
        }
    }

    /// Stops the link for good: the view is leaving the tree.
    func stopAnimating() {
        link?.invalidate()
        link = nil
        removeWindowObservers()
    }

    private func removeWindowObservers() {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
    }

    fileprivate func linkFired(_ link: CADisplayLink) {
        // Scrolled out of its window's view: nothing to recolour.
        guard !visibleRect.isEmpty else { return }
        renderFrame(at: CACurrentMediaTime())
    }
}

/// The display link's target: it holds the view weakly, so a link the
/// view forgot to stop cannot keep it alive.
@MainActor
private final class LEDStripLinkTarget: NSObject {
    weak var view: LEDStripLayerView?

    @objc func tick(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        view.linkFired(link)
    }
}

/// The dark plate an LED preview plays on, in either appearance: near
/// black, a touch lighter at the top edge like a lit room over a strip,
/// with a faint rim so it keeps its shape on a dark window.
struct LEDStage: View {
    var cornerRadius: CGFloat = 9

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(LinearGradient(colors: [Color(white: 0.13), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.04)],
                                                       startPoint: .top, endPoint: .bottom),
                                        lineWidth: 0.75))
    }
}

/// A provider's working light as the monitor plays it for one agent
/// working alone (`preview_provider_motion`): its chosen motion at its own
/// tempo, or the Relay for Automatic -- the same program the Pro is sent,
/// so the swatch can no longer show one motion while the strip plays
/// another. The local sketch stands in until the monitor answers and when
/// it is not running.
struct ProviderMotionPreview: View {
    let core: CoreModel
    let provider: String
    /// `LightingPreviewPrograms.working`, for a monitor that is away.
    let sketch: String
    var phase: TimeInterval = 0
    @ViewState private var rendered: (key: String, program: String)?

    struct Reply: Decodable {
        let program: String
    }

    /// What the render depends on: the provider and every setting.
    private var key: String { "\(core.isLive)|\(core.settings?.generation ?? 0)|\(provider)" }

    var body: some View {
        let live = rendered.flatMap { $0.key == key ? $0.program : nil }
        LEDStripPreview(program: live ?? sketch, style: .band, dotSize: 6, showsBackground: true,
                        cornerRadius: 6, phase: phase)
            .task(id: key) {
                let key = self.key
                guard core.isLive,
                      let reply = try? await core.request("preview_provider_motion",
                                                          args: ["provider": .string(provider), "led_count": .number(8)],
                                                          as: Reply.self),
                      !reply.program.isEmpty else { rendered = nil; return }
                rendered = (key, reply.program)
            }
    }
}

/// The finish the lights play (`list_finish_looks`): the shipped bloom,
/// Land or Ripple, in the done colour, as the monitor draws it; the local
/// sketch of the bloom stands in while it is away.
struct FinishLookPreview: View {
    let core: CoreModel
    let sketch: String
    @ViewState private var rendered: (key: String, program: String)?

    private var key: String { "\(core.isLive)|\(core.settings?.generation ?? 0)" }

    var body: some View {
        let live = rendered.flatMap { $0.key == key ? $0.program : nil }
        LEDStripPreview(program: live ?? sketch, style: .dots, dotSize: 9, spacing: 6)
            .task(id: key) {
                let key = self.key
                guard core.isLive,
                      let list = try? await core.request("list_finish_looks", as: FinishLookList.self),
                      let look = list.looks.first(where: { $0.style == list.current }) else { rendered = nil; return }
                rendered = (key, look.program)
            }
    }
}

/// Builds the small programs the Lighting page previews when the monitor
/// is not there to draw them: a provider's working animation under the
/// chosen blend mode and cycle speed, and the done celebration in a
/// colour. The daemon's own renders (`ProviderMotionPreview`,
/// `FinishLookPreview`) replace them whenever it answers.
enum LightingPreviewPrograms {
    static func working(colorHex: String, blendMode: String, cycleSeconds: Double, ledCount: Int = 8) -> String {
        let hex = normalized(colorHex)
        let ms = max(300, Int(cycleSeconds * 1000))
        let floor = scaled(hex, 0.10)
        let n = max(2, ledCount)
        switch blendMode {
        case "relay":
            // Spotlight: one agent flares along the strip.
            let step = max(40, ms / n)
            let segments = (0..<n).map { "\($0):\(hex) \(ms)ms pulse \($0 * step)ms" }.joined(separator: "; ")
            return "\(floor)\n\(segments)\nrepeat"
        case "spatial_split":
            // Split: this agent owns the left half, breathing.
            let mine = (0..<(n / 2)).map { "\($0):\(hex) \(ms)ms pulse 0ms" }.joined(separator: "; ")
            let rest = (n / 2..<n).map { "\($0):\(scaled(hex, 0.18))" }.joined(separator: "; ")
            return "\(rest)\n\(mine)\nrepeat"
        case "color_blend":
            // Smooth: a gradient of the colour rolling by.
            let shades = (0..<n).map { i in mixed(hex, scaled(hex, 0.25), Double(i) / Double(n - 1)) }.joined(separator: " ")
            return "\(shades)\nroll \(max(600, ms * 2))ms linear\nrepeat"
        case "cycle":
            // One at a time: the whole strip is this agent, then hands over.
            return "\(hex) \(ms / 2)ms cosine\n\(hex) \(ms)ms none\n\(scaled(hex, 0.05)) \(ms / 2)ms cosine\n\(scaled(hex, 0.05)) \(ms)ms none\nrepeat"
        case "classic":
            // Status only: a steady colour.
            return hex
        default:
            // Everyone: a swell, every LED together.
            return "\(floor)\n\(hex) \(ms)ms pulse\nrepeat"
        }
    }

    /// One STATE's own rhythm in its own colour: the light language's five
    /// motions (`colors.STATE_MOTION`), so the Lighting page's state rows
    /// preview what the strip actually plays rather than a flat swatch.
    ///
    /// Ask and Error are the pair this exists for. They are different
    /// colours now, and they are also different rhythms -- a beat that
    /// eases versus a hard square that does not -- so the row shows both
    /// channels of the distinction at once.
    static func state(_ mode: String, colorHex: String, cycleSeconds: Double = 1.6, ledCount: Int = 8) -> String {
        let hex = normalized(colorHex)
        let ms = max(500, Int(cycleSeconds * 1000))
        let n = max(2, ledCount)
        switch mode {
        case "working":
            let step = max(40, ms / n)
            let segments = (0..<n).map { "\($0):\(hex) \(ms)ms pulse \($0 * step)ms" }.joined(separator: "; ")
            return "\(scaled(hex, 0.10))\n\(segments)\nrepeat"
        case "ask":
            // A beat: one short sharp swell, resting lifted rather than dark.
            let beat = max(480, ms / 3)
            return "\(scaled(hex, 0.5))\n\(hex) \(beat)ms pulse\nrepeat"
        case "error":
            // A blink: a hard square, no easing at all, at 1 Hz.
            return "\(scaled(hex, 0.5)) \(ms / 2)ms none\n\(hex) \(ms / 2)ms none\nrepeat"
        case "done":
            return hex
        default:
            // Idle: one slow swell, every LED together.
            return "\(scaled(hex, 0.02))\n\(hex) \(ms * 3)ms pulse\nrepeat"
        }
    }

    /// The celebration: a fast ripple, a bloom, a hold, then off (the
    /// reference program in Tests/JRBarLEDSTests/Fixtures/programs).
    static func celebration(colorHex: String = "#00FF66", ledCount: Int = 8) -> String {
        let hex = normalized(colorHex)
        let n = max(2, ledCount)
        let ripple = (0..<n).map { "\($0):\(hex) 70ms none \($0 * 45)ms" }.joined(separator: "; ")
        return "off 90ms cosine\n\(ripple)\noff 70ms none\n\(hex) 280ms cosine\n\(mixed(hex, "#FFFFFF", 0.18)) 240ms cosine\n\(hex) 200ms cosine\n\(hex) 1400ms none\noff 900ms cosine"
    }

    /// A busy desk under `blendMode`: two agents working in their own
    /// colours and a third just done — the monitor's own `fleet` preview
    /// scenario, the decision a blend mode is really about, which a
    /// single-agent swatch cannot show. A local sketch of
    /// `colors.BLEND_MODE_DESCRIPTIONS` for a monitor without
    /// `preview_fleet`; the daemon's render is the authority. There is no
    /// ask in it on purpose: an ask takes the whole strip under every
    /// blend, so it says nothing about the blend.
    static func fleet(blendMode: String, working: (String, String), doneHex: String,
                      workingStateHex: String = "#00E5FF", cycleSeconds: Double, ledCount: Int = 8) -> String {
        let a = normalized(working.0), b = normalized(working.1), done = normalized(doneHex)
        let ms = max(600, Int(cycleSeconds * 1000))
        let n = max(2, ledCount)
        func block(_ range: Range<Int>, _ hex: String, _ timing: String) -> String {
            range.map { "\($0):\(hex)\(timing)" }.joined(separator: " ")
        }
        switch blendMode {
        case "round_robin":
            // Everyone: alternating LEDs, each agent in its own colour;
            // the working two breathe, the finished one holds.
            let colors = (0..<n).map { [a, b, done][$0 % 3] }
            let floor = colors.enumerated().map { $0.offset % 3 == 2 ? $0.element : scaled($0.element, 0.15) }.joined(separator: " ")
            let swell = colors.enumerated().filter { $0.offset % 3 != 2 }
                .map { "\($0.offset):\($0.element) \(ms)ms pulse" }.joined(separator: "; ")
            return "\(floor)\n\(swell)\nrepeat"
        case "spatial_split":
            // Split: a section each; the working sections beat while the
            // finished one holds.
            let third = max(1, n / 3)
            let base = (0..<n).map { index in
                index < third ? scaled(a, 0.4) : index < 2 * third ? scaled(b, 0.4) : done
            }.joined(separator: " ")
            let beat = (0..<(2 * third)).map { "\($0):\($0 < third ? a : b) \(ms)ms pulse" }.joined(separator: "; ")
            return "\(base)\n\(beat)\nrepeat"
        case "relay":
            // Spotlight: every section rests dim and one flares at a time.
            let third = max(1, n / 3)
            let sections: [(Range<Int>, String)] = [(0..<third, a), (third..<(2 * third), b), ((2 * third)..<n, done)]
            let dim = sections.flatMap { range, hex in range.map { _ in scaled(hex, 0.2) } }.joined(separator: " ")
            let flares = sections.map { range, hex in block(range, hex, "") + " \(ms)ms pulse" }
            return ([dim] + flares + ["repeat"]).joined(separator: "\n")
        case "cycle":
            // One at a time: the whole strip is each agent in turn.
            let lines = [a, b, done].flatMap { hex in ["\(hex) \(ms / 3)ms cosine", "\(hex) \(ms)ms none"] }
            return (lines + ["repeat"]).joined(separator: "\n")
        case "classic":
            // Status only: one colour for the desk's state, agents unnamed:
            // something is working.
            return state("working", colorHex: workingStateHex)
        default:
            // Smooth: the three colours blended into one gradient, drifting.
            let stops = (0..<n).map { index -> String in
                let t = Double(index) / Double(n - 1)
                return t < 0.5 ? mixed(a, b, t * 2) : mixed(b, done, (t - 0.5) * 2)
            }
            return "\(stops.joined(separator: " "))\nroll \(max(1200, ms * 3))ms linear\nrepeat"
        }
    }

    /// Rainstick idle, sped up so it can be seen: the daemon's drip is
    /// one pixel of the idle grey at 4 % luminance stepping every thirty
    /// seconds (`rainstick_idle.py`); the preview steps every 1.2 s at a
    /// brightness a settings row can show, walking the whole strip.
    static func rainstick(ledCount: Int = 8, stepMs: Int = 1200) -> String {
        let pixel = scaled("#8B93A7", 0.45)
        let n = max(2, ledCount)
        var lines = ["off"]
        for index in 0..<n {
            let previous = index == 0 ? "" : "\(index - 1):#000000 "
            lines.append("\(previous)\(index):\(pixel) \(stepMs)ms none")
        }
        lines.append("repeat")
        return lines.joined(separator: "\n")
    }

    static func normalized(_ hex: String) -> String {
        RGB8(hex: hex)?.hex ?? "#8E8E93"
    }

    static func scaled(_ hex: String, _ factor: Double) -> String {
        guard let rgb = RGB8(hex: hex) else { return hex }
        return RGB8(r: UInt8(Double(rgb.r) * factor), g: UInt8(Double(rgb.g) * factor), b: UInt8(Double(rgb.b) * factor)).hex
    }

    static func mixed(_ a: String, _ b: String, _ t: Double) -> String {
        guard let x = RGB8(hex: a), let y = RGB8(hex: b) else { return a }
        func lerp(_ p: UInt8, _ q: UInt8) -> UInt8 { UInt8(max(0, min(255, Double(p) + (Double(q) - Double(p)) * t))) }
        return RGB8(r: lerp(x.r, y.r), g: lerp(x.g, y.g), b: lerp(x.b, y.b)).hex
    }
}
