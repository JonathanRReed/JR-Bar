import AppKit
import SwiftUI
import Testing
@testable import JRBarCore
@testable import JRBarApp

@Suite("Calibration constrained layout", .serialized)
@MainActor
struct CalibrationLayoutTests {
    @Test(arguments: [CGSize(width: 380, height: 460), CGSize(width: 540, height: 640)])
    func expandedReferencePatchHasHorizontalMargins(size: CGSize) throws {
        let rig = Self.host(size: size, dark: true)
        defer { rig.window.contentView = nil; rig.window.close() }
        let referenceBitmap = try Self.bitmap(rig.host)
        let scale = CGFloat(referenceBitmap.pixelsWide) / size.width
        var longestStart = 0
        var longestEnd = 0
        for y in 0..<referenceBitmap.pixelsHigh {
            var start: Int?
            for x in 0...referenceBitmap.pixelsWide {
                let pixel = x < referenceBitmap.pixelsWide
                    ? referenceBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) : nil
                let white = pixel.map {
                    min($0.redComponent, $0.greenComponent, $0.blueComponent) >= 246.0 / 255.0
                } ?? false
                if white, start == nil {
                    start = x
                } else if !white, let runStart = start {
                    if x - runStart > longestEnd - longestStart {
                        longestStart = runStart
                        longestEnd = x
                    }
                    start = nil
                }
            }
        }
        #expect(CGFloat(longestEnd - longestStart) / scale >= 120, "White reference patch is missing")
        #expect(CGFloat(longestStart) / scale >= 16, "White reference patch crosses the left content margin")
        #expect(CGFloat(referenceBitmap.pixelsWide - longestEnd) / scale >= 16,
                "White reference patch crosses the right content margin")
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled),
          arguments: [CGSize(width: 380, height: 460), CGSize(width: 540, height: 640)])
    func expandedSheetRender(size: CGSize) throws {
        for dark in [false, true] {
            let rig = Self.host(size: size, dark: dark)
            defer { rig.window.contentView = nil; rig.window.close() }
            let rep = try Self.bitmap(rig.host)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            let directory = WindowsRenderProofTests.directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "calibration-expanded-\(Int(size.width))x\(Int(size.height))-\(dark ? "dark" : "light").png"
            try png.write(to: directory.appendingPathComponent(name))

            let scroller = try #require(Self.scrollView(in: rig.host))
            let document = try #require(scroller.documentView)
            let bottom = max(0, document.bounds.height - scroller.contentView.bounds.height)
            scroller.contentView.scroll(to: CGPoint(x: 0, y: document.isFlipped ? bottom : 0))
            scroller.reflectScrolledClipView(scroller.contentView)
            rig.host.layoutSubtreeIfNeeded()
            rig.window.displayIfNeeded()
            let bottomBitmap = try Self.bitmap(rig.host)
            let bottomPNG = try #require(bottomBitmap.representation(using: .png, properties: [:]))
            try bottomPNG.write(to: directory.appendingPathComponent(name.replacingOccurrences(of: ".png", with: "-bottom.png")))
        }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroller = view as? NSScrollView { return scroller }
        for child in view.subviews {
            if let scroller = scrollView(in: child) { return scroller }
        }
        return nil
    }

    private static func bitmap(_ host: NSView) throws -> NSBitmapImageRep {
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private static func host(size: CGSize, dark: Bool = false) -> (window: NSWindow, host: NSView) {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-calibration-layout-unused.sock")
        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
            document: .object(["devices": .array([.object([
                "id": .string("synthetic-light"), "name": .string("Synthetic Light"),
                "red_gain": .number(1), "green_gain": .number(1), "blue_gain": .number(1),
                "resting_glow": .number(0), "brightness": .number(128),
            ])]), "calibration_profiles": .object([
                "Night": .object(["synthetic-light": .object(["red_gain": .number(0.95)])]),
            ])]))))
        let store = SettingsStore(core: core)
        let view = CalibrationSheet(store: store, deviceID: "synthetic-light", dismiss: {}, fineTuneExpanded: true)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        return (window, host)
    }
}
