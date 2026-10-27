import AppKit
import JRBarCore
import JRBarLEDS
import QuartzCore
import SwiftUI

/// A program change gets one fade, unless Reduce Motion is on when it lands.
struct ScreenBarCrossfade {
    private(set) var duration: CFTimeInterval?

    mutating func arm(over seconds: CFTimeInterval, reduceMotion: Bool) {
        duration = reduceMotion ? nil : seconds
    }

    mutating func consume(reduceMotion: Bool) -> CFTimeInterval? {
        let seconds = duration
        duration = nil
        return reduceMotion ? nil : seconds
    }
}

/// The Screen Bar's drawing surface: four layers composited by the window
/// server and nothing rasterised in this process.
///
/// * `housingLayer` -- solid black, drawn only while our notch island is
///   up: the strip's seat. Square at the top where it runs into the
///   island's face, the notch profile's radius on its bottom corners, so
///   island and band read as one continuous black shape.
/// * `bandLayer`  -- the 4 pt rounded status band, one horizontal gradient;
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
    private var earWidth: CGFloat?
    private var earWasConstrained = false
    private var earRecovery: (start: CGFloat, target: CGFloat, elapsed: TimeInterval)?
    private var earLink: CADisplayLink?
    private var earTickAt: CFTimeInterval = 0
    var drivesEarRecoveryByHand = false
    var earRecoveryReduceMotionOverride: Bool?
    var onEarGeometryChange: (() -> Void)?
    private static let earRecoveryDuration: TimeInterval = 0.14

    private func presentedEarWidth(_ target: CGFloat, constrained: Bool) -> CGFloat {
        defer { earWasConstrained = constrained }
        guard let current = earWidth else { earWidth = target; return target }
        if target <= current || (earRecoveryReduceMotionOverride ?? Self.reduceMotion)
            || (!drivesEarRecoveryByHand && (!wingsLive || window == nil)) {
            earWidth = target
            earRecovery = nil
            earLink?.invalidate(); earLink = nil
            return target
        }
        guard earWasConstrained || earRecovery != nil else { earWidth = target; return target }
        if earRecovery?.target != target { earRecovery = (current, target, 0) }
        if !drivesEarRecoveryByHand, earLink == nil, window != nil {
            let link = displayLink(target: self, selector: #selector(earRecoveryTick(_:)))
            earLink = link
            earTickAt = CACurrentMediaTime()
            link.add(to: .main, forMode: .common)
        }
        return current
    }

    @objc private func earRecoveryTick(_ link: CADisplayLink) {
        let dt = max(0, link.timestamp - earTickAt)
        earTickAt = link.timestamp
        advanceEarRecovery(by: dt)
    }

    func advanceEarRecovery(by dt: TimeInterval) {
        guard var recovery = earRecovery else { return }
        recovery.elapsed += max(0, dt)
        let progress = min(1, recovery.elapsed / Self.earRecoveryDuration)
        let eased = 1 - pow(1 - progress, 3)
        earWidth = recovery.start + (recovery.target - recovery.start) * eased
        earRecovery = progress == 1 ? nil : recovery
        if progress == 1 { earLink?.invalidate(); earLink = nil }
        relayout()
        onEarGeometryChange?()
    }

    private let bandLayer = CAGradientLayer()
    private let haloLayer = CAGradientLayer()
    private let haloMask = CAGradientLayer()
    private let bandGeometryMask = CAShapeLayer()
    private let haloGeometryMask = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let housingLayer = CAShapeLayer()
    private let shoulderLayer = CAShapeLayer()
    private let colorSpace = ScreenBarGradientFrames.colorSpace
    private var lastStops: [BandStop] = []
    private var lastBandWidth: CGFloat = -1
    private(set) var bandRect: NSRect = .zero
    /// The width the window would have without the content wings' claim —
    /// the band hugs the notch (plus the glow wings) rather than growing
    /// into the flanks the slots widened the window for.
    var bandSpan: CGFloat = 0
    /// The slots' content, pushed by the controller on each core change;
    /// A notched display keeps both caps while either slot has content.
    var wings: ScreenBarWings = .empty {
        didSet { if wings != oldValue { relayout() } }
    }
    /// The claim `windowFrame` was built with — the ceiling on each
    /// side's ear. `updateWingChips` resolves it to the ears' drawn
    /// bounds, which are what hit regions and wing gestures answer to.
    private var updatingWingLayout = false
    private var updatingLayout = false
    /// Whether a wing update animated content; geometry is always immediate.
    var onWingLayout: ((Bool) -> Void)?

    func updateLayout(_ updates: () -> Void) {
        let wasUpdating = updatingLayout
        updatingLayout = true
        updates()
        updatingLayout = wasUpdating
        if !wasUpdating { relayout() }
    }
    var wingGeometry = ScreenBarWingGeometry() {
        didSet { if wingGeometry != oldValue && !updatingWingLayout { relayout() } }
    }
    /// The measured native-item edge on the right flank, retained for
    /// diagnostics. Menu interaction does not change wing visibility.
    var rightEarLimit: CGFloat? {
        didSet { if rightEarLimit != oldValue && !updatingWingLayout { relayout() } }
    }
    /// The measured native-item edge on the left flank. It does not
    /// resize or hide a wing the user has restored.
    var leftEarLimit: CGFloat? {
        didSet { if leftEarLimit != oldValue && !updatingWingLayout { relayout() } }
    }
    /// Apply both collision limits and their measured claims as one layout.
    func configureWingLayout(geometry: ScreenBarWingGeometry, leftLimit: CGFloat?, rightLimit: CGFloat?) {
        guard geometry != wingGeometry || leftLimit != leftEarLimit || rightLimit != rightEarLimit else { return }
        updatingWingLayout = true
        wingGeometry = geometry
        leftEarLimit = leftLimit
        rightEarLimit = rightLimit
        updatingWingLayout = false
        relayout()
    }

    /// The narrowest ear still worth drawing — a bare cap continues the
    /// band toward whatever item claimed the flank, so a thin ear is a
    /// shoulder, not a sliver.
    static let minimumEarWidth: CGFloat = 12
    /// An ear narrower than this has no room for its mark — the cap
    /// draws but the glyph stays out of a space it would clip.
    static let markMinWidth: CGFloat = 22
    /// The tray's bottom corner — the notch profile's resolution
    /// (`screen_bar_notch_profile` + `screen_bar_notch_corner`), pushed
    /// by the controller so the wrap's silhouette is the bezel's own.
    var notchCornerRadius: CGFloat = NotchProfile.standardCornerRadius {
        didSet { if notchCornerRadius != oldValue { relayout() } }
    }
    /// The ear's drawn bounds in view coordinates — content-sized,
    /// hugging the bezel — not the claim that capped it.
    private(set) var leftWingRect: NSRect?
    private(set) var rightWingRect: NSRect?
    /// The wings' shared tray — ear to ear, flush with the bezel's
    /// bottom edge — in view coordinates; nil while no wing is drawn or
    /// the screen has no notch to wrap.
    private(set) var trayRect: NSRect?
    /// The notch island's frame in view coordinates while it is ours and
    /// on screen — pushed by the controller on every reposition. Non-nil
    /// couples the band: the strip runs the island's width under it and
    /// `housingLayer` continues its silhouette (`ScreenBarCoupling`).
    /// nil is the standalone band: Notch off, the island parked, an
    /// external provider rendering, or a screen with no notch.
    var islandFrame: CGRect?
    /// The housing's drawn bounds in view coordinates — ours, so it joins
    /// the hit region; nil while the band stands alone.
    private(set) var housingRect: NSRect?
    private(set) var shoulderPath: CGPath?
    private(set) var nativeShoulderPath: CGPath?
    /// The actual housing after removing native-menu space.
    private(set) var housingPaintPath: CGPath?
    private let wingsModel = ScreenBarWingsModel()
    private var wingsHosting: NSHostingView<ScreenBarWingsView>?
    private var lastWingDiagnostic: String?
    var onAccessibilityPress: @MainActor () -> Bool = { false }
    /// Somebody can see the band (`ScreenBarVisibility.live`): the ears'
    /// own timelines pause while it is false.
    var wingsLive: Bool {
        get { wingsModel.live }
        set {
            if wingsModel.live != newValue {
                wingsModel.live = newValue
                if !newValue, let recovery = earRecovery {
                    earWidth = recovery.target
                    earRecovery = nil
                    earLink?.invalidate(); earLink = nil
                    relayout()
                    onEarGeometryChange?()
                }
            }
        }
    }
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
    private(set) var keyframesInstalled = false
    var onKeyframesInstalled: (() -> Void)?
    typealias GradientRenderer = @Sendable (LEDSKeyframePlan, CGFloat, Bool) async -> ScreenBarGradientFrames
    static let defaultGradientRenderer: GradientRenderer = { plan, width, reduced in
        await Task.detached(priority: .userInitiated) {
            ScreenBarGradientFrames.build(plan: plan, width: width, reduced: reduced)
        }.value
    }
    var gradientRenderer: GradientRenderer = defaultGradientRenderer

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            earLink?.invalidate()
            earLink = nil
            if let recovery = earRecovery { earWidth = recovery.target }
            earRecovery = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

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
        haloMask.mask = haloGeometryMask
        bandLayer.mask = bandGeometryMask
        for mask in [bandGeometryMask, haloGeometryMask] {
            mask.fillColor = CGColor(gray: 1, alpha: 1)
            mask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        }
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

        shoulderLayer.fillColor = CGColor(gray: 0, alpha: 1)
        shoulderLayer.actions = ["path": NSNull(), "hidden": NSNull()]
        root.addSublayer(shoulderLayer)
        root.addSublayer(housingLayer)
        root.addSublayer(haloLayer)
        root.addSublayer(bandLayer)
        root.addSublayer(outlineLayer)

        // A status light, not a bare coloured rect: VoiceOver gets a name
        // for the band (the controller refines the label when a program
        // is refused).
        setAccessibilityElement(false)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Screen Bar — agent status light")
        setAccessibilityHelp("Mirrors the agents' status; the same words are on the JR-Bar menu bar item")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }

    override func accessibilityPerformPress() -> Bool {
        onAccessibilityPress()
    }

    override func accessibilityFrame() -> NSRect {
        guard let window, !bandRect.isEmpty else { return super.accessibilityFrame() }
        return window.convertToScreen(convert(bandRect, to: nil))
    }

    override func layout() {
        super.layout()
        relayout()
    }

    func relayout() {
        guard !updatingLayout else { return }
        let size = bounds.size
        // Resolve the wings before seating the light. Their lower edge
        // belongs to the same silhouette as the island.
        updateWingChips()
        // The wings own a silhouette even when the Notch utility is off.
        // Seat the light below whichever of those bodies is visible.
        var silhouette = trayRect
        var couplingRadius = notchCornerRadius
        var islandBody: CGRect?
        let islandPaint = islandFrame.flatMap { islandPaintPath($0) }
        shoulderPath = nil
        if let islandFrame, islandFrame.intersects(CGRect(origin: .zero, size: size)) {
            // The housing continues the island's body, which stands in
            // from the frame's edge by the shoulder's width: the frame
            // itself would step the housing's sides out past the island's.
            let body = NotchSilhouetteGeometry.body(of: islandFrame, notchWidth: wingGeometry.notchWidth,
                                                    notchDepth: wingGeometry.notchDepth)
            islandBody = body
            couplingRadius = NotchSilhouetteGeometry.radius(size: islandFrame.size,
                notchDepth: wingGeometry.notchDepth, restingRadius: notchCornerRadius)
            silhouette = trayRect.map { tray in
                let depth = max(0, tray.minY - body.minY)
                if depth >= ScreenBarGeometry.wingSeatHeight, body.maxY == tray.maxY {
                    shoulderPath = ScreenBarGeometry.shoulderConnector(tray: tray, body: body,
                        trayRadius: notchCornerRadius, bodyRadius: couplingRadius)
                    return body
                }
                let progress = min(1, depth / ScreenBarGeometry.wingSeatHeight)
                let blend = progress * progress * (3 - 2 * progress)
                let startingWidth = max(body.width, tray.width)
                let width = startingWidth + (body.width - startingWidth) * blend
                let bottom = min(body.minY, tray.minY)
                let top = max(body.maxY, tray.maxY)
                let foot = CGRect(x: body.midX - width / 2, y: bottom,
                                  width: width, height: top - bottom)
                let joiningBody = CGRect(x: foot.minX, y: body.minY, width: width, height: body.height)
                shoulderPath = ScreenBarGeometry.shoulderConnector(tray: tray, body: joiningBody,
                    trayRadius: notchCornerRadius, bodyRadius: couplingRadius)
                return foot
            } ?? body
        }
        let rect: NSRect
        if wingGeometry.notchDepth > 0, let silhouette {
            let coupling = ScreenBarGeometry.coupledBand(in: size, island: silhouette,
                cornerRadius: couplingRadius)
            rect = coupling.band
            housingRect = coupling.housing
            housingPaintPath = menuSafePath(Self.housingPath(coupling.housing, radius: coupling.cornerRadius))
            if let islandPaint { housingPaintPath = housingPaintPath?.subtracting(islandPaint) }
            housingLayer.path = housingPaintPath
            housingLayer.isHidden = false
        } else {
            rect = ScreenBarGeometry.bandRect(in: size, preferredSpan: bandSpan > 0 ? bandSpan : nil,
                                              underBezel: wingGeometry.notchDepth)
            housingRect = nil
            housingPaintPath = nil
            housingLayer.isHidden = true
        }
        if let tray = trayRect {
            // The native island owns input for the visible lower ledge too.
            // Otherwise a swipe on a wing reaches the application behind it.
            let trayPaint = ScreenBarGeometry.trayPath(tray,
                stemWidth: wingGeometry.menuRowStemWidth,
                notchDepth: wingGeometry.notchDepth, radius: notchCornerRadius)
            let hull = silhouette == islandBody ? (islandPaint ?? CGMutablePath()) : ScreenBarGeometry.trayPath(silhouette ?? tray,
                stemWidth: wingGeometry.menuRowStemWidth,
                notchDepth: wingGeometry.notchDepth, radius: couplingRadius)
            var joined = hull.union(trayPaint)
            if let connector = shoulderPath { joined = joined.union(connector) }
            let safeHull = menuSafePath(joined)
            let outsideIsland = islandPaint.map { safeHull.subtracting($0) } ?? safeHull
            let skin = outsideIsland.subtracting(trayPaint)
            shoulderPath = skin.isEmpty ? nil : skin
            nativeShoulderPath = housingPaintPath.map { safeHull.union($0) } ?? safeHull
            if let islandPaint { nativeShoulderPath = nativeShoulderPath?.subtracting(islandPaint) }
        } else {
            nativeShoulderPath = shoulderPath
        }
        shoulderLayer.path = shoulderPath
        shoulderLayer.isHidden = shoulderPath == nil
        bandRect = rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bandLayer.frame = rect
        // The halo is the band, widened and bled a little past every edge:
        // the mask fades it out over the extra height the way the Python
        // bloom layers carry the light past the housing. A point and a
        // half, no more: under the notch that bleed lands on app content —
        // 3.5 pt of it smeared a warm fringe below the housing, and 3 pt
        // past the tucked end caps hazed the housing's corners.
        let haloFrame = rect.insetBy(dx: -1.5, dy: -1.5)
        haloLayer.frame = haloFrame
        haloMask.frame = CGRect(origin: .zero, size: haloFrame.size)
        updateLightGeometryMasks(band: rect, halo: haloFrame)
        let radius = ScreenBarGeometry.bandCapRadius(rect)
        outlineLayer.frame = bounds
        outlineLayer.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
        if lastBandWidth != rect.width {
            lastBandWidth = rect.width
            lastStops = []
        }
    }

    /// Keep coloured light inside the black housing, including its chin.
    private func updateLightGeometryMasks(band: CGRect, halo: CGRect) {
        for (mask, frame) in [(bandGeometryMask, band), (haloGeometryMask, halo)] {
            mask.frame = CGRect(origin: .zero, size: frame.size)
            if let housingPaintPath {
                var transform = CGAffineTransform(translationX: -frame.minX, y: -frame.minY)
                mask.path = housingPaintPath.copy(using: &transform)
            } else {
                mask.path = CGPath(rect: CGRect(origin: .zero, size: frame.size), transform: nil)
            }
        }
    }

    /// Positions the slot chips: a side draws only where the geometry
    /// claimed room AND the store gave it something to say. The hosting
    /// view is created lazily so a bar that never shows wings never pays
    /// for a SwiftUI tree.
    private func updateWingChips() {
        let size = bounds.size
        let leftRect: CGRect?
        let rightRect: CGRect?
        if wingGeometry.notchDepth > 0 {
            let anyContent = wings.left != nil || wings.right != nil
            let preferred = max(wings.left?.preferredEarWidth ?? 0, wings.right?.preferredEarWidth ?? 0)
            let wanted = anyContent ? ScreenBarGeometry.symmetricEarRects(
                in: size, geometry: wingGeometry,
                preferredWidth: preferred,
                minimumWidth: Self.minimumEarWidth) : (left: nil, right: nil)
            let target = wanted.left?.width ?? 0
            let constrained = target < preferred
            let width = presentedEarWidth(target, constrained: constrained)
            let rects = width > 0 ? ScreenBarGeometry.symmetricEarRects(
                in: size, geometry: wingGeometry,
                preferredWidth: width, minimumWidth: 0) : (left: nil, right: nil)
            leftRect = rects.left
            rightRect = rects.right
        } else {
            leftRect = wings.left == nil ? nil : ScreenBarGeometry.wingSlotRect(.left, in: size, geometry: wingGeometry)
            rightRect = wings.right == nil ? nil : ScreenBarGeometry.wingSlotRect(.right, in: size, geometry: wingGeometry)
        }
        let left = leftRect.flatMap { r in wings.left.map { (slot: $0, rect: r) } }
        let right = rightRect.flatMap { r in wings.right.map { (slot: $0, rect: r) } }
        leftWingRect = leftRect
        rightWingRect = rightRect
        if ScreenBarInteraction.diagnosticsEnabled {
            let provider = ScreenBarInteraction.diagnosticProvider(wings.left?.provider)
            let leftLimit = leftEarLimit.map { String(describing: $0) } ?? "none"
            let rightLimit = rightEarLimit.map { String(describing: $0) } ?? "none"
            let message = "wings layout provider=\(provider) left=\(leftRect?.width ?? 0) right=\(rightRect?.width ?? 0) leftLimit=\(leftLimit) rightLimit=\(rightLimit)"
            if message != lastWingDiagnostic {
                lastWingDiagnostic = message
                ScreenBarInteraction.diag(message)
            }
        }
        guard leftRect != nil || rightRect != nil else {
            if wingsModel.left != nil { wingsModel.left = nil }
            if wingsModel.right != nil { wingsModel.right = nil }
            if wingsModel.rightEar != nil { wingsModel.rightEar = nil }
            if wingsModel.tray != nil { wingsModel.tray = nil }
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
        // edge, under the bezel, to the right ear's outer edge, ending
        // where the bezel ends — the strip seated under it marks the
        // wing's reach. An unclaimed side ends the tray at its own bezel
        // edge; the bezel hides the middle.
        var tray: CGRect?
        if wingGeometry.notchDepth > 0 {
            let sideExtent = max(0, (size.width - wingGeometry.notchWidth) / 2.0)
            tray = CGRect(
                x: leftRect?.minX ?? sideExtent,
                y: size.height - (wingGeometry.notchDepth + ScreenBarGeometry.wingEarDrop),
                width: (rightRect?.maxX ?? (sideExtent + wingGeometry.notchWidth))
                    - (leftRect?.minX ?? sideExtent),
                height: wingGeometry.notchDepth + ScreenBarGeometry.wingEarDrop)
        }
        trayRect = tray
        // Geometry already follows the island's integrated spring. Only
        // content changing inside unchanged bounds may animate separately.
        let geometryChanged = wingsModel.tray != tray
            || wingsModel.notchCorner != notchCornerRadius
            || wingsModel.menuRowStemWidth != wingGeometry.menuRowStemWidth
            || wingsModel.notchDepth != wingGeometry.notchDepth
            || wingsModel.viewHeight != size.height
            || wingsModel.left?.rect != left?.rect
            || wingsModel.right?.rect != right?.rect
            || wingsModel.rightEar != rightRect
        let contentChanged = wingsModel.left?.slot != left?.slot || wingsModel.right?.slot != right?.slot
        let animateContent = !Self.reduceMotion && !geometryChanged && contentChanged && islandFrame == nil
        let mutate = {
            if self.wingsModel.tray != tray { self.wingsModel.tray = tray }
            self.wingsModel.menuRowStemWidth = self.wingGeometry.menuRowStemWidth
            self.wingsModel.notchDepth = self.wingGeometry.notchDepth
            if self.wingsModel.notchCorner != self.notchCornerRadius {
                self.wingsModel.notchCorner = self.notchCornerRadius
            }
            if self.wingsModel.viewHeight != size.height { self.wingsModel.viewHeight = size.height }
            if self.wingsModel.left?.rect != left?.rect || self.wingsModel.left?.slot != left?.slot {
                self.wingsModel.left = left
            }
            if self.wingsModel.right?.rect != right?.rect || self.wingsModel.right?.slot != right?.slot {
                self.wingsModel.right = right
            }
            if self.wingsModel.rightEar != rightRect { self.wingsModel.rightEar = rightRect }
        }
        if animateContent {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75), mutate)
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction, mutate)
        }
        onWingLayout?(animateContent)
        if wingsHosting?.frame != bounds { wingsHosting?.frame = bounds }
        wingsHosting?.isHidden = false
    }

    private var menuFloor: CGFloat {
        bounds.height - wingGeometry.notchDepth - ScreenBarGeometry.wingMenuGap
    }

    private var menuSafeWidth: CGFloat {
        let stem = wingGeometry.menuRowStemWidth
        return stem > 0 ? min(bounds.width, stem + 2 * ScreenBarGeometry.wingMenuRowExtent) : 0
    }

    func isMenuSafePoint(_ point: CGPoint) -> Bool {
        guard wingGeometry.notchDepth > 0 else { return true }
        return point.y <= menuFloor
            || abs(point.x - bounds.midX) <= menuSafeWidth / 2
    }

    func menuSafeRects(_ rect: CGRect) -> [CGRect] {
        guard wingGeometry.notchDepth > 0 else { return rect.isEmpty ? [] : [rect] }
        let floor = max(0, min(bounds.height, menuFloor))
        let below = CGRect(x: 0, y: 0, width: bounds.width, height: floor)
        let stemWidth = min(bounds.width, max(0, menuSafeWidth))
        let stem = CGRect(x: bounds.midX - stemWidth / 2, y: floor,
                          width: stemWidth, height: bounds.height - floor)
        return [rect.intersection(below), rect.intersection(stem)].filter { !$0.isEmpty && !$0.isNull }
    }

    var interactionRects: [CGRect] {
        [bandRect, leftWingRect, rightWingRect, trayRect, housingRect]
            .compactMap { $0 }.flatMap { menuSafeRects($0) }
    }

    private func menuSafePath(_ path: CGPath) -> CGPath {
        ScreenBarGeometry.menuSafePath(path, in: bounds.size,
            stemWidth: wingGeometry.menuRowStemWidth, notchDepth: wingGeometry.notchDepth)
    }

    private func islandPaintPath(_ frame: CGRect) -> CGPath? {
        ScreenBarTrayShape.islandPath(frame, stemWidth: wingGeometry.menuRowStemWidth,
            notchDepth: wingGeometry.notchDepth, radius: notchCornerRadius)
    }

    /// Continue the combined island and wings down to the light strip.
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

    /// An ear's drawn width — a wing of notch black on the bezel's
    /// flank, wide enough that the mark inside reads as the island's
    /// end cap rather than a floating menu-bar icon. The claim only
    /// ever caps it. Alcove's closed island stays compact: a 48 pt
    /// lobe read as a slab where the references keep slim caps.
    private static let earWidth: CGFloat = 36

    /// The content budget inside the fixed ear: the mark's width, plus
    /// the privacy dots' lead when
    /// they ride along — or, for a dots-only ear, the dots between two
    /// insets — plus the accessory's slice at the outer end.
    static func contentWidth(_ slot: ScreenBarWingSlot?) -> CGFloat {
        guard let slot else { return 0 }
        let accessory = slot.accessory == nil ? 0 : ScreenBarWingAccessory.width
        guard slot.showsSensors else { return earWidth + accessory }
        let lead = ScreenBarSensorDots.lead(slot.sensors)
        return (slot.hasMark ? lead + earWidth : lead + ScreenBarSensorDots.inset) + accessory
    }

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

    /// The hover tell: the ear under the pointer swells a few points
    /// outward — proof the notch is alive while the island's intent
    /// debounce decides whether the hover meant the card. A nil side
    /// settles both.
    func setWingHover(_ side: ScreenBarWingSide?) {
        let write = { [wingsModel] in
            wingsModel.leftSwell = side == .left
            wingsModel.rightSwell = side == .right
        }
        if Self.reduceMotion {
            write()
        } else {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.65), write)
        }
    }

    // MARK: Keyframes (Core Animation owns the motion)

    /// Hands `plan` to Core Animation: the lead pass from `anchor` (a
    /// `CACurrentMediaTime` instant, possibly long past), then the loop
    /// forever from `anchor + loopStart`. Static plans set the colours once.
    /// A repeat call with the same plan at the same phase is a no-op:
    /// re-arming the same animations just re-renders every keyframe's
    /// colours on the main thread for a window move the band cannot see.
    /// A cross-fade the next program change plays instead of a cut —
    /// armed by the controller when a strip leaves, used once.
    private var pendingCrossfade = ScreenBarCrossfade()

    /// The next `play` or `display` that changes the colours fades from
    /// what is on the band to the new program over `seconds`. Reduce
    /// Motion keeps the cut, as every other band transition does; tests
    /// pin the setting instead of reading this Mac's.
    func crossfadeNextChange(over seconds: CFTimeInterval, reduceMotion: Bool? = nil) {
        pendingCrossfade.arm(over: seconds, reduceMotion: reduceMotion ?? Self.reduceMotion)
    }

    /// Inside the caller's transaction: fades from the current presentation
    /// to this transaction's colours. Recheck Reduce Motion after the queue.
    private func consumeCrossfade() {
        guard let seconds = pendingCrossfade.consume(reduceMotion: Self.reduceMotion) else { return }
        for layer in [bandLayer, haloLayer] {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = seconds
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: kCATransition)
        }
    }

    /// Whether a cross-fade is armed and not yet used (tests).
    var hasPendingCrossfade: Bool { pendingCrossfade.duration != nil }

    private var gradientWorker: Task<Void, Never>?
    private var gradientGeneration: UInt64 = 0
    private var preparedGradient: (plan: LEDSKeyframePlan, width: CGFloat, reduced: Bool,
                                   frames: ScreenBarGradientFrames)?

    func waitForKeyframes() async { await gradientWorker?.value }

    func play(plan: LEDSKeyframePlan, anchor: CFTimeInterval) {
        let width = bandRect.width
        guard width > 0 else { return }
        if isPlayingKeyframes, let last = lastPlay,
           last.plan == plan, last.anchor == anchor, last.width == width { return }
        stopKeyframes()
        lastPlay = (plan, anchor, width)
        isPlayingKeyframes = true
        gradientGeneration &+= 1
        prepareGradient()
    }

    /// One worker and one latest request. Geometry changes during planning
    /// replace the desired width without queuing another detached render.
    private func prepareGradient() {
        guard gradientWorker == nil else { return }
        gradientWorker = Task { @MainActor [weak self] in
            while let self, self.isPlayingKeyframes, let request = self.lastPlay {
                let generation = self.gradientGeneration
                let reduced = Self.reduceMotion
                let frames: ScreenBarGradientFrames
                if let cached = self.preparedGradient, cached.plan == request.plan,
                   cached.width == request.width, cached.reduced == reduced {
                    frames = cached.frames
                } else {
                    frames = await self.gradientRenderer(request.plan, request.width, reduced)
                }
                guard !Task.isCancelled else { return }
                guard generation == self.gradientGeneration else { continue }
                self.preparedGradient = (request.plan, request.width, reduced, frames)
                self.install(plan: request.plan, anchor: request.anchor, frames: frames)
                self.keyframesInstalled = true
                self.onKeyframesInstalled?()
                self.gradientWorker = nil
                return
            }
            self?.gradientWorker = nil
        }
    }

    private func install(plan: LEDSKeyframePlan, anchor: CFTimeInterval, frames: ScreenBarGradientFrames) {
        lastStops = []
        bandIsLit = planIsLit(plan)
        let layerAnchor = bandLayer.convertTime(anchor, from: nil)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        consumeCrossfade()
        for layer in [bandLayer, haloLayer] {
            layer.removeAnimation(forKey: Self.leadKey)
            layer.removeAnimation(forKey: Self.loopKey)
            layer.locations = frames.locations
            layer.colors = frames.rest
        }
        if let lead = plan.lead, let prepared = frames.lead, layerAnchor + Double(lead.durationMs) / 1000.0 > CACurrentMediaTime() {
            let animation = keyframeAnimation(track: lead, prepared: prepared)
            animation.beginTime = layerAnchor
            animation.repeatCount = 1
            animation.fillMode = .removed
            animation.isRemovedOnCompletion = true
            bandLayer.add(animation, forKey: Self.leadKey)
            if Self.haloEnabled, let copy = animation.copy() as? CAKeyframeAnimation { haloLayer.add(copy, forKey: Self.leadKey) }
        }
        if let loop = plan.loop, let prepared = frames.loop {
            let animation = keyframeAnimation(track: loop, prepared: prepared)
            animation.beginTime = layerAnchor + Double(plan.loopStartMs) / 1000.0
            animation.repeatCount = .infinity
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            bandLayer.add(animation, forKey: Self.loopKey)
            if Self.haloEnabled, let copy = animation.copy() as? CAKeyframeAnimation { haloLayer.add(copy, forKey: Self.loopKey) }
        }
        CATransaction.commit()
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
        keyframesInstalled = false
        gradientGeneration &+= 1
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

    /// One track as a `colors` animation. The stops go through
    /// `ScreenBarBlend.keyframes` so a fade to or from black stays a
    /// straight line of light. Render-server playback caps at 60 Hz,
    /// the pipeline's `MAX_SAMPLE_RATE_HZ`: on a 120 Hz ProMotion
    /// panel an uncapped animation re-renders both ~70-stop gradients
    /// (the halo's through its mask, offscreen) twice as often, for
    /// programs the presentation compiler keeps under 2 Hz of flashing.
    private func keyframeAnimation(track: LEDSKeyframeTrack, prepared: ScreenBarGradientFrames.Track) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "colors")
        animation.values = prepared.colors
        animation.keyTimes = prepared.times
        animation.duration = Double(track.durationMs) / 1000.0
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isAdditive = false
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        return animation
    }

    // MARK: One frame (the frame-clock fallback)

    /// Paint one sample of the eight LEDs. Cheap to call every frame: the stop
    /// list is compared first and Core Animation only re-composites on change.
    func display(colors: [RGB], preservingPendingKeyframes: Bool = false) {
        if isPlayingKeyframes, !preservingPendingKeyframes { stopKeyframes() }
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
        consumeCrossfade()
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
