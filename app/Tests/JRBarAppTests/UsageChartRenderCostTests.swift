import JRBarTestSupport
import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import JRBarCore
@testable import JRBarApp

@MainActor
@Suite("Usage chart render cost diagnostic", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_COST_PROBE"] == "1"), .renderProofAppearance)
struct UsageChartRenderCostTests {
    @MainActor private struct Fixture {
        let name: String
        let history: UsageHistory
        let range: UsageHistoryRange
        let metric: UsageCenterStore.Metric
        var overview: OverviewStore? = nil
        var pointCount: Int {
            overview?.graph?.graph.series.reduce(0) { $0 + $1.values.count }
                ?? history.days.count * (metric == .tokens ? 3 : 1)
        }
        var totalsCount: Int { overview?.graph?.graph.days ?? history.days.count }
        var size: CGSize { overview == nil ? CGSize(width: 560, height: 260) : CGSize(width: 900, height: 620) }
    }

    private struct Sample: Codable {
        let diagnostic = "DEBUG actual chart component render only; no FPS, installed latency, or performance winner"
        let name: String
        let iteration: Int
        let warmup: Bool
        let wallNanoseconds: Int64
        let processCPUNanoseconds: Int64
        let width: Int
        let height: Int
        let declaredPointCount: Int
        let declaredTotalsCount: Int
        let pixelChecksum: UInt64
        let bluePlotPixels: Int
    }

    @Test func actualViewRenderSamples() throws {
        let cases = try fixtures()
        try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["JRBAR_RENDER_COST_PROFILE"] == "1" {
            let name = ProcessInfo.processInfo.environment["JRBAR_RENDER_COST_CASE"] ?? "365-tokens"
            try profile(try #require(cases.first { $0.name == name }))
            return
        }
        for fixture in cases {
            try measure(fixture, iteration: -1, warmup: true, writePNG: true)
        }
        for iteration in 0..<5 {
            let ordered = iteration.isMultiple(of: 2) ? cases : Array(cases.reversed())
            for fixture in ordered {
                try measure(fixture, iteration: iteration, warmup: false, writePNG: false)
            }
        }
    }

    private func fixtures() throws -> [Fixture] {
        let localCalendar = Calendar.current
        let start = try #require(localCalendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let days = try (0..<365).map { index -> UsageHistoryDay in
            let date = try #require(localCalendar.date(byAdding: .day, value: index, to: start))
            let parts = localCalendar.dateComponents([.year, .month, .day], from: date)
            let stamp = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
            return UsageHistoryDay(date: stamp, tokensIn: 200 + index % 23,
                                   tokensOut: 90 + index % 17, cacheRead: 40 + index % 11,
                                   costUsd: 0.1 + Double(index % 19) * 0.01)
        }
        func fixture(_ count: Int, _ range: UsageHistoryRange, _ metric: UsageCenterStore.Metric) -> Fixture {
            let name = "\(count)-\(metric == .tokens ? "tokens" : "cost")"
            return Fixture(name: name, history: UsageHistory(provider: "claude", range: range.rawValue,
                                                            days: Array(days.prefix(count))),
                           range: range, metric: metric)
        }
        func overview(_ count: Int) -> Fixture {
            let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-render-cost-fixture.sock")
            core.handle(.connected)
            core.apply(.state(CoreState()))
            let store = OverviewStore(core: core)
            var graph = CoreUsageGraph()
            graph.days = count
            graph.periodLabel = "Synthetic \(count)-day usage"
            graph.providers = ["claude", "codex", "gemini", "jrbar"]
            graph.labels = (0..<count).map { $0.isMultiple(of: 30) ? "Day \($0 + 1)" : "" }
            graph.series = graph.providers.enumerated().map { provider, id in
                .init(providerId: id, values: (0..<count).map { day in
                    Double((day * (provider + 3)) % 40_000 + 1_000 * (provider + 1))
                })
            }
            graph.scaleMax = 6_000
            store.pane = .usage
            store.graphDays = count
            store.graph = CoreUsageGraphDocument(graph: graph, summary: "Synthetic rendering fixture")
            store.graphProviderOptions = graph.providers
            return Fixture(name: "overview-\(count)-tokens",
                           history: UsageHistory(provider: "synthetic", range: "1y"),
                           range: .year, metric: .tokens, overview: store)
        }
        return [fixture(1, .week, .tokens), fixture(30, .month, .tokens),
                fixture(365, .year, .tokens), fixture(365, .year, .cost),
                Fixture(name: "empty", history: UsageHistory(provider: "claude", range: "7d"),
                        range: .week, metric: .tokens), overview(30), overview(365)]
    }

    private func render(_ fixture: Fixture) throws -> NSBitmapImageRep {
        if let store = fixture.overview {
            return try ProofRender.render(UsageGraphView(store: store).frame(width: 900, height: 620)
                .background(Color.white), size: fixture.size, dark: false, scale: 1, settle: 0)
        }
        let chart = UsageTokenChart(history: fixture.history, range: fixture.range, accent: Color(red: 0.12, green: 0.45, blue: 0.90), metric: fixture.metric)
            .padding(12)
            .frame(width: 560, height: 260)
            .background(Color.white)
        return try ProofRender.render(chart, size: CGSize(width: 560, height: 260),
                                      dark: false, scale: 1, settle: 0)
    }

    private func measure(_ fixture: Fixture, iteration: Int, warmup: Bool, writePNG: Bool) throws {
        let clock = ContinuousClock()
        let result = try autoreleasepool { () throws -> (NSBitmapImageRep, Int64, Int64) in
            let cpuStart = try cpuNanoseconds()
            let start = clock.now
            let bitmap = try render(fixture)
            let elapsed = start.duration(to: clock.now)
            let cpuEnd = try cpuNanoseconds()
            return (bitmap, nanoseconds(elapsed), cpuEnd - cpuStart)
        }
        let bitmap = result.0
        if writePNG {
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: ProofRender.directory.appendingPathComponent("usage-render-cost-\(fixture.name).png"))
        }
        let pixels = inspect(bitmap, fixture: fixture)
        let sample = Sample(name: fixture.name, iteration: iteration, warmup: warmup,
                            wallNanoseconds: result.1, processCPUNanoseconds: result.2,
                            width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                            declaredPointCount: fixture.pointCount, declaredTotalsCount: fixture.totalsCount,
                            pixelChecksum: pixels.checksum, bluePlotPixels: pixels.blue)
        try append(sample)
        #expect(bitmap.pixelsWide == Int(fixture.size.width) && bitmap.pixelsHigh == Int(fixture.size.height))
        if fixture.totalsCount == 0 {
            #expect(pixels.blue == 0, "Empty chart drew \(pixels.blue) blue plot pixels")
        } else {
            #expect(pixels.blue > 5, "\(fixture.name) has only \(pixels.blue) blue plot pixels with settle zero")
        }
    }

    private func inspect(_ bitmap: NSBitmapImageRep, fixture: Fixture) -> (checksum: UInt64, blue: Int) {
        var checksum: UInt64 = 14_695_981_039_346_656_037
        if let data = bitmap.bitmapData {
            for offset in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
                checksum = (checksum ^ UInt64(data[offset])) &* 1_099_511_628_211
            }
        }
        var blue = 0
        let top = fixture.overview == nil ? (fixture.metric == .tokens ? 0.20 : 0.08) : 0.55
        let bottom = fixture.overview == nil ? 0.92 : 0.85
        for y in Int(Double(bitmap.pixelsHigh) * top)..<Int(Double(bitmap.pixelsHigh) * bottom) {
            for x in Int(Double(bitmap.pixelsWide) * 0.12)..<Int(Double(bitmap.pixelsWide) * 0.98) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.blueComponent - color.redComponent > 0.08,
                   color.blueComponent - color.greenComponent > 0.04 { blue += 1 }
            }
        }
        return (checksum, blue)
    }

    private func cpuNanoseconds() throws -> Int64 {
        var usage = rusage()
        let status = getrusage(RUSAGE_SELF, &usage)
        try #require(status == 0)
        let seconds = Int64(usage.ru_utime.tv_sec) + Int64(usage.ru_stime.tv_sec)
        let micros = Int64(usage.ru_utime.tv_usec) + Int64(usage.ru_stime.tv_usec)
        return seconds * 1_000_000_000 + micros * 1_000
    }

    private func nanoseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
    }

    private func append(_ sample: Sample) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(sample)
        data.append(0x0A)
        let url = ProofRender.directory.appendingPathComponent("usage-render-cost.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        FileHandle.standardOutput.write(data)
    }

    private func profile(_ fixture: Fixture) throws {
        let first = try render(fixture)
        let pixels = inspect(first, fixture: fixture)
        try #require(pixels.blue > 5)
        let png = try #require(first.representation(using: .png, properties: [:]))
        try png.write(to: ProofRender.directory.appendingPathComponent("usage-render-cost-profile-\(fixture.name).png"))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        FileHandle.standardOutput.write(Data("PROFILE_READY pid=\(ProcessInfo.processInfo.processIdentifier)\n".utf8))
        var count = 0
        var errors = 0
        var consumed: UInt64 = 0
        while clock.now < deadline {
            try autoreleasepool {
                let bitmap = try render(fixture)
                if let data = bitmap.bitmapData {
                    consumed &+= UInt64(data[bitmap.bytesPerRow * bitmap.pixelsHigh / 2])
                } else {
                    errors += 1
                }
                if bitmap.pixelsWide != Int(fixture.size.width) || bitmap.pixelsHigh != Int(fixture.size.height) { errors += 1 }
            }
            count += 1
        }
        FileHandle.standardOutput.write(Data("PROFILE_DONE count=\(count) errors=\(errors) consumed=\(consumed) component-only DEBUG diagnostic\n".utf8))
        #expect(count > 0)
        #expect(errors == 0)
    }
}
