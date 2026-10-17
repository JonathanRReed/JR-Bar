import Foundation
import Testing
@testable import JRBarApp

/// The Keep Awake card reads macOS's power assertions off the main
/// thread and shows the last read while a new one runs.
@Suite("Keep Awake holders", .serialized)
@MainActor
struct KeepAwakeHoldersTests {
    // MARK: Keep Awake

    @Test("the power assertions are read off the main thread, and the card keeps the last read")
    func keepAwakeReadsInTheBackground() async {
        let prior = KeepAwakeHolders.lastRead
        defer { KeepAwakeHolders.lastRead = prior }
        let fixture = [KeepAwakeHolders.Holder(name: "Presentation", bundleID: "test.presentation", display: true)]
        let read = await KeepAwakeHolders.readInBackground {
            Thread.isMainThread ? nil : fixture
        }
        #expect(read == fixture)
        #expect(KeepAwakeHolders.lastRead == read)
    }

    @Test("a failed power assertion read preserves the last successful list")
    func failedReadKeepsLastHolders() async {
        let prior = KeepAwakeHolders.lastRead
        defer { KeepAwakeHolders.lastRead = prior }
        let fixture = [KeepAwakeHolders.Holder(name: "Presentation", bundleID: "test.presentation", display: true)]
        KeepAwakeHolders.lastRead = fixture
        let read = await KeepAwakeHolders.readInBackground { nil }
        #expect(read == nil)
        #expect(KeepAwakeHolders.lastRead == fixture)

        let empty = await KeepAwakeHolders.readInBackground { [] }
        #expect(empty == [])
        #expect(KeepAwakeHolders.lastRead.isEmpty)
    }

    @Test("an older read cannot replace a newer card's cached holders")
    func olderReadCannotReplaceCache() async {
        let prior = KeepAwakeHolders.lastRead
        defer { KeepAwakeHolders.lastRead = prior }
        let old = [KeepAwakeHolders.Holder(name: "Old", bundleID: "test.old", display: false)]
        let fresh = [KeepAwakeHolders.Holder(name: "Fresh", bundleID: "test.fresh", display: true)]
        let started = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let first = Task {
            await KeepAwakeHolders.readInBackground {
                started.continuation.yield(())
                _ = release.wait(timeout: .now() + 5)
                return old
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(await KeepAwakeHolders.readInBackground { fresh } == fresh)
        release.signal()
        #expect(await first.value == old, "the caller still receives its own completed read")
        #expect(KeepAwakeHolders.lastRead == fresh)
    }

    @Test("a canceled card's detached read cannot publish to the shared cache")
    func canceledReadCannotReplaceCache() async {
        let prior = KeepAwakeHolders.lastRead
        defer { KeepAwakeHolders.lastRead = prior }
        let fixture = [KeepAwakeHolders.Holder(name: "Canceled", bundleID: "test.canceled", display: true)]
        let started = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let reading = Task {
            await KeepAwakeHolders.readInBackground {
                started.continuation.yield(())
                _ = release.wait(timeout: .now() + 5)
                return fixture
            }
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        reading.cancel()
        release.signal()
        _ = await reading.value
        #expect(KeepAwakeHolders.lastRead == prior)
    }
}
