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
    var left: (slot: ScreenBarWingSlot, rect: CGRect)?
    var right: (slot: ScreenBarWingSlot, rect: CGRect)?
    /// The shared body — the ears are its visible ends, the chin under
    /// the bezel is the wrap. nil on notch-less screens, where the chips
    /// carry their own capsules beside the band.
    var tray: CGRect?
    var viewHeight: CGFloat = 0
    /// The dismiss-pull: the ear rides the finger's horizontal travel,
    /// already eased, so a flick visibly drags it off the notch.
    var leftPull: CGFloat = 0
    var rightPull: CGFloat = 0
}

/// The wing lobes. The drawn ear is a fixed-size complication hugging
/// the bezel — a mark inside the notch's own black shape continuing,
/// flush with the screen's top edge, where a centred capsule or bare
/// text in open menu-bar space reads as clutter. The claim is only the
/// ceiling on room; the ear's drawn bounds are what hit regions follow.
struct ScreenBarWingsView: View {
    @Bindable var model: ScreenBarWingsModel

    /// The notch's own bottom corner radius, matched so the tray reads
    /// as the bezel continuing, not a shape docked to it.
    private static let notchCorner: CGFloat = 10

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let tray = model.tray {
                // The one shape: flush with the screen's top edge, square
                // where it runs under the bezel, the outer bottom corners
                // rounded like the notch's own. The ears and the chin are
                // the same fill — the notch sits in it.
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: Self.notchCorner,
                                       bottomTrailingRadius: Self.notchCorner, topTrailingRadius: 0,
                                       style: .continuous)
                    .fill(.black)
                    .frame(width: tray.width, height: tray.height)
                    .position(x: tray.midX, y: model.viewHeight - tray.midY)
            }
            if let left = model.left { chip(left.slot, rect: left.rect, side: .left) }
            if let right = model.right { chip(right.slot, rect: right.rect, side: .right) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    /// The slot's mark — a symbol, never words. The ear is a complication
    /// on the bezel: the provider's bare glyph for state, a meter ring
    /// for quota, an SF mark for notices. The words stay in the peek and
    /// in VoiceOver.
    @ViewBuilder
    private func chip(_ slot: ScreenBarWingSlot, rect: CGRect, side: ScreenBarWingSide) -> some View {
        let tint = slot.tone == .neutral ? nil : slot.textColor
        // A dismiss-pull drags the ear off the bezel, fading as it goes.
        let pull = side == .left ? model.leftPull : model.rightPull
        let mark = Group {
            if let symbol = slot.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(slot.textColor)
            } else if let meter = slot.meter {
                ring(meter, slot: slot, tint: tint)
            } else if let provider = slot.provider {
                glyph(.style(for: provider), size: 11, tint: tint)
            } else {
                // A slot with words but no mark still holds its claim —
                // the lone dot is the resting grammar.
                Circle().fill(slot.textColor).frame(width: 5, height: 5)
            }
        }
        .opacity(1 - min(1, abs(pull) / 40))

        if model.tray != nil {
            mark
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX + pull, y: model.viewHeight - rect.midY)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(slot.text))
        } else {
            mark
                .padding(.vertical, 4)
                .fixedSize()
                .background(Capsule(style: .continuous).fill(.black))
                .frame(width: rect.width, height: rect.height,
                       alignment: side == .left ? .trailing : .leading)
                .position(x: rect.midX + pull, y: model.viewHeight - rect.midY)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(slot.text))
        }
    }

    /// The quota ear: a thin ring filling to `fraction` — the battery-glyph
    /// grammar every Mac user reads — with the provider's mark inside.
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
                glyph(.style(for: provider), size: 7, tint: tint)
            }
        }
        .frame(width: 16, height: 16)
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
