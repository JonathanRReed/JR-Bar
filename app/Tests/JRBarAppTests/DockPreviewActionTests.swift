import ApplicationServices
import Testing
@testable import JRBarApp

@MainActor
@Suite struct DockPreviewActionTests {
    private func window(
        id: Int,
        title: String,
        minimized: Bool = false,
        element: AXUIElement? = nil
    ) -> DockPreviewWindow {
        DockPreviewWindow(
            id: id,
            title: title,
            minimized: minimized,
            fullScreen: false,
            frame: CGRect(x: 40, y: 60, width: 800, height: 600),
            thumbnail: nil,
            element: element)
    }

    @Test("callbacks retained across a retarget cannot act on the old app")
    func retargetRejectsEveryStaleWindowAction() {
        let content = DockPreviewContent()
        let actions = DockPreviewActions(content: content)
        let appA = window(id: 1, title: "App A")
        let appB = window(id: 2, title: "App B")
        content.windows = [appA]

        var calls: [String] = []
        actions.onPick = { _ in calls.append("pick") }
        actions.onClose = { _ in calls.append("close") }
        actions.onMinimize = { _ in calls.append("minimize") }
        actions.onFullScreen = { _ in calls.append("fullscreen") }
        actions.onShake = { _ in calls.append("shake") }
        actions.onTile = { _, _ in calls.append("tile") }
        actions.onSwipeMinimize = { _, _ in calls.append("swipe") }

        let retainedCallbacks: [() -> Void] = [
            { actions.performWindowAction(appA, actions.onPick) },
            { actions.performWindowAction(appA, actions.onClose) },
            { actions.performWindowAction(appA, actions.onMinimize) },
            { actions.performWindowAction(appA, actions.onFullScreen) },
            { actions.performWindowAction(appA, actions.onShake) },
            { actions.performWindowAction(appA, value: DockTile.leftHalf, actions.onTile) },
            { actions.performWindowAction(appA, value: true, actions.onSwipeMinimize) },
        ]

        content.windows = [appB]
        retainedCallbacks.forEach { $0() }

        #expect(calls.isEmpty)
        #expect(content.windows.map(\.id) == [appB.id])
    }

    @Test("a valid action receives the current row rather than its rendered snapshot")
    func validActionForwardsFreshWindowStateAndGenericValue() {
        let content = DockPreviewContent()
        let actions = DockPreviewActions(content: content)
        let snapshot = window(id: 7, title: "Old title", minimized: false)
        let current = window(id: 7, title: "Current title", minimized: true)
        content.windows = [current]

        var minimizedWindow: DockPreviewWindow?
        var tiledWindow: DockPreviewWindow?
        var receivedTile: DockTile?
        actions.onMinimize = { minimizedWindow = $0 }
        actions.onTile = { window, tile in
            tiledWindow = window
            receivedTile = tile
        }

        actions.performWindowAction(snapshot, actions.onMinimize)
        actions.performWindowAction(snapshot, value: DockTile.bottomRight, actions.onTile)

        #expect(minimizedWindow?.title == "Current title")
        #expect(minimizedWindow?.minimized == true)
        #expect(tiledWindow?.minimized == true)
        #expect(receivedTile == .bottomRight)
    }

    @Test("removed rows, inactive panels, and released content suppress actions")
    func unavailablePreviewSuppressesActions() {
        var callCount = 0

        do {
            let content = DockPreviewContent()
            let actions = DockPreviewActions(content: content)
            let row = window(id: 11, title: "Gone")
            actions.onPick = { _ in callCount += 1 }

            content.windows = []
            actions.performWindowAction(row, actions.onPick)

            content.windows = [row]
            actions.isActive = { false }
            actions.performWindowAction(row, actions.onPick)
        }

        var content: DockPreviewContent? = DockPreviewContent()
        let actions = DockPreviewActions(content: content!)
        let row = window(id: 12, title: "Released")
        content?.windows = [row]
        actions.onPick = { _ in callCount += 1 }
        weak var releasedContent = content
        content = nil

        #expect(releasedContent == nil)
        actions.performWindowAction(row, actions.onPick)
        #expect(callCount == 0)
    }

    @Test("an offscreen retained panel rejects even a current window action")
    func hiddenPanelRejectsCurrentRow() {
        let content = DockPreviewContent()
        let row = window(id: 20, title: "Current")
        content.windows = [row]
        let panel = DockPreviewPanel(content: content)
        var calls = 0
        panel.actions.onClose = { _ in calls += 1 }

        #expect(!panel.isVisible)
        panel.actions.performWindowAction(row, panel.actions.onClose)
        #expect(calls == 0)
    }

    @Test("native IDs disambiguate identical windows and reject conflicting identities")
    func captureIdentityWinsOverPresentation() {
        let frame = CGRect(x: 40, y: 60, width: 800, height: 600)
        let rows: [(frame: CGRect?, title: String)] = [(frame, "Untitled"), (frame, "Untitled")]
        #expect(DockEnhanceMath.matchRow(scFrame: frame, scTitle: "Untitled", rows: rows,
                    scWindowID: 42, rowWindowIDs: [41, 42]) == 1)
        #expect(DockEnhanceMath.matchRow(scFrame: frame, scTitle: "Untitled", rows: rows,
                    scWindowID: 99, rowWindowIDs: [41, 42]) == nil)
        #expect(DockEnhanceMath.matchRow(scFrame: frame, scTitle: "Untitled", rows: rows) == nil)
        #expect(DockEnhanceMath.matchRow(scFrame: frame, scTitle: "Untitled", rows: rows,
                    scWindowID: 42, rowWindowIDs: [41, nil]) == 1)
        #expect(DockEnhanceMath.matchRow(scFrame: frame, scTitle: "Untitled", rows: rows,
                    scWindowID: 42, rowWindowIDs: [42, 42]) == nil)
    }

    @Test("a unique title disambiguates overlapping frames")
    func uniqueTitleResolvesOverlap() {
        let frame = CGRect(x: 40, y: 60, width: 800, height: 600)
        let rows: [(frame: CGRect?, title: String)] = [(frame, "First"), (frame, "Second")]
        #expect(DockEnhanceMath.matchRow(scFrame: frame, scTitle: "Second", rows: rows) == 1)
        #expect(DockEnhanceMath.matchRow(scFrame: .zero, scTitle: "Second", rows: rows) == 1)
    }

    @Test("ambiguous switcher rows keep both AX windows without guessed images or duplicate cards")
    func switcherAmbiguityPreservesWindowActions() throws {
        let firstHandle = AXUIElementCreateApplication(930_001)
        let secondHandle = AXUIElementCreateApplication(930_002)
        let first = window(id: 1, title: "Untitled", element: firstHandle)
        let second = window(id: 2, title: "Untitled", element: secondHandle)
        let rows = [
            SwitcherWindowRow(pid: 900_001, windowID: 41, title: "Untitled", bounds: first.frame!),
            SwitcherWindowRow(pid: 900_001, windowID: 42, title: "Untitled", bounds: first.frame!),
        ]
        let fallback = DockSwitcherList.order(rows: rows, windowsForApp: { _ in [first, second] },
                                             appName: { _ in "Fixture" }, icon: { _ in nil })
        #expect(fallback.map(\.id) == ["a900001-1", "a900001-2"])
        #expect(fallback.allSatisfy { $0.windowID == nil })

        var identifiedFirst = first
        var identifiedSecond = second
        identifiedFirst.windowID = 42
        identifiedSecond.windowID = 41
        let matched = DockSwitcherList.order(rows: rows,
            windowsForApp: { _ in [identifiedFirst, identifiedSecond] },
            appName: { _ in "Fixture" }, icon: { _ in nil })
        #expect(matched.map(\.id) == ["w41", "w42"])
        #expect(matched.map(\.windowID) == [41, 42])
        let firstMatchedElement = try #require(matched[0].element)
        #expect(CFEqual(firstMatchedElement, secondHandle))
        let offscreen = DockSwitcherList.order(rows: [], offRows: rows,
            windowsForApp: { _ in [first, second] },
            appName: { _ in "Fixture" }, icon: { _ in nil })
        #expect(offscreen.map(\.id) == ["a900001-1", "a900001-2"])
        #expect(offscreen.allSatisfy { $0.windowID == nil })
    }

    @Test("AX identity keeps stacked windows but removes repeated handles")
    func windowIdentityDeduplication() {
        let firstHandle = AXUIElementCreateApplication(910_001)
        let secondHandle = AXUIElementCreateApplication(910_002)
        let equalFirstHandle = AXUIElementCreateApplication(910_001)

        let first = window(id: 1, title: "Untitled window", element: firstHandle)
        let second = window(id: 2, title: "Untitled window", element: secondHandle)
        let repeatedFirst = window(id: 3, title: "Duplicate", element: equalFirstHandle)
        let noHandleA = window(id: 4, title: "No handle")
        let noHandleB = window(id: 5, title: "No handle")

        let unique = AppleDockReader.uniqueWindowsByIdentity([
            first, second, repeatedFirst, noHandleA, noHandleB,
        ])

        #expect(unique.map(\.id) == [1, 2, 4, 5])
        #expect(CFEqual(firstHandle, equalFirstHandle))
        var nativeFirst = first
        var nativeDuplicate = second
        nativeFirst.windowID = 123
        nativeDuplicate.windowID = 123
        #expect(AppleDockReader.uniqueWindowsByIdentity([nativeFirst, nativeDuplicate]).map(\.id) == [1])
    }
}
