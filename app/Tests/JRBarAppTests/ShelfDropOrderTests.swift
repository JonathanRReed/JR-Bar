import AppKit
import Foundation
import os
import Testing
import UniformTypeIdentifiers
@testable import JRBarApp

@Suite("Shelf drop order", .timeLimit(.minutes(2)))
@MainActor
struct ShelfDropOrderTests {
    private final class HeldProvider: NSItemProvider, @unchecked Sendable {
        private typealias Reply = @Sendable (Data?, Error?) -> Void
        private struct State {
            var reply: Reply?
            var delivered = false
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let starts = AsyncStream<Void>.makeStream()
        private let deliveries = AsyncStream<Void>.makeStream()

        func waitForStart() async -> Bool {
            if ready { return true }
            for await _ in starts.stream { return ready }
            return false
        }

        func waitForDelivery() async -> Bool {
            if delivered { return true }
            for await _ in deliveries.stream { return delivered }
            return false
        }

        override init() {
            super.init()
            let state = self.state
            let started = starts.continuation
            registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { reply in
                state.withLock { $0.reply = reply }
                started.yield(()); started.finish()
                return nil
            }
        }

        override func loadItem(
            forTypeIdentifier typeIdentifier: String,
            options: [AnyHashable: Any]? = nil,
            completionHandler: (@Sendable (NSSecureCoding?, Error?) -> Void)?
        ) {
            let state = self.state
            let delivered = deliveries.continuation
            super.loadItem(forTypeIdentifier: typeIdentifier, options: options) { item, error in
                completionHandler?(item, error)
                state.withLock { $0.delivered = true }
                delivered.yield(()); delivered.finish()
            }
        }

        var ready: Bool { state.withLock { $0.reply != nil } }
        var delivered: Bool { state.withLock { $0.delivered } }

        func finish(with url: URL?) {
            let reply = state.withLock { state in
                let reply = state.reply
                state.reply = nil
                return reply
            }
            if let url {
                reply?(url.dataRepresentation, nil)
            } else {
                reply?(nil, NSError(domain: "ShelfDropOrderTests", code: 1))
            }
        }
    }

    @Test("provider order survives reverse completion order")
    func reverseCompletion() async throws {
        let firstURL = URL(fileURLWithPath: "/tmp/jrbar-drop-order-first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/jrbar-drop-order-second.txt")
        let first = HeldProvider()
        let second = HeldProvider()
        var result: [URL]?
        let results = TestEvents<[URL]>()
        ShelfTrayDrop.urls(from: [first, second]) { result = $0; results.send($0) }
        let firstReady = await first.waitForStart()
        let secondReady = await second.waitForStart()
        let ready = firstReady && secondReady
        try #require(ready)
        second.finish(with: secondURL)
        let secondDelivered = await second.waitForDelivery()
        try #require(secondDelivered)
        #expect(result == nil)
        first.finish(with: firstURL)
        _ = try await results.next()
        #expect(result == [firstURL, secondURL])
    }

    @Test("failed providers leave successful URLs in provider order")
    func failurePreservesOrder() async throws {
        let firstURL = URL(fileURLWithPath: "/tmp/jrbar-drop-order-success-first.txt")
        let lastURL = URL(fileURLWithPath: "/tmp/jrbar-drop-order-success-last.txt")
        let first = HeldProvider()
        let failed = HeldProvider()
        let last = HeldProvider()
        var result: [URL]?
        let results = TestEvents<[URL]>()
        ShelfTrayDrop.urls(from: [first, failed, last]) { result = $0; results.send($0) }
        let firstReady = await first.waitForStart()
        let failureReady = await failed.waitForStart()
        let lastReady = await last.waitForStart()
        let ready = firstReady && failureReady && lastReady
        try #require(ready)
        last.finish(with: lastURL)
        let lastDelivered = await last.waitForDelivery()
        try #require(lastDelivered)
        failed.finish(with: nil)
        let failureDelivered = await failed.waitForDelivery()
        try #require(failureDelivered)
        #expect(result == nil)
        first.finish(with: firstURL)
        _ = try await results.next()
        #expect(result == [firstURL, lastURL])
    }
}
