import SwiftUI

private struct AdaptiveSettingsRowsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    public var adaptiveSettingsRows: Bool {
        get { self[AdaptiveSettingsRowsKey.self] }
        set { self[AdaptiveSettingsRowsKey.self] = newValue }
    }
}

/// Keeps a control beside its explanation until the explanation needs more room.
public struct SettingsControlLayout: Layout {
    public init() {}

    private struct Measurement {
        let width: CGFloat
        let label: CGSize
        let control: CGSize
        let stacked: Bool

        var height: CGFloat {
            stacked ? label.height + JRBarTokens.Space.sm + control.height : max(label.height, control.height)
        }
    }

    private func measure(_ proposal: ProposedViewSize, subviews: Subviews) -> Measurement {
        let width = max(0, proposal.width ?? 600)
        let controlWidth = min(width, subviews[1].sizeThatFits(.unspecified).width)
        let remaining = width - controlWidth - JRBarTokens.Space.md
        let stacked = remaining < 180
        let labelWidth = stacked ? width : remaining
        let label = subviews[0].sizeThatFits(ProposedViewSize(width: labelWidth, height: nil))
        let control = subviews[1].sizeThatFits(ProposedViewSize(width: controlWidth, height: nil))
        return Measurement(width: width, label: label, control: control, stacked: stacked)
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let measured = measure(proposal, subviews: subviews)
        return CGSize(width: measured.width, height: measured.height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let measured = measure(ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        let labelY = measured.stacked ? bounds.minY : bounds.midY - measured.label.height / 2
        let controlX = measured.stacked ? bounds.minX : bounds.maxX - measured.control.width
        let controlY =
            measured.stacked
            ? bounds.minY + measured.label.height + JRBarTokens.Space.sm
            : bounds.midY - measured.control.height / 2
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: labelY), anchor: .topLeading,
            proposal: ProposedViewSize(measured.label))
        subviews[1].place(
            at: CGPoint(x: controlX, y: controlY), anchor: .topLeading,
            proposal: ProposedViewSize(measured.control))
    }
}
