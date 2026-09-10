import AppKit
import JRBarLEDS
import QuartzCore

/// The Screen Bar's drawing surface: three layers composited by the window
/// server and nothing rasterised in this process.
///
/// * `bandLayer`  -- the 6 pt rounded status band, one horizontal gradient;
/// * `haloLayer`  -- the same gradient, a little larger, softened by a
///   vertical alpha mask and drawn at `HALO_ALPHA` below the band so the
///   strip reads as light, not paint. (A Core Image blur would pull the
///   whole layer tree back into this process; a mask stays on the render
///   server.)
/// * `outlineLayer` -- the design's neutral 0.8 pt housing outline.
///
/// Two ways to paint it. `play(plan:anchor:)` hands a whole program to Core
/// Animation as keyframe animations on the gradient's `colors` (fixed stop
/// locations, one per 4 pt column) so the app idles while the band moves;
/// `display(colors:)` paints one frame, for the frame-clock fallback.
@MainActor
final class ScreenBarView: NSView {
    private let bandLayer = CAGradientLayer()
    private let haloLayer = CAGradientLayer()
    private let haloMask = CAGradientLayer()
    private let outlineLayer = CAShapeLayer()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var lastStops: [BandStop] = []
    private var lastBandWidth: CGFloat = -1
    private(set) var bandRect: NSRect = .zero
    /// CGColor objects are the per-frame allocation hot spot; the palette a
    /// program cycles through is small, so cache them by quantised value.
    private var colorCache: [UInt64: CGColor] = [:]
    private static let haloEnabled = ProcessInfo.processInfo.environment["JRBAR_NO_HALO"] == nil
    private static let leadKey = "jrbar.lead"
    private static let loopKey = "jrbar.loop"
    /// Which mode the layers are in, so a switch resets the other's state.
    private(set) var isPlayingKeyframes = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let root = CALayer()
        root.isOpaque = false
        root.backgroundColor = nil
        layer = root
        layerContentsRedrawPolicy = .never

        for gradient in [haloLayer, bandLayer] {
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.type = .axial
            gradient.isOpaque = false
            gradient.actions = ["colors": NSNull(), "locations": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
        }
        bandLayer.cornerRadius = ScreenBarDesign.cornerRadius
        bandLayer.masksToBounds = true
        bandLayer.cornerCurve = .continuous

        haloLayer.opacity = Float(ScreenBarDesign.haloAlpha) * 2.4
        haloMask.startPoint = CGPoint(x: 0.5, y: 0)
        haloMask.endPoint = CGPoint(x: 0.5, y: 1)
        haloMask.type = .axial
        haloMask.colors = [
            CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0])!,
            CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0.85])!,
            CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!,
            CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0.85])!,
            CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0])!,
        ]
        haloMask.locations = [0, 0.3, 0.5, 0.7, 1]
        haloMask.cornerRadius = 5
        haloMask.cornerCurve = .continuous
        haloMask.actions = ["bounds": NSNull(), "position": NSNull()]
        haloLayer.mask = haloMask
        haloLayer.isHidden = !Self.haloEnabled

        outlineLayer.fillColor = nil
        outlineLayer.lineWidth = 0.8
        outlineLayer.strokeColor = CGColor(colorSpace: colorSpace, components: [0.25, 0.25, 0.25, ScreenBarDesign.outlineAlpha * ScreenBarGeometry.minGlow])
        outlineLayer.actions = ["path": NSNull(), "strokeColor": NSNull()]

        root.addSublayer(haloLayer)
        root.addSublayer(bandLayer)
        root.addSublayer(outlineLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        relayout()
    }

    func relayout() {
        let size = bounds.size
        let rect = ScreenBarGeometry.bandRect(in: size)
        bandRect = rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bandLayer.frame = rect
        // The halo is the band, widened and bled a little past both edges:
        // the mask fades it out over the extra height the way the Python
        // bloom layers carry the light past the housing.
        let haloFrame = rect.insetBy(dx: -3.0, dy: -3.0).offsetBy(dx: 0, dy: -0.5)
        haloLayer.frame = haloFrame
        haloMask.frame = CGRect(origin: .zero, size: haloFrame.size)
        let radius = min(ScreenBarDesign.cornerRadius, rect.height / 2.0, rect.width / 2.0)
        outlineLayer.frame = bounds
        outlineLayer.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
        if lastBandWidth != rect.width {
            lastBandWidth = rect.width
            lastStops = []
        }
    }

    // MARK: Keyframes (Core Animation owns the motion)

    /// Hands `plan` to Core Animation: the lead pass from `anchor` (a
    /// `CACurrentMediaTime` instant, possibly long past), then the loop
    /// forever from `anchor + loopStart`. Static plans set the colours once.
    /// Cheap to call again with the same plan (a geometry change, a wake).
    func play(plan: LEDSKeyframePlan, anchor: CFTimeInterval) {
        let width = bandRect.width
        guard width > 0 else { return }
        isPlayingKeyframes = true
        lastStops = []
        let locations = ScreenBarBlend.columnLocations(bandWidth: width).map { NSNumber(value: Double($0)) }
        func colors(_ codes: [RGB8]) -> [CGColor] {
            ScreenBarBlend.columnSamples(colors: codes.map(\.rgb), bandWidth: width, alphaScale: ScreenBarBlend.coreAlpha).map(cgColor(for:))
        }
        let restColors = colors(plan.loop?.frames.first ?? plan.finalCodes)
        let layerAnchor = bandLayer.convertTime(anchor, from: nil)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [bandLayer, haloLayer] {
            layer.removeAnimation(forKey: Self.leadKey)
            layer.removeAnimation(forKey: Self.loopKey)
            layer.locations = locations
            layer.colors = restColors
        }
        if let lead = plan.lead, layerAnchor + Double(lead.durationMs) / 1000.0 > CACurrentMediaTime() {
            let animation = Self.keyframeAnimation(track: lead, colors: lead.frames.map(colors))
            animation.beginTime = layerAnchor
            animation.repeatCount = 1
            animation.fillMode = .removed
            animation.isRemovedOnCompletion = true
            bandLayer.add(animation, forKey: Self.leadKey)
            if Self.haloEnabled, let copy = animation.copy() as? CAKeyframeAnimation { haloLayer.add(copy, forKey: Self.leadKey) }
        }
        if let loop = plan.loop {
            let animation = Self.keyframeAnimation(track: loop, colors: loop.frames.map(colors))
            animation.beginTime = layerAnchor + Double(plan.loopStartMs) / 1000.0
            animation.repeatCount = .infinity
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            bandLayer.add(animation, forKey: Self.loopKey)
            if Self.haloEnabled, let copy = animation.copy() as? CAKeyframeAnimation { haloLayer.add(copy, forKey: Self.loopKey) }
        }
        CATransaction.commit()
    }

    /// Takes Core Animation's hands off the layers; the next `display` paints.
    func stopKeyframes() {
        guard isPlayingKeyframes else { return }
        isPlayingKeyframes = false
        lastStops = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [bandLayer, haloLayer] {
            layer.removeAnimation(forKey: Self.leadKey)
            layer.removeAnimation(forKey: Self.loopKey)
        }
        CATransaction.commit()
    }

    private static func keyframeAnimation(track: LEDSKeyframeTrack, colors: [[CGColor]]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "colors")
        animation.values = colors
        animation.keyTimes = track.keyTimes.map { NSNumber(value: $0) }
        animation.duration = Double(track.durationMs) / 1000.0
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isAdditive = false
        return animation
    }

    // MARK: One frame (the frame-clock fallback)

    /// Paint one sample of the eight LEDs. Cheap to call every frame: the stop
    /// list is compared first and Core Animation only re-composites on change.
    func display(colors: [RGB]) {
        if isPlayingKeyframes { stopKeyframes() }
        let width = bandRect.width
        guard width > 0 else { return }
        let stops = ScreenBarBlend.stops(colors: colors, bandWidth: width, alphaScale: ScreenBarBlend.coreAlpha)
        if stops == lastStops { return }
        lastStops = stops
        let cgColors = stops.map(cgColor(for:))
        let locations = stops.map { NSNumber(value: Double($0.location)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if stops.isEmpty {
            bandLayer.colors = nil
            haloLayer.colors = nil
        } else {
            bandLayer.colors = cgColors
            bandLayer.locations = locations
            if Self.haloEnabled {
                haloLayer.colors = cgColors
                haloLayer.locations = locations
            }
        }
        CATransaction.commit()
    }

    private func cgColor(for stop: BandStop) -> CGColor {
        cgColor(r: stop.r, g: stop.g, b: stop.b, a: stop.a)
    }

    private func cgColor(for sample: ScreenBarBlend.Sample) -> CGColor {
        cgColor(r: sample.r, g: sample.g, b: sample.b, a: sample.a)
    }

    private func cgColor(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) -> CGColor {
        let key = UInt64(r * 1024) << 33 | UInt64(g * 1024) << 22 | UInt64(b * 1024) << 11 | UInt64(a * 1024)
        if let cached = colorCache[key] { return cached }
        if colorCache.count > 4096 { colorCache.removeAll(keepingCapacity: true) }
        let color = CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
        colorCache[key] = color
        return color
    }
}
