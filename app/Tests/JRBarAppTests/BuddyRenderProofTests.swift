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
/// `/tmp/buddy-proof`. Manual evidence for the review, not a golden
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
        let dir = URL(fileURLWithPath: "/tmp/buddy-proof", isDirectory: true)
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
        let dir = URL(fileURLWithPath: "/tmp/buddy-proof", isDirectory: true)
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
}
