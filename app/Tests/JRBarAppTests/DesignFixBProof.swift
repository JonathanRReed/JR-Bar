import AppKit
import JRBarUI
import QuartzCore
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
enum DesignFixBProof {
    /// The daemon's real light programs, exported beside the proofs. A run
    /// without that export skips the check that needs it instead of failing.
    nonisolated static var hasDaemonPrograms: Bool {
        let directory = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/jrbar-dfix-b-proof"
        return FileManager.default.fileExists(atPath: directory + "/daemon-programs.json")
    }

    static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"] ?? "/tmp/jrbar-dfix-b-proof")
    }

    static func write<V: View>(_ view: V, name: String, title: String, size: CGSize, dark: Bool) async throws {
        let bitmap = try await snapshot(view, title: title, size: size, dark: dark)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }

    static func snapshot<V: View>(_ view: V, title: String, size: CGSize, dark: Bool) async throws -> NSBitmapImageRep {
        try U5Proof.pinDefaultAccent()
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        let root = view.tint(.blue).accentColor(.blue)
            .environment(\.colorScheme, dark ? .dark : .light).environment(\.controlActiveState, .key)
            .environment(\.renderSnapshot, true).jrbarAccessibility(reduceMotion: true)
            .frame(width: size.width, height: size.height).background(JRBarTokens.Ink.window)
        let host = NSHostingView(rootView: root)
        let window = DesignFixBWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.title = title
        window.contentView = host
        host.appearance = appearance
        defer { window.contentView = nil; window.close() }
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        try #require(!NSScreen.screens.contains { $0.frame.intersects(window.frame) })
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        CATransaction.flush()
        let frame = try #require(window.contentView?.superview)
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        appearance.performAsCurrentDrawingAppearance { frame.cacheDisplay(in: frame.bounds, to: bitmap) }
        return bitmap
    }
}

private final class DesignFixBWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
