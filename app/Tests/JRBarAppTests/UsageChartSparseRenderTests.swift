import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

@MainActor
@Suite("Sparse usage chart render proof", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
struct UsageChartSparseRenderTests {
    @Test(arguments: ["tokens", "cost", "zero-tokens", "zero-cost"], [false, true])
    func boundaryMarkerIsComplete(_ fixture: String, dark: Bool) throws {
        let metric: UsageCenterStore.Metric = fixture.hasSuffix("cost") ? .cost : .tokens
        let zero = fixture.hasPrefix("zero-")
        let history = UsageHistory(provider: "claude", range: "7d", days: [
            UsageHistoryDay(date: "2026-10-10", tokensIn: zero ? 0 : 100, costUsd: zero ? 0 : 1),
        ], records: 1)
        let background = dark ? Color(red: 0.08, green: 0.08, blue: 0.08) : Color.white
        let chart = UsageChart(history: history, range: .week, metric: metric,
                               accent: Color(red: 0.12, green: 0.45, blue: 0.90))
            .padding(12)
            .frame(width: 560, height: 260)
            .background(background)
        let bitmap = try ProofRender.render(chart, size: CGSize(width: 560, height: 260), dark: dark)
        try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let name = "usage-boundary-\(fixture)-\(dark ? "dark" : "light").png"
        try png.write(to: ProofRender.directory.appendingPathComponent(name))
        let bounds = try #require(markerBounds(in: bitmap), "No marker in \(name)")
        #expect(bounds.width >= 5 && bounds.height >= 5)
        #expect(abs(bounds.width - bounds.height) <= 2,
                "Clipped circle in \(name): \(bounds.width) by \(bounds.height) pixels")
    }

    private func markerBounds(in bitmap: NSBitmapImageRep) -> (width: Int, height: Int)? {
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        var minX = width, minY = height, maxX = -1, maxY = -1
        // The centered singleton is right of the legend's color keys.
        for y in Int(Double(height) * 0.04)..<Int(Double(height) * 0.92) {
            for x in Int(Double(width) * 0.40)..<Int(Double(width) * 0.75) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.blueComponent - color.redComponent > 0.5,
                      color.blueComponent - color.greenComponent > 0.25 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return (maxX - minX + 1, maxY - minY + 1)
    }

    @Test(arguments: ["single-day-tokens", "single-day-cost", "single-hour-tokens",
                      "single-hour-cost", "two-day-tokens", "two-hour-tokens", "midnight-hour-tokens", "year-tokens", "zero-tokens", "unpriced-cost", "empty"], [false, true])
    func observedUsageHasPlotInk(_ fixture: String, dark: Bool) throws {
        let metric: UsageCenterStore.Metric = fixture.hasSuffix("cost") ? .cost : .tokens
        let history = history(for: fixture)
        let background = dark ? Color(red: 0.08, green: 0.08, blue: 0.08) : Color.white
        let range: UsageHistoryRange = fixture == "year-tokens" ? .year : .week
        let chart = UsageChart(history: history, range: range, metric: metric,
                               accent: Color(red: 0.12, green: 0.45, blue: 0.90))
            .padding(12)
            .frame(width: 560, height: 260)
            .background(background)
        let bitmap = try ProofRender.render(chart, size: CGSize(width: 560, height: 260), dark: dark)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
        let theme = dark ? "dark" : "light"
        let name = "usage-sparse-\(fixture)-\(theme).png"
        try png.write(to: ProofRender.directory.appendingPathComponent(name))

        let ink = bluePlotPixels(in: bitmap, showsLegend: metric == .tokens)
        if fixture == "empty" || fixture == "unpriced-cost" {
            #expect(ink == 0, "History without priced plot data drew \(ink) blue plot pixels in \(name)")
        } else {
            #expect(ink > 20, "Observed usage needs visible plot ink, found \(ink) pixels in \(name)")
        }
    }

    private func history(for fixture: String) -> UsageHistory {
        if fixture == "empty" {
            return UsageHistory(provider: "claude", range: "7d")
        }
        if fixture == "midnight-hour-tokens" {
            return UsageHistory(provider: "claude", range: "7d", hours: [
                UsageHistoryHour(hour: "2026-10-10T23:00", tokensIn: 250),
                UsageHistoryHour(hour: "2026-10-11T01:00", tokensIn: 150),
            ])
        }
        if fixture == "year-tokens" {
            return UsageHistory(provider: "claude", range: "365d", days: [
                UsageHistoryDay(date: "2026-01-01", tokensIn: 250),
                UsageHistoryDay(date: "2026-04-15", tokensIn: 150),
                UsageHistoryDay(date: "2026-10-10", tokensIn: 350),
            ])
        }
        if fixture == "zero-tokens" {
            return UsageHistory(provider: "claude", range: "7d", days: [
                UsageHistoryDay(date: "2026-10-10"),
            ])
        }
        if fixture == "unpriced-cost" {
            return UsageHistory(provider: "claude", range: "7d", days: [
                UsageHistoryDay(date: "2026-10-10", tokensIn: 250),
            ], unpricedRecords: 1, unpricedModels: ["fixture-model"])
        }
        if fixture.hasPrefix("single-hour") || fixture == "two-hour-tokens" {
            var hours = [UsageHistoryHour(hour: "2026-10-10T12:00", tokensIn: 250, costUsd: 0.5)]
            if fixture == "two-hour-tokens" {
                hours.append(UsageHistoryHour(hour: "2026-10-10T13:00", tokensIn: 150, costUsd: 0.3))
            }
            return UsageHistory(provider: "claude", range: "7d", hours: hours)
        }
        var days = [UsageHistoryDay(date: "2026-10-10", tokensIn: 250, costUsd: 0.5)]
        if fixture == "two-day-tokens" {
            days.append(UsageHistoryDay(date: "2026-10-11", tokensIn: 150, costUsd: 0.3))
        }
        return UsageHistory(provider: "claude", range: "7d", days: days)
    }

    private func bluePlotPixels(in bitmap: NSBitmapImageRep, showsLegend: Bool) -> Int {
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        var count = 0
        // Keep the legend, axis labels and outer padding outside the oracle.
        let top = showsLegend ? 0.20 : 0.08
        for y in Int(Double(height) * top)..<Int(Double(height) * 0.92) {
            for x in Int(Double(width) * 0.12)..<Int(Double(width) * 0.98) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.blueComponent - color.redComponent > 0.08,
                   color.blueComponent - color.greenComponent > 0.04 {
                    count += 1
                }
            }
        }
        return count
    }
}
