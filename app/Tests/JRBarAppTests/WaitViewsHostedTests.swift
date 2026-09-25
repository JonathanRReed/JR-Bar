import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// `DelayedWait` hosted the way the app hosts it: a labelled button
/// keeps its width as its wait shows, and a bare wait holds its slot.
/// With `JRBAR_RENDER_PROOF=1`, also a proof of the placements through
/// `NSHostingView` and `cacheDisplay`, so the buttons and the system
/// spinner draw as themselves.
@Suite("Wait views, hosted", .serialized)
@MainActor
struct WaitViewsHostedTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A small bordered button whose label waits, as `ResignInButton`
    /// draws it.
    struct WaitingButton: View {
        let title: String
        var activity: AgentActivity?

        var body: some View {
            Button {} label: {
                DelayedWait(since: WaitViewsHostedTests.start, activity: activity) {
                    Label(title, systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    /// The view's fitting size `elapsed` seconds into its wait.
    static func fitting<V: View>(_ view: V, elapsed: TimeInterval) -> CGSize {
        let still = WaitStill(now: start.addingTimeInterval(elapsed))
        let hosting = NSHostingView(rootView: view.fixedSize().environment(\.waitStill, still))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

    @Test("a button keeps its width as its wait shows, spinner or orb")
    func buttonKeepsItsWidth() {
        for activity in [nil, AgentActivity.thinking] as [AgentActivity?] {
            let before = Self.fitting(WaitingButton(title: "Re-sign in", activity: activity), elapsed: 1)
            let after = Self.fitting(WaitingButton(title: "Re-sign in", activity: activity), elapsed: 2.5)
            #expect(before == after, "\(String(describing: activity))")
            #expect(before.width > 60, "the label, not an orb, sets the width")
        }
    }

    @Test("a bare wait holds its slot's size through the reveal")
    func bareWaitHoldsItsSlot() {
        for size in [12, 14] as [CGFloat] {
            for activity in [nil, AgentActivity.searching] as [AgentActivity?] {
                let before = Self.fitting(DelayedWait(since: Self.start, activity: activity, size: size), elapsed: 0.5)
                let after = Self.fitting(DelayedWait(since: Self.start, activity: activity, size: size), elapsed: 2.5)
                #expect(before == after, "\(size) \(String(describing: activity))")
                #expect(before.width > 0 && before.height > 0)
            }
        }
    }

    // MARK: Render proof

    /// One moment of the placements: the buttons that start a job, the
    /// ordinary loads (spinners), and a search (an orb).
    struct PlacementsRow: View {
        let caption: String

        var body: some View {
            HStack(alignment: .center, spacing: 14) {
                Text(caption)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
                WaitingButton(title: "Re-sign in")
                Button {} label: {
                    DelayedWait(since: WaitViewsHostedTests.start) { Text("Apply keymap") }.frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                Button {} label: {
                    DelayedWait(since: WaitViewsHostedTests.start, size: 12) { Text("Install") }.frame(width: 58)
                }
                .controlSize(.small)
                Divider().frame(height: 18)
                HStack(spacing: 8) {
                    DelayedWait(since: WaitViewsHostedTests.start)
                    Text("Loading…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    DelayedWait(since: WaitViewsHostedTests.start, size: 12)
                    Text("Reading the transcript…").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                HStack(spacing: 8) {
                    DelayedWait(since: WaitViewsHostedTests.start, activity: .searching)
                    Text("Looking for agent folders…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    struct PlacementsSheet: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                PlacementsRow(caption: "1 s")
                    .environment(\.waitStill, WaitStill(now: WaitViewsHostedTests.start.addingTimeInterval(1)))
                PlacementsRow(caption: "2.5 s")
                    .environment(\.waitStill, WaitStill(now: WaitViewsHostedTests.start.addingTimeInterval(2.5)))
            }
            .padding(16)
        }
    }

    @Test(.enabled(if: WaitEffectsRenderProofTests.enabled))
    func placementsProof() throws {
        try FileManager.default.createDirectory(at: WaitEffectsRenderProofTests.directory,
                                                withIntermediateDirectories: true)
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let staged = PlacementsSheet()
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
            let name = "placements-\(dark ? "dark" : "light").png"
            try png.write(to: WaitEffectsRenderProofTests.directory.appendingPathComponent(name))
        }
    }
}
