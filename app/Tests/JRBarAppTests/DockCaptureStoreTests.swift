import AppKit
import Foundation
import Testing
@testable import JRBarApp

/// The stills the Dock previews keep: bounded by decoded bytes, kept for
/// ten minutes as a window's last-known picture, least recently shown out
/// first. Synthetic images, a passed-in clock.
@Suite("Dock capture store")
@MainActor
struct DockCaptureStoreTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func image(_ side: Int) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    @Test("an image costs four bytes a pixel of its bitmap, not its size in points")
    func cost() {
        #expect(DockCaptureStore.cost(of: image(100)) == 40_000)
        let retina = image(200)
        retina.size = NSSize(width: 100, height: 100)
        #expect(DockCaptureStore.cost(of: retina) == 160_000)
        #expect(DockCaptureStore.cost(of: NSImage(size: NSSize(width: 10, height: 5))) == 200)
    }

    @Test("past the byte limit the least recently shown stills go first")
    func leastRecentlyShownGoesFirst() {
        var store = DockCaptureStore(limit: 100_000)
        store.store(image(100), key: "a", tag: nil, at: Self.t0)
        store.store(image(100), key: "b", tag: nil, at: Self.t0)
        #expect(store.bytes == 80_000 && store.count == 2)
        // Showing "a" makes "b" the one that was shown longest ago.
        #expect(store.entry("a", now: Self.t0) != nil)
        store.store(image(100), key: "c", tag: nil, at: Self.t0)
        #expect(store.bytes == 80_000)
        #expect(store.entry("b", now: Self.t0) == nil)
        #expect(store.entry("a", now: Self.t0) != nil && store.entry("c", now: Self.t0) != nil)
    }

    @Test("a still bigger than the whole store is not kept, and replacing a still recounts its bytes")
    func accounting() {
        var store = DockCaptureStore(limit: 50_000)
        store.store(image(200), key: "huge", tag: nil, at: Self.t0)
        #expect(store.count == 0 && store.bytes == 0)
        store.store(image(100), key: "a", tag: "working", at: Self.t0)
        store.store(image(50), key: "a", tag: "asking", at: Self.t0)
        #expect(store.count == 1 && store.bytes == 10_000)
        #expect(store.entry("a", now: Self.t0)?.tag == "asking")
        store.remove("a")
        store.remove("a")
        #expect(store.bytes == 0)
        store.store(image(100), key: "b", tag: nil, at: Self.t0)
        store.removeAll()
        #expect(store.count == 0 && store.bytes == 0)
    }

    @Test("a still is a window's last-known picture for ten minutes and then it is gone, without waiting for a capture")
    func expiry() {
        var store = DockCaptureStore()
        store.store(image(10), key: "a", tag: nil, at: Self.t0)
        #expect(store.entry("a", now: Self.t0.addingTimeInterval(599)) != nil)
        #expect(store.peek("a", now: Self.t0.addingTimeInterval(45))?.age == 45)
        #expect(store.entry("a", now: Self.t0.addingTimeInterval(600)) == nil)
        #expect(store.bytes == 0, "asking for an expired still drops it")
        store.store(image(10), key: "b", tag: nil, at: Self.t0)
        store.store(image(10), key: "c", tag: nil, at: Self.t0.addingTimeInterval(700))
        #expect(store.count == 1, "storing prunes what has expired")
    }

    @Test("the thumbnailer serves a last-known still, and says whether it is fresh enough to keep")
    func lastKnown() {
        // The thumbnailer's store is shared by every Dock test in the
        // process, and emptying it bumps the epoch other suites' captures
        // are waiting on. So this test owns a pid nobody else uses and
        // never empties the store; it runs to the end without yielding the
        // main actor, so nothing else can touch the store under it.
        let pid: pid_t = 914_100
        let epoch = DockThumbnailer.captureEpoch
        let still = image(20)
        // The real time, not a far-off one: storing prunes whatever has
        // expired, and a date in the future would expire every other
        // test's stills. The store's byte count belongs to everyone, so it
        // is not asserted here; the store's own tests cover it.
        let now = Date()
        #expect(DockThumbnailer.lastKnown(pid: pid, windowID: 7001, tag: nil, now: now) == nil)
        _ = DockThumbnailer.cacheCapture(still, pid: pid, windowID: 7001, tag: "working", epoch: epoch, now: now)
        let fresh = DockThumbnailer.lastKnown(pid: pid, windowID: 7001, tag: "working",
                                              now: now.addingTimeInterval(10))
        #expect(fresh?.image === still && fresh?.fresh == true)
        // Past the half minute a still stops standing in for a capture,
        // but it is still the picture to open on.
        let old = DockThumbnailer.lastKnown(pid: pid, windowID: 7001, tag: "working",
                                            now: now.addingTimeInterval(120))
        #expect(old?.image === still && old?.fresh == false)
        // Taken under another agent state: shown, then replaced.
        #expect(DockThumbnailer.lastKnown(pid: pid, windowID: 7001, tag: "asking",
                                          now: now.addingTimeInterval(10))?.fresh == false)
        // Another app's window with the same id is another window.
        #expect(DockThumbnailer.lastKnown(pid: pid + 1, windowID: 7001, tag: "working", now: now) == nil)
        // A capture from before a revocation is refused.
        #expect(DockThumbnailer.cacheCapture(still, pid: pid, windowID: 7002, tag: nil, epoch: epoch - 1) == nil)
        #expect(DockThumbnailer.lastKnown(pid: pid, windowID: 7002, tag: nil, now: now) == nil)
    }
}
