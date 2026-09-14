import AppKit
import SwiftUI

/// One wing slot's content: a capsule in the menu-bar area beside the
/// notch — the selected task and the attention count on the left, the
/// headline usage meter on the right. `provider` leads the chip with the
/// provider's bare glyph; `tone` is the state colour the words take.
struct ScreenBarWingSlot: Equatable {
    enum Tone: Equatable {
        /// White on the black capsule — ambient information.
        case neutral
        /// Waiting is amber everywhere in the app.
        case attention
        /// Failed is red.
        case alert
    }

    var text: String
    var provider: String?
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

/// The wing chips. The claimed rect keeps the hit region honest; the
/// drawn capsule hugs the notch side of that claim and sizes to its
/// content — an opaque black pill against the black notch is the
/// notch-extension look, where a claim-filling capsule or bare text in
/// open menu-bar space reads as clutter. Text truncates inside rather
/// than growing the claim.
struct ScreenBarWingsView: View {
    @Bindable var model: ScreenBarWingsModel

    /// How far the capsule's black runs under the bezel past the claim's
    /// notch edge — past the capsule's cap radius, so the silhouette
    /// meets the notch on a straight edge and the merge has no seam. The
    /// bezel covers this overlap; the content never enters it.
    private static let notchSeam: CGFloat = 12

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
            }
            Text(slot.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(slot.textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                // The capsule hugs content, so the bound has to live on
                // the text — without it a long label outgrows the claim
                // and the pill rides onto the notch.
                .frame(maxWidth: max(24, rect.width - (slot.provider == nil ? 18 : 32)))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3.5)
        // The capsule's notch-side padding runs `seam` under the bezel:
        // its rounded cap submerges, so the black meets the notch on a
        // straight edge instead of touching it at one tangent point.
        .padding(side == .left ? .trailing : .leading, seam)
        .fixedSize()
        .background(Capsule(style: .continuous).fill(.black))
        // The capsule hugs the notch side of the claim — a left chip
        // anchors to the claim's trailing edge, a right chip to its
        // leading edge — and the frame grows by the seam so the padded
        // capsule still lands its edge on the bezel.
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
