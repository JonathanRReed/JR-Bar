import AppKit
import JRBarCore
import JRBarTestSupport
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Dock Music render proofs", .serialized, .renderProofAppearance)
struct DockMusicRenderProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func cards() async throws {
        for dark in [false, true] {
            for mode in ["not-running", "stopped", "paused", "playing", "no-permission", "denied", "stale", "no-artwork", "long-title", "unavailable"] {
                let fixture = DockMusicTests.Fixture()
                fixture.running = mode != "not-running"
                fixture.fails = mode == "unavailable"
                fixture.status = mode == "denied" ? .denied : mode == "no-permission" ? .needed : .granted
                let art = mode == "no-artwork" ? nil : Self.artwork()
                var media = DockMusicTests.track(playing: mode != "paused", artwork: art)
                if mode == "long-title" {
                    media.title = "A Song for the Last Train through the Valley of Paper Lanterns"
                    media.artist = "The Example Quartet and the Synthetic String Orchestra"
                    media.album = "Small Hours, Volume Two: The Complete Evening Sessions"
                }
                fixture.reading = .init(media: mode == "stopped" ? nil : media,
                    shuffle: true, repeatMode: .one, volume: 72, favorite: mode == "stopped" ? nil : true)
                let player = fixture.makePlayer()
                player.start(fullControls: mode != "no-permission")
                if mode == "unavailable" { fixture.monitor.onChange?(media) }
                await player.settle()
                if mode == "no-permission" || mode == "denied" { fixture.monitor.onChange?(media) }
                if mode == "stale" {
                    fixture.fails = true
                    fixture.changed?()
                    await player.settle()
                }
                let content = DockPreviewContent()
                content.appName = "Music"
                content.bundleID = DockMusicSource.bundleID
                content.isRunning = fixture.running
                content.icon = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Music")
                content.musicPlayerEnabled = true
                content.music = player
                let scene = DockPreviewView(content: content, actions: DockPreviewActions(content: content))
                    .background(dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
                try ProofRender.write(scene, size: CGSize(width: 370, height: 600),
                    name: "dock-music-\(mode)-\(dark ? "dark" : "light")", dark: dark, settle: 0)
                player.stop()
            }
        }
    }

    private static func artwork() -> Data? {
        let image = NSImage(size: CGSize(width: 256, height: 256))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 256, height: 256)).fill()
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: CGRect(x: 34, y: 28, width: 188, height: 188)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: CGRect(x: 98, y: 92, width: 60, height: 60)).fill()
        image.unlockFocus()
        return image.tiffRepresentation
    }
}
