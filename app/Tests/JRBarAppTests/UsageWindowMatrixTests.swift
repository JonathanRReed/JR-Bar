import AppKit
import JRBarCore
import JRBarTestSupport
import JRBarUI
import QuartzCore
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Usage window placement matrix", .serialized, .renderProofAppearance)
@MainActor
struct UsageWindowMatrixTests {
    struct Matrix: Decodable {
        var now: Double
        var cases: [Entry]
    }
    struct Entry: Decodable {
        var name: String
        var provider: CoreProviderUsage
        var placements: [String: UsageWindowPlacement]
    }

    static func fixture() throws -> Matrix {
        let url = try #require(Bundle.module.url(forResource: "usage-window-matrix", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Matrix.self, from: Data(contentsOf: url))
    }

    @Test func everyParserWindowLandsAndRenders() async throws {
        let matrix = try Self.fixture()
        for entry in matrix.cases {
            let provider = entry.provider
            for window in provider.windows {
                #expect(window.placement == entry.placements[window.id], "\(entry.name): \(window.id)")
            }
            let names = UsageOverviewTable.windowNames(providers: [provider], now: matrix.now, connected: true)
            #expect(provider.windows.allSatisfy { names.contains($0.overviewColumn) })
            let panel = PanelCompositionTests.store(usage: [provider])
            panel.now = Date(timeIntervalSince1970: matrix.now)
            let row = PanelProviderSection(store: panel, composition: PanelComposition(store: panel)).gauge(provider)
            for width: CGFloat in [320, 372] {
                let rendered = await evidence(row.frame(width: width))
                let measured = provider.windows.filter { $0.usedPct != nil }
                for window in measured {
                    #expect(rendered[window.id]?.percentUsed == window.usedPct, "\(entry.name): \(window.id) at \(width)")
                }
                if !measured.isEmpty { #expect(!rendered.isEmpty, "\(entry.name) must not show only dashes") }
                let host = NSHostingView(rootView: row.frame(width: width).fixedSize(horizontal: false, vertical: true))
                #expect(host.fittingSize.width == width)
                #expect(host.fittingSize.height <= PanelComposition.usageHeight(provider), "\(entry.name): \(host.fittingSize.height)")
            }
            let overview = UsageGaugeRow(provider: provider, name: provider.id, now: matrix.now,
                style: .compact, windowNames: names)
            let overviewReadings = await evidence(overview.frame(width: 180 + CGFloat(names.count) * 100))
            for window in provider.windows where window.usedPct != nil {
                #expect(overviewReadings[window.id]?.percentUsed == window.usedPct)
            }
            let headline = provider.headlineWindow
            #expect(UsageCenterStore.primaryWindow(of: provider) == headline)
            let meter = StatusItemController.previewMeter(for: provider, document: nil, now: matrix.now)
            #expect(meter.fraction == headline?.usedPct.map { $0 / 100 })
            let lines = StatusMenuLines.usage([provider], live: true, now: matrix.now)
            if let headline {
                #expect(lines.count == 1)
                #expect(lines[0].contains(headline.placementLabel))
                #expect(lines[0].contains(headline.percentText))
            } else { #expect(lines.isEmpty) }
        }
    }

    @Test func resetCountdownDoesNotImplyDurationAndUnknownStaysUnknown() {
        let credits = CoreUsageWindow(key: "credits", name: "Credits", usedPct: 28, resetsAt: 18_000)
        #expect(credits.placement == .labelled)
        for name in ["15-hour", "17-day", "Unclassified", "Session"] {
            #expect(CoreUsageWindow(name: name, usedPct: 10).placement == .labelled)
        }
        let unknown = CoreUsageWindow(key: "daily", name: "Daily", usedPct: nil)
        let provider = CoreProviderUsage(id: "devin", windows: [unknown], state: "ready")
        #expect(unknown.placement == .labelled)
        #expect(UsageGaugeReading(window: unknown, provider: provider, now: 0).percentUsed == nil)
        #expect(UsageWindowLabel.column("Standard 5-hour") == "Standard 5h")
        #expect(UsageWindowLabel.column("Core 7-day") == "Core 7d")
        #expect(UsageWindowLabel.column("Standard Monthly") == "Standard Monthly")
        #expect(UsageWindowLabel.column("Included plan") == "Included plan")
    }

    private func evidence<V: View>(_ view: V) async -> [String: UsageGaugeReading] {
        var readings: [String: UsageGaugeReading] = [:]
        let root = view.onPreferenceChange(UsageGaugeEvidence.self) { readings = $0 }
            .environment(\.renderSnapshot, true)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 1000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        return readings
    }
}
