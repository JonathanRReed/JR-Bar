import AppKit
import CoreGraphics
import JRBarCore
import SwiftUI

/// What the "Your bar" card shows under the divider engine: the apps by
/// where they sit, left of the icon, right of it, or covered. Position is
/// the setting, so this is a read-out of the bar, not a list to edit.
struct MenuBarPositionContent: Equatable {
    /// One tile: an app (or a helper without a bundle) once, however many
    /// items it has on that side.
    struct Entry: Equatable, Identifiable {
        var id: String
        var item: MenuBarItem
        var name: String
    }

    var hidden: [Entry] = []
    var shown: [Entry] = []
    var always: [Entry] = []
    /// Hidden items macOS parked that the bar could not draw if revealed.
    var parked = 0

    /// Build it from the engine's plan. Apple's own items, our own, and
    /// the native overflow control are not apps the person arranges.
    nonisolated static func make(plan: MenuBarHidePlan, rows: [CGRect]) -> MenuBarPositionContent {
        func entries(_ items: [MenuBarItem]) -> [Entry] {
            var seen = Set<String>()
            var out: [Entry] = []
            for item in items.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
                guard !item.isNativeOverflowControl, !MenuBarItemLister.isProtected(item),
                      MenuBarUtility.isForeignOwner(item.ownerName),
                      !MenuBarUtility.isOwnFamily(item.bundleID) else { continue }
                let key = item.bundleID ?? item.id
                guard seen.insert(key).inserted else { continue }
                out.append(Entry(id: key, item: item, name: item.ownerName))
            }
            return out
        }
        return MenuBarPositionContent(
            hidden: entries(plan.hidden), shown: entries(plan.shown), always: entries(plan.alwaysHidden),
            parked: MenuBarUtility.parkedRemainder(plan: plan, rows: rows).count)
    }

    var isEmpty: Bool { hidden.isEmpty && shown.isEmpty && always.isEmpty }
}

/// The diagram: the bar as the person sees it — Hidden on the left, the
/// JR-Bar icon as the divider, Shown on the right — drawn from the live
/// listing. Tiles are read-only: JR-Bar never moves another app's item.
struct MenuBarPositionDiagram: View {
    let content: MenuBarPositionContent
    /// Called when a tile's menu asks to move it: the answer is the
    /// ⌘-drag note, never a move.
    var onAsk: (MenuBarPositionContent.Entry, MenuBarItemSection) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                lane(content.hidden, caption: MenuBarPositionCopy.hiddenCaption,
                     hint: MenuBarPositionCopy.hiddenHint, symbol: "eye.slash", leading: true)
                divider
                lane(content.shown, caption: MenuBarPositionCopy.shownCaption,
                     hint: MenuBarPositionCopy.shownHint, symbol: "eye", leading: false)
            }
            .frame(minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            if !content.always.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "lock").font(.system(size: 10, weight: .semibold))
                    Text("Always hidden")
                        .font(.system(size: 11.5, weight: .medium))
                    ForEach(content.always) { entry in tile(entry, dimmed: true) }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu bar: \(content.hidden.count) hidden left of the icon, \(content.shown.count) shown right of it")
    }

    private var divider: some View {
        VStack(spacing: 3) {
            ZStack {
                Capsule().fill(Color.accentColor.opacity(0.18))
                Image(nsImage: StatusItemController.glyph())
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color.accentColor)
                    .padding(5)
            }
            .frame(width: 34, height: 34)
            Text("JR-Bar")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The JR-Bar icon, the divider")
    }

    private func lane(_ entries: [MenuBarPositionContent.Entry], caption: String, hint: String,
                      symbol: String, leading: Bool) -> some View {
        VStack(alignment: leading ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
                Text(caption).font(.system(size: 11, weight: .semibold))
                Text("\(entries.count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            if entries.isEmpty {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(leading ? .trailing : .leading)
            } else {
                let columns = [GridItem(.adaptive(minimum: 26, maximum: 30), spacing: 3)]
                LazyVGrid(columns: columns, alignment: leading ? .trailing : .leading, spacing: 3) {
                    ForEach(entries) { entry in tile(entry, dimmed: leading) }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: leading ? .trailing : .leading)
    }

    private func tile(_ entry: MenuBarPositionContent.Entry, dimmed: Bool) -> some View {
        MenuBarAppFace(item: entry.item, size: 20)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07)))
            .opacity(dimmed ? 0.8 : 1)
            .help(entry.name)
            .contextMenu {
                Button("How to hide \(entry.name)") { onAsk(entry, .hidden) }
                Button("How to keep \(entry.name) shown") { onAsk(entry, .shown) }
                Button("Always hidden (cover where it sits)") { onAsk(entry, .alwaysHidden) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.name)
    }
}

/// The apps the old saved list hid, offered as suggestions. The divider
/// never hides one on the list's say-so: each is shown unless the person
/// has already dragged it left of the icon, and this says which still are.
struct MenuBarSuggestionsContent: Equatable {
    enum State: Equatable, Sendable {
        /// The app has an item right of the icon.
        case shown
        /// The app has no item on the bar right now.
        case absent
    }

    struct Row: Equatable, Identifiable {
        var id: String
        var name: String
        var state: State
    }

    var rows: [Row]

    var lead: String { MenuBarPositionCopy.suggestionsLead(count: rows.count) }

    /// Apps already left of the icon are done and drop out. Shown first
    /// (the work to do), then the ones not on the bar, each by name.
    nonisolated static func make(suggestions: [String], plan: MenuBarHidePlan,
                                 name: (String) -> String) -> MenuBarSuggestionsContent {
        let shownApps = Set(plan.shown.compactMap(\.bundleID))
        let hiddenApps = Set((plan.hidden + plan.alwaysHidden).compactMap(\.bundleID))
        let rows: [Row] = suggestions.compactMap { app in
            if shownApps.contains(app) { return Row(id: app, name: name(app), state: .shown) }
            if hiddenApps.contains(app) { return nil }
            return Row(id: app, name: name(app), state: .absent)
        }.sorted { lhs, rhs in
            if lhs.state != rhs.state { return lhs.state == .shown }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return MenuBarSuggestionsContent(rows: rows)
    }
}

/// The one-line hint a new divider shows, with a way to close it.
struct MenuBarDividerHint: View {
    var onDismiss: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.draw")
                .foregroundStyle(Color.accentColor)
            Text(MenuBarPositionCopy.hint)
                .font(.callout)
            Spacer(minLength: 0)
            Button("Got it") { onDismiss() }
                .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.accentColor.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

/// The suggestions list: the apps the old list hid, with where each sits.
/// Acting on one is a ⌘-drag only the person can make; the row can only
/// be taken off the list.
struct MenuBarSuggestionsPanel: View {
    let content: MenuBarSuggestionsContent
    var onForget: (String) -> Void = { _ in }
    /// The most rows drawn before the rest fold into a count.
    static let visibleRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(content.lead)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(content.rows.prefix(Self.visibleRows)) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.state == .shown ? "arrow.left.circle" : "questionmark.circle")
                        .foregroundStyle(row.state == .shown ? Color.orange : Color.secondary)
                        .frame(width: 14)
                    Text(MenuBarPositionCopy.suggestionLine(name: row.name, state: row.state))
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                    Button("Not now") { onForget(row.id) }
                        .controlSize(.small)
                        .help("Stop suggesting \(row.name). It stays where it is.")
                }
            }
            if content.rows.count > Self.visibleRows {
                Text("and \(content.rows.count - Self.visibleRows) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.05)))
    }
}

/// The lines under "What JR-Bar sees": what the app believes about the bar
/// right now, in plain facts, so a bar that looks wrong can be told apart
/// from one JR-Bar misreads.
struct MenuBarDividerReadoutView: View {
    let readout: MenuBarDividerReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(readout.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("What JR-Bar sees. " + readout.lines.joined(separator: " "))
    }
}
