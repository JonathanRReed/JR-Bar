import Darwin
import Foundation
import Testing
@testable import JRBarCore

@Suite("Session reconstruction benchmark", .serialized)
struct SessionReconstructionBenchmarkTests {
    @Test("blank-line allocation and error-heavy story construction")
    func reconstructionCost() {
        guard let mode = ProcessInfo.processInfo.environment["JRBAR_RECONSTRUCTION_BENCHMARK"] else { return }
        let megabytes = Int(ProcessInfo.processInfo.environment["JRBAR_BENCHMARK_MIB"] ?? "16") ?? 16
        precondition((1...64).contains(megabytes))
        let started: ContinuousClock.Instant
        var count: Int
        switch mode {
        case "blank-before", "blank-after":
            let payload = Data(repeating: 0x0A, count: megabytes * 1024 * 1024)
            started = .now
            if mode == "blank-before" {
                count = formerBlankLineCount([payload])
            } else {
                let result = SessionReconstructor.reconstruct(segments: [payload], provider: "claude")
                count = result.totalLines
                #expect(result.items.isEmpty && result.gaps.isEmpty)
            }
            #expect(count == payload.count)
        case "story-before", "story-after":
            let items = (0..<2500).flatMap { index in
                [ReconstructedItem(seq: index * 2, kind: .toolUse,
                                   name: "tool-\(index)", toolUseID: "call-\(index)"),
                 ReconstructedItem(seq: index * 2 + 1, kind: .toolResult,
                                   toolUseID: "call-\(index)", isError: true)]
            }
            started = .now
            let names = mode == "story-before"
                ? formerFailedToolNames(items)
                : SessionReconstructor.story(for: items).failedToolNames
            count = names.count
            #expect(names == (0..<2500).map { "tool-\($0)" })
        default:
            Issue.record("Unknown reconstruction benchmark mode: \(mode)")
            return
        }
        let elapsed = started.duration(to: .now)
        var usage = rusage()
        #expect(getrusage(RUSAGE_SELF, &usage) == 0)
        let inputMiB = mode.hasPrefix("blank-") ? megabytes : 0
        print("reconstruction mode=\(mode) input_mib=\(inputMiB) count=\(count) elapsed=\(elapsed) peak_rss_bytes=\(usage.ru_maxrss)")
    }

    // The former algorithm for blank input, including its buffer and range array.
    private func formerBlankLineCount(_ segments: [Data]) -> Int {
        var data = Data()
        data.reserveCapacity(segments.reduce(0) { $0 + $1.count })
        for segment in segments { data.append(segment) }
        var start = 0
        var ranges: [Range<Int>] = []
        for index in 0..<data.count where data[index] == 0x0A {
            ranges.append(start..<index)
            start = index + 1
        }
        if start < data.count { ranges.append(start..<data.count) }
        var count = 0
        for range in ranges {
            count += 1
            let line = String(decoding: data[range], as: UTF8.self)
            precondition(line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        return count
    }

    private func formerFailedToolNames(_ items: [ReconstructedItem]) -> [String] {
        var names: [String] = []
        for item in items where item.isError && (item.kind == .toolUse || item.kind == .toolResult) {
            let paired = items.first { $0.kind == .toolUse && $0.toolUseID == item.toolUseID }?.name
            if let name = item.name ?? paired, !names.contains(name) { names.append(name) }
        }
        return names
    }
}
