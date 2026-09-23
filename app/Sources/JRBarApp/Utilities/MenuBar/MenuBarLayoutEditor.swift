import AppKit
import JRBarCore
import SwiftUI

/// The card's picture of the bar you are building — Ice's and
/// Bartender's layout editor: three rows, Shown, Hidden and Always, of
/// the items' own glyphs (the photographs the Item Bar wears; the app's
/// icon until one is taken). Drag a tile to another row, or use its menu,
/// and the pick lands through the same write the pickers make — per app
/// under the concealer, a cover where it sits under the spacer engine, on
/// the active profile when it already speaks for the app.
enum MenuBarLayoutEditor {
    /// One row: its section and the subjects standing in it, in bar
    /// order.
    struct Row: Equatable, Identifiable {
        var section: MenuBarItemSection
        var subjects: [MenuBarProfileSubject]
        var id: MenuBarItemSection { section }
    }

    /// The three rows, always all three — an empty row is still a place
    /// to drop. Pure so a test pins it.
    nonisolated static func rows(subjects: [MenuBarProfileSubject],
                                 section: (MenuBarProfileSubject) -> MenuBarItemSection) -> [Row] {
        MenuBarItemSection.allCases.map { target in
            Row(section: target, subjects: subjects.filter { section($0) == target })
        }
    }

    nonisolated static func title(_ section: MenuBarItemSection) -> String {
        switch section {
        case .shown: "Shown"
        case .hidden: "Hidden"
        case .alwaysHidden: "Always"
        }
    }

    /// The item ids among `dropped` that are tiles of this editor — a
    /// drop of stray text from another app moves nothing.
    nonisolated static func movableIDs(_ dropped: [String],
                                       subjects: [MenuBarProfileSubject]) -> [String] {
        let known = Set(subjects.map(\.item.id))
        var seen = Set<String>()
        return dropped.filter { known.contains($0) && seen.insert($0).inserted }
    }
}

/// The editor's view: a label column and three drop rows of tiles.
struct MenuBarLayoutEditorView: View {
    let utility: MenuBarUtility
    /// Where the plan put an item, for the tile's tooltip.
    let placement: (MenuBarItem) -> String
    @ViewState private var targeted: MenuBarItemSection?

    var body: some View {
        let subjects = utility.profileSubjects
        let rows = MenuBarLayoutEditor.rows(subjects: subjects) { utility.effectiveSection(for: $0.item) }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(MenuBarLayoutEditor.title(row.section))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .leading)
                    lane(row, subjects: subjects)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu bar layout")
    }

    private func lane(_ row: MenuBarLayoutEditor.Row, subjects: [MenuBarProfileSubject]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                if row.subjects.isEmpty {
                    Text("Drag here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                }
                ForEach(row.subjects) { subject in
                    tile(subject, in: row.section)
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 30)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(targeted == row.section ? 0.12 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(targeted == row.section ? 0.6 : 0), lineWidth: 1))
        .dropDestination(for: String.self) { dropped, _ in
            let ids = MenuBarLayoutEditor.movableIDs(dropped, subjects: subjects)
            for id in ids { utility.setSection(row.section, for: id) }
            return !ids.isEmpty
        } isTargeted: { inside in
            if inside { targeted = row.section } else if targeted == row.section { targeted = nil }
        }
    }

    private func tile(_ subject: MenuBarProfileSubject, in section: MenuBarItemSection) -> some View {
        let face = utility.glyphFace(for: subject.item)
        let width = face.map { MenuBarGlyphProcessing.tileWidth(pointWidth: $0.width * 20 / 22) } ?? 22
        return Group {
            if let face {
                Image(nsImage: face.image)
                    .renderingMode(face.template ? .template : .original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.primary)
                    .frame(width: width, height: 20)
            } else {
                Image(nsImage: subject.item.owner?.icon ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .frame(width: 22, height: 20)
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(0.06)))
        .contentShape(Rectangle())
        .draggable(subject.item.id) {
            Text(subject.title)
                .font(.callout)
                .padding(6)
        }
        .help("\(subject.title) — \(placement(subject.item)). Drag it to another row.")
        .contextMenu {
            ForEach(MenuBarItemSection.allCases.filter { $0 != section }, id: \.self) { target in
                Button("Move to \(MenuBarLayoutEditor.title(target))") {
                    utility.setSection(target, for: subject.item.id)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subject.title)
        .accessibilityValue(MenuBarLayoutEditor.title(section))
        .accessibilityActions {
            ForEach(MenuBarItemSection.allCases.filter { $0 != section }, id: \.self) { target in
                Button("Move to \(MenuBarLayoutEditor.title(target))") {
                    utility.setSection(target, for: subject.item.id)
                }
            }
        }
    }
}
