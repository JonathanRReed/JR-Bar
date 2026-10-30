import CoreGraphics
import JRBarCore
import JRBarUI
import Testing
@testable import JRBarApp

@Suite struct DockPreviewMetricsTests {
    @Test func defaultsUseTheMediumSizeTable() {
        #expect(DockPreviewMetrics.standard == DockPreviewSize.medium.metrics)
    }

    @Test func geometryComesFromTheSizeTable() {
        for size in DockPreviewSize.allCases {
            let metrics = size.metrics
            #expect(metrics.panelInset == size.outerPadding)
            #expect(metrics.cardPad == size.innerPadding)
            #expect(metrics.sectionSpacing == size.spacing)
            #expect(metrics.cardSpacing == size.rowSpacing)
            #expect(metrics.headerIcon == size.headerIcon)
            #expect(metrics.plateRadius == DockChrome.stillRadius + size.innerPadding)
            #expect(metrics.panelRadius == metrics.plateRadius + size.outerPadding)
            #expect(metrics.cardPad >= JRBarTokens.Space.xs)
            #expect(metrics.verbDisc >= 20)
        }
    }

    @MainActor @Test func switcherSpacingDoesNotChangeWidgetGeometry() {
        var saved = DockEnhanceSettings()
        let preferences = DockEnhancePreferences()
        preferences.read = { saved }
        preferences.write = { saved = $0 }
        for size in DockPreviewSize.allCases {
            preferences.previewSize = size
            let expected = saved.previewSize.metrics
            for spacing in [0.5, 0.6, 1, 1.4, 1.6] {
                saved.previewSpacing = spacing
                #expect(saved.previewSize.metrics == expected)
            }
        }
    }
}
