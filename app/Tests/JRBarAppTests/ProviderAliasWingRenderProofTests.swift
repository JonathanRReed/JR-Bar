import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore
@testable import JRBarUI

@Suite("Provider alias wings render proof", .serialized)
@MainActor
struct ProviderAliasWingRenderProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write wing PNGs"))
    func allProvidersInLightDarkAndBlue() throws {
        let providers = ProviderStyle.table.keys.sorted() + ["unknown-driver"]
        for dark in [false, true] {
            for blue in [false, true] {
                let sheet = VStack(spacing: 6) {
                    ForEach(providers, id: \.self) { provider in
                        row(provider, dark: dark, blue: blue)
                    }
                }
                .padding(16)
                .background(dark ? Color(white: 0.17) : Color(white: 0.93))
                let renderer = ImageRenderer(content: sheet.environment(\.colorScheme, dark ? .dark : .light))
                renderer.scale = 2
                let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
                let name = "provider-alias-wings-\(dark ? "dark" : "light")-\(blue ? "blue" : "default").png"
                try png.write(to: ProofRender.directory.appendingPathComponent(name))
            }
        }
    }

    private func row(_ provider: String, dark: Bool, blue: Bool) -> some View {
        let base = ProviderStyle.style(for: provider)
        let style = ProviderStyle(id: base.id, name: base.name, accentHex: blue ? "#007AFF" : base.accentHex,
                                  glyph: base.glyph, fallback: base.fallback)
        return HStack(spacing: 14) {
            Text(base.name).font(.system(size: 12)).frame(width: 96, alignment: .leading)
            NotchProviderTile(style: style, size: 22)
            ProviderLogoTile(provider: provider, accent: blue ? .blue : nil)
            // The wing mark uses the same style resolver at its existing 13 pt size.
            mark(style).frame(width: 36, height: 36).background(.black, in: RoundedRectangle(cornerRadius: 8))
            ProviderMarkRenderProofTests.ears(provider).frame(width: 500, height: 48)
        }
        .foregroundStyle(dark ? .white : .black)
    }

    @ViewBuilder private func mark(_ style: ProviderStyle) -> some View {
        switch style.mark {
        case .logo(let logo):
            ProviderLogoMark(logo: logo, size: 13).foregroundStyle(style.markInk(on: .black))
        case .symbol(let symbol):
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.gray)
        case .text(let text):
            Text(text).font(.system(size: 13)).foregroundStyle(style.markInk(on: .black))
        }
    }
}
