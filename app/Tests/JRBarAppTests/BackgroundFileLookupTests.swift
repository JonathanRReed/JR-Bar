import AppKit
import ApplicationServices
import JRBarTestSupport
import Testing
@testable import JRBarApp

@Suite("Background file lookups", .temporaryDirectory, .serialized, .timeLimit(.minutes(1)))
@MainActor
struct BackgroundFileLookupTests {
    private final class Deadline: @unchecked Sendable {
        private let lock = NSLock()
        private var callback: (@Sendable () -> Void)?
        func schedule(_ work: @escaping @Sendable () -> Void) { lock.lock(); callback = work; lock.unlock() }
        func fire() { lock.lock(); let work = callback; lock.unlock(); work?() }
    }

    @Test("a blocked bundle read leaves Dock targets and main actor responsive")
    func blockedDockLookup() async throws {
        let entered = TestSignal(), finished = TestSignal()
        let gate = TestGate(), deadline = Deadline()
        let cache = BackgroundLookupCache<URL, String>(limit: 1,
            scheduleDeadline: { _, work in deadline.schedule(work) },
            changed: { finished.signal() }, load: { _ in
                #expect(!Thread.isMainThread)
                entered.signal()
                gate.wait()
                return "example.app"
            })
        defer { gate.signal() }
        let url = URL(fileURLWithPath: "/Applications/Synthetic.app")
        let tile = DockAXItem(element: AXUIElementCreateSystemWide(),
                             frame: CGRect(x: 0, y: 0, width: 40, height: 40), title: "Synthetic", url: url, kind: .app)
        let first = DockEnhanceController.quickQuitTargets([tile], running: ["example.app"], resolve: { cache.value(for: $0) })
        #expect(first.isEmpty)
        #expect(await entered.wait())
        for _ in 0..<50 {
            #expect(DockEnhanceController.quickQuitTargets([tile], running: ["example.app"], resolve: { cache.value(for: $0) }).isEmpty)
        }
        // The deadline returns while the worker is still held. Late results
        // cannot become quick-quit targets after the lookup timed out.
        deadline.fire()
        #expect(await finished.wait())
        #expect(await cache.resolve(url) == nil)
        gate.signal()
        #expect(await finished.wait())
        #expect(cache.value(for: url) == nil)
    }

    @Test("folder tiles never reach a bundle resolver")
    func folderIsNotAnApp() {
        let tile = DockAXItem(element: AXUIElementCreateSystemWide(), frame: .zero,
                             title: "Downloads", url: URL(fileURLWithPath: "/Users/synthetic/Downloads"), kind: .folder)
        let targets = DockEnhanceController.quickQuitTargets([tile], running: []) { _ in
            Issue.record("a folder reached the bundle resolver")
            return nil
        }
        #expect(targets.isEmpty)
    }

    @Test("protected paths submit no reads until that exact item joins the Shelf")
    func protectedPathsNeedShelfMembership() async {
        let read = TestSignal()
        let metadata = ExternalFileMetadata(home: "/Users/synthetic", reader: { _ in
            #expect(!Thread.isMainThread)
            read.signal()
            return ExternalFileSnapshot(available: true)
        })
        let paths = ["/Users/synthetic/Desktop/a", "/Users/synthetic/Documents/a", "/Users/synthetic/Downloads/a",
                     "/Users/synthetic/Library/Mobile Documents/a", "/Users/synthetic/Library/CloudStorage/a",
                     "/Volumes/External/a", "/Network/Share/a"]
        for path in paths {
            #expect(metadata.snapshot(URL(fileURLWithPath: path))?.available == false)
        }
        let item = URL(fileURLWithPath: paths[2])
        metadata.setShelfPaths([item.path])
        #expect(metadata.snapshot(item) == nil)
        #expect(metadata.snapshot(item.deletingLastPathComponent())?.available == false)
        #expect(metadata.snapshot(item.appendingPathComponent("child"))?.available == false)
        #expect(await read.wait())
    }

    @Test("expired work retains its lane instead of spawning more blocked reads")
    func boundedWorkers() async {
        let entered = TestSignal(), completed = TestSignal(), gate = TestGate(), deadline = Deadline()
        let cache = BackgroundLookupCache<Int, Int>(limit: 1,
            scheduleDeadline: { _, work in deadline.schedule(work) }, changed: { completed.signal() }, load: { key in
                entered.signal(); gate.wait(); return key
            })
        defer { gate.signal() }
        #expect(cache.value(for: 1) == nil)
        #expect(await entered.wait())
        deadline.fire()
        #expect(await completed.wait())
        for key in 2...100 { #expect(cache.value(for: key) == nil) }
        gate.signal()
        #expect(await completed.wait())
    }
    @Test("a dataless item or symlink stops inspection before any child is read")
    func unavailableComponents() {
        let url = URL(fileURLWithPath: "/Users/synthetic/Downloads/cloud/fish.png")
        let policy = ExternalFilePolicy(home: "/Users/synthetic", shelfPaths: [url.path])
        for unavailable in [ExternalFilePolicy.Facts(dataless: true), .init(symbolicLink: true), .init(local: false)] {
            var inspected: [String] = []
            let available = policy.available(url) { path in
                inspected.append(path)
                return path.hasSuffix("/cloud") ? unavailable : .init()
            }
            #expect(!available)
            #expect(inspected.last == "/Users/synthetic/Downloads/cloud")
            #expect(!inspected.contains(url.path))
        }
        var probes = 0
        #expect(!ExternalFilePolicy(home: "/Users/synthetic").available(url) { _ in
            probes += 1
            return .init()
        })
        #expect(probes == 0)
    }

    @Test("removing and re-adding a Shelf path retires its previous cached grant")
    func shelfGrantIsRetired() async throws {
        let reads = TestEvents<ExternalFileMetadata.Request>()
        let metadata = ExternalFileMetadata(home: "/Users/synthetic", reader: { request in
            reads.send(request)
            return ExternalFileSnapshot(available: true)
        })
        let url = URL(fileURLWithPath: "/Users/synthetic/Downloads/fish.png")
        metadata.setShelfPaths([url.path])
        _ = metadata.snapshot(url)
        let first = try await reads.next()
        metadata.setShelfPaths([])
        #expect(metadata.snapshot(url)?.available == false)
        metadata.setShelfPaths([url.path])
        #expect(metadata.snapshot(url) == nil)
        let second = try await reads.next()
        #expect(first.grant != nil && second.grant != nil && first.grant != second.grant)
    }

    @Test("an unregistered app keeps its declared bundle icon")
    func declaredBundleIcon() async throws {
        let root = TestTemporaryDirectory.currentURL.appendingPathComponent("jrbar-icon-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Synthetic.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist: [String: String] = ["CFBundleIdentifier": "com.example.synthetic-icon", "CFBundlePackageType": "APPL",
                                       "CFBundleIconFile": "Fish.png", "CFBundleName": "Synthetic"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 16, bitsPerPixel: 32))
        let pixels = try #require(bitmap.bitmapData)
        for index in 0..<16 {
            pixels[index * 4] = 255
            pixels[index * 4 + 1] = 0
            pixels[index * 4 + 2] = 0
            pixels[index * 4 + 3] = 255
        }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: resources.appendingPathComponent("Fish.png"))
        let metadata = ExternalFileMetadata()
        let icon = try #require(await metadata.resolveIcon(app))
        let cgImage = try #require(icon.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let pixel = try #require(NSBitmapImageRep(cgImage: cgImage).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        #expect(pixel.redComponent > 0.9)
        #expect(pixel.greenComponent < 0.1)
        #expect(pixel.blueComponent < 0.1)
    }

    @Test("a policy-blocked Dock folder does not ask for a permission grant")
    func protectedFolderIsUnavailable() {
        let url = URL(fileURLWithPath: "/Volumes/JRBarSyntheticForbidden")
        #expect(DockEnhanceController.folderListing(of: url).state == .failed)
    }

}
