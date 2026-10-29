import JRBarTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// Frame-by-frame render proof of the island's motion. The real
/// `NotchIslandView` is hosted, the frame spring is read at fixed times
/// (no clock runs), and each frame is drawn the way the window would
/// draw it: the shape at the spring's size on its stage, the card's
/// openness read off the shape's travel. The frames are tiled into one
/// contact sheet per move so a person can judge the choreography the way
/// it plays: the shape first, the sheet coming into focus as it grows,
/// the rows cascading, the edge light arriving last, and the fold taking
/// it all back. Off by default; set `JRBAR_RENDER_PROOF=1` to write
/// `notch-motion-*.png` into `JRBAR_RENDER_PROOF_DIR`.
@Suite("Notch motion render proof", .renderProofAppearance)
@MainActor
struct NotchMotionRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    private static let openTimes: [Double] = [0, 0.02, 0.04, 0.06, 0.08, 0.10, 0.13, 0.16, 0.20, 0.25, 0.32, 0.45]
    private static let closeTimes: [Double] = [0, 0.015, 0.03, 0.045, 0.06, 0.08, 0.10, 0.13, 0.16, 0.20, 0.26, 0.35]

    /// One move, rendered at each of `times`.
    private func frames(opening: Bool, times: [Double], mid: Bool = false, wideRest: Bool = false) throws -> [ProofCell] {
        let (toy, store, monitor) = NotchSurfaceRenderProofTests.makeToy()
        defer { withExtendedLifetime(store) {} }
        let model = toy.cardModel
        NotchSurfaceRenderProofTests.fill(model, monitor: monitor)
        defer { NotchSurfaceRenderProofTests.clearTray(model) }
        let depth = max(toy.notchDepth, 32)
        let slot = NotchSurfaceRenderProofTests.slotWidth
        let width = NotchIslandLayout.expandedWidth(slotWidth: slot)
        let probe = NSHostingView(rootView: NotchCardView(model: model, style: .island, width: width))
        probe.layoutSubtreeIfNeeded()
        let height = toy.cardTopPad + ceil(probe.fittingSize.height)
        toy.expand(held: true)
        toy.stage.cardHeight = height

        let idle = CGRect(x: 0, y: 0, width: wideRest ? width + 80 : slot, height: depth)
        let card = CGRect(x: 0, y: 0, width: width, height: height)
        let morph = NotchMorph(rest: idle.height, open: card.height,
                               restWidth: idle.width, openWidth: card.width)
        let stageSize = CGSize(width: max(width, idle.width) + 24, height: height + 14)
        let canvas = CGSize(width: stageSize.width + 40, height: stageSize.height + 16)

        var spring = NotchFrameSpring(at: opening ? idle : card)
        spring.retarget(opening ? card : idle,
                        motion: NotchMotion.frameMotion(from: spring.frame, to: opening ? card : idle))
        var elapsed = 0.0
        var cells: [ProofCell] = []
        for t in times {
            spring.integrate(dt: t - elapsed)
            elapsed = t
            let shape = spring.frame
            let openness = morph.openness(size: shape.size)
            toy.stage.shape = CGRect(x: (stageSize.width - shape.width) / 2, y: 0,
                                     width: shape.width, height: shape.height)
            toy.stage.setOpenness(openness, expanded: true)
            toy.stage.showContent(level: NotchReveal.sheet(openness: openness).opacity, expanded: true)
            let scene = ZStack(alignment: .top) {
                ProofDesktop(dark: true)
                Rectangle().fill(Color.black.opacity(0.22)).frame(height: depth)
                UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8, style: .continuous)
                    .fill(.black)
                    .frame(width: slot, height: depth)
                NotchIslandView(toy: toy).frame(width: stageSize.width, height: stageSize.height)
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .top)
            let bitmap = try ProofRender.render(scene, size: canvas, scale: 1.5, settle: 0.1)
            cells.append(ProofCell(label: String(format: "t %3d ms   h %3.0f   open %.2f",
                                            Int((t * 1000).rounded()), shape.height, openness),
                              bitmap: bitmap))
        }
        toy.stage.shape = nil
        return cells
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func openFrames() throws {
        let cells = try frames(opening: true, times: Self.openTimes)
        try ProofContactSheet.write(cells, columns: 4, title: "OPEN  spring 0.42 / 0.78, read at fixed times",
                  name: "notch-motion-open")
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func closeFrames() throws {
        let cells = try frames(opening: false, times: Self.closeTimes)
        try ProofContactSheet.write(cells, columns: 4, title: "CLOSE  spring 0.23 / 0.95, read at fixed times",
                  name: "notch-motion-close")
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write PNGs"))
    func wideRestCloseFrames() throws {
        let cells = try frames(opening: false, times: Self.closeTimes, wideRest: true)
        try ProofContactSheet.write(cells, columns: 4, title: "CLOSE to wider shoulders, read at fixed times",
                  name: "notch-motion-wide-rest-close")
    }
}


struct ProofCell {
    var label: String
    var bitmap: NSBitmapImageRep
}

@MainActor
enum ProofContactSheet {
    /// Tile `cells` into one sheet, `columns` across, each captioned.
    static func write(_ cells: [ProofCell], columns: Int, title: String, name: String,
                      footer: NSBitmapImageRep? = nil) throws {
        let first = try #require(cells.first)
        let cellW = first.bitmap.pixelsWide
        let cellH = first.bitmap.pixelsHigh
        let caption = 34
        let rows = (cells.count + columns - 1) / columns
        let titleBar = 44
        let width = cellW * columns
        let footerHeight = footer?.pixelsHigh ?? 0
        let height = titleBar + (cellH + caption) * rows + footerHeight
        let sheet = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: sheet))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: 0.07, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .regular),
            .foregroundColor: NSColor(white: 0.85, alpha: 1),
        ]
        (title as NSString).draw(at: NSPoint(x: 14, y: height - 34), withAttributes: attributes)
        for (index, cell) in cells.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = column * cellW
            let top = titleBar + row * (cellH + caption)
            let y = height - top - cellH
            cell.bitmap.draw(in: NSRect(x: x, y: y, width: cellW, height: cellH))
            (cell.label as NSString).draw(at: NSPoint(x: x + 10, y: y - 26), withAttributes: attributes)
        }
        if let footer {
            footer.draw(in: NSRect(x: 0, y: 0, width: min(width, footer.pixelsWide), height: footerHeight))
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(sheet.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: ProofRender.directory, withIntermediateDirectories: true)
        try png.write(to: ProofRender.directory.appendingPathComponent("\(name).png"))
    }


}
