import AppKit
import SwiftUI
import Darwin
import Foundation
import Observation
import Testing
@testable import JRBarCore
@testable import JRBarApp

@Suite("App state performance", .serialized)
@MainActor
struct AppPerformanceTests {
    final class Ticket: @unchecked Sendable {
        nonisolated(unsafe) static var live = 0
        init() { Self.live += 1 }
        deinit { Self.live -= 1 }
        var fired = false
    }

    private func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    private func allocation() -> malloc_statistics_t {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats
    }

    private func checkpoint(_ label: String) throws {
        guard let root = ProcessInfo.processInfo.environment["JRBAR_PERF_CHECKPOINT_DIR"] else { return }
        let directory = URL(fileURLWithPath: root)
        try Data("\(getpid())".utf8).write(to: directory.appendingPathComponent(label))
        let fifo = try FileHandle(forReadingFrom: directory.appendingPathComponent("continue"))
        _ = try fifo.read(upToCount: 1)
        try fifo.close()
    }

    @Test("ten thousand decoded states keep observation tickets bounded")
    func stateFeed() throws {
        let core = CoreModel(socketPath: "/tmp/jrbar-performance-unused.sock")
        core.handle(.connected)
        let defaults = UserDefaults(suiteName: ScratchDefaults.suiteName("jrbar.performance"))!
        let store = PanelStore(core: core, draftsDefaults: defaults, screenBarShown: false)
        store.animationsArmed = false
        let rendered = ProcessInfo.processInfo.environment["JRBAR_PERF_RENDERED"] == "1"
        let host: NSHostingView<PanelView>? = rendered ? NSHostingView(rootView: PanelView(store: store)) : nil
        host?.frame = CGRect(x: 0, y: 0, width: PanelView.width, height: 500)
        let decoder = JSONDecoder()
        let legacy = ProcessInfo.processInfo.environment["JRBAR_PERF_MODE"] == "legacy"
        var observer: Ticket?
        var registrations = 0
        func arm() {
            let ticket = Ticket()
            withObservationTracking {
                if legacy { _ = core.state } else { AppDelegate.observedAppFacts(core) }
                _ = core.settings
            } onChange: { ticket.fired = true }
            observer = ticket
            registrations += 1
            _ = store.rows
        }
        func feed(_ count: Int) throws {
            for index in 0..<count {
                try autoreleasepool {
                    let data = Data("""
                    {"v":1,"generation":\(index),"now":1790000000,"sessions":[{"id":"fixture","provider":"claude","kind":"main","mode":"working"}],"asks":[],"devices":[]}
                    """.utf8)
                    let state = try decoder.decode(CoreState.self, from: data)
                    core.apply(.state(state))
                    if observer?.fired != false { arm() }
                    if let host {
                        host.needsLayout = true
                        host.layoutSubtreeIfNeeded()
                    }
                    #expect(core.sessions.map(\.id) == ["fixture"])
                }
            }
        }
        try feed(1_000)
        try checkpoint("warm")
        let initial = allocation()
        let start = cpu()
        let builds = store.rowsComputations
        let arms = registrations
        try feed(10_000)
        let elapsed = cpu() - start
        let final = allocation()
        #expect(Ticket.live == 1, "unchanged settings must not retain retired state observers")
        // Malloc totals belong to the process. Only compare them in the
        // isolated probe, never beside unrelated parallel test suites.
        if ProcessInfo.processInfo.environment["JRBAR_PERF_ISOLATED"] == "1" {
            #expect(final.blocks_in_use < initial.blocks_in_use + 1_000)
            #expect(final.size_in_use < initial.size_in_use + 2_000_000)
        }
        print("PERF state mode=\(legacy ? "legacy" : "slices") rendered=\(rendered) messages=10000 cpu_seconds=\(elapsed) blocks_delta=\(Int(final.blocks_in_use) - Int(initial.blocks_in_use)) bytes_delta=\(Int(final.size_in_use) - Int(initial.size_in_use)) row_builds=\(store.rowsComputations - builds) registrations=\(registrations - arms) tickets=\(Ticket.live)")
        try checkpoint("fed")
        core.handle(.disconnected(reason: "fixture complete"))
        observer = nil
        #expect(Ticket.live == 0)
        _ = defaults
    }
}
