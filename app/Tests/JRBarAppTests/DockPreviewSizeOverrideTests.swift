import AppKit
import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("Dock widget size overrides", .serialized)
struct DockPreviewSizeOverrideTests {
    @Test func contextMenuAndSettingsUseTheSamePersistedOverrides() throws {
        var saved = DockEnhanceSettings()
        let preferences = DockEnhancePreferences()
        preferences.read = { saved }
        preferences.write = { saved = $0 }
        let controller = DockEnhanceController(preferences: preferences)
        controller.preview.bundleID = "test.synthetic.mail"
        controller.preview.mailState = .loading
        let panel = controller.ensurePanel()
        defer { panel.close() }
        #expect(saved.previewSize == .medium)
        #expect(saved.previewSizeOverrides.isEmpty)
        for size in DockPreviewSize.allCases {
            // This is the callback used by every context-menu size item.
            panel.actions.onPreviewSize?(size)
            #expect(saved.previewSizeOverrides["test.synthetic.mail"] == size)
            #expect(controller.preview.previewSize == size)
            #expect(panel.fittingSize().width == size.widgetSize.width)
            #expect(panel.fittingSize().height <= size.widgetSize.height)
            let restored = try JSONDecoder().decode(DockEnhanceSettings.self, from: JSONEncoder().encode(saved))
            #expect(restored.previewSize(for: "test.synthetic.mail") == size)
            #expect(restored.previewSize(for: "test.synthetic.other") == .medium)
        }
        // A Settings override reaches an already-created card through the same resolution.
        preferences.setPreviewSize(.small, for: "test.synthetic.mail")
        controller.syncPreviewSize()
        #expect(controller.preview.previewSize == .small)
        preferences.previewSize = .large
        controller.syncPreviewSize()
        #expect(controller.preview.previewSize == .small)
        panel.actions.onPreviewSize?(nil)
        #expect(saved.previewSizeOverrides["test.synthetic.mail"] == nil)
        #expect(controller.preview.previewSize == .large)
        #expect(saved.previewSize == .large)
    }

    @Test func mediaDefaultKeepsAppOverridesIndependent() {
        var settings = DockEnhanceSettings(previewSize: .medium)
        settings.previewSizeOverrides[DockEnhanceSettings.otherMediaSizeKey] = .small
        settings.previewSizeOverrides["test.synthetic.player"] = .large
        #expect(settings.previewSize(for: "test.synthetic.player", isMedia: true) == .large)
        #expect(settings.previewSize(for: "test.synthetic.other", isMedia: true) == .small)
        #expect(settings.previewSize(for: "test.synthetic.other") == .medium)
    }
    @Test func resizingKeepsTheDockEdgeAndDoesNotDrift() {
        let original = CGRect(x: 400, y: 500, width: 452, height: 220)
        for edge in [DockEdge.bottom, .left, .right] {
            let small = DockPreviewPanel.resizedFrame(original, size: DockPreviewSize.small.widgetSize, edge: edge)
            let large = DockPreviewPanel.resizedFrame(small, size: DockPreviewSize.large.widgetSize, edge: edge)
            let restored = DockPreviewPanel.resizedFrame(large, size: original.size, edge: edge)
            #expect(restored == original)
            switch edge {
            case .bottom: #expect(large.minY == original.minY && large.midX == original.midX)
            case .left: #expect(large.minX == original.minX && large.midY == original.midY)
            case .right: #expect(large.maxX == original.maxX && large.midY == original.midY)
            }
        }
    }
}
