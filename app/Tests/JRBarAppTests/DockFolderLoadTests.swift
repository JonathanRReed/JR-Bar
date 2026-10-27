import JRBarTestSupport
import Foundation
import Testing
@testable import JRBarApp

@MainActor
@Suite(.temporaryDirectory) struct DockFolderLoadTests {
    @Test func missingFoldersAndFilesAreFailuresRatherThanEmptyFolders() throws {
        let root = TestTemporaryDirectory.currentURL.appendingPathComponent("jrbar-folder-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing")
        #expect(DockEnhanceController.folderListing(of: missing).state == .failed)
        let file = root.appendingPathComponent("file.txt")
        try Data("Synthetic fixture".utf8).write(to: file)
        #expect(DockEnhanceController.folderListing(of: file).state == .failed)
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let listing = DockEnhanceController.folderListing(of: empty)
        #expect(listing.state == .ready)
        #expect(listing.entries.isEmpty)
    }

    @Test func deadlinesDoNotReleaseBlockedReadSlots() async {
        let lane = DockFolderLoad.Lane()
        let readGate = AsyncStream<Void>.makeStream()
        let deadlineGate = AsyncStream<Void>.makeStream()
        let timedOut = AsyncStream<Void>.makeStream()
        let readStarted = AsyncStream<Void>.makeStream()
        var reads = 0
        let first = DockFolderLoad.start(lane: lane, read: {
            reads += 1
            readStarted.continuation.yield(())
            for await _ in readGate.stream { break }
            return DockFolderListing(denied: true)
        }, waitForDeadline: {
            for await _ in deadlineGate.stream { break }
        }, receive: { _ in timedOut.continuation.yield(()) })
        for await _ in readStarted.stream { break }
        deadlineGate.continuation.yield(())
        for await _ in timedOut.stream { break }

        // The second slot still serves a healthy folder after the first stalls.
        let second = DockFolderLoad.start(lane: lane, read: {
            reads += 1
            return DockFolderListing(denied: true)
        }, receive: { listing in #expect(listing != nil) })
        await second.value
        #expect(reads == 2)

        let secondReadGate = AsyncStream<Void>.makeStream()
        let secondDeadlineGate = AsyncStream<Void>.makeStream()
        let secondTimeout = AsyncStream<Void>.makeStream()
        let secondReadStarted = AsyncStream<Void>.makeStream()
        let blocked = DockFolderLoad.start(lane: lane, read: {
            reads += 1
            secondReadStarted.continuation.yield(())
            for await _ in secondReadGate.stream { break }
            return DockFolderListing(denied: true)
        }, waitForDeadline: {
            for await _ in secondDeadlineGate.stream { break }
        }, receive: { _ in secondTimeout.continuation.yield(()) })
        for await _ in secondReadStarted.stream { break }
        secondDeadlineGate.continuation.yield(())
        for await _ in secondTimeout.stream { break }
        for _ in 0..<8 {
            let refused = DockFolderLoad.start(lane: lane, read: {
                reads += 1
                return DockFolderListing(denied: true)
            }, receive: { listing in #expect(listing == nil) })
            await refused.value
        }
        #expect(reads == 3, "Timed-out reads keep their slots until the filesystem returns")
        readGate.continuation.finish()
        secondReadGate.continuation.finish()
        await first.value
        await blocked.value
        let recovered = DockFolderLoad.start(lane: lane, read: {
            reads += 1
            return DockFolderListing(denied: true)
        }, receive: { listing in #expect(listing != nil) })
        await recovered.value
        #expect(reads == 4)
        deadlineGate.continuation.finish()
        timedOut.continuation.finish()
        secondDeadlineGate.continuation.finish()
        secondTimeout.continuation.finish()
        readStarted.continuation.finish()
        secondReadStarted.continuation.finish()
    }

    @Test func deadlineFinishesBeforeBlockedReadAndDropsItsLateResult() async {
        let readGate = AsyncStream<Void>.makeStream()
        let deadlineGate = AsyncStream<Void>.makeStream()
        let completion = AsyncStream<Void>.makeStream()
        var results: [Bool] = []
        let work = DockFolderLoad.start(lane: .init(), read: {
            for await _ in readGate.stream { break }
            return DockFolderListing(denied: true)
        }, waitForDeadline: {
            for await _ in deadlineGate.stream { break }
        }, receive: { listing in
            results.append(listing != nil)
            completion.continuation.yield(())
        })

        deadlineGate.continuation.yield(())
        for await _ in completion.stream { break }
        #expect(results == [false], "the deadline ends loading while the read is still blocked")

        readGate.continuation.yield(())
        await work.value
        #expect(results == [false], "a late read cannot replace failure")
        readGate.continuation.finish()
        deadlineGate.continuation.finish()
        completion.continuation.finish()
    }

    @Test func readFinishesFirstAndCancelsTheDeadline() async {
        let deadlineGate = AsyncStream<Void>.makeStream()
        let deadlineFinished = AsyncStream<Void>.makeStream()
        var results: [Bool?] = []
        let work = DockFolderLoad.start(lane: .init(), read: {
            DockFolderListing(denied: true)
        }, waitForDeadline: {
            for await _ in deadlineGate.stream { break }
            deadlineFinished.continuation.yield(())
        }, receive: { listing in
            results.append(listing?.denied)
        })

        await work.value
        #expect(results == [true])
        deadlineGate.continuation.yield(())
        deadlineGate.continuation.finish()
        for await _ in deadlineFinished.stream { break }
        #expect(results == [true], "the completed read remains the only result")
        deadlineFinished.continuation.finish()
    }
}
