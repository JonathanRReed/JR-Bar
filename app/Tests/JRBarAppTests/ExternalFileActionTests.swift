import AppKit
import JRBarTestSupport
import Testing
import SwiftUI
@testable import JRBarApp

@MainActor
@Suite("Fresh external file actions", .serialized, .timeLimit(.minutes(1)))
struct ExternalFileActionTests {
    @Test("loaded files deleted before an action are refused")
    func deletedShelfAction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file.txt")
        try Data("synthetic".utf8).write(to: url)
        let suite = "jrbar-fresh-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tray = ShelfTrayModel(defaults: defaults)
        tray.add([url])
        await tray.refreshMetadata()
        let entry = try #require(tray.entries.first)
        #expect(!entry.missing)
        try FileManager.default.removeItem(at: url)
        #expect(await tray.presentURLs(of: [entry]).isEmpty, "drag and share receive no stale URLs")
        #expect(tray.actionNotice?.contains("deleted") == true)
        tray.beginKeyboardSelection()
        var opened = false
        tray.openURL = { _ in opened = true; return true }
        #expect(await tray.openKeyboardSelection() == "The selected files moved or were deleted.")
        #expect(!opened)
        await tray.quickLook(entry)
        #expect(tray.actionNotice?.contains("deleted") == true)
        #expect(await tray.sendViaAirDrop([entry]) == false)
    }

    @Test("attachment requests read replacements and reject deletions without waiting for preview expiry")
    func currentAttachment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("image.png")
        func write(_ red: CGFloat) throws {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
            for x in 0..<2 { for y in 0..<2 {
                bitmap.setColor(NSColor(deviceRed: red, green: 0, blue: 0, alpha: 1), atX: x, y: y)
            } }
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
        }
        let metadata = ExternalFileMetadata()
        try write(1)
        let first = try #require(await metadata.attachment(url))
        try write(0)
        let second = try #require(await metadata.attachment(url))
        #expect(first.tiffRepresentation != second.tiffRepresentation)
        try FileManager.default.removeItem(at: url)
        #expect(await metadata.attachment(url) == nil)
    }

    @Test("an explicit local symlink resolves but an automatic probe does not follow it")
    func explicitSymlink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.txt")
        try Data("synthetic".utf8).write(to: target)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let metadata = ExternalFileMetadata()
        #expect(await metadata.validate(link)?.available != true)
        metadata.setShelfPaths([link.path])
        #expect(await metadata.validate(link)?.available == true)
        let protected = URL(fileURLWithPath: "/Users/synthetic/Documents/never-probe")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: protected)
        #expect(ExternalFilePolicy(home: "/Users/synthetic", shelfPaths: [link.path]).resolvedURL(link) == nil)
    }

    @Test("a configured Dock folder authorizes only its listing")
    func dockFolderGrant() {
        let root = URL(fileURLWithPath: "/Users/synthetic/Downloads")
        let policy = ExternalFilePolicy(home: "/Users/synthetic", dockFolders: [root.path])
        #expect(policy.allows(root))
        #expect(policy.allows(root.appendingPathComponent("file.txt")))
        #expect(!policy.allows(root.appendingPathComponent("child/grandchild.txt")))
        #expect(!ExternalFilePolicy(home: "/Users/synthetic").allows(root))
    }

    @Test("completed icons replace a Shelf placeholder even when no thumbnail exists")
    func shelfIconCompletion() async throws {
        let entered = TestSignal(), gate = TestGate()
        let metadata = ExternalFileMetadata(reader: { _ in ExternalFileSnapshot(available: true) }, iconReader: { _ in
            #expect(!Thread.isMainThread)
            entered.signal()
            gate.wait()
            return ExternalFileSnapshot(icon: NSImage(size: NSSize(width: 12, height: 12)))
        })
        defer { gate.signal() }
        let suite = "jrbar-icons-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tray = ShelfTrayModel(defaults: defaults, metadata: metadata)
        tray.loadThumbnail = { _, done in done(nil) }
        let url = URL(fileURLWithPath: "/tmp/synthetic-icon.txt")
        tray.add([url])
        await tray.refreshMetadata()
        let item = try #require(tray.items.first)
        let placeholder = tray.icon(for: item)
        #expect(await entered.wait())
        gate.signal()
        _ = await metadata.resolveIcon(url)
        let completed = tray.icon(for: item)
        #expect(completed !== placeholder)
        #expect(tray.icon(for: item) === completed)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 for Shelf proofs"))
    func shelfFileProofs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("Files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "jrbar-file-proof-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metadata = ExternalFileMetadata()
        let tray = ShelfTrayModel(defaults: defaults, metadata: metadata)
        tray.loadThumbnail = { _, done in done(nil) }
        tray.add([folder])
        await tray.refreshMetadata()
        _ = await metadata.resolveIcon(folder)
        let timers = ShelfTimerModel(storeURL: root.appendingPathComponent("timers.json"), schedulingEnabled: false)
        let model = NotchCardModel(timers: timers, tray: tray, runtimeEnabled: false)
        model.show(.shelf)
        let card = NotchCardView(model: model, style: .glass, width: 480, pinnedLayout: true)
            .background(Color(nsColor: .windowBackgroundColor))
        for dark in [false, true] {
            try ProofRender.write(card, size: CGSize(width: 480, height: 300),
                                  name: "shelf-folder-\(dark ? "dark" : "light")", dark: dark)
        }
        try FileManager.default.removeItem(at: folder)
        _ = await tray.presentURLs(of: tray.entries)
        for dark in [false, true] {
            try ProofRender.write(card, size: CGSize(width: 480, height: 300),
                                  name: "shelf-deleted-\(dark ? "dark" : "light")", dark: dark)
        }
    }

}
