import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// Render proof for the Notch Buddy roster: every character in the five
/// pose-shapes that read at a glance (pacing, waving, asleep, slumped,
/// celebrating), still poses in a dark capsule, 4×, written to
/// `/tmp/buddy-proof`. Manual evidence for the review, not a golden
/// test — the skeleton's still poses are deterministic, but the proof
/// exists so a human can look at them.
@Suite("Buddy render proof")
@MainActor
struct BuddyRenderProofTests {
    @Test func snapshots() throws {
        let dir = URL(fileURLWithPath: "/tmp/buddy-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let moods: [(name: String, mood: NotchBuddyToy.Mood, tint: Color)] = [
            ("pacing", .pacing, .accentColor),
            ("waving", .waving, .orange),
            ("asleep", .asleep, Color(nsColor: .tertiaryLabelColor)),
            ("slumped", .slumped, .red),
            ("celebrating", .celebrating, .green),
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
                                         leans: false, still: true, askCount: 2)
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
}
