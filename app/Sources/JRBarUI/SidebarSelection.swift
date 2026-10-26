import SwiftUI

public extension View {
    func jrbarSidebarSelection(_ selected: Bool) -> some View {
        self
            .jrbarType(.body)
            .foregroundStyle(selected ? JRBarTokens.Ink.onAccent : JRBarTokens.Ink.label)
            .frame(maxWidth: .infinity, minHeight: JRBarTokens.Space.xxxl, alignment: .leading)
            .padding(.horizontal, JRBarTokens.Space.sm)
            .background(selected ? JRBarTokens.Ink.accent : .clear,
                        in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.control))
    }
}
