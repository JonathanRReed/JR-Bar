import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// Draws a filmstrip's samples: the real `NotchIslandView` at each
/// sampled size, tiled into one contact sheet per scenario with the
/// curves under it, plus the CSV. Only runs with `JRBAR_RENDER_PROOF=1`
/// (`JRBAR_RENDER_PROOF_DIR` names the folder).
@MainActor
enum NotchFilmstripRender {
    static let columns = 4
    static let frames = 16

    /// The card measured the way the window measures it, so the numbers
    /// and the pictures share one geometry.
    static func geometry() -> NotchFilmstrip.Geometry {
        var geometry = NotchFilmstrip.Geometry.standard()
        let (toy, store, monitor) = NotchSurfaceRenderProofTests.makeToy()
        defer { withExtendedLifetime(store) {} }
        NotchSurfaceRenderProofTests.fill(toy.cardModel, monitor: monitor)
        defer { NotchSurfaceRenderProofTests.clearTray(toy.cardModel) }
        let width = NotchIslandLayout.expandedWidth(slotWidth: geometry.slot)
        let probe = NSHostingView(rootView: NotchCardView(model: toy.cardModel, style: .island, width: width))
        probe.layoutSubtreeIfNeeded()
        geometry.card = CGSize(width: width, height: toy.cardTopPad + ceil(probe.fittingSize.height))
        geometry.ask = NotchIslandLayout.askSize(slotWidth: geometry.slot, notchDepth: geometry.depth,
                                                 summaryLines: toy.askSummaryLines, takeover: false)
        return geometry
    }

    private static let askNotice: AlcoveNotice = {
        let ask = CoreAsk(session: "claude:ask", openedAt: Date().timeIntervalSince1970 - 190,
                          summary: "Run the migration against the staging database?",
                          answerable: true, request: "r1", preview: "make migrate ENV=staging")
        return AlcoveNotice(id: "a", kind: .ask, title: "Claude · rename-the-fish",
                            subtitle: "needs you", provider: "claude", session: "claude:ask",
                            key: "ask:claude:ask|r1", ask: ask)
    }()

    private static let doneNotice = AlcoveNotice(id: "c", kind: .completed, title: "Claude",
                                                 subtitle: "rename-the-fish finished",
                                                 provider: "claude", key: "c")

    /// One scenario: the contact sheet, the CSV at the sheet's moments
    /// and the dense CSV at every 1/120 s.
    static func write(_ script: NotchFilmstrip.Script, film: NotchFilmstrip, outputName: String) throws {
        let dense = film.play(script)
        let picks = film.film(script, count: frames)
        let cells = try render(script, picks: picks, geometry: film.geometry)
        let footer = try plot(dense, script: script, width: cells[0].bitmap.pixelsWide * columns)
        try ProofContactSheet.write(cells, columns: columns, title: script.title,
                                    name: outputName, footer: footer)
        let directory = ProofRender.directory
        try NotchFilmstrip.csv(picks).write(to: directory.appendingPathComponent("\(outputName).csv"),
                                            atomically: true, encoding: .utf8)
        let every120 = stride(from: 0, to: dense.count, by: Int((1.0 / 120) / NotchFilmstrip.step))
            .map { dense[$0] }
        try NotchFilmstrip.csv(every120).write(to: directory.appendingPathComponent("\(outputName)-dense.csv"),
                                               atomically: true, encoding: .utf8)
    }

    // MARK: Cells

    private static func render(_ script: NotchFilmstrip.Script, picks: [NotchFilmstrip.Sample],
                               geometry: NotchFilmstrip.Geometry) throws -> [ProofCell] {
        // The strip scenarios need a quiet house (no ask or failure to take the right
        // shoulder from the track); the rest want the busy one.
        let quiet = CoreState(sessions: [
            CoreSession(id: "claude:1", provider: "claude", label: "review-patch", mode: "working"),
        ])
        let (toy, store, monitor) = NotchSurfaceRenderProofTests.makeToy(
            state: script.content == .trackSwap ? quiet : NotchSurfaceRenderProofTests.sessions())
        defer { withExtendedLifetime(store) {} }
        NotchSurfaceRenderProofTests.fill(toy.cardModel, monitor: monitor)
        defer { NotchSurfaceRenderProofTests.clearTray(toy.cardModel) }
        let depth = geometry.depth
        let slot = geometry.slot
        let widest = picks.map(\.size.width).max() ?? slot
        let tallest = picks.map(\.size.height).max() ?? depth
        let stageSize = CGSize(width: max(widest, script.start.width) + 24, height: tallest + 14)
        let canvas = CGSize(width: stageSize.width + 40, height: stageSize.height + 16)

        switch script.content {
        case .card:
            toy.expand(held: true)
            toy.stage.cardHeight = script.morph.open
            toy.stage.cardWidth = script.morph.openWidth
        case .notice:
            toy.activeCapsule = script.name.hasPrefix("ask") ? askNotice : doneNotice
            toy.stage.noticeMorph = script.morph
            toy.stage.showNotice(level: 0, shown: true)
        case .trackSwap, .hoverMarks:
            break
        }
        defer { toy.stage.shape = nil }

        func scene(size: CGSize) -> some View {
            ZStack(alignment: .top) {
                ProofDesktop(dark: true)
                Rectangle().fill(Color.black.opacity(0.22)).frame(height: depth)
                UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8, style: .continuous)
                    .fill(.black).frame(width: slot, height: depth)
                NotchIslandView(toy: toy).frame(width: stageSize.width, height: stageSize.height)
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .top)
        }

        var cells: [ProofCell] = []
        for sample in picks {
            toy.stage.shape = CGRect(x: (stageSize.width - sample.size.width) / 2, y: 0,
                                     width: sample.size.width, height: sample.size.height)
            if script.content == .card {
                toy.stage.setOpenness(sample.openness, expanded: true)
                toy.stage.showContent(level: sample.contentLevel, expanded: true)
            }
            if script.content == .notice {
                toy.stage.showNotice(level: sample.contentLevel, shown: toy.activeCapsule != nil)
            }
            var bitmap: NSBitmapImageRep
            if script.content == .trackSwap {
                toy.noteMedia(NotchSurfaceRenderProofTests.media())
                let old = try ProofRender.render(scene(size: sample.size), size: canvas, scale: 1.5, settle: 0.05)
                var next = NotchSurfaceRenderProofTests.media()
                next.title = "Midnight City (Remastered Live)"
                toy.noteMedia(next)
                let new = try ProofRender.render(scene(size: sample.size), size: canvas, scale: 1.5, settle: 0.05)
                let levels = NotchMotion.trackSwapLevels(since: sample.t)
                bitmap = try blend(old, new, outgoing: levels.outgoing, incoming: levels.incoming)
            } else {
                bitmap = try ProofRender.render(scene(size: sample.size), size: canvas, scale: 1.5, settle: 0.1)
            }
            let label = String(format: "t %3d  %3.0fx%3.0f  r %2.0f  a %.2f", Int((sample.t * 1000).rounded()),
                               sample.size.width, sample.size.height, sample.radius, sample.contentOpacity)
            cells.append(ProofCell(label: label, bitmap: bitmap))
        }
        return cells
    }

    /// The two renders of a track change, each at its own level: the old
    /// words leaving as the new arrive (`NotchMotion.trackSwapLevels`).
    /// Each render carries the same black body and desktop, so the words
    /// are what differs between them; the pixelwise darker of the two is
    /// the body without either's words, and each is added over it at its
    /// level.
    private static func blend(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep,
                              outgoing: CGFloat, incoming: CGFloat) throws -> NSBitmapImageRep {
        let out = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: a.pixelsWide, pixelsHigh: a.pixelsHigh, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                guard let pa = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let pb = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                func mix(_ ca: CGFloat, _ cb: CGFloat) -> CGFloat {
                    let base = min(ca, cb)
                    return min(1, max(0, base + (ca - base) * outgoing + (cb - base) * incoming))
                }
                out.setColor(NSColor(deviceRed: mix(pa.redComponent, pb.redComponent),
                                     green: mix(pa.greenComponent, pb.greenComponent),
                                     blue: mix(pa.blueComponent, pb.blueComponent), alpha: 1),
                             atX: x, y: y)
            }
        }
        return out
    }

    // MARK: Curves

    private struct Curve {
        var name: String
        var color: NSColor
        var value: (NotchFilmstrip.Sample) -> CGFloat
    }

    /// The scenario's curves under its frames: shape, content and corner
    /// against time, each scaled to its own range so the shapes of the
    /// curves can be compared, with a tick every 50 ms.
    private static func plot(_ dense: [NotchFilmstrip.Sample], script: NotchFilmstrip.Script,
                             width: Int) throws -> NSBitmapImageRep {
        let height = 330
        let margin: CGFloat = 60
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: 0.1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        func range(_ value: (NotchFilmstrip.Sample) -> CGFloat) -> (CGFloat, CGFloat) {
            let values = dense.map(value)
            let low = values.min() ?? 0
            let high = values.max() ?? 1
            return (low, max(high, low + 0.001))
        }
        let curves: [Curve] = [
            Curve(name: "width", color: .systemBlue, value: { $0.size.width }),
            Curve(name: "height", color: .systemGreen, value: { $0.size.height }),
            Curve(name: "content opacity", color: .white, value: { $0.contentOpacity }),
            Curve(name: "corner radius", color: .systemOrange, value: { $0.radius }),
            Curve(name: "top flare", color: .systemPink, value: { $0.flare }),
            Curve(name: "shadow", color: .systemGray, value: { $0.shadow }),
            Curve(name: "height speed", color: .systemYellow, value: { $0.velocity.height }),
        ]
        let plotRect = NSRect(x: margin, y: 30, width: CGFloat(width) - margin - 24, height: CGFloat(height) - 70)
        let end = dense.last?.t ?? 1
        // Ticks.
        NSColor(white: 0.25, alpha: 1).setStroke()
        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        var tick = 0.0
        while tick <= end + 1e-9 {
            let x = plotRect.minX + CGFloat(tick / end) * plotRect.width
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: plotRect.minY))
            line.line(to: NSPoint(x: x, y: plotRect.maxY))
            line.lineWidth = 1
            line.stroke()
            ("\(Int((tick * 1000).rounded()))" as NSString).draw(
                at: NSPoint(x: x - 10, y: 8),
                withAttributes: [.font: font, .foregroundColor: NSColor(white: 0.6, alpha: 1)])
            tick += 0.05
        }
        var legendX = margin
        for curve in curves {
            let (low, high) = range(curve.value)
            let path = NSBezierPath()
            for (index, sample) in dense.enumerated() {
                let x = plotRect.minX + CGFloat(sample.t / end) * plotRect.width
                let y = plotRect.minY + (curve.value(sample) - low) / (high - low) * plotRect.height
                index == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
            }
            curve.color.setStroke()
            path.lineWidth = 2
            path.stroke()
            let label = String(format: "%@ %.0f..%.0f", curve.name, Double(low), Double(high))
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: curve.color]
            (label as NSString).draw(at: NSPoint(x: legendX, y: CGFloat(height) - 30), withAttributes: attrs)
            legendX += (label as NSString).size(withAttributes: attrs).width + 18
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
}
