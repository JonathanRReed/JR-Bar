import JRBarTestSupport
import AppKit
import Foundation
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

/// Render proof for the 0.10.1 toy features: the buddy's eyes on the
/// pointer, and the little schools flocking. Off by default; set
/// `JRBAR_RENDER_PROOF=1` to write PNGs into `JRBAR_RENDER_PROOF_DIR`.
@Suite("Toy features render proof", .serialized, .renderProofAppearance)
@MainActor
struct ToyFeaturesRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    private static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-toy-features", isDirectory: true)
    }

    private static func write<V: View>(_ view: V, name: String, scale: CGFloat = 2) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: Eyes

    /// Every body looking toward eight pointer spots round it, plus the
    /// centre (pointer far away) and Reduce Motion (always centred).
    @Test(.enabled(if: enabled)) func eyesFollow() throws {
        let spots: [(name: String, dx: Double, dy: Double)] = [
            ("far", 900, 0), ("right", 80, 0), ("up-right", 60, 60), ("up", 0, 80),
            ("up-left", -60, 60), ("left", -80, 0), ("down-left", -60, -60),
            ("down", 0, -80), ("down-right", 60, -60),
        ]
        for dark in [true, false] {
            let sheet = VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("").frame(width: 70)
                    ForEach(spots.indices, id: \.self) { i in
                        Text(spots[i].name).font(.system(size: 9)).frame(width: 64)
                    }
                    Text("Reduce Motion").font(.system(size: 9)).frame(width: 64)
                }
                ForEach(BuddyCharacter.allCases, id: \.self) { character in
                    HStack(spacing: 6) {
                        Text(character.displayName).font(.system(size: 10)).frame(width: 70, alignment: .leading)
                        ForEach(spots.indices, id: \.self) { i in
                            let look = BuddyGaze.target(pointer: CGPoint(x: spots[i].dx, y: spots[i].dy),
                                                        eyes: .zero)
                            Self.eyeTile(character, gaze: look, still: false, dark: dark)
                        }
                        Self.eyeTile(character, gaze: BuddyGaze.Look(x: 0.8, y: 0, weight: 1),
                                     still: true, dark: dark)
                    }
                }
            }
            .padding(12)
            .background(dark ? Color(white: 0.08) : Color(white: 0.96))
            .foregroundStyle(dark ? Color.white : Color.black)
            .environment(\.colorScheme, dark ? .dark : .light)
            try Self.write(sheet, name: "t2-eyes-follow-\(dark ? "dark" : "light")", scale: 3)
        }
    }

    private static func eyeTile(_ character: BuddyCharacter, gaze: BuddyGaze.Look, still: Bool,
                                dark: Bool) -> some View {
        BuddyFigure(character: character, mood: .pacing, tint: .accentColor, phase: 2.35,
                    hopProgress: nil, waveAge: nil, slumpAge: nil, leans: false, still: still,
                    askCount: 0, care: .content, trick: nil, treatAge: nil, crumbAge: nil,
                    turn: nil, handoff: nil, gaze: gaze)
            .frame(width: 30, height: 26)
            .scaleEffect(2)
            .frame(width: 64, height: 56)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(dark ? Color(white: 0.15) : Color.white))
    }

    // MARK: Schools

    private struct Frame {
        var layouts: [String: AquariumView.Layout]
        var tetras: [PetPose]
        var t: Double
    }

    /// A parent with six fry and a second fish crossing the tetras' path,
    /// stepped frame by frame through the real steering and layout.
    @Test(.enabled(if: enabled)) func schools() throws {
        let size = CGSize(width: 900, height: 520)
        let base = Date(timeIntervalSince1970: 2_000_000)
        let parent = Fish(id: "parent", label: "review-patch", providerID: "claude", state: .swimming,
                          lane: 0.45, speed: 0.08, direction: 1,
                          stateSince: base.addingTimeInterval(-100), enteredAt: .distantPast,
                          species: .clownfish)
        let blocker = Fish(id: "blocker", label: "long-think", providerID: "codex", state: .swimming,
                           lane: 0.3, speed: 0.06, direction: -1,
                           stateSince: base.addingTimeInterval(-100), enteredAt: .distantPast,
                           species: .angelfish)
        let fry = (0..<6).map { i in
            Fish(id: "fry-\(i)", label: "worker", providerID: "claude", state: .swimming, lane: 0.45,
                 speed: 0.08, direction: 1, stateSince: base.addingTimeInterval(-100),
                 enteredAt: .distantPast, species: .minnow, isFry: true, anchorID: parent.id)
        }
        let roster = [parent, blocker] + fry
        let game = AquariumGame(inventory: [ShopItem.tetraSchool.rawValue: 1])
        let tank = AquariumView(fixture: .init(fish: roster, showLabels: false, game: game, night: 0))
        var frames: [Frame] = []
        for i in 0..<(30 * 12) {
            let t = 100 + Double(i) / 30
            let now = base.addingTimeInterval(t)
            _ = tank.stepSwim(roster, in: size, t: t, now: now, density: 1)
            var layouts: [String: AquariumView.Layout] = [:]
            for fish in [parent, blocker] {
                layouts[fish.id] = tank.layout(of: fish, in: size, at: t, now: now)
                tank.motion.swim.record(fish, layout: layouts[fish.id]!, t: t)
            }
            for f in fry {
                let parentLayout = layouts[parent.id]!
                layouts[f.id] = tank.layout(of: f, in: size, at: t, now: now, parent: (parent, parentLayout))
            }
            let mains = layouts.filter { $0.key == parent.id || $0.key == blocker.id }
            let tetras = tank.tetraPoses(size: size, t: t,
                                         obstacles: AquariumView.schoolObstacles(mains))
            frames.append(Frame(layouts: layouts, tetras: tetras, t: t))
        }
        let picks = [30, 120, 210, 300, 359]
        let panels = VStack(spacing: 8) {
            ForEach(picks, id: \.self) { pick in
                Self.schoolPanel(tank: tank, roster: roster, frames: frames, at: pick, size: size, base: base)
            }
        }
        .padding(8)
        .background(Color(white: 0.08))
        try Self.write(panels, name: "t2-school-filmstrip", scale: 1.5)
    }

    private static func schoolPanel(tank: AquariumView, roster: [Fish], frames: [Frame], at pick: Int,
                                    size: CGSize, base: Date) -> some View {
        let frame = frames[pick]
        let trail = frames[max(0, pick - 24)...pick]
        return Canvas { context, size in
            var canvas = context
            canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.13, green: 0.5, blue: 0.62), Color(red: 0.03, green: 0.16, blue: 0.36)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            // The last 0.8 s of each small swimmer, as fading dots.
            for (k, past) in trail.enumerated() {
                let fade = Double(k) / Double(max(1, trail.count))
                for (id, l) in past.layouts where id.hasPrefix("fry") {
                    canvas.fill(Path(ellipseIn: CGRect(x: l.x - 1.2, y: l.y - 1.2, width: 2.4, height: 2.4)),
                                with: .color(.white.opacity(0.35 * fade)))
                }
                for pose in past.tetras {
                    canvas.fill(Path(ellipseIn: CGRect(x: pose.x - 1, y: pose.y - 1, width: 2, height: 2)),
                                with: .color(Color(red: 0.4, green: 0.9, blue: 1).opacity(0.35 * fade)))
                }
            }
            let now = base.addingTimeInterval(frame.t)
            for fish in roster {
                guard let l = frame.layouts[fish.id] else { continue }
                var parent: (fish: Fish, layout: AquariumView.Layout)?
                if fish.isFry, let pl = frame.layouts["parent"] { parent = (roster[0], pl) }
                tank.drawFish(canvas: &canvas, size: size, t: frame.t, now: now, fish: fish, layout: l,
                              parent: parent, showLabels: false)
            }
            for pose in frame.tetras {
                var c = canvas
                c.translateBy(x: pose.x, y: pose.y)
                c.scaleBy(x: pose.c, y: 1)
                PetArt.neonTetra(&c, length: 15)
            }
            let label = Text(String(format: "t = %.1f s", frame.t - 100))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            canvas.draw(label, at: CGPoint(x: 16, y: 16), anchor: .topLeading)
        }
        .frame(width: size.width, height: size.height)
    }
}
