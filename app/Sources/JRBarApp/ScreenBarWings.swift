import AppKit
import SwiftUI

/// One wing slot's content: a lobe of the notch itself — the selected
/// task on the left, the headline usage meter on the right, or a
/// transient device notice. The ear draws a mark only — the provider's
/// bare glyph, a quota ring, or an SF symbol; `text` is the peek's and
/// VoiceOver's copy, not the ear's face. `tone` is the state colour.
struct ScreenBarWingSlot: Equatable {
    enum Tone: Equatable {
        /// White on the black lobe — ambient information.
        case neutral
        /// Waiting is amber everywhere in the app.
        case attention
        /// Failed is red.
        case alert
    }

    var text: String
    var provider: String?
    /// An SF Symbol leading the words instead of a provider glyph —
    /// "bolt.fill" for a charger, "headphones" for an output route.
    var symbol: String?
    /// The ear's ring fill, 0…1 — the usage meter's fraction. nil means
    /// no ring (state ears, notices).
    var meter: Double?
    /// The window's time left as a fraction of its own span — a drain
    /// arc inside the fill ring, 1 → just reset, 0 → resetting now.
    /// nil draws none: a `credits` lane has no clock to drain.
    var reset: Double?
    /// The mark is a live equalizer instead of a glyph — the media ear,
    /// drawn only while something is actually playing. `text` still
    /// carries the track line for the peek and VoiceOver.
    var visualizer = false
    var tone: Tone = .neutral

    var textColor: Color {
        switch tone {
        case .neutral: return .white.opacity(0.92)
        case .attention: return .orange
        case .alert: return .red
        }
    }
}

/// The two slots: nil means the side draws nothing and claims no room —
/// empty slots collapse rather than hold space open.
struct ScreenBarWings: Equatable {
    var left: ScreenBarWingSlot?
    var right: ScreenBarWingSlot?

    static let empty = ScreenBarWings()

    subscript(side: ScreenBarWingSide) -> ScreenBarWingSlot? {
        get { side == .left ? left : right }
        set { if side == .left { left = newValue } else { right = newValue } }
    }
}

/// What the wings view draws: each side's slot and the rect the
/// geometry claimed for it, plus the tray — the one continuous shape
/// that runs from the left claim, under the bezel, to the right claim
/// and drops a chin below it. All in view coordinates (origin
/// bottom-left, as `ScreenBarGeometry.wingSlotRect` returns them — the
/// view flips y for SwiftUI's top-left space).
@MainActor
@Observable
final class ScreenBarWingsModel {
    /// Each tuple's rect is the mark's zone — on the right it stops
    /// short of the handle slice, so the mark centres in what is left.
    var left: (slot: ScreenBarWingSlot, rect: CGRect)?
    var right: (slot: ScreenBarWingSlot, rect: CGRect)?
    /// The right ear's full bounds — mark zone plus the handle slice —
    /// for the hover wash. nil when no right ear draws.
    var rightEar: CGRect?
    /// The hidden-run handle's slice of the right ear while the
    /// menu-bar concealer runs — a control drawn in our own surface,
    /// so it can never park the way a status item does.
    var rightHandle: CGRect?
    var rightHandleRevealed = false
    /// The shared body — the ears are its visible ends, the chin under
    /// the bezel is the wrap. nil on notch-less screens, where the chips
    /// carry their own capsules beside the band.
    var tray: CGRect?
    /// The tray's bottom corner — the notch profile's radius, so the
    /// wrap's silhouette is the bezel's own.
    var notchCorner: CGFloat = NotchProfile.standardCornerRadius
    /// The bezel's side edges in tray-local x — where the tray runs
    /// under the notch its silhouette must keep the hardware's bottom
    /// corner arcs, or it paves them and reads as a slab clipping in.
    var bezelLeft: CGFloat = 0
    var bezelRight: CGFloat = 0
    /// How far each ear's lobe hangs below the bezel's bottom edge —
    /// `wingEarDrop` while a wing claims room, 0 otherwise. The tray's
    /// middle run stays at the bezel's bottom; only the lobes drop.
    var earDrop: CGFloat = 0
    var viewHeight: CGFloat = 0
    /// The dismiss-pull: the ear rides the finger's horizontal travel,
    /// already eased, so a flick visibly drags it off the notch.
    var leftPull: CGFloat = 0
    var rightPull: CGFloat = 0
    /// The hover tell: the ear under the pointer swells — proof the
    /// notch is alive while the intent debounce decides on the card.
    var leftSwell = false
    var rightSwell = false
}

/// The wing lobes. The drawn ear is a fixed-size complication hugging
/// the bezel — a mark inside the notch's own black shape continuing,
/// flush with the screen's top edge, where a centred capsule or bare
/// text in open menu-bar space reads as clutter. The claim is only the
/// ceiling on room; the ear's drawn bounds are what hit regions follow.
struct ScreenBarWingsView: View {
    @Bindable var model: ScreenBarWingsModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let tray = model.tray {
                // The one shape: flush with the screen's top edge, square
                // where it runs under the bezel, the outer bottom corners
                // rounded like the notch's own — and the bezel's own
                // bottom-corner arcs scooped back out of it where it
                // passes under them, so the hardware's curve stays the
                // silhouette instead of being paved into a slab. The
                // ears and the chin are the same fill — the notch sits
                // in it.
                NotchTrayShape(bezelLeft: model.bezelLeft, bezelRight: model.bezelRight,
                               corner: model.notchCorner, drop: model.earDrop)
                    .fill(.black, style: FillStyle(eoFill: true))
                    .frame(width: tray.width, height: tray.height)
                    .position(x: tray.midX, y: model.viewHeight - tray.midY)
            }
            if let left = model.left { chip(left.slot, rect: left.rect, side: .left) }
            if let right = model.right { chip(right.slot, rect: right.rect, side: .right) }
            if let handle = model.rightHandle {
                // The hidden-run toggle — ‹ for "items parked left of
                // the bar", › while the run is out. Our own surface,
                // so it can never be covered or parked.
                Image(systemName: model.rightHandleRevealed ? "chevron.right" : "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: handle.width, height: handle.height)
                    .position(x: handle.midX, y: model.viewHeight - handle.midY)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Hidden menu bar items"))
            }
            // A handle-only right ear still needs its hover wash.
            if model.right == nil, let ear = model.rightEar, model.rightSwell {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: model.notchCorner,
                    topTrailingRadius: 0, style: .continuous)
                    .fill(.white.opacity(0.10))
                    .frame(width: ear.width, height: ear.height)
                    .position(x: ear.midX, y: model.viewHeight - ear.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    /// The hover tell's reach — outward only, never over the bezel.
    static let swellReach: CGFloat = 3
    /// …and its grow — a whisper of scale on the mark itself.
    static let swellScale: CGFloat = 1.18

    /// The slot's mark — a symbol, never words. The ear is a complication
    /// on the bezel: the provider's bare glyph for state, a meter ring
    /// for quota, an SF mark for notices. The words stay in the peek and
    /// in VoiceOver.
    @ViewBuilder
    private func chip(_ slot: ScreenBarWingSlot, rect: CGRect, side: ScreenBarWingSide) -> some View {
        let tint = slot.tone == .neutral ? nil : slot.textColor
        // A dismiss-pull drags the ear off the bezel, fading as it goes.
        let pull = side == .left ? model.leftPull : model.rightPull
        // The tell reaches only outward — inward travel would paint the
        // mark over the bezel.
        let swell = side == .left ? model.leftSwell : model.rightSwell
        let reach = swell ? Self.swellReach * (side == .left ? -1 : 1) : 0
        let mark = Group {
            if slot.visualizer {
                // The media ear: three bars bouncing on their own
                // phases — the island strip's grammar, not a spectrum.
                // The slot only exists while the track plays; Reduce
                // Motion pins them still. 12 fps is plenty at 13 pt.
                TimelineView(.animation(minimumInterval: 1.0 / 12.0,
                                        paused: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    HStack(alignment: .bottom, spacing: 1.5) {
                        ForEach(0..<3, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(slot.textColor)
                                .frame(width: 2.5,
                                       height: 3 + 7 * abs(sin(t * 3.2 + Double(index) * 1.9)))
                        }
                    }
                    .frame(height: 13, alignment: .bottom)
                }
            } else if let symbol = slot.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(slot.textColor)
            } else if let meter = slot.meter {
                ring(meter, slot: slot, tint: tint)
            } else if let provider = slot.provider {
                glyph(.style(for: provider), size: 13, tint: tint)
            } else {
                // A slot with words but no mark still holds its claim —
                // the lone dot is the resting grammar.
                Circle().fill(slot.textColor).frame(width: 5, height: 5)
            }
        }
        .scaleEffect(swell ? Self.swellScale : 1)
        .opacity(1 - min(1, abs(pull) / 40))

        if model.tray != nil {
            // The wash covers the ear's full span — the mark's zone plus
            // the handle's slice on the right; the mark keeps its own
            // rect so it centres left of the handle.
            let wash = side == .right ? (model.rightEar ?? rect) : rect
            ZStack {
                if swell {
                    // The hover tell's body: a light wash over the ear's
                    // own silhouette — square top, the outer bottom
                    // corner rounded like the tray's — so the wing
                    // itself answers the pointer, not just the mark.
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: side == .left ? model.notchCorner : 0,
                        bottomTrailingRadius: side == .right ? model.notchCorner : 0,
                        topTrailingRadius: 0, style: .continuous)
                        .fill(.white.opacity(0.10))
                }
                // An ear the flank shrank below a mark's room draws the
                // cap alone — a glyph that size clips against the edge.
                if rect.width >= ScreenBarView.markMinWidth {
                    mark
                        .offset(x: rect.midX - wash.midX + pull + reach)
                }
            }
            .frame(width: wash.width, height: wash.height)
            // The wash stays welded to the tray; the mark rides the
            // pull and the outward reach inside it.
            .position(x: wash.midX, y: model.viewHeight - wash.midY)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(slot.text))
        } else {
            mark
                .padding(.vertical, 4)
                .fixedSize()
                .background(Capsule(style: .continuous).fill(.black))
                .frame(width: rect.width, height: rect.height,
                       alignment: side == .left ? .trailing : .leading)
                .position(x: rect.midX + pull + reach, y: model.viewHeight - rect.midY)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(slot.text))
        }
    }

    /// The quota ear: a thin ring filling to `fraction` — the battery-glyph
    /// grammar every Mac user reads — with the provider's mark inside.
    /// The reset countdown lives in the ear's text and tooltip: a second
    /// arc inside the ring read as a stray line over the mark, so it went.
    private func ring(_ fraction: Double, slot: ScreenBarWingSlot, tint: Color?) -> some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.22), lineWidth: 1.6)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(tint ?? (slot.provider.map { ProviderStyle.style(for: $0).accent } ?? .white),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let provider = slot.provider {
                glyph(.style(for: provider), size: 8.5, tint: tint)
            }
        }
        .frame(width: 18, height: 18)
    }

    /// The provider's bare glyph in its accent — no badge: the boxed
    /// `ProviderTile` reads as a menu-bar icon where the references draw a
    /// plain mark against the notch extension. `tint` wins for the
    /// attention/alert tones.
    @ViewBuilder
    private func glyph(_ style: ProviderStyle, size: CGFloat, tint: Color? = nil) -> some View {
        switch style.glyph {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint ?? style.accent)
        case .text(let text):
            Text(text)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundStyle(tint ?? style.accent)
        }
    }
}

/// The ears' shared body: a flat top at the screen's edge running one
/// uniform band `drop` below the bezel's bottom edge — the ears are the
/// band's own end caps, so the whole silhouette reads as the notch
/// continued, not two drips stepped under it. The band's outer bottom
/// corners carry a small radius. Where the tray passes under the bezel,
/// the hardware's bottom-corner arcs are scooped back out (the caller
/// fills even-odd, so each gap subpath punches a hole) — a square fill
/// would pave the notch's rounded corners and read as a slab clipping
/// into it rather than the notch's own continuation.
private struct NotchTrayShape: Shape {
    /// The bezel's side edges in tray-local x. A side whose edge sits
    /// inside the tray has a claimed ear — the tray steps down into that
    /// ear's lobe; a side at the tray's own edge has none.
    var bezelLeft: CGFloat
    var bezelRight: CGFloat
    /// The notch profile's corner radius — the lobes' outer bottom
    /// corners and the bezel's arcs alike.
    var corner: CGFloat
    /// How far the ear lobes hang below the bezel's bottom edge
    /// (`wingEarDrop`). The middle run under the bezel never drops —
    /// a chin there read as the notch grown downward.
    var drop: CGFloat

    func path(in rect: CGRect) -> Path {
        // One uniform band: the whole tray runs `drop` below the bezel's
        // bottom edge (0 today — the ears win with width, not depth), so
        // the ears read as the island's own end caps. Two radii:
        // `scoop` is the notch profile's own corner — it rounds the
        // band's outer bottom corners, so each ear's silhouette is the
        // bezel's mirrored outward, and it is the arc the punched gaps
        // keep under the hardware's corners.
        let depth = rect.height - max(0, drop)
        let scoop = max(0, min(corner, depth, rect.width / 2.0))
        var path = Path()
        guard rect.width > 0, rect.height > 0, depth > 0 else {
            path.addRect(rect)
            return path
        }
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        if scoop > 0 {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - scoop))
            path.addArc(center: CGPoint(x: rect.maxX - scoop, y: rect.maxY - scoop), radius: scoop,
                        startAngle: .degrees(0), endAngle: .degrees(90), clockwise: true)
            path.addLine(to: CGPoint(x: rect.minX + scoop, y: rect.maxY))
            path.addArc(center: CGPoint(x: rect.minX + scoop, y: rect.maxY - scoop), radius: scoop,
                        startAngle: .degrees(90), endAngle: .degrees(180), clockwise: true)
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.closeSubpath()
        for (edge, leading) in [(bezelLeft, true), (bezelRight, false)] {
            // A corner square the tray covers gets its gap punched back
            // out; one outside the tray is open already. Partial coverage
            // would paint the spill — those never arise from the claims.
            let square = CGRect(x: leading ? edge : edge - scoop,
                                y: depth - scoop, width: scoop, height: scoop)
            guard scoop > 0, square.minX >= rect.minX - 0.5, square.maxX <= rect.maxX + 0.5,
                  square.minY >= rect.minY else { continue }
            path.addPath(cornerGap(square: square, leading: leading))
        }
        return path
    }

    /// The below-arc region of a bottom-corner square — the sliver the
    /// bezel leaves open at its feet. y grows downward in the view.
    private func cornerGap(square: CGRect, leading: Bool) -> Path {
        var gap = Path()
        if leading {
            gap.move(to: CGPoint(x: square.minX, y: square.minY))
            gap.addLine(to: CGPoint(x: square.minX, y: square.maxY))
            gap.addLine(to: CGPoint(x: square.maxX, y: square.maxY))
            gap.addArc(center: CGPoint(x: square.maxX, y: square.minY), radius: square.width,
                       startAngle: .degrees(90), endAngle: .degrees(180), clockwise: true)
        } else {
            gap.move(to: CGPoint(x: square.maxX, y: square.minY))
            gap.addLine(to: CGPoint(x: square.maxX, y: square.maxY))
            gap.addLine(to: CGPoint(x: square.minX, y: square.maxY))
            gap.addArc(center: CGPoint(x: square.minX, y: square.minY), radius: square.width,
                       startAngle: .degrees(90), endAngle: .degrees(0), clockwise: false)
        }
        gap.closeSubpath()
        return gap
    }
}
