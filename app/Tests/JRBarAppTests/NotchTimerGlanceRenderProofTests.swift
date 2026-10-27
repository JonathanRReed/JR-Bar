import JRBarTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Notch timer glance render proof", .temporaryDirectory, .serialized)
@MainActor
struct NotchTimerGlanceRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write timer glance PNGs"))
    func runningPausedAndDone() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let directory = TestTemporaryDirectory.currentURL.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for mode in ["running", "paused", "done"] {
            let timers = ShelfTimerModel(storeURL: directory.appendingPathComponent("\(mode).json"),
                                         schedulingEnabled: false, clock: { now })
            let title = mode == "paused" ? "Review the final presentation before lunch" : "Tea"
            let timer = timers.add(label: title, duration: 125,
                                   now: mode == "done" ? now.addingTimeInterval(-130) : now)
            if mode == "paused" { timers.pause(timer) }
            if mode == "running" { timers.add(label: "Laundry", duration: 1800, now: now) }
            if mode == "done" { timers.sweep() }
            let scene = VStack(alignment: .leading, spacing: 12) {
                Text("Now").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                NotchTimerGlanceRow(timers: timers, style: .island, onOpenShelf: {}, stillDate: now)
            }
            .padding(16)
            .frame(width: 320)
            .background(.black, in: RoundedRectangle(cornerRadius: 20))
            try ProofRender.write(scene, size: CGSize(width: 320, height: 110),
                                  name: "notch-timer-glance-\(mode)")
        }
    }
}
