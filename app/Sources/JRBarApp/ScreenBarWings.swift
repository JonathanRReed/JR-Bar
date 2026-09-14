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

/// What the wings view draws: each side's slot and the capsule rect the
/// geometry claimed for it, in view coordinates (origin bottom-left, as
/// `ScreenBarGeometry.wingSlotRect` returns them — the view flips y for
/// SwiftUI's top-left space).
@MainActor
@Observable
final class ScreenBarWingsModel {
    var left: (slot: ScreenBarWingSlot, rect: CGRect)?
    var right: (slot: ScreenBarWingSlot, rect: CGRect)?
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

    /// How far the lobe's black runs under the bezel past the claim's
    /// notch edge — the bezel covers the overlap, so the merge has no
    /// seam. The content never enters it.
    private static let notchSeam: CGFloat = 12
    /// The notch's own bottom corner radius, matched so the ear reads as
    /// the bezel continuing, not a pill docked to it.
    private static let notchCorner: CGFloat = 10

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let left = model.left { chip(left.slot, rect: left.rect, side: .left) }
            if let right = model.right { chip(right.slot, rect: right.rect, side: .right) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private func chip(_ slot: ScreenBarWingSlot, rect: CGRect, side: ScreenBarWingSide) -> some View {
        let seam = Self.notchSeam
        return HStack(spacing: 5) {
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
                // The lobe hugs content, so the bound has to live on the
                // text — without it a long label outgrows the claim and
                // the black rides into menu-bar space it was not given.
                .frame(maxWidth: max(24, rect.width - (slot.provider == nil && slot.symbol == nil ? 20 : 36)))
        }
        .padding(.horizontal, 10)
        // The lobe's notch-side padding runs `seam` under the bezel so
        // the merge has no seam; the content never enters it.
        .padding(side == .left ? .trailing : .leading, seam)
        .fixedSize()
        // The ear is the notch's own depth, centred on the claim — the
        // lobe's top and bottom edges are the bezel's, flush with the
        // screen's top edge.
        .frame(height: rect.height)
        .background(lobe(side).fill(.black))
        // The lobe anchors to the claim's notch-side edge — a left chip
        // to its trailing edge, a right chip to its leading — and the
        // frame grows by the seam so the padded lobe still lands its
        // submerged edge under the bezel.
        .frame(width: rect.width + seam, height: rect.height,
               alignment: side == .left ? .trailing : .leading)
        // The rect is in the hosting view's bottom-left space; SwiftUI
        // positions from the top, so flip the midpoint — and shift the
        // widened frame half a seam toward the notch so the claim keeps
        // its outer edge.
        .position(x: rect.midX + (side == .left ? seam / 2 : -seam / 2),
                  y: model.viewHeight - rect.midY)
        .accessibilityElement(children: .combine)
    }

    /// The notch's ear: a shape that shares the bezel's top and bottom
    /// edges — square corners on the flush sides, and the outer bottom
    /// corner rounded like the notch's own. The submerged notch-side
    /// edge needs no radius; the bezel covers it.
    private func lobe(_ side: ScreenBarWingSide) -> UnevenRoundedRectangle {
        let corner = Self.notchCorner
        switch side {
        case .left:
            return UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: corner,
                                          bottomTrailingRadius: 0, topTrailingRadius: 0,
                                          style: .continuous)
        case .right:
            return UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                          bottomTrailingRadius: corner, topTrailingRadius: 0,
                                          style: .continuous)
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
