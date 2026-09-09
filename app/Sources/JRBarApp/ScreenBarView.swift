import AppKit
import CoreImage
import JRBarLEDS
import QuartzCore

/// The Screen Bar's drawing surface: three GPU-composited layers and no
/// per-frame CPU rasterisation.
///
/// * `bandLayer`  -- the 6 pt rounded status band, one horizontal gradient
///   whose stops come from `ScreenBarBlend` (the Python blend, verbatim);
/// * `haloLayer`  -- the same gradient, Gaussian-blurred on the GPU and drawn
///   at `HALO_ALPHA` below the band so the strip reads as light, not paint;
/// * `outlineLayer` -- the design's neutral 0.8 pt housing outline.
@MainActor
final class ScreenBarView: NSView {
    private let bandLayer = CAGradientLayer()
    private let haloLayer = CAGradientLayer()
    private let outlineLayer = CAShapeLayer()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var lastStops: [BandStop] = []
    private var lastBandWidth: CGFloat = -1
    private(set) var bandRect: NSRect = .zero
    /// CGColor objects are the per-frame allocation hot spot; the palette a
    /// program cycles through is small, so cache them by quantised value.
    private var colorCache: [UInt64: CGColor] = [:]
    private var frameCounter = 0
    private static let haloEnabled = ProcessInfo.processInfo.environment["JRBAR_NO_HALO"] == nil

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerUsesCoreImageFilters = true
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
            gradient.actions = ["colors": NSNull(), "locations": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        }
        bandLayer.cornerRadius = ScreenBarDesign.cornerRadius
        bandLayer.masksToBounds = true
        bandLayer.cornerCurve = .continuous

        haloLayer.opacity = Float(ScreenBarDesign.haloAlpha) * 2.4
        haloLayer.cornerRadius = ScreenBarDesign.cornerRadius
        if Self.haloEnabled, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(3.2, forKey: kCIInputRadiusKey)
            haloLayer.filters = [blur]
        }
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
        // The halo is the band, widened slightly and bled downward: the blur
        // radius carries the light past the housing edge the way the Python
        // bloom layers do above the band.
        haloLayer.frame = rect.insetBy(dx: -1.5, dy: -2.0).offsetBy(dx: 0, dy: -1.0)
        let radius = min(ScreenBarDesign.cornerRadius, rect.height / 2.0, rect.width / 2.0)
        outlineLayer.frame = bounds
        outlineLayer.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
        if lastBandWidth != rect.width {
            lastBandWidth = rect.width
            lastStops = []
        }
    }

    /// Paint one sample of the eight LEDs. Cheap to call every frame: the stop
    /// list is compared first and Core Animation only re-composites on change.
    func display(colors: [RGB]) {
        let width = bandRect.width
        guard width > 0 else { return }
        let stops = ScreenBarBlend.stops(colors: colors, bandWidth: width, alphaScale: ScreenBarBlend.coreAlpha)
        if stops == lastStops { return }
        lastStops = stops
        frameCounter &+= 1
        let cgColors = stops.map(cgColor(for:))
        let locations = stops.map { NSNumber(value: Double($0.location)) }
        // The blurred halo cannot show single-frame detail; refreshing it on
        // alternate frames halves its share of the commit.
        let refreshHalo = Self.haloEnabled && (frameCounter & 1 == 0 || stops.isEmpty)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if stops.isEmpty {
            bandLayer.colors = nil
            haloLayer.colors = nil
        } else {
            bandLayer.colors = cgColors
            bandLayer.locations = locations
            if refreshHalo {
                haloLayer.colors = cgColors
                haloLayer.locations = locations
            }
        }
        CATransaction.commit()
    }

    private func cgColor(for stop: BandStop) -> CGColor {
        let key = UInt64(stop.r * 1024) << 33 | UInt64(stop.g * 1024) << 22 | UInt64(stop.b * 1024) << 11 | UInt64(stop.a * 1024)
        if let cached = colorCache[key] { return cached }
        if colorCache.count > 4096 { colorCache.removeAll(keepingCapacity: true) }
        let color = CGColor(colorSpace: colorSpace, components: [stop.r, stop.g, stop.b, stop.a])!
        colorCache[key] = color
        return color
    }
}
