import AppKit
import Foundation
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

/// Opt-in frame cost for the tank and the buddy: the work one frame
/// does, timed over many frames inside a single offscreen draw so the
/// renderer's own setup is paid once. Run with
/// `JRBAR_FRAME_COST=1 swift test --filter ToyFrameCostTests`; each case
/// prints a `frame-cost` line. Numbers are for comparing builds on one
/// Mac, not budgets.
@Suite("Toy frame cost", .serialized)
@MainActor
struct ToyFrameCostTests {
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["JRBAR_FRAME_COST"] == "1" }

    private let size = CGSize(width: 900, height: 560)
    private let base = Date(timeIntervalSince1970: 2_000_000)

    private final class Timing { var total: Duration = .zero }

    /// Four working fish with six fry each, plus the tetra school.
    private func tank() -> (AquariumView, [Fish]) {
        var roster: [Fish] = []
        for index in 0..<4 {
            let parent = Fish(id: "parent-\(index)", label: "work-\(index)",
                              providerID: index.isMultiple(of: 2) ? "claude" : "codex",
                              state: .swimming, lane: 0.25 + Double(index) * 0.15, speed: 0.08,
                              direction: index.isMultiple(of: 2) ? 1 : -1,
                              stateSince: base.addingTimeInterval(-100), enteredAt: .distantPast,
                              species: .clownfish)
            roster.append(parent)
            for fry in 0..<6 {
                roster.append(Fish(id: "fry-\(index)-\(fry)", label: "worker", providerID: parent.providerID,
                                   state: .swimming, lane: parent.lane, speed: 0.08, direction: 1,
                                   stateSince: base.addingTimeInterval(-100), enteredAt: .distantPast,
                                   species: .minnow, isFry: true, anchorID: parent.id))
            }
        }
        let game = AquariumGame(inventory: [ShopItem.tetraSchool.rawValue: 1])
        let view = AquariumView(fixture: .init(fish: roster, game: game, night: 0))
        return (view, roster)
    }

    @Test(.enabled(if: ToyFrameCostTests.enabled, "set JRBAR_FRAME_COST=1"))
    func aquarium() throws {
        let (view, roster) = tank()
        let mains = Dictionary(uniqueKeysWithValues: roster.filter { !$0.isFry }.map { ($0.id, $0) })
        let frames = 900
        let timing = Timing()
        let size = self.size
        let base = self.base
        let canvas = Canvas { context, size in
            var canvas = context
            let clock = ContinuousClock()
            let start = clock.now
            for frame in 0..<frames {
                let t = 100 + Double(frame) / 30
                let now = base.addingTimeInterval(t)
                _ = view.stepSwim(roster, in: size, t: t, now: now, density: 1)
                var layouts: [String: AquariumView.Layout] = [:]
                for fish in roster where !fish.isFry {
                    layouts[fish.id] = view.layout(of: fish, in: size, at: t, now: now)
                }
                for fish in roster {
                    var parent: (fish: Fish, layout: AquariumView.Layout)?
                    if let id = fish.anchorID, let main = mains[id], let l = layouts[id] { parent = (main, l) }
                    let l = layouts[fish.id] ?? view.layout(of: fish, in: size, at: t, now: now, parent: parent)
                    view.drawFish(canvas: &canvas, size: size, t: t, now: now, fish: fish, layout: l,
                                  parent: parent, showLabels: true)
                }
                view.drawTetraSchool(canvas: &canvas, size: size, t: t)
                view.drawPlankton(canvas: &canvas, size: size, t: t, density: 1, front: false)
                view.drawBubbles(canvas: &canvas, size: size, t: t, density: 1)
            }
            timing.total = start.duration(to: clock.now)
        }
        let renderer = ImageRenderer(content: canvas.frame(width: size.width, height: size.height))
        _ = renderer.nsImage
        report("aquarium", frames: frames, timing.total)
    }

    /// The schools' motion alone — fry places and tetra poses, no
    /// drawing — the part the flocking changes.
    @Test(.enabled(if: ToyFrameCostTests.enabled, "set JRBAR_FRAME_COST=1"))
    func schoolMotion() throws {
        let (view, roster) = tank()
        let mains = Dictionary(uniqueKeysWithValues: roster.filter { !$0.isFry }.map { ($0.id, $0) })
        let frames = 3_000
        var sink = 0.0
        let clock = ContinuousClock()
        let start = clock.now
        for frame in 0..<frames {
            let t = 100 + Double(frame) / 30
            let now = base.addingTimeInterval(t)
            var layouts: [String: AquariumView.Layout] = [:]
            for fish in roster where !fish.isFry {
                layouts[fish.id] = view.layout(of: fish, in: size, at: t, now: now)
            }
            for fish in roster where fish.isFry {
                guard let id = fish.anchorID, let main = mains[id], let l = layouts[id] else { continue }
                sink += view.layout(of: fish, in: size, at: t, now: now, parent: (main, l)).x
            }
            for pose in view.tetraPoses(size: size, t: t) { sink += pose.x }
        }
        let total = start.duration(to: clock.now)
        #expect(sink.isFinite)
        report("school-motion", frames: frames, total)
    }

    @Test(.enabled(if: ToyFrameCostTests.enabled, "set JRBAR_FRAME_COST=1"))
    func buddy() throws {
        let variants: [(name: String, gaze: BuddyGaze.Look)] = [
            ("buddy-rest", .rest),
            ("buddy-gaze", BuddyGaze.Look(x: 0.6, y: -0.3, weight: 1)),
        ]
        for variant in variants {
            let frames = 240
            let clock = ContinuousClock()
            let start = clock.now
            for frame in 0..<frames {
                let figure = BuddyFigure(character: BuddyCharacter.allCases[frame % 10], mood: .pacing,
                                         tint: .blue, phase: Double(frame) / 30, hopProgress: nil,
                                         waveAge: nil, slumpAge: nil, leans: false, still: false,
                                         askCount: 0, care: .content, trick: nil, treatAge: nil,
                                         crumbAge: nil, gaze: variant.gaze)
                    .frame(width: 30, height: 26)
                let renderer = ImageRenderer(content: figure)
                renderer.scale = 2
                _ = renderer.cgImage
            }
            report(variant.name, frames: frames, start.duration(to: clock.now))
        }
    }

    private func report(_ name: String, frames: Int, _ total: Duration) {
        let seconds = Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18
        let perFrame = seconds / Double(frames) * 1000
        let line = "frame-cost \(name) frames=\(frames) ms/frame=\(String(format: "%.3f", perFrame))"
        print(line)
        if let out = ProcessInfo.processInfo.environment["JRBAR_FRAME_COST_OUT"] {
            let handle = FileHandle(forWritingAtPath: out) ?? {
                FileManager.default.createFile(atPath: out, contents: nil)
                return FileHandle(forWritingAtPath: out)
            }()
            handle?.seekToEndOfFile()
            handle?.write(Data((line + "\n").utf8))
            try? handle?.close()
        }
    }
}
