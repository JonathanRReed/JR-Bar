import AppKit
import JRBarCore
import SwiftUI
import UniformTypeIdentifiers

/// The view's panel-side callbacks — a stable box so the owning
/// `DockPanel` can fill in "the folder tile was tapped, anchor the
/// popover to it" without the view knowing what a panel is.
final class DockViewActions {
    /// A folder tile's click — the panel toggles its grid popover.
    /// The fallback opens the folder in Finder, the honest answer
    /// when nothing anchors a popover. Always invoked on the main
    /// actor.
    var onFolderTap: @MainActor (DockItem) -> Void = { item in
        if let url = item.bundleURL {
            NSWorkspace.shared.open(url)
        }
    }

    init() {}
}

/// The bar's icon row (docs/TOY-PARITY.md, Replace P1–P4): app icons
/// via `DockIconResolver` (running-app icon → bundle icon → workspace
/// — rasterized at Retina density, never the generic white page), the
/// running dot under them, the badge when one's readable, spring
/// magnification driven by `DockMagnifier`, click to activate/launch,
/// the right-click menu, drag-reorder inside the pinned run. Past the
/// app run sits the file group — widget tiles, folder stacks that
/// open a grid popover, and the tray's parked files — then the Trash
/// rides at the end like Apple's.
///
/// The row runs along the dock axis — horizontal for `.bottom`,
/// vertical for `.left`/`.right` — inside a named coordinate space the
/// hover reports into, so the magnifier's pointer position and the
/// icon centres share one ruler. Dropping a file URL anywhere on the
/// row routes through `DockDropPlan`: directories pin as folder
/// stacks, files park in the tray.
struct DockView: View {
    let model: DockModel
    let magnifier: DockMagnifier
    let edge: DockEdge
    let settings: DockSettings
    var actions: DockViewActions = DockViewActions()

    /// Inter-icon gap — the magnifier and the panel's width math read
    /// the same constant.
    static let spacing: CGFloat = 6
    /// A separator's footprint along the dock axis — the panel's
    /// length math and the magnifier's centre map read the same value.
    static let separatorWidth: CGFloat = 8
    /// Pixel density the resolver rasterizes at — Retina is the floor,
    /// a 1× display just gets a better-resampled image.
    static let backingScale: CGFloat = 2

    private var horizontal: Bool { edge.isHorizontal }

    var body: some View {
        row
            .padding(DockPanel.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { syncMagnifier() }
            .onChange(of: model.items) { _, _ in syncMagnifier() }
            .onChange(of: settings.iconSize) { _, _ in syncMagnifier() }
    }

    private var row: some View {
        let separators = Self.separatorIndices(for: model.items)
        return layout {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                if separators.contains(index) {
                    separator
                }
                iconTile(item)
            }
        }
        .coordinateSpace(name: Self.axisSpace)
        .onContinuousHover(coordinateSpace: .named(Self.axisSpace)) { phase in
            switch phase {
            case .active(let point):
                magnifier.notePointer(horizontal ? point.x : point.y)
            case .ended:
                magnifier.notePointer(nil)
            }
        }
        // Files dropped anywhere on the bar: folders pin a stack,
        // files park in the tray. Tile-level drops (pin reorder,
        // folder targets) claim their own first.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !providers.isEmpty else { return false }
            DockDropSupport.loadURLs(providers) { urls in
                Task { @MainActor in model.acceptDrop(urls: urls) }
            }
            return true
        }
    }

    private func layout<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Group {
            if horizontal {
                HStack(spacing: Self.spacing) { content() }
            } else {
                VStack(spacing: Self.spacing) { content() }
            }
        }
    }

    /// The hairline between groups — before the first running-only
    /// tile after the pinned run, and before the Trash.
    private var separator: some View {
        Group {
            if horizontal {
                Capsule()
                    .fill(.primary.opacity(0.3))
                    .frame(width: 1.5, height: settings.iconSize * 0.62)
                    .frame(width: Self.separatorWidth)
            } else {
                Capsule()
                    .fill(.primary.opacity(0.3))
                    .frame(width: settings.iconSize * 0.62, height: 1.5)
                    .frame(height: Self.separatorWidth)
            }
        }
    }

    /// Row indices a separator precedes — wherever the section
    /// changes (apps → files → Trash) plus the pinned → running-only
    /// boundary inside the app run. Pure so the panel's length math
    /// and the tests agree with what the row draws.
    static func separatorIndices(for items: [DockItem]) -> Set<Int> {
        var out = Set<Int>()
        for index in items.indices.dropFirst() {
            let previous = items[index - 1]
            let item = items[index]
            let sectionBoundary = item.section != previous.section
            let pinBoundary = item.section == .apps
                && previous.section == .apps
                && !item.isPinned && previous.isPinned
            if sectionBoundary || pinBoundary {
                out.insert(index)
            }
        }
        return out
    }

    private static let axisSpace = "jrbar-dock-axis"

    private func syncMagnifier() {
        magnifier.itemIDs = model.items.map(\.id)
        magnifier.iconSize = settings.iconSize
        magnifier.spacing = Self.spacing
        var extra: [String: Double] = [:]
        for index in Self.separatorIndices(for: model.items) {
            // A separator costs its width plus the gap around it, and
            // the icon centres shift by that much — the wave has to
            // know or it lifts the wrong icons past a divider.
            extra[model.items[index].id] = Self.separatorWidth + Self.spacing
        }
        magnifier.extraBefore = extra
    }

    // MARK: A tile

    private func iconTile(_ item: DockItem) -> some View {
        if let kind = item.widget {
            return AnyView(widgetTile(item, kind: kind))
        }
        if item.isFolder {
            return AnyView(fileTile(item, isFolder: true))
        }
        if item.isTrayItem {
            return AnyView(fileTile(item, isFolder: false))
        }
        return AnyView(appTile(item))
    }

    /// A widget tile — fixed size, own content, no running mark.
    /// `scaleEffect` carries the magnification wave so the tile still
    /// rides it like every other.
    private func widgetTile(_ item: DockItem, kind: DockWidgetKind) -> some View {
        let scale = magnifier.scales[item.id] ?? 1
        let base = settings.iconSize
        return DockWidgetTile(kind: kind, widgetModel: model.widgetModel, size: base)
            .scaleEffect(scale)
            .frame(width: base * scale, height: base * scale)
            .help(item.name)
    }

    /// A folder-stack or tray tile: the file's icon, magnified like
    /// the apps; folder clicks toggle the grid popover, tray clicks
    /// open the file. Both drag out the real file URL; a folder tile
    /// is also a drop target (drop moves files inside).
    private func fileTile(_ item: DockItem, isFolder: Bool) -> some View {
        let scale = magnifier.scales[item.id] ?? 1
        let base = settings.iconSize
        let renderSize = base * (settings.magnification.enabled ? settings.magnification.scale : 1)
        let path = item.bundleURL?.path ?? ""
        return Button {
            isFolder ? actions.onFolderTap(item) : model.activate(item)
        } label: {
            Image(nsImage: DockIconResolver.icon(
                for: item, pointSize: renderSize, scale: Self.backingScale))
                .resizable()
                .interpolation(.high)
                .frame(width: base * scale, height: base * scale)
        }
        .buttonStyle(DockIconButtonStyle())
        .help(item.name)
        .contextMenu { fileMenu(for: item, isFolder: isFolder, path: path) }
        .draggableWhenTrayItem(item: item)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // Only folder tiles take drops — files land in the folder.
            guard isFolder, !path.isEmpty, !providers.isEmpty else { return false }
            DockDropSupport.loadURLs(providers) { urls in
                Task { @MainActor in model.moveIntoFolder(urls, folderPath: path) }
            }
            return true
        }
    }

    /// The file group's menus: a folder gets Open / Reveal / unpin;
    /// a tray item gets Open / Reveal / forget. Neither touches the
    /// file itself — remove means "off the bar", never "delete".
    @ViewBuilder
    private func fileMenu(for item: DockItem, isFolder: Bool, path: String) -> some View {
        Button("Open") { model.activate(item) }
        Button("Reveal in Finder") { model.reveal(item) }
        Divider()
        if isFolder {
            Button("Remove from Dock") { model.removeFolder(path: path) }
        } else {
            Button("Remove from Tray") { model.removeTrayItem(path: path) }
        }
    }

    private func appTile(_ item: DockItem) -> some View {
        let scale = magnifier.scales[item.id] ?? 1
        let base = settings.iconSize
        // Rasterize at the largest the wave can grow the icon so a
        // magnified tile is sharp too — downscaling is free, a
        // magnified upscale is the blur screenshots showed.
        let renderSize = base * (settings.magnification.enabled ? settings.magnification.scale : 1)
        let icon = ZStack(alignment: .topTrailing) {
            Image(nsImage: DockIconResolver.icon(
                for: item, pointSize: renderSize, scale: Self.backingScale))
                .resizable()
                .interpolation(.high)
                .frame(width: base * scale, height: base * scale)
                .opacity(item.isHidden ? 0.55 : 1)
            if let badge = item.badge, !badge.isEmpty {
                Text(badge)
                    .font(.system(size: max(9, base * 0.28), weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.red, in: Capsule())
                    .offset(x: 4, y: -4)
            }
        }
        // The indicator lives on the cross axis — under the icon for a
        // bottom bar, on the screen-interior side for a left/right
        // dock (trailing on `.left`, leading on `.right`, the way
        // Apple's side docks mark running apps). Sizing the tile along
        // the dock axis only keeps the rendered row matching the
        // panel's length math.
        let tile = Group {
            if horizontal {
                VStack(spacing: 0) { icon; indicator(for: item) }
                    .frame(width: base * scale)
            } else {
                HStack(spacing: 0) {
                    if edge == .right { indicator(for: item) }
                    icon
                    if edge == .left { indicator(for: item) }
                }
                .frame(height: base * scale)
            }
        }

        return AnyView(
            Button { model.activate(item) } label: { tile }
                .buttonStyle(DockIconButtonStyle())
                .help(item.name)
                .contextMenu { menu(for: item) }
                .onDrop(of: [.text], delegate: DockPinDropDelegate(
                    targetIsPinned: item.isPinned, targetID: item.bundleID,
                    movePin: { dragged, before in model.movePin(dragged, before: before) }))
                .draggableOnPin(item: item)
        )
    }

    /// The running mark: `dot` is Apple's pellet, `card` a small
    /// capsule, `none` keeps the slot reserved so a launch doesn't
    /// shift the row. The reserved slot sits on the cross axis —
    /// height for a bottom bar, width for a side dock — so it never
    /// inflates the row's length.
    @ViewBuilder
    private func indicator(for item: DockItem) -> some View {
        let room = DockPanel.indicatorRoom
        let shown = item.isRunning && settings.runningIndicator != .none
        if horizontal {
            mark(for: item, shown: shown)
                .frame(height: room)
        } else {
            mark(for: item, shown: shown)
                .frame(width: room)
        }
    }

    @ViewBuilder
    private func mark(for item: DockItem, shown: Bool) -> some View {
        if !shown {
            Color.clear
        } else {
            switch settings.runningIndicator {
            case .dot:
                Circle()
                    .fill(Color.primary.opacity(0.8))
                    .frame(width: 4.5, height: 4.5)
            case .card:
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: horizontal ? 14 : 4, height: horizontal ? 4 : 14)
            case .none:
                Color.clear
            }
        }
    }

    // MARK: Menu

    /// The right-click set — the P1 basics for apps; the Trash gets
    /// its own pair (open, empty).
    @ViewBuilder
    private func menu(for item: DockItem) -> some View {
        if item.isTrash {
            Button("Open Trash") { model.openTrash() }
            Button("Empty Trash…") { model.emptyTrash() }
                .disabled(item.trashIsEmpty)
        } else {
            Button(item.isRunning ? "Bring \(item.name) to Front" : "Open \(item.name)") {
                model.activate(item)
            }
            if item.isRunning {
                Button(item.isHidden ? "Unhide" : "Hide") {
                    item.isHidden ? model.unhide(item) : model.hide(item)
                }
            }
            Divider()
            Button(item.isPinned ? "Remove from Dock" : "Keep in Dock") {
                model.togglePin(item)
            }
            if item.isRunning || item.bundleID == DockModel.finderBundleID {
                Divider()
                if item.bundleID == DockModel.finderBundleID {
                    Button("Relaunch") { model.forceQuit(item) }
                } else if item.isRunning {
                    Button("Quit") { model.quit(item) }
                    Button("Force Quit") { model.forceQuit(item) }
                }
            }
        }
    }
}

/// The tile's click feel — a soft press-in, the way Apple's dock icon
/// darkens under the mouse. Only the scale; the magnifier owns size.
private struct DockIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
    /// Tray items drag out the real file URL — the shelf's "drag out"
    /// hands the file to whatever accepts it (it stays parked; the
    /// menu's Remove forgets the park). Folder tiles deliberately
    /// don't drag: a dropped-on-Finder file URL is a *move*, and a
    /// pinned folder must never relocate itself.
    @ViewBuilder
    func draggableWhenTrayItem(item: DockItem) -> some View {
        if item.isTrayItem, let url = item.bundleURL {
            self.onDrag { NSItemProvider(object: url as NSURL) }
        } else {
            self
        }
    }

    /// Pins are drag sources for reorder; running-only tiles and the
    /// Trash are not.
    @ViewBuilder
    func draggableOnPin(item: DockItem) -> some View {
        if item.isPinned {
            self.onDrag { NSItemProvider(object: item.bundleID as NSString) }
        } else {
            self
        }
    }
}

/// Reorder inside the pinned run: a drop onto a pinned tile moves the
/// dragged pin to the target's slot (`DockModel.movePin`). Drops on
/// running-only tiles validate but move nothing — the pinned run is
/// the only reorderable range.
struct DockPinDropDelegate: DropDelegate {
    let targetIsPinned: Bool
    let targetID: String
    /// `DockModel.movePin(_:before:)` — a MainActor hop keeps the
    /// delegate itself Sendable.
    let movePin: @MainActor (String, String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        targetIsPinned && info.hasItemsConforming(to: [.text])
    }

    func performDrop(info: DropInfo) -> Bool {
        guard targetIsPinned,
              let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let dragged = object as? String else { return }
            Task { @MainActor in
                movePin(dragged, targetID)
            }
        }
        return true
    }
}
