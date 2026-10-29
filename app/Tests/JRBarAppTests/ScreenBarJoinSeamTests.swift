import JRBarTestSupport
import AppKit
import SwiftUI
import Testing
import JRBarCore
import JRBarLEDS
import JRBarUI
@testable import JRBarApp

@MainActor
@Suite("Notch panel join", .renderProofAppearance)
struct ScreenBarJoinSeamTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    private enum Surface: String, CaseIterable {
        case island, wings, joined
    }

    private struct HostedBar: NSViewRepresentable {
        let bar: ScreenBarView
        func makeNSView(context: Context) -> ScreenBarView { bar }
        func updateNSView(_ nsView: ScreenBarView, context: Context) {}
    }

    @Test("the black island and wings leave no bright inner seam",
          .enabled(if: enabled), arguments: [1.0, 2.0])
    func opaqueJoin(scale: Double) throws {
        let size = CGSize(width: 480, height: 100)
        let silhouette = NotchSilhouette(notchDepth: 32, restingRadius: 8, notchWidth: 186)
        var cells: [ProofCell] = []
        var census = "surface,offset,scale,left_peak,right_peak\n"
        for offset: CGFloat in [0, 0.25, 0.5, 0.75] {
            let island = CGRect(x: 147 + offset, y: 68, width: 186, height: 32)
            for surface in Surface.allCases {
                let bar = ScreenBarView(frame: CGRect(origin: .zero, size: size))
                bar.updateLayout {
                    bar.wingGeometry = ScreenBarWingGeometry(notchWidth: 186, notchDepth: 32,
                        bandSpan: 480, leftExtent: 132, rightExtent: 132)
                    bar.islandFrame = island
                    bar.wings = ScreenBarWings(left: ScreenBarWingSlot(text: "Left", provider: "codex"),
                        right: ScreenBarWingSlot(text: "Right", symbol: "circle.fill"))
                }
                bar.display(colors: Array(repeating: RGB(r: 0, g: 0, b: 0), count: 8))
                let scene = ZStack(alignment: .topLeading) {
                    Color(white: 0.75)
                    if surface != .wings {
                        silhouette.fill(.black).clipShape(silhouette)
                            .frame(width: island.width, height: island.height)
                            .position(x: island.midX, y: size.height - island.midY)
                    }
                    if surface != .island {
                        HostedBar(bar: bar).frame(width: size.width, height: size.height)
                    }
                }
                let bitmap = try ProofRender.render(scene, size: size, scale: scale, settle: 0.03)
                func peak(at edge: CGFloat) -> CGFloat {
                    var peak: CGFloat = 0
                    for y in Int(3 * scale)..<Int(20 * scale) {
                        for x in Int(floor((edge - 1) * scale))...Int(ceil((edge + 1) * scale)) {
                            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                                peak = max(peak, color.redComponent, color.greenComponent, color.blueComponent)
                            }
                        }
                    }
                    return peak
                }
                let left = peak(at: island.minX)
                let right = peak(at: island.maxX)
                census += "\(surface.rawValue),\(offset),\(scale),\(left),\(right)\n"
                if surface == .joined {
                    #expect(left < 0.02, "The left inner join must stay black at offset \(offset)")
                    #expect(right < 0.02, "The right inner join must stay black at offset \(offset)")
                }
                cells.append(ProofCell(label: "\(surface.rawValue) offset \(offset)", bitmap: bitmap))
            }
        }
        try ProofContactSheet.write(cells, columns: 3, title: "Black panel join, \(Int(scale))x",
                                    name: "notch-join-census-\(Int(scale))x")
        try census.write(to: ProofRender.directory.appendingPathComponent("notch-join-census-\(Int(scale))x.csv"),
                         atomically: true, encoding: .utf8)
    }
}
