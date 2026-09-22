import AppKit
import Foundation
import Testing
@testable import JRBarApp

/// Opt-in timing evidence for the Dock preview's real AppKit/SwiftUI layout path.
/// The panels are never ordered on screen, and synthetic windows carry no AX
/// handles or thumbnails, so this performs no scanning, capture, or actions.
@Suite("Dock layout profile")
@MainActor
struct DockLayoutProfileTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_DOCK_LAYOUT_PROFILE"] == "1",
                   "set JRBAR_DOCK_LAYOUT_PROFILE=1 to write /tmp/jrbar-dock-layout-profile.json"))
    func profileColdAndRepeatedFittingSize() throws {
        var scenarios: [[String: Any]] = []
        for count in [1, 6] {
            let content = Self.content(windowCount: count)

            let constructionStart = CFAbsoluteTimeGetCurrent()
            let panel = DockPreviewPanel(content: content)
            let constructionMS = Self.elapsedMS(since: constructionStart)

            let firstStart = CFAbsoluteTimeGetCurrent()
            let firstSize = panel.fittingSize()
            let firstMS = Self.elapsedMS(since: firstStart)

            var repeatedMS: [Double] = []
            var repeatedSizes: [[String: Double]] = []
            for _ in 0..<8 {
                let start = CFAbsoluteTimeGetCurrent()
                let size = panel.fittingSize()
                repeatedMS.append(Self.elapsedMS(since: start))
                repeatedSizes.append(Self.sizeJSON(size))
            }

            scenarios.append([
                "windowCount": count,
                "constructionMS": constructionMS,
                "firstFittingMS": firstMS,
                "firstSize": Self.sizeJSON(firstSize),
                "repeatedFittingMS": repeatedMS,
                "repeatedSizes": repeatedSizes,
            ])
            panel.close()
        }

        let report: [String: Any] = [
            "configuration": "release",
            "scenarios": scenarios,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let output = URL(fileURLWithPath: "/tmp/jrbar-dock-layout-profile.json")
        try data.write(to: output, options: .atomic)
        print("Dock layout profile: \(output.path)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_DOCK_LAYOUT_PROFILE"] == "1",
                   "set JRBAR_DOCK_LAYOUT_PROFILE=1 to write /tmp/jrbar-dock-empty-prewarm-profile.json"))
    func profileEmptyRetainedPanelPrewarm() throws {
        let retainedContent = DockPreviewContent()

        let emptyConstructionStart = CFAbsoluteTimeGetCurrent()
        let retainedPanel = DockPreviewPanel(content: retainedContent)
        let emptyConstructionMS = Self.elapsedMS(since: emptyConstructionStart)

        let emptyFitStart = CFAbsoluteTimeGetCurrent()
        let emptySize = retainedPanel.fittingSize()
        let emptyFittingMS = Self.elapsedMS(since: emptyFitStart)

        Self.populate(retainedContent, windowCount: 1)
        let populatedFitStart = CFAbsoluteTimeGetCurrent()
        let populatedSize = retainedPanel.fittingSize()
        let populatedFittingMS = Self.elapsedMS(since: populatedFitStart)

        let freshContent = Self.content(windowCount: 1)
        let freshConstructionStart = CFAbsoluteTimeGetCurrent()
        let freshPanel = DockPreviewPanel(content: freshContent)
        let freshConstructionMS = Self.elapsedMS(since: freshConstructionStart)

        let freshFitStart = CFAbsoluteTimeGetCurrent()
        let freshSize = freshPanel.fittingSize()
        let freshFittingMS = Self.elapsedMS(since: freshFitStart)

        let report: [String: Any] = [
            "configuration": "release",
            "emptyRetainedPanel": [
                "constructionMS": emptyConstructionMS,
                "firstFittingMS": emptyFittingMS,
                "size": Self.sizeJSON(emptySize),
            ],
            "retainedPanelAfterOneWindow": [
                "firstFittingMS": populatedFittingMS,
                "size": Self.sizeJSON(populatedSize),
            ],
            "freshOneWindowPanel": [
                "constructionMS": freshConstructionMS,
                "firstFittingMS": freshFittingMS,
                "size": Self.sizeJSON(freshSize),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let output = URL(fileURLWithPath: "/tmp/jrbar-dock-empty-prewarm-profile.json")
        try data.write(to: output, options: .atomic)
        print("Dock empty prewarm profile: \(output.path)")

        retainedPanel.close()
        freshPanel.close()
    }

    private static func content(windowCount: Int) -> DockPreviewContent {
        let content = DockPreviewContent()
        populate(content, windowCount: windowCount)
        return content
    }

    private static func populate(_ content: DockPreviewContent, windowCount: Int) {
        content.appName = "Synthetic App"
        content.bundleID = "com.example.synthetic"
        content.isRunning = true
        content.windows = (0..<windowCount).map { index in
            DockPreviewWindow(
                id: index,
                title: "Synthetic Window \(index + 1)",
                minimized: index.isMultiple(of: 3),
                fullScreen: false,
                frame: CGRect(x: index * 20, y: index * 15, width: 900, height: 600),
                thumbnail: nil,
                element: nil)
        }
    }

    private static func elapsedMS(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1_000
    }

    private static func sizeJSON(_ size: CGSize) -> [String: Double] {
        ["width": size.width, "height": size.height]
    }
}
