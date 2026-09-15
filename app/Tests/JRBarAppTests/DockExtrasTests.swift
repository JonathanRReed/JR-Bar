import AppKit
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// P2–P4's pure machinery: the folder listing (sort, hidden filter,
/// cap), the drop classifier, the tray/folder collections on
/// `DockModel`, the scroll-gesture interpreter, window cycling, and
/// the new separators. Panel chrome and AX reads stay behind seams.
@MainActor
@Suite struct DockExtrasTests {

    // MARK: Folder listing

    /// A real temp directory — the listing's sort and hidden-file
    /// filter against actual disk entries.
    private func tempFolder(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-dock-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            let url = dir.appendingPathComponent(name)
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent().appendingPathComponent(
                        String(name.dropLast())), withIntermediateDirectories: true)
            } else {
                try Data().write(to: url)
            }
        }
        return dir
    }

    @Test func folderListingSortsAndSkipsHidden() throws {
        let dir = try tempFolder(["b.txt", "A.txt", ".hidden", "zzz.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let entries = DockFolderListing.contents(of: dir)
        #expect(entries.map(\.name) == ["A.txt", "b.txt", "zzz.txt"],
                "display-name order, dotfile out")
        #expect(entries.allSatisfy { !$0.isDirectory })
    }

    @Test func folderListingCapsAtTheMax() {
        let base = URL(fileURLWithPath: "/tmp/fake")
        let urls = (0..<500).map { base.appendingPathComponent("f\($0).txt") }
        let entries = DockFolderListing.contents(
            of: base, lister: { _ in urls }, isDirectory: { _ in false })
        #expect(entries.count == DockFolderListing.maxEntries,
                "a runaway folder can't sprawl the popover")
    }

    @Test func anUnreadableFolderListsEmpty() {
        let entries = DockFolderListing.contents(
            of: URL(fileURLWithPath: "/nonexistent"),
            lister: { _ in nil }, isDirectory: { _ in false })
        #expect(entries.isEmpty, "a failed read is an empty stack, not a crash")
    }

    @Test func gridColumnsStayDeterministic() {
        #expect(DockFolderGridView.columnCount(for: 0) == 2)
        #expect(DockFolderGridView.columnCount(for: 3) == 3)
        #expect(DockFolderGridView.columnCount(for: 100) == DockFolderGridView.maxColumns)
    }

    // MARK: Drop classification

    @Test func dropsClassifyFoldersVersusFiles() {
        let plan = DockDropPlan.classify(
            urls: [URL(fileURLWithPath: "/tmp/dir"),
                   URL(fileURLWithPath: "/tmp/note.txt"),
                   URL(string: "https://example.com")!],
            isDirectory: { $0.lastPathComponent == "dir" })
        #expect(plan.folders == ["/tmp/dir"])
        #expect(plan.tray == ["/tmp/note.txt"],
                "a non-file URL never reaches the tray")
    }

    // MARK: Folders & tray on the model

    private func startedModel(_ settings: DockSettings) -> DockModel {
        let model = DockModel()
        model.settings = { settings }
        model.runningApplications = { [] }
        model.trashContents = { [] }
        model.start()
        return model
    }

    @Test func foldersAndTrayRideBetweenAppsAndTrash() {
        let model = startedModel(DockSettings(
            pinned: ["x.pin"], seededFromAppleDock: true,
            folders: ["/tmp/Folder"], tray: ["/tmp/note.txt"]))
        defer { model.stop() }
        model.pathExists = { _ in true }
        model.refresh()
        #expect(model.items.count == 4)
        #expect(model.items[0].bundleID == "x.pin" && model.items[0].section == .apps)
        #expect(model.items[1].isFolder && model.items[1].bundleURL?.path == "/tmp/Folder")
        #expect(model.items[2].isTrayItem)
        #expect(model.items[3].isTrash, "the Trash still rides last")
        #expect(DockView.separatorIndices(for: model.items) == [1, 3],
                "apps→files and files→Trash each draw a divider")
    }

    @Test func aMissingFolderKeepsItsPinButSkipsTheTile() {
        let model = startedModel(DockSettings(
            seededFromAppleDock: true, folders: ["/gone"]))
        defer { model.stop() }
        model.pathExists = { _ in false }
        model.refresh()
        #expect(model.items.allSatisfy { !$0.isFolder },
                "an ejected folder draws no tile…")
        #expect(model.folderPaths == ["/gone"], "…but keeps its pin")
    }

    @Test func folderEditsDedupeAndReport() {
        let model = startedModel(DockSettings(seededFromAppleDock: true))
        defer { model.stop() }
        var persisted: [[String]] = []
        model.onFoldersChanged = { persisted.append($0) }
        model.addFolder(path: "/tmp/Folder")
        model.addFolder(path: "/tmp/Folder")
        #expect(model.folderPaths == ["/tmp/Folder"], "a re-drop is a no-op")
        model.removeFolder(path: "/tmp/Folder")
        #expect(model.folderPaths.isEmpty)
        #expect(persisted == [["/tmp/Folder"], []])
    }

    @Test func trayEditsDedupeAndReport() {
        let model = startedModel(DockSettings(seededFromAppleDock: true))
        defer { model.stop() }
        var persisted: [[String]] = []
        model.onTrayChanged = { persisted.append($0) }
        model.addTrayItem(path: "/tmp/a.txt")
        model.addTrayItem(path: "/tmp/a.txt")
        model.addTrayItem(path: "/tmp/b.txt")
        #expect(model.trayPaths == ["/tmp/a.txt", "/tmp/b.txt"])
        model.removeTrayItem(path: "/tmp/a.txt")
        #expect(model.trayPaths == ["/tmp/b.txt"])
        #expect(persisted == [["/tmp/a.txt"], ["/tmp/a.txt", "/tmp/b.txt"], ["/tmp/b.txt"]])
    }

    @Test func aRowDropSplitsFoldersFromFiles() {
        let model = startedModel(DockSettings(seededFromAppleDock: true))
        defer { model.stop() }
        var folders: [[String]] = []
        var tray: [[String]] = []
        model.onFoldersChanged = { folders.append($0) }
        model.onTrayChanged = { tray.append($0) }
        model.directoryCheck = { $0.pathExtension == "app" || $0.hasDirectoryPath }
        model.acceptDrop(urls: [URL(fileURLWithPath: "/tmp/Stuff", isDirectory: true),
                                URL(fileURLWithPath: "/tmp/readme.txt")])
        #expect(model.folderPaths == ["/tmp/Stuff"])
        #expect(model.trayPaths == ["/tmp/readme.txt"])
        #expect(folders == [["/tmp/Stuff"]] && tray == [["/tmp/readme.txt"]],
                "each collection reports once per drop")
    }

    @Test func aFolderTileDropMovesFilesInside() {
        let model = startedModel(DockSettings(seededFromAppleDock: true))
        defer { model.stop() }
        var moves: [(String, String)] = []
        model.fileMover = { source, folder in
            moves.append((source.path, folder.path))
            return true
        }
        model.moveIntoFolder([URL(fileURLWithPath: "/tmp/a.txt"),
                              URL(fileURLWithPath: "/tmp/b.txt")],
                             folderPath: "/tmp/Folder")
        #expect(moves.count == 2)
        #expect(moves.allSatisfy { $0.1 == "/tmp/Folder" })
    }

    // MARK: Gestures

    @Test func theWheelStepsWindows() {
        var interpreter = DockScrollInterpreter()
        #expect(interpreter.noteWheel(deltaY: -10) == .cycleWindows(forward: true),
                "wheel down = next window")
        #expect(interpreter.noteWheel(deltaY: 10) == .cycleWindows(forward: false))
        #expect(interpreter.noteWheel(deltaY: 0) == nil)
    }

    @Test func anUpwardPanOpensPreviewsOnce() {
        var interpreter = DockScrollInterpreter()
        #expect(interpreter.notePan(dx: 0, dy: 60, began: true, ended: false) == nil)
        #expect(interpreter.notePan(dx: 0, dy: 80, began: false, ended: false)
                == .showPreviews, "past the threshold, previews fire")
        #expect(interpreter.notePan(dx: 0, dy: 40, began: false, ended: false) == nil,
                "…and only once per gesture")
    }

    @Test func aHorizontalPanCyclesPerStep() {
        var interpreter = DockScrollInterpreter()
        _ = interpreter.notePan(dx: 0, dy: 0, began: true, ended: false)
        #expect(interpreter.notePan(dx: -60, dy: 0, began: false, ended: false)
                == .cycleWindows(forward: true), "fingers left = next")
        #expect(interpreter.notePan(dx: 60, dy: 0, began: false, ended: false)
                == .cycleWindows(forward: false), "fingers right = previous")
    }

    @Test func aDownwardPanCyclesForward() {
        var interpreter = DockScrollInterpreter()
        _ = interpreter.notePan(dx: 0, dy: 0, began: true, ended: false)
        #expect(interpreter.notePan(dx: 0, dy: -40, began: false, ended: false)
                == .cycleWindows(forward: true))
    }

    @Test func aGestureEndResetsTheTravel() {
        var interpreter = DockScrollInterpreter()
        _ = interpreter.notePan(dx: 0, dy: 100, began: true, ended: false)
        #expect(interpreter.notePan(dx: 0, dy: 0, began: false, ended: true) == nil)
        // A new gesture starts from zero — the old travel can't leak in.
        #expect(interpreter.notePan(dx: 0, dy: 30, began: true, ended: false) == nil)
    }

    @Test func gestureHitTestingRespectsTheRadius() {
        let centers: [Double] = [28, 90, 152]
        #expect(DockGestureMath.itemIndex(at: 30, centers: centers, hitRadius: 34) == 0)
        #expect(DockGestureMath.itemIndex(at: 90, centers: centers, hitRadius: 34) == 1)
        #expect(DockGestureMath.itemIndex(at: 500, centers: centers, hitRadius: 34) == nil,
                "past the end is no tile, not the last tile")
        #expect(DockGestureMath.itemIndex(at: 30, centers: [], hitRadius: 34) == nil)
    }

    // MARK: Window cycling

    @Test func theCycleCursorWrapsBothWays() {
        #expect(DockModel.nextCycleIndex(current: nil, count: 3, forward: true) == 0)
        #expect(DockModel.nextCycleIndex(current: nil, count: 3, forward: false) == 2)
        #expect(DockModel.nextCycleIndex(current: 2, count: 3, forward: true) == 0)
        #expect(DockModel.nextCycleIndex(current: 0, count: 3, forward: false) == 2)
        #expect(DockModel.nextCycleIndex(current: 9, count: 3, forward: true) == 0,
                "a stale cursor restarts — a window closed mid-cycle")
        #expect(DockModel.nextCycleIndex(current: nil, count: 0, forward: true) == nil)
    }

    @Test func cyclingRaisesEachWindowInTurn() {
        let model = DockModel()
        let windows = (0..<3).map {
            DockPreviewWindow(id: $0, title: "w\($0)", minimized: false, element: nil)
        }
        model.windowProvider = { _ in windows }
        var raised: [String] = []
        model.windowCycler = { window, _ in raised.append(window.title) }
        let item = DockItem(bundleID: "com.example.App", name: "App", bundleURL: nil,
                            isRunning: true, isPinned: false,
                            processIdentifier: ProcessInfo.processInfo.processIdentifier)
        model.cycleWindows(item, forward: true)
        model.cycleWindows(item, forward: true)
        model.cycleWindows(item, forward: true)
        model.cycleWindows(item, forward: true)
        #expect(raised == ["w0", "w1", "w2", "w0"], "the ring wraps")
        raised = []
        model.cycleWindows(item, forward: false)
        #expect(raised == ["w2"], "backwards wraps the other way")
    }

    @Test func cyclingWithoutWindowsFallsBackToActivate() {
        let model = DockModel()
        model.windowProvider = { _ in [] }
        var activated = false
        model.activateApp = { _ in activated = true }
        var raised = 0
        model.windowCycler = { _, _ in raised += 1 }
        let item = DockItem(bundleID: "com.example.App", name: "App", bundleURL: nil,
                            isRunning: true, isPinned: false,
                            processIdentifier: ProcessInfo.processInfo.processIdentifier)
        model.cycleWindows(item, forward: true)
        #expect(activated, "no AX windows — activate is the honest answer")
        #expect(raised == 0)
    }

    @Test func cyclingAFolderIsANoOp() {
        let model = DockModel()
        var raised = 0
        model.windowCycler = { _, _ in raised += 1 }
        model.cycleWindows(.folder(path: "/tmp/x"), forward: true)
        #expect(raised == 0, "only app tiles cycle")
    }

    // MARK: Preview fill

    @Test func thePreviewGroupsAnAppsWindowsIntoOneRowSet() {
        let previewer = DockItemPreviewer()
        let windows = (0..<3).map {
            DockPreviewWindow(id: $0, title: "Doc \($0)", minimized: false, element: nil)
        }
        previewer.windows = { _ in windows }
        previewer.fill(item: DockItem(
            bundleID: "com.example.App", name: "App", bundleURL: nil,
            isRunning: true, isPinned: false,
            processIdentifier: ProcessInfo.processInfo.processIdentifier))
        #expect(previewer.content.windows.count == 3,
                "a multi-window app carries all its windows in one preview")
        #expect(previewer.content.appName == "App")
        #expect(previewer.content.isRunning)
    }

    // MARK: Widgets

    @Test func theBatteryPollReadsThroughTheSeam() {
        let widgets = DockWidgetModel()
        widgets.read = {
            AlcovePowerState(hasBattery: true, onAC: true, charging: true,
                             percent: 84, fullyCharged: false)
        }
        widgets.start()
        defer { widgets.stop() }
        #expect(widgets.power.percent == 84)
        #expect(widgets.power.charging)
    }

    @Test func theBatteryGlyphFollowsTheCharge() {
        func symbol(_ percent: Int?, battery: Bool = true) -> String {
            DockWidgetTile.batterySymbol(for: AlcovePowerState(
                hasBattery: battery, onAC: false, charging: false,
                percent: percent, fullyCharged: false))
        }
        #expect(symbol(5) == "battery.0percent")
        #expect(symbol(30) == "battery.25percent")
        #expect(symbol(50) == "battery.50percent")
        #expect(symbol(80) == "battery.75percent")
        #expect(symbol(100) == "battery.100percent")
        #expect(symbol(nil, battery: false) == "battery.0percent",
                "a desktop gets the empty mark, not an invented charge")
    }

    @Test func widgetsOnlyDrawWhenToggledOn() {
        let model = startedModel(DockSettings(
            seededFromAppleDock: true,
            widgets: DockWidgetSettings(clock: true, battery: false)))
        defer { model.stop() }
        #expect(model.items.contains { $0.widget == .clock })
        #expect(!model.items.contains { $0.widget == .battery })
        #expect(!model.widgetModel.running,
                "the battery poll only runs while its tile can draw")
    }

    // MARK: Settings

    @Test func collectionsRoundTrip() throws {
        var settings = DockSettings(folders: ["/tmp/a", "/tmp/a", "/tmp/b"],
                                    tray: ["/tmp/x.txt"],
                                    widgets: DockWidgetSettings(clock: true))
        settings.enabled = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DockSettings.self, from: data)
        #expect(decoded == settings)
        #expect(decoded.folders == ["/tmp/a", "/tmp/b"], "paths decode deduped")
        #expect(decoded.widgets.clock && !decoded.widgets.battery)
    }

    @Test func collectionsDecodeTolerantly() throws {
        let decoded = try JSONDecoder().decode(
            DockSettings.self,
            from: Data(#"{"folders": "many", "tray": 7, "widgets": {"clock": "yes"}}"#.utf8))
        #expect(decoded.folders.isEmpty && decoded.tray.isEmpty)
        #expect(decoded.widgets == DockWidgetSettings(),
                "mistyped widget keys fall back to off")
        #expect(DockSettings().folders.isEmpty && DockSettings().tray.isEmpty)
    }
}
