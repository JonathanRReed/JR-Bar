import JRBarTestSupport
import AppKit
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// Render proof for the island's outline against the hardware's: each
/// face is drawn over a menu bar and a notch the size a 14-inch
/// MacBook Pro reports (185 x 32 pt), once as it reads on screen (pure
/// black on pure black) and once x-rayed, the island in red at half
/// strength so a gap, a seam or an overhang against the hardware shows.
/// Off by default; `JRBAR_RENDER_PROOF=1` writes `notch-silhouette-*.png`
/// into `JRBAR_RENDER_PROOF_DIR`.
@Suite("Notch silhouette render proof", .renderProofAppearance)
@MainActor
struct NotchSilhouetteRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    private static let hardwareWidth: CGFloat = 185
    private static let depth: CGFloat = 32

    /// The real notch: a black rectangle with the bottom corners rounded
    /// at the measured radius and the top corners flaring outward.
    private struct Hardware: View {
        var body: some View {
            let notch = NotchSilhouette(notchDepth: NotchSilhouetteRenderProofTests.depth,
                                        restingRadius: 8,
                                        notchWidth: NotchSilhouetteRenderProofTests.hardwareWidth - 8)
            notch.fill(.black)
                .frame(width: NotchSilhouetteRenderProofTests.hardwareWidth,
                       height: NotchSilhouetteRenderProofTests.depth)
        }
    }

    private struct Scene: View {
        var face: CGSize
        var xray: Bool
        var light: Bool
        var width: CGFloat

        var body: some View {
            let depth = NotchSilhouetteRenderProofTests.depth
            let island = NotchSilhouette(notchDepth: depth, restingRadius: 8, notchWidth: 186)
            let wallpaper = LinearGradient(
                colors: light ? [Color(red: 0.86, green: 0.9, blue: 0.97), Color(red: 0.97, green: 0.93, blue: 0.86)]
                              : [Color(red: 0.12, green: 0.14, blue: 0.2), Color(red: 0.2, green: 0.12, blue: 0.2)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            let barFill = light ? Color.white.opacity(0.55) : Color.white.opacity(0.1)
            let ink = light ? Color.black.opacity(0.8) : Color.white.opacity(0.85)
            ZStack(alignment: .top) {
                wallpaper
                barFill.frame(height: 33).frame(maxHeight: .infinity, alignment: .top)
                HStack {
                    Text("Finder  File  Edit  View").font(.system(size: 13)).foregroundStyle(ink)
                    Spacer()
                    Text("Wi-Fi  Tue 9:41").font(.system(size: 13)).foregroundStyle(ink)
                }
                .padding(.horizontal, 12)
                .frame(height: 24)
                Hardware()
                island.fill(xray ? Color.red.opacity(0.5) : Color.black)
                    .frame(width: face.width, height: face.height)
            }
            .frame(width: width, height: 230, alignment: .top)
            .clipped()
        }
    }

    private static let faces: [(name: String, size: CGSize)] = [
        ("bare", CGSize(width: 186, height: 32)),
        ("shoulders", CGSize(width: 206, height: 32)),
        ("notice", CGSize(width: 262, height: 58)),
        ("midmorph", CGSize(width: 300, height: 110)),
        ("card", CGSize(width: 340, height: 190)),
    ]

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func everyFaceAgainstTheHardware() throws {
        for (name, size) in Self.faces {
            for light in [true, false] {
                let view = HStack(spacing: 0) {
                    Scene(face: size, xray: false, light: light, width: 360)
                    Scene(face: size, xray: true, light: light, width: 360)
                }
                try ProofRender.write(view, size: CGSize(width: 720, height: 230),
                                      name: "notch-silhouette-\(name)-\(light ? "light" : "dark")",
                                      dark: !light, scale: 3, settle: 0.02)
            }
        }
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func theBareHousingAtOneTimesToo() throws {
        let view = HStack(spacing: 0) {
            Scene(face: CGSize(width: 186, height: 32), xray: false, light: true, width: 360)
            Scene(face: CGSize(width: 186, height: 32), xray: true, light: true, width: 360)
        }
        try ProofRender.write(view, size: CGSize(width: 720, height: 230),
                              name: "notch-silhouette-bare-1x", dark: false, scale: 1, settle: 0.02)
    }
}
