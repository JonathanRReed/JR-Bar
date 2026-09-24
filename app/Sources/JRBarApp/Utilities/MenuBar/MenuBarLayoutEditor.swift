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

    /// The row's mark beside its name.
    nonisolated static func symbol(_ section: MenuBarItemSection) -> String {
        switch section {
        case .shown: "eye"
        case .hidden: "eye.slash"
        case .alwaysHidden: "lock"
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

/// The editor's view: three labelled drop lanes of tiles.
struct MenuBarLayoutEditorView: View {
    /// What the editor reads and writes — the utility's own, or a
    /// fixture's in a render proof.
    @MainActor
    struct Source {
        var subjects: () -> [MenuBarProfileSubject]
        var section: (MenuBarItem) -> MenuBarItemSection
        var setSection: (MenuBarItemSection, String) -> Void
        var face: (MenuBarItem) -> MenuBarGlyphCache.Face?
        /// Whether show for updates watches the item — nil while that
        /// feature is off, and the tile's menu leaves the row out.
        var watchesUpdates: (MenuBarItem) -> Bool?
        var setWatchesUpdates: (Bool, MenuBarItem) -> Void

        init(subjects: @escaping () -> [MenuBarProfileSubject],
             section: @escaping (MenuBarItem) -> MenuBarItemSection,
             setSection: @escaping (MenuBarItemSection, String) -> Void,
             face: @escaping (MenuBarItem) -> MenuBarGlyphCache.Face?,
             watchesUpdates: @escaping (MenuBarItem) -> Bool? = { _ in nil },
             setWatchesUpdates: @escaping (Bool, MenuBarItem) -> Void = { _, _ in }) {
            self.subjects = subjects
            self.section = section
            self.setSection = setSection
            self.face = face
            self.watchesUpdates = watchesUpdates
            self.setWatchesUpdates = setWatchesUpdates
        }

        init(utility: MenuBarUtility) {
            self.init(subjects: { utility.profileSubjects },
                      section: { utility.effectiveSection(for: $0) },
                      setSection: { utility.setSection($0, for: $1) },
                      face: { utility.glyphFace(for: $0) },
                      watchesUpdates: { item in
                          utility.settings().showForUpdates ? utility.watchesUpdates(of: item) : nil
                      },
                      setWatchesUpdates: { utility.setWatchesUpdates($0, for: $1) })
        }
    }

    let source: Source
    /// Where the plan put an item, for the tile's tooltip.
    let placement: (MenuBarItem) -> String
    @ViewState private var targeted: MenuBarItemSection?

    init(utility: MenuBarUtility, placement: @escaping (MenuBarItem) -> String) {
        self.init(source: Source(utility: utility), placement: placement)
    }

    init(source: Source, placement: @escaping (MenuBarItem) -> String) {
        self.source = source
        self.placement = placement
    }

    /// A lane's height — a tile and its breathing room.
    static let laneHeight: CGFloat = 34

    var body: some View {
        let subjects = source.subjects()
        let rows = MenuBarLayoutEditor.rows(subjects: subjects) { source.section($0.item) }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    label(row)
                    lane(row, subjects: subjects)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu bar layout")
    }

    private func label(_ row: MenuBarLayoutEditor.Row) -> some View {
        HStack(spacing: 5) {
            Image(systemName: MenuBarLayoutEditor.symbol(row.section))
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 13)
            Text(MenuBarLayoutEditor.title(row.section))
                .font(.system(size: 11.5, weight: .medium))
            Spacer(minLength: 0)
            Text("\(row.subjects.count)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .frame(width: 76)
    }

    private func lane(_ row: MenuBarLayoutEditor.Row, subjects: [MenuBarProfileSubject]) -> some View {
        let isTarget = targeted == row.section
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ScrollView(.horizontal) {
            HStack(spacing: 4) {
                if row.subjects.isEmpty {
                    Text("Drag items here")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                }
                ForEach(row.subjects) { subject in
                    tile(subject, in: row.section)
                }
            }
            .padding(.horizontal, 5)
            .frame(height: Self.laneHeight)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(isTarget ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
        .overlay {
            if row.subjects.isEmpty && !isTarget {
                shape.strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            } else {
                shape.strokeBorder(isTarget ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.07),
                                   lineWidth: 1)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isTarget)
        .dropDestination(for: String.self) { dropped, _ in
            let ids = MenuBarLayoutEditor.movableIDs(dropped, subjects: subjects)
            for id in ids { source.setSection(row.section, id) }
            return !ids.isEmpty
        } isTargeted: { inside in
            if inside { targeted = row.section } else if targeted == row.section { targeted = nil }
        }
    }

    private func tile(_ subject: MenuBarProfileSubject, in section: MenuBarItemSection) -> some View {
        let face = source.face(subject.item)
        let width = face.map { MenuBarGlyphProcessing.tileWidth(pointWidth: $0.width * 18 / 22) } ?? 22
        return Group {
            if let face {
                Image(nsImage: face.image)
                    .renderingMode(face.template ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.primary)
                    .frame(width: width, height: 18)
            } else {
                MenuBarAppFace(item: subject.item, size: 18)
                    .frame(width: 22, height: 18)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        .opacity(section == .shown ? 1 : 0.85)
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
                    source.setSection(target, subject.item.id)
                }
            }
            if let watched = source.watchesUpdates(subject.item) {
                Divider()
                Toggle("Show When It Changes", isOn: Binding(
                    get: { watched },
                    set: { source.setWatchesUpdates($0, subject.item) }))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subject.title)
        .accessibilityValue(MenuBarLayoutEditor.title(section))
        .accessibilityActions {
            ForEach(MenuBarItemSection.allCases.filter { $0 != section }, id: \.self) { target in
                Button("Move to \(MenuBarLayoutEditor.title(target))") {
                    source.setSection(target, subject.item.id)
                }
            }
        }
    }
}
