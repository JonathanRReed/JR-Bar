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

/// The wing chips. Each fills the rect the geometry measured for it —
/// fixed extents keep the hit region honest (the drawn capsule and the
/// tested rect are the same) and keep content churn from reframing the
/// window. Text truncates inside rather than growing the claim.
struct ScreenBarWingsView: View {
    @Bindable var model: ScreenBarWingsModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let left = model.left { chip(left.slot, rect: left.rect) }
            if let right = model.right { chip(right.slot, rect: right.rect) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private func chip(_ slot: ScreenBarWingSlot, rect: CGRect) -> some View {
        HStack(spacing: 5) {
            if let provider = slot.provider {
                ProviderTile(style: .style(for: provider), size: 13)
            }
            Text(slot.text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(slot.textColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .frame(width: rect.width, height: rect.height)
        .background(Capsule(style: .continuous).fill(.black.opacity(0.82)))
        // The rect is in the hosting view's bottom-left space; SwiftUI
        // positions from the top, so flip the midpoint.
        .position(x: rect.midX, y: model.viewHeight - rect.midY)
        .accessibilityElement(children: .combine)
    }
}
