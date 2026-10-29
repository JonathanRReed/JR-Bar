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
        var panel_cells: [String: UsageGaugeCellState]
    }

    static func fixture() throws -> Matrix {
        let url = try #require(Bundle.module.url(forResource: "usage-window-matrix", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Matrix.self, from: Data(contentsOf: url))
    }

    @Test func everyParserWindowLandsAndRenders() async throws {
        let matrix = try Self.fixture()
        let overviewNames = UsageOverviewTable.windowNames(providers: matrix.cases.map(\.provider),
            now: matrix.now, connected: true)
        let panel = PanelCompositionTests.store(usage: matrix.cases.map(\.provider))
        panel.now = Date(timeIntervalSince1970: matrix.now)
        for entry in matrix.cases {
            let provider = entry.provider
            for window in provider.windows {
                #expect(window.placement == entry.placements[window.id], "\(entry.name): \(window.id)")
            }
            let names = UsageOverviewTable.windowNames(providers: [provider], now: matrix.now, connected: true)
            #expect(provider.windows.allSatisfy { names.contains($0.overviewColumn) })
            let row = PanelProviderSection(store: panel, composition: PanelComposition(store: panel)).gauge(provider)
            for width: CGFloat in [320, 372] {
                let rendered = await evidence(row.frame(width: width))
                let measured = provider.windows.filter { $0.usedPct != nil }
                for window in measured {
                    #expect(rendered.readings[window.id]?.percentUsed == window.usedPct, "\(entry.name): \(window.id) at \(width)")
                }
                if !measured.isEmpty { #expect(!rendered.readings.isEmpty, "\(entry.name) must not show only dashes") }
                for column in ["5h", "7d"] {
                    #expect((rendered.cells[column] ?? .empty) == entry.panel_cells[column], "\(entry.name): \(column) at \(width)")
                }
                let host = NSHostingView(rootView: row.frame(width: width).fixedSize(horizontal: false, vertical: true))
                #expect(host.fittingSize.width == width)
                #expect(host.fittingSize.height <= PanelComposition.usageHeight(provider), "\(entry.name): \(host.fittingSize.height)")
            }
            let overview = UsageGaugeRow(provider: provider, name: provider.id, now: matrix.now,
                style: .compact, windowNames: overviewNames)
            let overviewReadings = await evidence(overview.frame(width: 180 + CGFloat(overviewNames.count) * 120))
            for window in provider.windows where window.usedPct != nil {
                #expect(overviewReadings.readings[window.id]?.percentUsed == window.usedPct)
            }
            for column in overviewNames {
                let window = provider.windows.first { $0.name == column || $0.overviewColumn == column }
                let expected: UsageGaugeCellState = window.map { $0.usedPct == nil ? .dash : .reading } ?? .empty
                #expect((overviewReadings.cells[column] ?? .empty) == expected, "\(entry.name): overview \(column)")
            }
            let headline = provider.headlineWindow
            #expect(UsageCenterStore.primaryWindow(of: provider) == headline)
            let meter = StatusItemController.previewMeter(for: provider, document: nil, now: matrix.now)
            #expect(meter.fraction == headline?.usedPct.map { $0 / 100 })
            let lines = StatusMenuLines.usage([provider], live: true, now: matrix.now)
            if let headline {
                #expect(lines.count == 1)
                #expect(lines[0].contains(headline.placementLabel))
                let amount = headline.usedPct == nil ? UsageStatus.noReading.word : headline.percentText
                #expect(lines[0].contains(amount))
            } else { #expect(lines.isEmpty) }
        }
    }

    @Test func grokMainRowHasItsCreditsAndNoDash() async throws {
        let matrix = try Self.fixture()
        let grok = try #require(matrix.cases.first { $0.provider.id == "grok" }?.provider)
        let row = UsageGaugeRow(provider: grok, name: "Grok", now: matrix.now,
            style: .panel, windowNames: ["5h", "7d"])
        let rendered = await evidence(row.frame(width: 320))
        #expect(rendered.cells == ["5h": .empty, "7d": .ownCell])
        #expect(!rendered.cells.values.contains(.dash))
        #expect(rendered.readings["credits"]?.percentUsed == grok.windows.first?.usedPct)
        #expect(UsageGaugeRow.panelAdditionalHeight(grok) == 16)
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

    private struct Evidence {
        var readings: [String: UsageGaugeReading] = [:]
        var cells: [String: UsageGaugeCellState] = [:]
    }

    private func evidence<V: View>(_ view: V) async -> Evidence {
        var result = Evidence()
        let root = view.onPreferenceChange(UsageGaugeEvidence.self) { result.readings = $0 }
            .onPreferenceChange(UsageGaugeCellEvidence.self) { result.cells = $0 }
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
        return result
    }
}
