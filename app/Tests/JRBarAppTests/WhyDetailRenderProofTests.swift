import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The Why-this-light popover with its "In this state" row counted on the
/// app's clock. Off by default; set `JRBAR_RENDER_PROOF=1` to write the
/// popover, light and dark, into `JRBAR_RENDER_PROOF_DIR` (default
/// /tmp/why-proof): the row as the daemon's frozen number left it, and the
/// row counted from the session's `since`.
@Suite("Why this light, drawn", .serialized)
@MainActor
struct WhyDetailRenderProofTests {
    static let now = Date(timeIntervalSince1970: 1_789_046_900)
    static let session = "claude:session:proof-1"

    /// A working strip held for 25 minutes whose last frame said 4 s.
    static func explanation(sessionListed: Bool) -> LightExplanation? {
        let held = CoreSession(id: session, provider: "claude", label: "jr-bar-proof", shortId: "1a2b3c4d",
                               mode: "working", lifecycle: "active", since: now.timeIntervalSince1970 - 1500)
        let detail = CoreWhyDetail(session: session, label: "jr-bar-proof", provider: "claude",
                                   secondsInState: 4, brightnessFactor: 1.0, dimming: [])
        let surface = CoreLightSurface(program: "…", ledCount: 8, anchor: now.timeIntervalSince1970 - 83,
                                       motion: "continuous", staticFallback: "#FF9500", brightness: 0.8,
                                       why: "working", whyDetail: detail)
        let lights = CoreLights(surfaces: ["hardware": surface, "screen_bar": surface], linked: true)
        let state = CoreState(generation: 1, now: now.timeIntervalSince1970, sessions: sessionListed ? [held] : [])
        return LightExplainer.explain(lights: lights, state: state, settings: nil, now: now)
    }

    @Test("the popover row reads the time held, not the frame's small number")
    func rowReadsTheClock() throws {
        let aged = try #require(Self.explanation(sessionListed: true))
        let frozen = try #require(Self.explanation(sessionListed: false))
        #expect(aged.details.first { $0.label == "In this state" }?.value == "25 min")
        #expect(frozen.details.first { $0.label == "In this state" }?.value == "4 s")
    }

    struct Sheet: View {
        let before: WhyDetailModel
        let after: WhyDetailModel

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Before: the frame's number, as of when it was built")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                WhyDetailView(model: before)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                Text("After: counted from the session's since, on the app's clock")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                WhyDetailView(model: after)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
            }
            .padding(16)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func popoverProof() throws {
        let path = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/why-proof"
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let before = WhyDetailModel()
        before.explanation = Self.explanation(sessionListed: false)
        let after = WhyDetailModel()
        after.explanation = Self.explanation(sessionListed: true)
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let staged = Sheet(before: before, after: after)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let hosting = NSHostingView(rootView: staged.fixedSize())
            hosting.appearance = appearance
            hosting.layoutSubtreeIfNeeded()
            let canvas = hosting.fittingSize
            hosting.frame = CGRect(origin: .zero, size: canvas)
            let proofWindow = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                                       backing: .buffered, defer: false)
            proofWindow.appearance = appearance
            proofWindow.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            let scale: CGFloat = 2
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = canvas
            appearance?.performAsCurrentDrawingAppearance {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            }
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("why-this-light-\(dark ? "dark" : "light").png"))
        }
    }
}
