import AppKit
import SwiftUI

/// One wing slot's content: a lobe of the notch itself — the selected
/// task and the attention count on the left, the headline usage meter on
/// the right, or a transient device notice. `provider` leads with the
/// provider's bare glyph; `symbol` is a plain SF mark for notices with
/// no provider; `tone` is the state colour the words take.
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
}

/// The wing lobes. The claimed rect keeps the hit region honest; the
/// drawn ear hugs the notch side of that claim and sizes to its content
/// — the notch's own black shape continuing, flush with the screen's top
/// edge, where a centred capsule or bare text in open menu-bar space
/// reads as clutter. Text truncates inside rather than growing the
/// claim.
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

    /// The slot's words and mark. With a tray the chip is content only,
    /// centred in its claim — the ear's measured room beside the notch.
    /// Notch-less screens have no tray, so the chip keeps its own
    /// capsule hugging the band's end.
    @ViewBuilder
    private func chip(_ slot: ScreenBarWingSlot, rect: CGRect, side: ScreenBarWingSide) -> some View {
        let content = HStack(spacing: 5) {
            if let provider = slot.provider {
                glyph(.style(for: provider))
            } else if let symbol = slot.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(slot.textColor)
            }
            Text(slot.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(slot.textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                // The bound lives on the text — a long label truncates
                // inside its claim instead of riding past the shape.
                .frame(maxWidth: max(24, rect.width - (slot.provider == nil && slot.symbol == nil ? 20 : 36)))
        }
        .padding(.horizontal, 10)

        if model.tray != nil {
            content
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: model.viewHeight - rect.midY)
                .accessibilityElement(children: .combine)
        } else {
            content
                .padding(.vertical, 3.5)
                .fixedSize()
                .background(Capsule(style: .continuous).fill(.black))
                .frame(width: rect.width, height: rect.height,
                       alignment: side == .left ? .trailing : .leading)
                .position(x: rect.midX, y: model.viewHeight - rect.midY)
                .accessibilityElement(children: .combine)
        }
    }

    /// The provider's bare glyph in its accent — no badge: the boxed
    /// `ProviderTile` reads as a menu-bar icon where the references draw a
    /// plain mark against the notch extension.
    @ViewBuilder
    private func glyph(_ style: ProviderStyle) -> some View {
        switch style.glyph {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(style.accent)
        case .text(let text):
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(style.accent)
        }
    }
}
