import AppKit
@testable import JRBarCore
import JRBarTestSupport
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Notch hover cost", .temporaryDirectory, .serialized)
@MainActor
struct NotchHoverCostTests {
    @Test func hoverAndOffscreenCard() throws {
        let core = CoreModel()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let providers = ["claude", "codex", "gemini"].map { id in
            CoreProviderUsage(id: id, windows: [
                CoreUsageWindow(name: "5h", usedPct: 70, resetsAt: now.timeIntervalSince1970 + 14400),
            ], forecast: CoreUsageForecast(exhaustsAt: now.timeIntervalSince1970 + 7200,
                                          pace: "ahead", ratePctPerHour: 15))
        }
        core.handle(.connected)
        core.apply(.state(CoreState(sessions: [
            CoreSession(id: "claude:sample", provider: "claude", label: "Sample task", mode: "working"),
            CoreSession(id: "codex:sample", provider: "codex", label: "Sample check", mode: "working"),
        ], usage: CoreUsage(providers: providers))))
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let power = AlcovePowerState(hasBattery: true, onAC: true, charging: false,
                                     percent: 100, fullyCharged: true)
        let tray = ShelfTrayModel(defaults: ScratchDefaults.open(ScratchDefaults.suiteName("hover-cost")))
        let model = NotchCardModel(timers: ShelfTimerModel.scratch(), tray: tray,
                                  utility: ShelfUtilityModel(power: power), runtimeEnabled: false)
        let owner = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: model, notchRuntimeEnabled: false)
        let toy = owner.notch!
        toy.islandVisible = true
        toy.reduceMotion = { true }
        toy.menuBarHidden = { false }
        toy.pointerLocation = { CGPoint(x: -20000, y: -20000) }
        let timers = ManualTimers()
        toy.hoverTimer = { timers.arm($0, $1) }
        let window = NotchIslandWindow(toy: toy)
        toy.island = window
        defer {
            toy.island = nil
            window.contentView = nil
            window.close()
            withExtendedLifetime(owner) {}
        }
        var durations: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<6 {
            let start = clock.now
            toy.setHovered(true)
            timers.advance(by: 0.2)
            #expect(toy.islandExpanded && model.pinned)
            #expect(model.meters.count == 3)
            let width = toy.expandedCardWidth
            let height = window.expandedCardHeight(width: width)
            #expect(height > 100)
            let host = try #require(window.contentView)
            host.frame.size = CGSize(width: width, height: toy.cardTopPad + height)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0)
            let pixels = try #require(bitmap.bitmapData)
            let bytes = UnsafeBufferPointer(start: pixels, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            #expect(bytes.contains { $0 != 0 })
            durations.append(milliseconds(start.duration(to: clock.now)))
            toy.setHovered(false)
            timers.advance(by: 1)
            #expect(!toy.islandExpanded && !model.pinned)
            #expect(timers.live == 0)
        }
        let meters = UsageCenterStore.notchMeters(core: core, now: now)
        var captionDurations: [Double] = []
        let profile = ProcessInfo.processInfo.environment["JRBAR_NOTCH_HOVER_PROFILE"] == "1"
        let captionRepeats = profile ? 2000 : 100
        for _ in 0..<5 {
            let start = clock.now
            var characters = 0
            for _ in 0..<captionRepeats {
                for meter in meters {
                    let caption = NotchMeterCaption(meter: meter, now: now)
                    characters += caption.forms.joined().count
                }
            }
            #expect(characters > 0)
            captionDurations.append(milliseconds(start.duration(to: clock.now)))
        }
        print("HOVER_COST openAndRenderMS=\(durations) captions\(captionRepeats * meters.count)MS=\(captionDurations)")
        #expect(durations.dropFirst().allSatisfy { $0 < 1000 })
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
