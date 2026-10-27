import SwiftUI

public struct ActionButton<Label: View>: View {
    private let action: () -> Void
    private let label: Label
    private let prominent: Bool

    public init(prominent: Bool = false, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
        self.prominent = prominent
    }

    public var body: some View {
        Group {
            if prominent {
                Button(action: action) { label }.buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { label }.buttonStyle(.bordered)
            }
        }.controlSize(.small)
    }
}

public extension ActionButton where Label == Text {
    init(_ title: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.init(prominent: prominent, action: action) { Text(title) }
    }
}
