import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// Render proof for the notch wrap: the tray silhouette against a fake
/// bezel at 4×, so a human can eyeball that the corners match the
/// hardware's own radius and the marks centre inside the bezel — the
/// thing screenshots keep judging. Off by default; set
/// `JRBAR_RENDER_PROOF=1` to write /tmp/notch-proof PNGs.
@Suite("Notch wrap render proof")
@MainActor
struct NotchRenderProofTests {
        /// The scene the screenshots crop: a 185-pt bezel at the top of a
    /// 500-pt window, our tray wrapping it — ear lobes dropping below the
    /// bezel's line. The bezel is drawn as the test's own black bar —
    /// what the hardware shows.
    private static func scene(_ model: ScreenBarWingsModel) -> some View {
        ZStack(alignment: .top) {
            Color(white: 0.24)   // the menu bar's field
            VStack(spacing: 0) {
                // The bezel: screen top, square where it meets the lid,
                // bottom corners at the hardware's own ~8 pt.
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 8,
                                       bottomTrailingRadius: 8, topTrailingRadius: 0,
                                       style: .continuous)
                    .fill(.black)
                    .frame(width: 185, height: 32)
                Spacer()
            }
            ScreenBarWingsView(model: model)
        }
        .frame(width: 500, height: 48)
        .environment(\.colorScheme, .dark)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write /tmp/notch-proof PNGs"))
    func snapshots() throws {
        let dir = URL(fileURLWithPath: "/tmp/notch-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // The claim the geometry answers for a 185-pt slot in a
        // 500-pt window: the ears hug the bezel at its own depth —
        // flush with the hardware's bottom edge, 36 pt of wing.
        let size = NSSize(width: 500, height: 48)
        let depth: CGFloat = 32 + ScreenBarGeometry.wingEarDrop
        let leftRect = CGRect(x: 157.5 - 36, y: size.height - depth, width: 36, height: depth)
        let rightRect = CGRect(x: 342.5, y: size.height - depth, width: 36, height: depth)

        for (name, left, right, corner) in [
            ("standard-8pt", ScreenBarWingSlot(text: "Working", provider: "claude"),
             ScreenBarWingSlot(text: "Claude 72%", provider: "claude", meter: 0.72),
             NotchProfile.standardCornerRadius),
            ("custom-4pt", ScreenBarWingSlot(text: "Working", provider: "claude"),
             ScreenBarWingSlot(text: "Claude 72%", provider: "claude", meter: 0.72),
             CGFloat(4)),
            ("notice", nil,
             ScreenBarWingSlot(text: "Charging · 84%", symbol: "bolt.fill", tone: .attention),
             NotchProfile.standardCornerRadius),
        ] as [(String, ScreenBarWingSlot?, ScreenBarWingSlot?, CGFloat)] {
            let model = ScreenBarWingsModel()
            model.viewHeight = size.height
            model.notchCorner = corner
            model.earDrop = ScreenBarGeometry.wingEarDrop
            // The bezel's side edges in tray-local x: 185-pt bezel centred
            // in the 500-pt scene → 157.5 / 342.5, less the tray's origin.
            // An unclaimed side ends the tray at its bezel edge, as
            // `updateWingChips` builds it — that side must grow no lobe.
            let trayMinX = left == nil ? 157.5 : leftRect.minX
            let trayMaxX = right == nil ? 342.5 : rightRect.maxX
            let trayRect = CGRect(x: trayMinX, y: size.height - depth,
                                  width: trayMaxX - trayMinX, height: depth)
            model.bezelLeft = 157.5 - trayRect.minX
            model.bezelRight = 342.5 - trayRect.minX
            model.tray = trayRect
            model.left = left.map { ($0, leftRect) }
            model.right = right.map { ($0, rightRect) }

            let renderer = ImageRenderer(content: Self.scene(model))
            renderer.scale = 4
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                Issue.record("render failed for \(name)")
                continue
            }
            try png.write(to: dir.appendingPathComponent("\(name).png"))
        }
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }
}
