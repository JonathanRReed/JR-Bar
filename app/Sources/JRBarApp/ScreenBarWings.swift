import AppKit
import SwiftUI

/// One wing slot's content: a capsule in the menu-bar area beside the
/// notch — the selected task and the attention count on the left, the
/// headline usage meter on the right. `provider` leads the chip with the
/// provider's tile; `tone` is the state colour the words take.
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let left = model.left { chip(left.slot, rect: left.rect, side: .left) }
            if let right = model.right { chip(right.slot, rect: right.rect, side: .right) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private func chip(_ slot: ScreenBarWingSlot, rect: CGRect, side: ScreenBarWingSide) -> some View {
        HStack(spacing: 5) {
            if let provider = slot.provider {
                ProviderTile(style: .style(for: provider), size: 12)
            }
            Text(slot.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(slot.textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                // The capsule hugs content, so the bound has to live on
                // the text — without it a long label outgrows the claim
                // and the pill rides onto the notch.
                .frame(maxWidth: max(24, rect.width - (slot.provider == nil ? 18 : 36)))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3.5)
        .fixedSize()
        .background(Capsule(style: .continuous).fill(.black))
        // The capsule hugs the notch side of the claim: a left chip
        // anchors to the claim's trailing edge, a right chip to its
        // leading edge — the pill always touches the notch's flank.
        .frame(width: rect.width, height: rect.height,
               alignment: side == .left ? .trailing : .leading)
        // The rect is in the hosting view's bottom-left space; SwiftUI
        // positions from the top, so flip the midpoint.
        .position(x: rect.midX, y: model.viewHeight - rect.midY)
        .accessibilityElement(children: .combine)
    }
}
