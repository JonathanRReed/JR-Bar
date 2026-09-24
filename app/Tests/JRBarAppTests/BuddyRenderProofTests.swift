import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// Render proof for the Notch Buddy roster: every character in the
/// pose-shapes that read at a glance (pacing, waving, asleep, slumped,
/// celebrating — plus the care layers: the missing-you droop and a
/// treat's hearts), still poses in a dark capsule, 4×, written to
/// `JRBAR_RENDER_PROOF_DIR` (default `/tmp/buddy-proof`). Manual
/// evidence for the review, not a golden
/// test — the skeleton's still poses are deterministic, but the proof
/// exists so a human can look at them. It only runs when
/// `JRBAR_RENDER_PROOF=1` is in the environment, so the regular suite
/// never writes files.
@Suite("Buddy render proof")
@MainActor
struct BuddyRenderProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write /tmp/buddy-proof PNGs"))
    func snapshots() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
                      ?? "/tmp/buddy-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let moods: [(name: String, mood: NotchBuddyToy.Mood, tint: Color,
                     care: BuddyCare.Mood, treatAge: TimeInterval?, crumbAge: TimeInterval?)] = [
            ("pacing", .pacing, .accentColor, .content, nil, nil),
            ("waving", .waving, .orange, .content, nil, nil),
            ("asleep", .asleep, Color(nsColor: .tertiaryLabelColor), .content, nil, nil),
            ("slumped", .slumped, .red, .content, nil, nil),
            ("celebrating", .celebrating, .green, .content, nil, 0.5),
            ("missing", .pacing, .accentColor, .missing, nil, nil),
            ("fed", .gathering, .accentColor, .fed, 0.35, nil),
        ]
        var written: [String] = []
        for character in BuddyCharacter.allCases {
            for entry in moods {
                // still: true — the Reduce Motion poses are the
                // deterministic ones. waveAge past the entrance shows
                // the wave proper (and the "!" stays up); askCount 2
                // shows the "!2" badge.
                let figure = BuddyFigure(character: character, mood: entry.mood,
                                         tint: entry.tint, phase: 2.35,
                                         hopProgress: nil,
                                         waveAge: entry.mood == .waving ? 1.1 : nil,
                                         slumpAge: entry.mood == .slumped ? 1.5 : nil,
                                         leans: false, still: true, askCount: 2,
                                         care: entry.care, trick: nil,
                                         treatAge: entry.treatAge, crumbAge: entry.crumbAge)
                let staged = figure
                    .frame(width: 30, height: 26)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(white: 0.13)))
                    .padding(4)
                    .environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: staged)
                renderer.scale = 4
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    Issue.record("render failed for \(character.rawValue)/\(entry.name)")
                    continue
                }
                let name = "\(character.rawValue)-\(entry.name).png"
                try png.write(to: dir.appendingPathComponent(name))
                written.append(name)
            }
        }
        #expect(written.count == BuddyCharacter.allCases.count * moods.count)
    }

    /// The floating buddy at each dial stop: the same layout math
    /// `NotchBuddyView` applies — draw at 18pt, `scaleEffect`, claim the
    /// scaled frame, scale the padding — so a human can eyeball that 3×
    /// reads as a desk pet, not a magnified toolbar chip. Everything is
    /// vector, so nothing resamples.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write /tmp/buddy-proof PNGs"))
    func scaledSnapshots() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
                      ?? "/tmp/buddy-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var written: [String] = []
        for character in BuddyCharacter.allCases {
            for scale in [1.0, 2.0, 3.0] {
                let figure = BuddyFigure(character: character, mood: .pacing,
                                         tint: .accentColor, phase: 2.35,
                                         hopProgress: nil, waveAge: nil, slumpAge: nil,
                                         leans: false, still: true, askCount: 0,
                                         care: .content, trick: nil,
                                         treatAge: nil, crumbAge: nil)
                // The view's own recipe: 18pt canvas, scale transform,
                // then the scaled footprint and padding.
                let staged = figure
                    .frame(width: 18, height: 18)
                    .scaleEffect(scale)
                    .frame(width: 18 * scale, height: 18 * scale)
                    .padding(.horizontal, 9 * scale)
                    .padding(.vertical, 6 * scale)
                    .background(RoundedRectangle(cornerRadius: 15 * scale, style: .continuous)
                        .fill(Color(white: 0.13)))
                    .padding(4)
                    .environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: staged)
                renderer.scale = 2
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    Issue.record("render failed for \(character.rawValue) at \(scale)×")
                    continue
                }
                let name = "\(character.rawValue)-\(Int(scale))x.png"
                try png.write(to: dir.appendingPathComponent(name))
                written.append(name)
            }
        }
        #expect(written.count == BuddyCharacter.allCases.count * 3)
    }

    /// The whole roster on two contact sheets a human can take in at a
    /// glance: every character down the rows and every pose across
    /// (`buddy-sheet-moods`), then every character in each piece of the
    /// wardrobe and each life stage (`buddy-sheet-wardrobe`), on the
    /// dark pill the docked buddy hangs in. Written to
    /// `JRBAR_RENDER_PROOF_DIR` (default `/tmp/jrbar-audit`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the contact sheets"))
    func contactSheets() throws {
        let moods: [(mood: NotchBuddyToy.Mood, tint: Color, care: BuddyCare.Mood,
                     treat: TimeInterval?, crumb: TimeInterval?)] = [
            (.pacing, ProviderStyle.style(for: "claude").accent, .content, nil, nil),
            (.gathering, ProviderStyle.style(for: "codex").accent, .content, nil, nil),
            (.waving, .orange, .content, nil, nil),
            (.slumped, .red, .content, nil, nil),
            (.celebrating, .green, .content, nil, 0.5),
            (.asleep, Color(nsColor: .tertiaryLabelColor), .content, nil, nil),
            (.pacing, ProviderStyle.style(for: "claude").accent, .missing, nil, nil),
            (.gathering, ProviderStyle.style(for: "claude").accent, .fed, 0.35, nil),
        ]
        let moodSheet = VStack(spacing: 6) {
            ForEach(BuddyCharacter.allCases, id: \.self) { character in
                HStack(spacing: 6) {
                    ForEach(moods.indices, id: \.self) { i in
                        let entry = moods[i]
                        Self.tile(BuddyFigure(character: character, mood: entry.mood, tint: entry.tint,
                                              phase: 2.35, hopProgress: nil,
                                              waveAge: entry.mood == .waving ? 1.1 : nil,
                                              slumpAge: entry.mood == .slumped ? 1.5 : nil,
                                              leans: false, still: true, askCount: 2,
                                              care: entry.care, trick: nil,
                                              treatAge: entry.treat, crumbAge: entry.crumb))
                    }
                }
            }
        }
        try Self.writeSheet(moodSheet, name: "buddy-sheet-moods")

        let outfits: [ShopItem?] = [nil, .buddyBeanie, .buddyBow, .buddyFlower]
        let stages: [BuddyStage] = [.hatchling, .elder]
        let wardrobeSheet = VStack(spacing: 6) {
            ForEach(BuddyCharacter.allCases, id: \.self) { character in
                HStack(spacing: 6) {
                    ForEach(outfits.indices, id: \.self) { i in
                        Self.tile(BuddyFigure(character: character, mood: .pacing,
                                              tint: ProviderStyle.style(for: "claude").accent,
                                              phase: 2.35, hopProgress: nil, waveAge: nil,
                                              slumpAge: nil, leans: false, still: true, askCount: 0,
                                              care: .content, trick: nil, treatAge: nil,
                                              crumbAge: nil, wearing: outfits[i]))
                    }
                    ForEach(stages.indices, id: \.self) { i in
                        Self.tile(BuddyFigure(character: character, mood: i == 0 ? .pacing : .asleep,
                                              tint: i == 0 ? ProviderStyle.style(for: "codex").accent
                                                  : Color(nsColor: .tertiaryLabelColor),
                                              phase: 2.35, hopProgress: nil, waveAge: nil,
                                              slumpAge: nil, leans: false, still: true, askCount: 0,
                                              care: .content, trick: nil, treatAge: nil,
                                              crumbAge: nil, stage: stages[i]))
                    }
                }
            }
        }
        try Self.writeSheet(wardrobeSheet, name: "buddy-sheet-wardrobe")

        // The pieces up close, on four bodies: every outfit, the
        // nightcap and the ask's badge at three times the docked size.
        let closeUp = VStack(spacing: 8) {
            ForEach([BuddyCharacter.dot, .cat, .crab, .ufo], id: \.self) { character in
                HStack(spacing: 8) {
                    ForEach(outfits.indices, id: \.self) { i in
                        Self.zoomTile(BuddyFigure(character: character, mood: .pacing,
                                                  tint: ProviderStyle.style(for: "codex").accent,
                                                  phase: 2.35, hopProgress: nil, waveAge: nil,
                                                  slumpAge: nil, leans: false, still: true, askCount: 0,
                                                  care: .content, trick: nil, treatAge: nil,
                                                  crumbAge: nil, wearing: outfits[i]))
                    }
                    Self.zoomTile(BuddyFigure(character: character, mood: .asleep,
                                              tint: Color(nsColor: .tertiaryLabelColor),
                                              phase: 2.35, hopProgress: nil, waveAge: nil,
                                              slumpAge: nil, leans: false, still: true, askCount: 0,
                                              care: .content, trick: nil, treatAge: nil, crumbAge: nil))
                    Self.zoomTile(BuddyFigure(character: character, mood: .waving, tint: .orange,
                                              phase: 2.35, hopProgress: nil, waveAge: 1.1,
                                              slumpAge: nil, leans: false, still: true, askCount: 3,
                                              care: .content, trick: nil, treatAge: nil, crumbAge: nil))
                }
            }
        }
        try Self.writeSheet(closeUp, name: "buddy-sheet-closeup")
    }

    /// One figure three times over, on the pill's dark ground.
    private static func zoomTile(_ figure: BuddyFigure) -> some View {
        figure
            .frame(width: 18, height: 18)
            .scaleEffect(3)
            .frame(width: 54, height: 60)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.11)))
    }

    /// One figure on the docked pill's dark ground.
    private static func tile(_ figure: BuddyFigure) -> some View {
        figure
            .frame(width: 18, height: 18)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.11)))
    }

    private static func writeSheet<V: View>(_ sheet: V, name: String) throws {
        let staged = sheet
            .padding(10)
            .background(Color(white: 0.05))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: staged)
        renderer.scale = 5
        let image = try #require(renderer.cgImage)
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
                      ?? "/tmp/jrbar-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    // MARK: lane buddy

    /// The walk's turn, frame by frame: four bodies reversing from right
    /// to left over `BuddyTurn.duration`, eight frames 50 ms apart, zoomed
    /// so the lean, the narrowing and the eyes crossing ahead of the body
    /// read. A hairline marks upright. Light and dark grounds.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the turn sequence"))
    func turnSequence() throws {
        let steps = (0..<8).map { Double($0) * 0.05 }
        let bodies: [BuddyCharacter] = [.dot, .cat, .owl, .ufo]
        for dark in [false, true] {
            let ground = dark ? Color(white: 0.11) : Color(white: 0.93)
            let sheet = VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(steps.indices, id: \.self) { i in
                        Text("\(Int((steps[i] * 1000).rounded())) ms")
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 66)
                    }
                }
                ForEach(bodies, id: \.self) { character in
                    HStack(spacing: 6) {
                        ForEach(steps.indices, id: \.self) { i in
                            Self.turnTile(character: character, elapsed: steps[i], ground: ground)
                        }
                    }
                }
            }
            .padding(10)
            .background(dark ? Color(white: 0.05) : Color(white: 0.99))
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 3
            let image = try #require(renderer.cgImage)
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
            try png.write(to: ProofRender.directory
                .appendingPathComponent("buddy-turn-sequence-\(dark ? "dark" : "light").png"))
        }
    }

    /// One frame of the reversal, three times the docked size, with a
    /// hairline through upright.
    private static func turnTile(character: BuddyCharacter, elapsed: Double, ground: Color) -> some View {
        let turn = BuddyTurn.eased(from: 1, to: -1, elapsed: elapsed)
        return BuddyFigure(character: character, mood: .pacing,
                           tint: ProviderStyle.style(for: "claude").accent,
                           phase: 2.35, hopProgress: nil, waveAge: nil, slumpAge: nil,
                           leans: false, still: false, askCount: 0, care: .content,
                           trick: nil, treatAge: nil, crumbAge: nil, stride: 0, turn: turn)
            .frame(width: 18, height: 18)
            .scaleEffect(3)
            .frame(width: 54, height: 60)
            .padding(6)
            .background(alignment: .center) {
                Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 0.5)
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ground))
    }

    /// The card with its roaming rows — the hover caption, walks and how
    /// often — on the grouped settings ground, both appearances, through
    /// the native path so the real controls draw.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the card"))
    func card() throws {
        var toys = ToysState()
        toys.notchBuddy = NotchBuddySettings(enabled: true, character: "cat",
                                             freePosition: BuddySpot(x: 900, y: 600), scale: 1.75)
        toys.notchBuddy.walkEvery = 8
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: toys,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        defer { withExtendedLifetime(store) {} }
        let controls = store.notchBuddy.controls
        let probe = NSHostingView(rootView: controls.frame(width: 560))
        probe.layoutSubtreeIfNeeded()
        let height = ceil(probe.fittingSize.height) + 90
        for dark in [false, true] {
            let view = Form { Section { controls } }
                .formStyle(.grouped)
                .frame(width: 640, height: height)
            try ProofRender.write(view, size: CGSize(width: 640, height: height),
                                  name: "buddy-card-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    /// The moves between homes and moods, frame by frame: a docked tuck
    /// ducking up under the notch, a 2× buddy fresh out of the notch
    /// growing in from the docked size (the dashed ring is where the
    /// docked figure stood), and a completion hop handing off from the
    /// patrol's right-hand end instead of jumping to centre.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write the presence strip"))
    func presenceStrip() throws {
        let tint = ProviderStyle.style(for: "codex").accent
        func body(_ mood: NotchBuddyToy.Mood = .pacing, hop: Double? = nil,
                  handoff: BuddyHandoff? = nil) -> BuddyFigure {
            BuddyFigure(character: .cat, mood: mood, tint: mood == .celebrating ? .green : tint,
                        phase: 2.35, hopProgress: hop, waveAge: nil, slumpAge: nil, leans: false,
                        still: false, askCount: 0, care: .content, trick: nil, treatAge: nil,
                        crumbAge: nil, stride: 0.45 * 3.4, handoff: handoff)
        }
        func placed(_ figure: BuddyFigure, _ place: NotchBuddyView.Presence, scale: Double) -> some View {
            figure
                .scaleEffect(place.scale, anchor: place.anchor)
                .offset(place.offset)
                .opacity(place.opacity)
                .frame(width: 18, height: 18)
                .scaleEffect(scale)
                .frame(width: 18 * scale, height: 18 * scale)
        }
        let ticks = (0..<6).map { Double($0) / 5 }
        for dark in [false, true] {
            let ground = dark ? Color(white: 0.11) : Color(white: 0.93)
            let tile = RoundedRectangle(cornerRadius: 14, style: .continuous)
            let sheet = VStack(alignment: .leading, spacing: 8) {
                Text("Tuck, docked · 0 → \(Int(NotchBuddyToy.tuckDuration * 1000)) ms")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(ticks.indices, id: \.self) { i in
                        placed(body(), NotchBuddyView.presence(tuck: ticks[i], arrival: nil, docked: true,
                                                              scale: 3, reduceMotion: false), scale: 3)
                            .frame(width: 66, height: 66).background(tile.fill(ground))
                    }
                }
                Text("Out of the notch at 2× · 0 → \(Int(BuddyArrival.duration * 1000)) ms")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(ticks.indices, id: \.self) { i in
                        let arrival = BuddyArrival(fromScale: 0.5, drift: CGSize(width: 0, height: 3.5),
                                                   age: ticks[i] * BuddyArrival.duration)
                        placed(body(), NotchBuddyView.presence(tuck: nil, arrival: arrival, docked: false,
                                                              scale: 2, reduceMotion: false), scale: 2)
                            .frame(width: 66, height: 66)
                            .overlay {
                                Circle().stroke(Color.secondary.opacity(0.6),
                                                style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))
                                    .frame(width: 22, height: 22).offset(y: 3.5)
                            }
                            .background(tile.fill(ground))
                    }
                }
                Text("Completion hop from the patrol's end · 0 → \(Int(BuddyHandoff.duration * 1000)) ms")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(ticks.indices, id: \.self) { i in
                        let age = ticks[i] * BuddyHandoff.duration
                        placed(body(.celebrating, hop: age / 1.1,
                                    handoff: BuddyHandoff(from: .pacing, age: age)),
                               NotchBuddyView.presence(tuck: nil, arrival: nil, docked: false, scale: 3,
                                                       reduceMotion: false), scale: 3)
                            .frame(width: 66, height: 66)
                            .background(alignment: .center) {
                                Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 0.5)
                            }
                            .background(tile.fill(ground))
                    }
                }
            }
            .padding(10)
            .background(dark ? Color(white: 0.05) : Color(white: 0.99))
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 3
            let image = try #require(renderer.cgImage)
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
            try png.write(to: ProofRender.directory
                .appendingPathComponent("buddy-presence-\(dark ? "dark" : "light").png"))
        }
    }
}
