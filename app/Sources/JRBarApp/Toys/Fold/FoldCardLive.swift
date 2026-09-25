import AppKit
import Observation
import QuartzCore
import SwiftUI

// MARK: - The lid glyph

/// The Fold card's live lid: `FoldLidGlyph`'s marks as shape layers,
/// redrawn from the toy's `cardAngle` without SwiftUI. A render proof's
/// still (`renderSnapshot`) draws the SwiftUI glyph instead.
struct FoldLiveLid: View {
    let toy: FoldToy
    let activation: Double?
    @Environment(\.renderSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            FoldLidGlyph(angle: toy.cardAngle, activation: activation)
        } else {
            FoldLidLayers(toy: toy, activation: activation)
                .accessibilityHidden(true)
        }
    }
}

private struct FoldLidLayers: NSViewRepresentable {
    let toy: FoldToy
    let activation: Double?

    func makeNSView(context: Context) -> FoldLidLayerView {
        FoldLidLayerView(toy: toy, activation: activation)
    }

    func updateNSView(_ view: FoldLidLayerView, context: Context) {
        view.activation = activation
    }

    static func dismantleNSView(_ view: FoldLidLayerView, coordinator: ()) {
        view.stopFollowing()
    }
}

/// The glyph's layers: one shape layer per mark, re-pathed when the
/// angle, the fold zone or the size changes, and recoloured with the
/// appearance and the accent colour.
@MainActor
final class FoldLidLayerView: NSView {
    var activation: Double? {
        didSet { if activation != oldValue { needsLayout = true } }
    }
    /// The angle drawn; the loop keeps it on the toy's `cardAngle`.
    private(set) var angle: Double?
    private var loop: ObservationLoop?
    private var shapes: [CAShapeLayer] = []
    private var marks: [FoldLidGlyph.Mark] = []

    init(toy: FoldToy, activation: Double?) {
        self.activation = activation
        super.init(frame: CGRect(x: 0, y: 0, width: 118, height: 70))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(false)
        needsLayout = true
        loop = ObservationLoop { [weak self, weak toy] in
            guard let self, let toy else { return }
            self.show(angle: toy.cardAngle)
        }
    }

    /// For tests: a glyph with no toy behind it.
    init(angle: Double?, activation: Double?) {
        self.angle = angle
        self.activation = activation
        super.init(frame: CGRect(x: 0, y: 0, width: 118, height: 70))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(angle newAngle: Double?) {
        guard newAngle != angle else { return }
        angle = newAngle
        needsLayout = true
    }

    func stopFollowing() {
        loop?.cancel()
        loop = nil
    }

    override func layout() {
        super.layout()
        marks = FoldLidGlyph.marks(in: bounds.size, angle: angle, activation: activation)
        redraw()
    }

    override func updateLayer() {
        redraw()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }

    /// The marks on the layers, in this view's appearance.
    private func redraw() {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while shapes.count < marks.count {
            let shape = CAShapeLayer()
            root.addSublayer(shape)
            shapes.append(shape)
        }
        while shapes.count > marks.count {
            shapes.removeLast().removeFromSuperlayer()
        }
        var primary = CGColor(gray: 0, alpha: 1)
        var accent = CGColor(gray: 0, alpha: 1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            primary = NSColor.labelColor.cgColor
            accent = NSColor.controlAccentColor.cgColor
        }
        for (shape, mark) in zip(shapes, marks) {
            shape.frame = bounds
            shape.path = mark.path
            let ink = mark.ink == .accent ? accent : primary
            let color = ink.copy(alpha: ink.alpha * mark.opacity) ?? ink
            if let stroke = mark.stroke {
                shape.fillColor = nil
                shape.strokeColor = color
                shape.lineWidth = stroke.lineWidth
                shape.lineCap = stroke.lineCap == .round ? .round : .butt
                shape.lineDashPattern = stroke.dash.isEmpty ? nil : stroke.dash.map { NSNumber(value: Double($0)) }
            } else {
                shape.fillColor = color
                shape.strokeColor = nil
                shape.lineDashPattern = nil
            }
        }
        CATransaction.commit()
    }
}

// MARK: - The angle

/// The card's big angle — "104°", or "no sensor" and "—" a size down —
/// as an AppKit label of a fixed size, following the toy's `cardAngle`
/// without SwiftUI. A render proof's still draws a SwiftUI `Text`.
struct FoldLiveAngle: View {
    let toy: FoldToy
    @Environment(\.renderSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            let text = FoldToy.angleText(toy.cardAngle, sensorAvailable: toy.sensor.available)
            Text(text)
                .font(toy.cardAngle == nil ? .system(size: 17, weight: .medium, design: .rounded)
                                           : .system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(toy.cardAngle == nil ? .secondary : .primary)
        } else {
            // The size follows only whether there is an angle, not the
            // number: the big face's line, or the note's.
            let size = FoldAngleLabelView.size(hasAngle: toy.cardHasAngle)
            FoldAngleLabel(toy: toy)
                .frame(width: size.width, height: size.height)
        }
    }
}

private struct FoldAngleLabel: NSViewRepresentable {
    let toy: FoldToy

    func makeNSView(context: Context) -> FoldAngleLabelView {
        FoldAngleLabelView(toy: toy)
    }

    func updateNSView(_ view: FoldAngleLabelView, context: Context) {}

    static func dismantleNSView(_ view: FoldAngleLabelView, coordinator: ()) {
        view.stopFollowing()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FoldAngleLabelView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? FoldAngleLabelView.width, height: proposal.height ?? 0)
    }
}

/// The label itself: one layer holding the text drawn as a picture.
/// Its size never changes with the number, so a new angle is a redraw of
/// these few points and nothing else. (A text layer loses the rounded
/// system face; a text field draws twice into an offscreen still.)
@MainActor
final class FoldAngleLabelView: NSView {
    /// Room for "180°" in the big face and "no sensor" in the small one.
    static let width: CGFloat = 96

    static let bigFont: NSFont = rounded(.monospacedDigitSystemFont(ofSize: 26, weight: .semibold))
    static let smallFont: NSFont = rounded(.monospacedDigitSystemFont(ofSize: 17, weight: .medium))

    /// One line of the face in use — the height the SwiftUI `Text` had.
    static func size(hasAngle: Bool) -> CGSize {
        let font = hasAngle ? bigFont : smallFont
        return CGSize(width: width, height: lineHeight(font))
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }

    /// `words` drawn from the top left of a `size` picture at `scale`.
    private static func picture(_ words: NSAttributedString, size: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        words.draw(with: CGRect(x: 0, y: 0, width: size.width, height: size.height),
                   options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func rounded(_ font: NSFont) -> NSFont {
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private let textLayer = CALayer()
    private var loop: ObservationLoop?
    /// What the label shows: a number in the big face, or a note.
    private var hasAngle = true
    private(set) var text = ""

    init(toy: FoldToy) {
        super.init(frame: CGRect(origin: .zero, size: Self.size(hasAngle: true)))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        textLayer.contentsGravity = .topLeft
        textLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(textLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        loop = ObservationLoop { [weak self, weak toy] in
            guard let self, let toy else { return }
            self.show(angle: toy.cardAngle, sensorAvailable: toy.sensor.available)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(angle: Double?, sensorAvailable: Bool) {
        let words = FoldToy.angleText(angle, sensorAvailable: sensorAvailable)
        let number = angle != nil
        guard words != text || number != hasAngle else { return }
        text = words
        hasAngle = number
        setAccessibilityValue(words)
        redraw()
    }

    func stopFollowing() {
        loop?.cancel()
        loop = nil
    }

    override func layout() {
        super.layout()
        redraw()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redraw()
    }

    /// The text in its face and ink — primary for a number, secondary for
    /// a note, as the SwiftUI text had it — resolved for this view's
    /// appearance, and centred on the line.
    private func redraw() {
        let font = hasAngle ? Self.bigFont : Self.smallFont
        var ink = NSColor.labelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base: NSColor = hasAngle ? .labelColor : .secondaryLabelColor
            ink = NSColor(cgColor: base.cgColor) ?? base
        }
        let height = Self.lineHeight(font)
        let line = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        let scale = window?.backingScaleFactor ?? 2
        let words = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.frame = line
        textLayer.contentsScale = scale
        textLayer.contents = Self.picture(words, size: line.size, scale: scale)
        CATransaction.commit()
    }
}
