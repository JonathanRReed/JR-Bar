import SwiftUI

public extension View {
    func jrbarSidebarSelection(_ selected: Bool) -> some View {
        self
            .foregroundStyle(selected ? JRBarTokens.Ink.onAccent : JRBarTokens.Ink.label)
            .jrbarType(.body)
            .frame(maxWidth: .infinity, minHeight: JRBarTokens.Space.xxxl, alignment: .leading)
            .padding(.horizontal, JRBarTokens.Space.sm)
            .background {
                RoundedRectangle(cornerRadius: JRBarTokens.Radius.control)
                    .fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
            }
            .tint(JRBarTokens.Ink.accent)
    }
}
