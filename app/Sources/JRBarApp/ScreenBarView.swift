import AppKit
import JRBarLEDS
import QuartzCore
import SwiftUI

/// The Screen Bar's drawing surface: four layers composited by the window
/// server and nothing rasterised in this process.
///
/// * `housingLayer` -- solid black, drawn only while our notch island is
///   up: the strip's seat. Square at the top where it runs into the
///   island's face, the notch profile's radius on its bottom corners, so
///   island and band read as one continuous black shape.
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
    private let housingLayer = CAShapeLayer()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var lastStops: [BandStop] = []
    private var lastBandWidth: CGFloat = -1
    private(set) var bandRect: NSRect = .zero
    /// The width the window would have without the content wings' claim —
    /// the band hugs the notch (plus the glow wings) rather than growing
    /// into the flanks the slots widened the window for.
    var bandSpan: CGFloat = 0
    /// The slots' content, pushed by the controller on each core change;
    /// nil slots collapse — they claim no room and draw nothing.
    var wings: ScreenBarWings = .empty {
        didSet { if wings != oldValue { updateWingChips() } }
    }
    /// The claim `windowFrame` was built with — the ceiling on each
    /// side's ear. `updateWingChips` resolves it to the ears' drawn
    /// bounds, which are what hit regions and wing gestures answer to.
    var wingGeometry = ScreenBarWingGeometry() {
        didSet { if wingGeometry != oldValue { updateWingChips() } }
    }
    /// The x (view coordinates) the right ear may not reach past —
    /// macOS's « sits there while the Menu Bar utility hides a run.
    /// nil is no limit.
    var rightEarLimit: CGFloat? {
        didSet { if rightEarLimit != oldValue { updateWingChips() } }
    }
    /// The narrowest ear still worth drawing — the ring plus a point
    /// of air each side.
    static let minimumEarWidth: CGFloat = 18
    /// The tray's bottom corner — the notch profile's resolution
    /// (`screen_bar_notch_profile` + `screen_bar_notch_corner`), pushed
    /// by the controller so the wrap's silhouette is the bezel's own.
    var notchCornerRadius: CGFloat = NotchProfile.standardCornerRadius {
        didSet { if notchCornerRadius != oldValue { updateWingChips() } }
    }
    /// The ear's drawn bounds in view coordinates — content-sized,
    /// hugging the bezel — not the claim that capped it.
    private(set) var leftWingRect: NSRect?
    private(set) var rightWingRect: NSRect?
    /// The wings' shared tray — ear to ear under the bezel with a chin
    /// below it — in view coordinates; nil while no wing is drawn or the
    /// screen has no notch to wrap.
    private(set) var trayRect: NSRect?
    /// The notch island's frame in view coordinates while it is ours and
    /// on screen — pushed by the controller on every reposition. Non-nil
    /// couples the band: the strip runs edge to edge under the island and
    /// `housingLayer` continues its silhouette (`ScreenBarCoupling`).
    /// nil is the standalone band: Notch off, the island parked, an
    /// external provider rendering, or a screen with no notch.
    var islandFrame: CGRect?
    /// The housing's drawn bounds in view coordinates — ours, so it joins
    /// the hit region; nil while the band stands alone.
    private(set) var housingRect: NSRect?
    private let wingsModel = ScreenBarWingsModel()
    private var wingsHosting: NSHostingView<ScreenBarWingsView>?
    /// Settings › Screen Bar › Minimum glow, pushed in live: it scales the
    /// housing rim and nothing else. A band showing no light gets no rim —
    /// a black program under a lit outline is a resting glow the strip
    /// does not have.
    var minGlow: CGFloat = ScreenBarGeometry.minGlow {
        didSet { if minGlow != oldValue { updateOutline() } }
    }
    private var bandIsLit = false {
        didSet { if bandIsLit != oldValue { updateOutline() } }
    }
    /// CGColor objects are the per-frame allocation hot spot; the palette a
    /// program cycles through is small, so cache them by quantised value.
    private var colorCache: [UInt64: CGColor] = [:]
    /// What Core Animation was last handed; a re-`play` with the same plan
    /// at the same anchor and width changes nothing on screen.
    private var lastPlay: (plan: LEDSKeyframePlan, anchor: CFTimeInterval, width: CGFloat)?
    private static let haloEnabled = ProcessInfo.processInfo.environment["JRBAR_NO_HALO"] == nil
    private static let leadKey = "jrbar.lead"
    private static let loopKey = "jrbar.loop"
    /// Reduce Motion is a live setting; read it per call, never cached.
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
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

        // The halo reads through the mask's dim edges, so the layer needs
        // more than the design constant to land at 0.16 perceived alpha —
        // 2.4 was tuned by eye against the band's dark floor.
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
        updateOutline()
        outlineLayer.actions = ["path": NSNull(), "strokeColor": NSNull()]

        // The island's own material: plain black, no stroke — the same
        // `.fill(.black)` the island's background wears.
        housingLayer.fillColor = CGColor(gray: 0, alpha: 1)
        housingLayer.isHidden = true
        housingLayer.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]

        root.addSublayer(housingLayer)
        root.addSublayer(haloLayer)
        root.addSublayer(bandLayer)
        root.addSublayer(outlineLayer)

        // A status light, not a bare coloured rect: VoiceOver gets a name
        // for the band (the controller refines the label when a program
        // is refused).
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Screen Bar — agent status light")
        setAccessibilityHelp("Mirrors the agents' status; the same words are on the JR-Bar menu bar item")
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
        // Coupled to our island when it is drawn over a real notch: the
        // strip spans the island edge to edge and the black housing
        // continues its silhouette. Anything else — Notch off, an
        // external provider, a notch-less screen — is the standalone band.
        let rect: NSRect
        if let islandFrame, wingGeometry.notchDepth > 0,
           islandFrame.intersects(CGRect(origin: .zero, size: size)) {
            let coupling = ScreenBarGeometry.coupledBand(in: size, island: islandFrame,
                                                         notchDepth: wingGeometry.notchDepth,
                                                         cornerRadius: notchCornerRadius)
            rect = coupling.band
            housingRect = coupling.housing
            housingLayer.path = Self.housingPath(coupling.housing, radius: coupling.cornerRadius)
            housingLayer.isHidden = false
        } else {
            rect = ScreenBarGeometry.bandRect(in: size, preferredSpan: bandSpan > 0 ? bandSpan : nil)
            housingRect = nil
            housingLayer.isHidden = true
        }
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
        // The claims are the ceiling on ear width; `updateWingChips`
        // turns them into the ears' drawn bounds, which are what hit
        // regions and wing gestures answer to.
        updateWingChips()
    }

    /// Positions the slot chips: a side draws only where the geometry
    /// claimed room AND the store gave it something to say. The hosting
    /// view is created lazily so a bar that never shows wings never pays
    /// for a SwiftUI tree.
    private func updateWingChips() {
        let size = bounds.size
        // The ear is content-sized and hugs the bezel's edge — the claim
        // is only the ceiling on the room it may take, never its width.
        // The ear's own bounds are what hit regions answer to, so empty
        // claim space is not a dead-zone magnet.
        func ear(_ side: ScreenBarWingSide, _ slot: ScreenBarWingSlot?) -> (slot: ScreenBarWingSlot, rect: CGRect)? {
            guard let slot,
                  let claim = ScreenBarGeometry.wingSlotRect(side, in: size, geometry: wingGeometry)
            else { return nil }
            // Notch-less: the capsule chip carries itself in the claim.
            guard wingGeometry.notchDepth > 0 else { return (slot, claim) }
            let depth = wingGeometry.notchDepth + ScreenBarGeometry.wingTrayChin
            var width = min(claim.width, Self.earWidth)
            if side == .right, let limit = rightEarLimit {
                width = min(width, limit - claim.minX)
                guard width >= Self.minimumEarWidth else { return nil }
            }
            let x = side == .left ? claim.maxX - width : claim.minX
            return (slot, CGRect(x: x, y: size.height - depth, width: width, height: depth))
        }
        let left = ear(.left, wings.left)
        let right = ear(.right, wings.right)
        leftWingRect = left?.rect
        rightWingRect = right?.rect
        guard left != nil || right != nil else {
            wingsModel.left = nil
            wingsModel.right = nil
            wingsModel.tray = nil
            trayRect = nil
            wingsHosting?.isHidden = true
            return
        }
        if wingsHosting == nil {
            let hosting = NSHostingView(rootView: ScreenBarWingsView(model: wingsModel))
            addSubview(hosting)
            wingsHosting = hosting
        }
        // The tray is the one continuous shape: from the left ear's outer
        // edge, under the bezel, to the right ear's outer edge — the chin
        // below the bezel so the notch visibly sits in the shape. An
        // unclaimed side ends the tray at its own bezel edge; the bezel
        // hides the middle.
        var tray: CGRect?
        if wingGeometry.notchDepth > 0 {
            let sideExtent = max(0, (size.width - wingGeometry.notchWidth) / 2.0)
            tray = CGRect(
                x: left?.rect.minX ?? sideExtent,
                y: size.height - (wingGeometry.notchDepth + ScreenBarGeometry.wingTrayChin),
                width: (right?.rect.maxX ?? (sideExtent + wingGeometry.notchWidth))
                    - (left?.rect.minX ?? sideExtent),
                height: wingGeometry.notchDepth + ScreenBarGeometry.wingTrayChin)
        }
        trayRect = tray
        // The island morphs rather than pops: tray and ears spring to
        // their new bounds while a claim persists — Alcove's motion.
        let mutate = {
            self.wingsModel.tray = tray
            self.wingsModel.notchCorner = self.notchCornerRadius
            self.wingsModel.chin = tray == nil ? 0 : ScreenBarGeometry.wingTrayChin
            self.wingsModel.viewHeight = size.height
            self.wingsModel.left = left
            self.wingsModel.right = right
        }
        if Self.reduceMotion {
            mutate()
        } else {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.9), mutate)
        }
        wingsHosting?.frame = bounds
        wingsHosting?.isHidden = false
    }

    /// Square at the top, rounded at the bottom — the housing's
    /// silhouette in the view's unflipped coordinates: the straight top
    /// edge disappears into the island's face while the bottom corners
    /// carry the notch profile's radius.
    private static func housingPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, rect.height, rect.width / 2.0))
        let path = CGMutablePath()
        guard r > 0 else {
            path.addRect(rect)
            return path
        }
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                    radius: r, startAngle: 0, endAngle: -.pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r),
                    radius: r, startAngle: -.pi / 2, endAngle: .pi, clockwise: true)
        path.closeSubpath()
        return path
    }

    /// An ear's drawn width — a fixed complication on the bezel's edge:
    /// the mark's room plus its padding. The claim only ever caps it.
    /// The ring is 16 pt; 4 pt of air each side. Wider ears read as
    /// the notch grown sideways.
    private static let earWidth: CGFloat = 24

    /// A dismiss-pull drags the ear off the bezel: outward travel only
    /// (inward pulls meet the notch), eased by `tanh` so it resists as
    /// it leaves. Direct writes while the finger moves — the ear keeps
    /// up — and a spring back to zero when the pull ends short of the
    /// flick threshold.
    func setWingPull(_ side: ScreenBarWingSide, to dx: CGFloat, springBack: Bool = false) {
        let outward = side == .left ? min(0, dx) : max(0, dx)
        let eased = CGFloat(36 * tanh(Double(outward) / 36))
        let write = { [wingsModel] in
            if side == .left { wingsModel.leftPull = eased } else { wingsModel.rightPull = eased }
        }
        if springBack, !Self.reduceMotion {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.65), write)
        } else {
            write()
        }
    }

    // MARK: Keyframes (Core Animation owns the motion)

    /// Hands `plan` to Core Animation: the lead pass from `anchor` (a
    /// `CACurrentMediaTime` instant, possibly long past), then the loop
    /// forever from `anchor + loopStart`. Static plans set the colours once.
    /// A repeat call with the same plan at the same phase is a no-op:
    /// re-arming the same animations just re-renders every keyframe's
    /// colours on the main thread for a window move the band cannot see.
    func play(plan: LEDSKeyframePlan, anchor: CFTimeInterval) {
        let width = bandRect.width
        guard width > 0 else { return }
        if isPlayingKeyframes, let last = lastPlay,
           last.plan == plan, last.anchor == anchor, last.width == width {
            return
        }
        lastPlay = (plan, anchor, width)
        isPlayingKeyframes = true
        lastStops = []
        bandIsLit = planIsLit(plan)
        let locations = ScreenBarBlend.columnLocations(bandWidth: width).map { NSNumber(value: Double($0)) }
        func colors(_ codes: [RGB8]) -> [CGColor] {
            ScreenBarBlend.columnSamples(colors: codes.map(\.rgb), bandWidth: width, alphaScale: ScreenBarBlend.coreAlpha).map(cgColor(for:))
        }
        // Reduce Motion keeps the colour and drops the motion: the layers
        // hold the program's brightest frame and no animation goes on.
        let reduced = Self.reduceMotion
        let restColors = colors(Self.stillCodes(for: plan, reduced: reduced))
        let layerAnchor = bandLayer.convertTime(anchor, from: nil)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [bandLayer, haloLayer] {
            layer.removeAnimation(forKey: Self.leadKey)
            layer.removeAnimation(forKey: Self.loopKey)
            layer.locations = locations
            layer.colors = restColors
        }
        if !reduced, let lead = plan.lead, layerAnchor + Double(lead.durationMs) / 1000.0 > CACurrentMediaTime() {
            let animation = Self.keyframeAnimation(track: lead, colors: lead.frames.map(colors))
            animation.beginTime = layerAnchor
            animation.repeatCount = 1
            animation.fillMode = .removed
            animation.isRemovedOnCompletion = true
            bandLayer.add(animation, forKey: Self.leadKey)
            if Self.haloEnabled, let copy = animation.copy() as? CAKeyframeAnimation { haloLayer.add(copy, forKey: Self.leadKey) }
        }
        if !reduced, let loop = plan.loop {
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

    /// The frame the layers hold. Unreduced that is the loop's first frame —
    /// what the lead hands the loop. Under Reduce Motion it is the program's
    /// brightest frame, so a pulse keeps its peak and a chase keeps its
    /// gradient instead of resting on a first frame that may be dark.
    private static func stillCodes(for plan: LEDSKeyframePlan, reduced: Bool) -> [RGB8] {
        guard reduced else { return plan.loop?.frames.first ?? plan.finalCodes }
        let frames = (plan.lead?.frames ?? []) + (plan.loop?.frames ?? []) + [plan.finalCodes]
        return frames.max { lightLevel($0) < lightLevel($1) } ?? plan.finalCodes
    }

    /// Total light in a frame, for picking the brightest.
    private static func lightLevel(_ codes: [RGB8]) -> Int {
        codes.reduce(0) { $0 + Int(max($1.r, max($1.g, $1.b))) }
    }

    /// True when the program ever lights an LED: the rim only shows while
    /// there is something for it to sit around.
    private func planIsLit(_ plan: LEDSKeyframePlan) -> Bool {
        let frames = (plan.lead?.frames ?? []) + (plan.loop?.frames ?? []) + [plan.finalCodes]
        return frames.contains { $0.contains { $0 != .black } }
    }

    /// The rim's stroke for the current light state: `minGlow` while the
    /// band shows light, nothing while it is dark.
    private func updateOutline() {
        let alpha = bandIsLit ? ScreenBarDesign.outlineAlpha * min(1, max(0, minGlow)) : 0
        outlineLayer.strokeColor = CGColor(colorSpace: colorSpace, components: [0.25, 0.25, 0.25, alpha])
    }

    /// Takes Core Animation's hands off the layers; the next `display` paints.
    func stopKeyframes() {
        guard isPlayingKeyframes else { return }
        isPlayingKeyframes = false
        lastPlay = nil
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
        bandIsLit = !stops.isEmpty
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
