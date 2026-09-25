import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// Render proof for the Confetti work, as a person sees it: the burst on
/// a desktop under the menu bar, with the notch drawn ON TOP — it is a
/// hole in the screen, so anything under it is never seen. Jonathan's
/// MacBook Pro geometry (1512 × 982, the notch 663.5–848.5 × 32), a
/// notchless 1920 × 1080 display and a 3440 × 1440 ultrawide. Every
/// burst is seeded, so a frame is the same frame every run. Each PNG's
/// line prints how much of the burst the notch hides, how wide and how
/// tall it has spread (the middle 90 % of the pieces on screen) and how
/// many pieces are on the far layer — numbers, not
/// goldens. Written to `JRBAR_RENDER_PROOF_DIR` (default
/// `/tmp/confetti-proof`) only when `JRBAR_RENDER_PROOF=1`.
@Suite("Confetti render proof")
@MainActor
struct ConfettiRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"
    static let times: [Double] = [0.08, 0.25, 0.6, 1.2, 2.4, 3.6]
    static let notch = CGRect(x: 663.5, y: 0, width: 185, height: 32)
    static let icon = CGRect(x: 1270, y: 4, width: 26, height: 24)

    private var dir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/confetti-proof",
            isDirectory: true)
    }

    static func laptop(windows: [CGRect] = []) -> ConfettiStage {
        ConfettiStage(width: 1512, height: 982, notch: notch, menuBarBottom: 32, icon: icon, floor: 912,
                      windows: windows, dockSpan: 378...1134)
    }

    static let claude = ConfettiView.look(.provider, tint: ProviderStyle.style(for: "claude").accent,
                                          provider: "claude")

    static func recipe(_ origin: ConfettiOrigin, _ landing: ConfettiLanding, look: ConfettiLook = claude,
                       shapes: ConfettiShapes = .mixed) -> ConfettiBurst.Recipe {
        ConfettiBurst.Recipe(origin: origin, landing: landing, shapes: shapes, slotWeights: look.weights,
                             glyphs: look.glyphs.count)
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the confetti frames"))
    func everyOriginAndLanding() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for origin in ConfettiOrigin.allCases {
            for landing in ConfettiLanding.allCases {
                let burst = ConfettiBurst(stage: Self.laptop(), recipe: Self.recipe(origin, landing), seed: 7)
                var frames: [CGImage] = []
                for time in Self.times {
                    let image = try render(burst, look: Self.claude, at: time, scale: 1)
                    frames.append(image)
                    try write(image, "confetti-\(origin.rawValue)-\(landing.rawValue)-\(Self.stamp(time))")
                    print(Self.metrics(burst, at: time, name: "\(origin.rawValue)/\(landing.rawValue) \(time) s"))
                }
                try write(Self.sheet(frames, columns: 3), "sheet-\(origin.rawValue)-\(landing.rawValue)")
            }
        }
    }

    /// Rest with two windows open: the pieces come to lie along their
    /// top edges (and the Dock's, between them).
    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the confetti frames"))
    func restOnWindows() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let windows = [CGRect(x: 120, y: 260, width: 640, height: 520), CGRect(x: 820, y: 420, width: 560, height: 420)]
        let burst = ConfettiBurst(stage: Self.laptop(windows: windows), recipe: Self.recipe(.notch, .rest), seed: 7)
        var frames: [CGImage] = []
        for time in Self.times {
            let image = try render(burst, look: Self.claude, at: time, scale: 1)
            frames.append(image)
            print(Self.metrics(burst, at: time, name: "rest on windows \(time) s"))
        }
        try write(Self.sheet(frames, columns: 3), "sheet-rest-on-windows")
        try write(try render(burst, look: Self.claude, at: 2.4, scale: 2), "confetti-rest-on-windows-2.4-2x")
        // A maximised window in front of a smaller one: no ledge of its
        // own, and the edge behind it is hidden, so pieces fall past its
        // content to the Dock.
        let maximised = [CGRect(x: 0, y: 38, width: 1512, height: 874), CGRect(x: 200, y: 300, width: 800, height: 500)]
        let behind = ConfettiBurst(stage: Self.laptop(windows: maximised), recipe: Self.recipe(.notch, .rest), seed: 7)
        let stills = try [1.2, 2.4, 3.6].map { try render(behind, look: Self.claude, at: $0, scale: 1) }
        try write(Self.sheet(stills, columns: 3), "sheet-rest-maximised")
    }

    /// The first beats at 2×, where the pop at the lip and the paper's
    /// light can be looked at closely.
    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the confetti frames"))
    func closeUps() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let burst = ConfettiBurst(stage: Self.laptop(), recipe: Self.recipe(.notch, .fall), seed: 7)
        for time in [0.08, 0.25, 0.6] {
            try write(try render(burst, look: Self.claude, at: time, scale: 2), "confetti-notch-\(Self.stamp(time))-2x")
        }
        let icon = ConfettiBurst(stage: Self.laptop(), recipe: Self.recipe(.icon, .fall), seed: 7)
        try write(try render(icon, look: Self.claude, at: 0.12, scale: 2), "confetti-icon-0.12-2x")
    }

    /// Reduce Motion: a glow at the lip, nothing crossing the screen.
    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the confetti frames"))
    func reduceMotion() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for origin in [ConfettiOrigin.notch, .icon] {
            let burst = ConfettiBurst(stage: Self.laptop(), recipe: Self.recipe(origin, .rest), seed: 7)
            for time in [0.2, 0.5] {
                let image = try render(burst, look: Self.claude, at: time, scale: 1, flash: true)
                try write(image, "confetti-reduce-motion-\(origin.rawValue)-\(Self.stamp(time))")
            }
        }
    }

    /// Other displays: a notchless 1080p (the menu bar's bottom centre is
    /// the lip) and an ultrawide, where the reach scales with the width.
    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the confetti frames"))
    func otherDisplays() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let displays: [(String, ConfettiStage)] = [
            ("1920x1080", ConfettiStage(width: 1920, height: 1080, notch: nil, menuBarBottom: 24, icon: nil,
                                        floor: 1010)),
            ("3440x1440", ConfettiStage(width: 3440, height: 1440, notch: nil, menuBarBottom: 24, icon: nil,
                                        floor: 1370)),
        ]
        for (name, stage) in displays {
            let burst = ConfettiBurst(stage: stage, recipe: Self.recipe(.notch, .fall), seed: 7)
            var frames: [CGImage] = []
            for time in [0.25, 0.6, 1.2, 2.4] {
                frames.append(try render(burst, look: Self.claude, at: time, scale: 0.5))
                print(Self.metrics(burst, at: time, name: "\(name) \(time) s"))
            }
            try write(Self.sheet(frames, columns: 2), "sheet-\(name)")
        }
    }

    /// Each palette and shape set in the card's preview tile, still.
    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write the confetti frames"))
    func palettesAndShapes() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let everyone = ["claude", "codex", "gemini"].map { (id: $0, color: ProviderStyle.style(for: $0).accent) }
        var tiles: [CGImage] = []
        for palette in ConfettiPalette.allCases {
            var settings = ConfettiSettings(enabled: true)
            settings.palette = palette
            let tile = ConfettiProofTile(settings: settings, everyone: everyone)
            tiles.append(try image(of: tile.frame(width: 420, height: 140), scale: 2))
        }
        for shapes in ConfettiShapes.allCases {
            var settings = ConfettiSettings(enabled: true)
            settings.shapes = shapes
            let tile = ConfettiProofTile(settings: settings, everyone: everyone)
            tiles.append(try image(of: tile.frame(width: 420, height: 140), scale: 2))
        }
        try write(Self.sheet(tiles, columns: 3), "sheet-palettes-and-shapes")
    }

    // MARK: Drawing

    private func render(_ burst: ConfettiBurst, look: ConfettiLook, at time: Double, scale: CGFloat,
                        flash: Bool = false) throws -> CGImage {
        var view = ConfettiView(burst: burst, look: look, flash: flash)
        view.frozen = time
        let stage = burst.stage
        let scene = ZStack(alignment: .topLeading) {
            ConfettiProofDesk(stage: stage)
            view.frame(width: stage.width, height: stage.height)
            ConfettiProofHole(stage: stage)
        }
        .frame(width: stage.width, height: stage.height)
        return try image(of: scene, scale: scale)
    }

    private func image(of view: some View, scale: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return try #require(renderer.cgImage)
    }

    private func write(_ image: CGImage, _ name: String) throws {
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent(name + ".png"))
    }

    static func stamp(_ time: Double) -> String { String(format: "%.2f", time) }

    /// Frames side by side, `columns` to a row, on a dark ground.
    static func sheet(_ frames: [CGImage], columns: Int) -> CGImage {
        let width = frames.map(\.width).max() ?? 1
        let height = frames.map(\.height).max() ?? 1
        let rows = (frames.count + columns - 1) / columns
        let gap = 8
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: columns * width + (columns - 1) * gap,
                                height: rows * height + (rows - 1) * gap, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(gray: 0.05, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: context?.width ?? 0, height: context?.height ?? 0))
        for (index, frame) in frames.enumerated() {
            let column = index % columns, row = index / columns
            let y = (context?.height ?? 0) - (row + 1) * height - row * gap
            context?.draw(frame, in: CGRect(x: column * (width + gap), y: y, width: frame.width, height: frame.height))
        }
        return context?.makeImage() ?? frames[0]
    }

    /// The numbers printed with each frame.
    static func metrics(_ burst: ConfettiBurst, at time: Double, name: String) -> String {
        var launched = 0, hidden = 0, far = 0
        var xs: [Double] = []
        var ys: [Double] = []
        for index in burst.pieces.indices {
            guard let frame = burst.frame(of: index, at: time) else { continue }
            launched += 1
            xs.append(frame.x)
            if frame.opacity > 0.05, frame.y >= 0, frame.y <= burst.stage.height { ys.append(frame.y) }
            if burst.pieces[index].far { far += 1 }
            if let notch = burst.stage.notch, notch.contains(CGPoint(x: frame.x, y: frame.y)) { hidden += 1 }
        }
        xs.sort()
        let spread = xs.count < 2 ? 0
            : (xs[Int(Double(xs.count - 1) * 0.95)] - xs[Int(Double(xs.count - 1) * 0.05)]) / burst.stage.width
        ys.sort()
        let depth = ys.count < 2 ? 0
            : (ys[Int(Double(ys.count - 1) * 0.95)] - ys[Int(Double(ys.count - 1) * 0.05)]) / burst.stage.height
        let hiddenShare = launched == 0 ? 0 : Double(hidden) / Double(launched)
        return String(format: "confetti proof %@: %d pieces, %.0f%% in the notch, spread %.0f%% of the width, "
                      + "%.0f%% of the height (%d on screen), %d far",
                      name, launched, hiddenShare * 100, spread * 100, depth * 100, ys.count, far)
    }
}

/// The proof's desktop: a night gradient, the other windows (a light
/// body under a title bar), and the menu bar strip.
struct ConfettiProofDesk: View {
    let stage: ConfettiStage

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.13, green: 0.17, blue: 0.30), Color(red: 0.36, green: 0.27, blue: 0.42)],
                           startPoint: .top, endPoint: .bottom)
            // Back to front: the list runs front to back.
            ForEach(Array(stage.windows.enumerated().reversed()), id: \.offset) { _, window in
                ConfettiProofWindow()
                    .frame(width: window.width, height: window.height)
                    .offset(x: window.minX, y: window.minY)
            }
            Rectangle().fill(Color.black.opacity(0.3)).frame(width: stage.width, height: stage.menuBarBottom)
            if stage.floor < stage.height {
                // The Dock, where the stage says it runs (else the middle half).
                let span = stage.dockSpan ?? (stage.width * 0.25)...(stage.width * 0.75)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.16))
                    .frame(width: span.upperBound - span.lowerBound, height: stage.height - stage.floor - 6)
                    .offset(x: span.lowerBound, y: stage.floor + 2)
            }
        }
        .frame(width: stage.width, height: stage.height, alignment: .topLeading)
    }
}

private struct ConfettiProofWindow: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(white: 0.93))
            .overlay(alignment: .top) {
                Rectangle().fill(Color(white: 0.84)).frame(height: 28)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

/// The notch, drawn over everything: on real hardware it is a hole.
struct ConfettiProofHole: View {
    let stage: ConfettiStage

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let notch = stage.notch {
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                    .fill(.black)
                    .frame(width: notch.width, height: notch.height)
                    .offset(x: notch.minX)
            }
        }
        .frame(width: stage.width, height: stage.height, alignment: .topLeading)
    }
}

/// The card's preview tile, frozen on its resting frame, for a palette
/// or shape set — the tile itself, as the card draws it.
private struct ConfettiProofTile: View {
    let settings: ConfettiSettings
    let everyone: [(id: String, color: Color)]

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ConfettiPreviewTile(settings: settings,
                                shot: ConfettiShot(provider: "claude", tint: ProviderStyle.style(for: "claude").accent),
                                everyone: everyone)
            Text("\(settings.palette.rawValue) · \(settings.shapes.rawValue)")
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(0.7))
                .padding(6)
        }
    }
}
