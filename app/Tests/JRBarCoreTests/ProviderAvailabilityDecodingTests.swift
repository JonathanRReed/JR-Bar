import Foundation
import Testing
@testable import JRBarCore

@Suite("Provider availability decoding")
struct ProviderAvailabilityDecodingTests {
    private func decode(_ json: String) throws -> CoreProviderUsage {
        try JSONDecoder().decode(CoreProviderUsage.self, from: Data(json.utf8))
    }

    @Test func availabilityAndStatusStayVisibleWithoutWindows() throws {
        let row = try decode(#"{"id":"antigravity","windows":[],"state":"unavailable","availability":"source_idle","status_text":"Quota service is not running","last_good_age_seconds":7200,"panel_visible":true,"action":"Open Antigravity to refresh","action_kind":"open_app"}"#)
        #expect(row.availability == "source_idle")
        #expect(row.statusText == "Quota service is not running")
        #expect(row.lastGoodAgeSeconds == 7200)
        #expect(row.actionKind == "open_app")
        #expect(row.action == "Open Antigravity to refresh")
        #expect(row.panelVisible)
        #expect(!row.foldsIntoQuietPanelRow)
    }

    @Test func explicitHiddenAndRemovedRowsDecode() throws {
        let hidden = try decode(#"{"id":"grok","panel_visible":false,"availability":"not_found","status_text":"Not found on this Mac","action":"Hide","action_kind":"hide"}"#)
        #expect(!hidden.panelVisible)
        #expect(hidden.actionKind == "hide")
        #expect(!hidden.foldsIntoQuietPanelRow)
        #expect(hidden.canSetPanelVisibility)
    }

    @Test func absentProviderHasNoPanelVisibilityControl() throws {
        let absent = try decode(#"{"id":"grok","panel_visible":false,"availability":"absent"}"#)
        #expect(!absent.panelVisible)
        #expect(!absent.canSetPanelVisibility)
    }

    @Test func resetWindowCannotShowItsHistoricalPercentAsCurrent() throws {
        let row = try decode(#"{"id":"claude","status_text":"Quota window reset since the last reading","windows":[{"id":"five_hour","name":"5-hour","used_pct":95,"elapsed":true,"last_used_pct":95}]}"#)
        let window = try #require(row.windows.first)
        #expect(window.elapsed)
        #expect(window.usedPct == nil)
        #expect(window.lastUsedPct == 95)
        #expect(window.isUnknown)
        #expect(!row.foldsIntoQuietPanelRow)
    }

    @Test func olderDaemonKeepsExistingDefaults() throws {
        let row = try decode(#"{"id":"claude","windows":[{"name":"Weekly","used_pct":25}]}"#)
        #expect(row.availability == nil)
        #expect(row.statusText == nil)
        #expect(row.lastGoodAgeSeconds == nil)
        #expect(row.actionKind == nil)
        #expect(row.panelVisible)
        #expect(row.canSetPanelVisibility)
        let window = try #require(row.windows.first)
        #expect(!window.elapsed)
        #expect(window.lastUsedPct == nil)
        #expect(window.usedPct == 25)
    }

    @Test func malformedAdditionsDoNotDropAnOlderRow() throws {
        let row = try decode(#"{"id":"claude","panel_visible":"bad","availability":9,"status_text":false,"action_kind":42,"windows":[{"name":"Weekly","used_pct":25,"elapsed":"bad"}]}"#)
        #expect(row.panelVisible)
        #expect(row.statusText == nil)
        #expect(row.actionKind == nil)
        #expect(row.windows.first?.usedPct == 25)
    }
}
