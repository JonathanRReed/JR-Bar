import JRBarUI
import SwiftUI

struct ToysPage: View {
    let store: SettingsStore
    var body: some View {
        VStack(alignment: .leading, spacing: JRBarTokens.Space.sm) {
            Text("Toys").jrbarType(.section)
            if let toys = store.toys {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: JRBarTokens.Space.md) {
                    ForEach(toys.toys, id: \.id) { toy in
                        SettingsToyTile(store: store, toy: toy)
                    }
                }
            }
        }
        .id(SettingsStore.groupAnchor("Toys"))
    }
}

private struct SettingsToyTile: View {
    let store: SettingsStore
    let toy: any Toy

    var body: some View {
        VStack(spacing: 0) {
            Button { store.openFeature(toy.id) } label: {
                SettingsToyArtwork(id: toy.id, symbol: toy.symbol)
                    .frame(height: 88)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Open \(toy.name) settings")
            HStack {
                Button(toy.name) { store.openFeature(toy.id) }
                    .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                Toggle(toy.switchLabel, isOn: Binding(get: { toy.isOn }, set: { toy.isOn = $0 }))
                    .labelsHidden().toggleStyle(.switch)
            }
            .padding(JRBarTokens.Space.md)
        }
        .background(JRBarTokens.Ink.group, in: RoundedRectangle(cornerRadius: JRBarTokens.Radius.group))
        .overlay(RoundedRectangle(cornerRadius: JRBarTokens.Radius.group).strokeBorder(JRBarTokens.Ink.groupEdge))
    }
}

private struct SettingsToyArtwork: View {
    let id: String
    let symbol: String

    var body: some View {
        Canvas { context, size in draw(in: context, size: size) }
        .background(JRBarTokens.Ink.accentSoft)
        .overlay {
            if id == "notch-buddy" {
                BuddyRosterFigure(character: .cat, pacing: false)
                    .frame(width: 18, height: 18).scaleEffect(2)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        let colors: [Color] = [.blue, .orange, .green, .pink, .purple]
        if id == "confetti" {
            for i in 0..<26 {
                let x = CGFloat((i * 37 + 11) % 100) / 100 * size.width
                let y = CGFloat((i * 23 + 7) % 70)
                let rect = CGRect(x: x, y: y, width: 5, height: 9)
                context.fill(Path(rect), with: .color(colors[i % colors.count]))
            }
        } else if id == "aquarium" {
            for i in 0..<3 {
                let x = size.width * (0.25 + Double(i) * 0.22)
                let y = 18 + CGFloat(i % 2) * 30
                let body = CGRect(x: x, y: y, width: 30, height: 16)
                context.fill(Path(ellipseIn: body), with: .color(colors[i]))
                var tail = Path()
                tail.move(to: CGPoint(x: x + 25, y: y + 8))
                tail.addLine(to: CGPoint(x: x + 39, y: y))
                tail.addLine(to: CGPoint(x: x + 39, y: y + 16))
                tail.closeSubpath()
                context.fill(tail, with: .color(colors[i]))
            }
        } else if id == "fold" {
            let rect = CGRect(x: size.width / 2 - 48, y: 12, width: 96, height: 64)
            context.fill(Path(roundedRect: rect, cornerRadius: JRBarTokens.Radius.control), with: .color(.white))
            var crease = Path()
            crease.move(to: CGPoint(x: rect.maxX - 28, y: rect.maxY))
            crease.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 28))
            crease.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            crease.closeSubpath()
            context.fill(crease, with: .color(.gray.opacity(0.3)))
        } else if id != "notch-buddy" {
            context.draw(Text(Image(systemName: symbol)).font(JRBarTokens.TypeStyle.title.font),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
        }
    }
}
