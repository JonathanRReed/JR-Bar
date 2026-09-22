import AppKit
import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// Opt-in timing evidence for the real offscreen Notch island layout path.
/// The window is constructed but never ordered, and its stores disable media,
/// power, camera, calendar, reminder, and notch runtime work.
@MainActor
@Suite("Notch layout profile")
struct NotchLayoutProfileTests {
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["JRBAR_NOTCH_LAYOUT_PROFILE"] == "1",
        "set JRBAR_NOTCH_LAYOUT_PROFILE=1 to write /tmp/jrbar-notch-layout-profile.json"
    ))
    func profileColdAndRepeatedExpandedCardLayout() throws {
        let fixtureStart = CFAbsoluteTimeGetCurrent()
        let fixture = Self.makeFixture()
        let fixtureConstructionMS = Self.elapsedMS(since: fixtureStart)

        let windowStart = CFAbsoluteTimeGetCurrent()
        let window = NotchIslandWindow(toy: fixture.toy)
        let windowConstructionMS = Self.elapsedMS(since: windowStart)
        defer { window.close() }

        let width: CGFloat = 380
        let firstStart = CFAbsoluteTimeGetCurrent()
        let firstHeight = window.expandedCardHeight(width: width)
        let firstMeasurementMS = Self.elapsedMS(since: firstStart)

        var repeatedHeights: [Double] = []
        var repeatedMeasurementMS: [Double] = []
        for _ in 0..<8 {
            let start = CFAbsoluteTimeGetCurrent()
            repeatedHeights.append(window.expandedCardHeight(width: width))
            repeatedMeasurementMS.append(Self.elapsedMS(since: start))
        }

        fixture.toy.cardModel.rows = [
            NotchIslandRow(id: "one", label: "Compile release", provider: "codex", activity: .working),
            NotchIslandRow(id: "two", label: "Review output", provider: "claude", activity: .waiting),
            NotchIslandRow(id: "three", label: "Repair tests", provider: "codex", activity: .done),
        ]
        let changedStart = CFAbsoluteTimeGetCurrent()
        let changedHeight = window.expandedCardHeight(width: width)
        let changedMeasurementMS = Self.elapsedMS(since: changedStart)
        let changedRepeatHeight = window.expandedCardHeight(width: width)

        #expect(firstHeight > 0)
        #expect(repeatedHeights.allSatisfy { $0 > 0 && abs($0 - firstHeight) < 0.5 })
        #expect(changedHeight > firstHeight)
        #expect(abs(changedRepeatHeight - changedHeight) < 0.5)

        // A fresh window after SwiftUI has initialized distinguishes process
        // startup cost from the cost of constructing each window's probe.
        let secondWindowStart = CFAbsoluteTimeGetCurrent()
        let secondWindow = NotchIslandWindow(toy: fixture.toy)
        let secondWindowConstructionMS = Self.elapsedMS(since: secondWindowStart)
        defer { secondWindow.close() }
        let secondMeasurementStart = CFAbsoluteTimeGetCurrent()
        let secondHeight = secondWindow.expandedCardHeight(width: width)
        let secondMeasurementMS = Self.elapsedMS(since: secondMeasurementStart)
        #expect(abs(secondHeight - changedHeight) < 0.5)

        let report: [String: Any] = [
            "configuration": "release",
            "width": width,
            "fixtureConstructionMS": fixtureConstructionMS,
            "windowConstructionMS": windowConstructionMS,
            "firstExpandedCardHeightMS": firstMeasurementMS,
            "firstHeight": firstHeight,
            "repeatedExpandedCardHeightMS": repeatedMeasurementMS,
            "repeatedHeights": repeatedHeights,
            "changedContentMeasurementMS": changedMeasurementMS,
            "changedContentHeight": changedHeight,
            "changedContentRepeatHeight": changedRepeatHeight,
            "secondWindowConstructionMS": secondWindowConstructionMS,
            "secondWindowFirstMeasurementMS": secondMeasurementMS,
            "secondWindowHeight": secondHeight,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys])
        let output = URL(fileURLWithPath: "/tmp/jrbar-notch-layout-profile.json")
        try data.write(to: output, options: .atomic)
        print("Notch layout profile: \(output.path)")

        withExtendedLifetime(fixture.store) {}
    }

    private static func makeFixture() -> (toy: NotchToy, store: ToysStore) {
        let core = CoreModel()
        var state = ToysState()
        state.notch = NotchSettings(
            enabled: true,
            provider: .jrbar,
            islandEnabled: true)
        let cardModel = makeTestCardModel()
        cardModel.pinned = true
        let store = ToysStore(
            core: core,
            settings: SettingsStore(core: core),
            state: state,
            cardModel: cardModel,
            notchRuntimeEnabled: false)
        return (store.notch, store)
    }

    private static func elapsedMS(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1_000
    }
}
