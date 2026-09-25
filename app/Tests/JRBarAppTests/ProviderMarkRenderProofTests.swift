import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore
@testable import JRBarUI

/// Render proof for the provider marks, every provider on every surface
/// that draws one, so a person can check each reads from 12 pt up in
/// light and dark: the tile at the sizes its 33 call sites use, the bare
/// mark in its ink, the Screen Bar ear on black (the quota ring and the
/// bare mark), the Overview graph's orbs, a confetti fleck, and the
/// menu-bar strip (`StatusItemController.renderStyles`). Off by default;
/// set `JRBAR_RENDER_PROOF=1` to write `provider-marks-*.png` and the
/// menu-bar styles into `JRBAR_RENDER_PROOF_DIR` (default
/// `/tmp/jrbar-audit`).
@Suite("Provider mark render proof")
@MainActor
struct ProviderMarkRenderProofTests {
    static let providers = SettingsKey.providers + ["openai-api", "t3code", "jrbar", "mystery"]

    private var dir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/jrbar-audit",
            isDirectory: true)
    }

    private func write(_ view: some View, _ name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write provider-marks PNGs"))
    func snapshots() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .dark ? "dark" : "light"
            try write(ProviderMarkSheet(providers: Self.providers).environment(\.colorScheme, scheme),
                      "provider-marks-\(name)")
        }
        try write(ProviderMarkSurfaces(providers: Self.providers), "provider-marks-surfaces")
        try write(VStack(spacing: 0) {
            ForEach(Self.providers, id: \.self) { provider in Self.ears(provider) }
        }, "provider-marks-screenbar-ears")
        StatusItemController.renderStyles(to: dir.appendingPathComponent("provider-marks-menubar").path)
    }

    /// The Screen Bar's own ears round a 185 pt bezel, as the notch proof
    /// draws them: the bare 13 pt mark on the left, the 16 pt quota ring
    /// with its 8 pt mark on the right.
    static func ears(_ provider: String) -> some View {
        let size = NSSize(width: 500, height: 48)
        let depth: CGFloat = 32 + ScreenBarGeometry.wingEarDrop
        let leftRect = CGRect(x: 157.5 - 36, y: size.height - depth, width: 36, height: depth)
        let rightRect = CGRect(x: 342.5, y: size.height - depth, width: 36, height: depth)
        let model = ScreenBarWingsModel()
        model.viewHeight = size.height
        model.notchCorner = NotchProfile.standardCornerRadius
        model.tray = CGRect(x: leftRect.minX, y: size.height - depth, width: rightRect.maxX - leftRect.minX,
                            height: depth)
        model.left = (ScreenBarWingSlot(text: "Working", provider: provider), leftRect)
        model.right = (ScreenBarWingSlot(text: "72%", provider: provider, meter: 0.72), rightRect)
        return ZStack(alignment: .top) {
            Color(white: 0.24)
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 8, bottomTrailingRadius: 8,
                                   topTrailingRadius: 0, style: .continuous)
                .fill(.black)
                .frame(width: 185, height: 32)
            ScreenBarWingsView(model: model)
            Text(ProviderStyle.style(for: provider).name).font(.system(size: 10)).foregroundStyle(.white)
                .frame(width: 185, height: 32)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
    }
}

/// One row per provider: the tile at every size in use, then the bare
/// mark in the tile's ink at 8–24 pt.
private struct ProviderMarkSheet: View {
    let providers: [String]
    @Environment(\.colorScheme) private var colorScheme
    static let tiles: [CGFloat] = [14, 16, 18, 20, 22, 24, 26, 30, 32]
    static let bare: [CGFloat] = [8, 10, 12, 16, 24]

    var body: some View {
        let dark = colorScheme == .dark
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(dark ? "Dark" : "Light").font(.system(size: 13, weight: .semibold)).frame(width: 96, alignment: .leading)
                ForEach(Self.tiles, id: \.self) { side in
                    Text("\(Int(side))").font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 32)
                }
                ForEach(Self.bare, id: \.self) { side in
                    Text("\(Int(side))").font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 26)
                }
            }
            ForEach(providers, id: \.self) { provider in
                let style = ProviderStyle.style(for: provider)
                HStack(spacing: 10) {
                    Text(style.name).font(.system(size: 12)).frame(width: 96, alignment: .leading)
                    ForEach(Self.tiles, id: \.self) { side in
                        ProviderTile(style: style, size: side).frame(width: 32)
                    }
                    ForEach(Self.bare, id: \.self) { side in
                        mark(style, side: side).frame(width: 26)
                    }
                }
            }
        }
        .padding(16)
        .background(dark ? Color(white: 0.17) : Color(white: 0.93))
    }

    @ViewBuilder
    private func mark(_ style: ProviderStyle, side: CGFloat) -> some View {
        switch style.mark {
        case .logo(let logo):
            ProviderLogoMark(logo: logo, size: side).foregroundStyle(style.markInk(dark: colorScheme == .dark))
        case .symbol(let name):
            Image(systemName: name).font(.system(size: side, weight: .semibold))
        case .text(let text):
            Text(text).font(.system(size: side, weight: .semibold))
        }
    }
}

/// The marks where they sit on black and on orbs: the ear's 16 pt quota
/// ring with its 8 pt mark and the 13 pt bare mark, the graph's hub orb
/// (60 pt, 25 pt white mark), a live session orb (36 pt, 15 pt white) and
/// a pale one (15 pt ink), and a confetti fleck at 14 pt.
private struct ProviderMarkSurfaces: View {
    let providers: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(providers, id: \.self) { provider in
                let style = ProviderStyle.style(for: provider)
                HStack(spacing: 14) {
                    Text(style.name).font(.system(size: 12)).foregroundStyle(.white).frame(width: 96, alignment: .leading)
                    ear(style)
                    orb(style, diameter: 60, side: 25, lit: true)
                    orb(style, diameter: 36, side: 15, lit: true)
                    orb(style, diameter: 36, side: 15, lit: false)
                    fleck(style)
                }
            }
        }
        .padding(16)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private func logo(_ style: ProviderStyle) -> ProviderLogo? {
        if case .logo(let logo) = style.mark { return logo }
        return nil
    }

    @ViewBuilder
    private func ear(_ style: ProviderStyle) -> some View {
        let ink = style.markInk(on: .black)
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(.white.opacity(0.22), lineWidth: 1.4)
                Circle().trim(from: 0, to: 0.62).stroke(style.accent, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if let logo = logo(style) { ProviderLogoMark(logo: logo, size: 8).foregroundStyle(ink) }
            }
            .frame(width: 16, height: 16)
            if let logo = logo(style) { ProviderLogoMark(logo: logo, size: 13).foregroundStyle(ink) }
        }
        .frame(width: 44, height: 24)
    }

    @ViewBuilder
    private func orb(_ style: ProviderStyle, diameter: CGFloat, side: CGFloat, lit: Bool) -> some View {
        ZStack {
            if lit {
                Circle().fill(RadialGradient(colors: [style.accent.mix(with: .white, by: 0.3), style.accent,
                                                      style.accent.mix(with: .black, by: 0.18)],
                                             center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0,
                                             endRadius: diameter * 0.75))
            } else {
                Circle().fill(style.accent.opacity(0.2))
                Circle().stroke(style.accent.opacity(0.28), lineWidth: 0.75)
            }
            if let logo = logo(style) {
                if lit {
                    ProviderLogoMark(logo: logo, size: side).foregroundStyle(.black.opacity(0.18)).offset(y: 0.5)
                    ProviderLogoMark(logo: logo, size: side).foregroundStyle(.white)
                } else {
                    ProviderLogoMark(logo: logo, size: side).foregroundStyle(style.markInk(dark: true))
                }
            }
        }
        .frame(width: diameter, height: diameter)
    }

    @ViewBuilder
    private func fleck(_ style: ProviderStyle) -> some View {
        let glyph = ConfettiView.glyph(for: style.id) ?? .symbol("star.fill")
        Canvas { context, size in
            let marks = ConfettiView.resolve([glyph], in: context)
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.rotate(by: .degrees(-18))
            switch marks[0] {
            case .path(let path):
                context.scaleBy(x: 14, y: 14)
                context.fill(path, with: .color(style.accent))
            case .text(let text):
                context.scaleBy(x: 14 / 13, y: 14 / 13)
                context.draw(text, at: .zero, anchor: .center)
            }
        }
        .frame(width: 24, height: 24)
    }
}
