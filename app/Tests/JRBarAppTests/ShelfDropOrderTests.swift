import AppKit
import Foundation
import os
import Testing
import UniformTypeIdentifiers
@testable import JRBarApp

@Suite("Shelf drop order", .timeLimit(.minutes(1)))
@MainActor
struct ShelfDropOrderTests {
    private final class HeldProvider: NSItemProvider, @unchecked Sendable {
        private typealias Reply = @Sendable (Data?, Error?) -> Void
        private struct State {
            var reply: Reply?
            var delivered = false
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        override init() {
            super.init()
            let state = self.state
            registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { reply in
                state.withLock { $0.reply = reply }
                return nil
            }
        }

        override func loadItem(
            forTypeIdentifier typeIdentifier: String,
            options: [AnyHashable: Any]? = nil,
            completionHandler: (@Sendable (NSSecureCoding?, Error?) -> Void)?
        ) {
            let state = self.state
            super.loadItem(forTypeIdentifier: typeIdentifier, options: options) { item, error in
                completionHandler?(item, error)
                state.withLock { $0.delivered = true }
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

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !condition(), clock.now < deadline { await Task.yield() }
        return condition()
    }

    @Test("provider order survives reverse completion order")
    func reverseCompletion() async throws {
        let firstURL = URL(fileURLWithPath: "/tmp/jrbar-drop-order-first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/jrbar-drop-order-second.txt")
        let first = HeldProvider()
        let second = HeldProvider()
        var result: [URL]?
        ShelfTrayDrop.urls(from: [first, second]) { result = $0 }
        let ready = await waitUntil { first.ready && second.ready }
        try #require(ready)
        second.finish(with: secondURL)
        let secondDelivered = await waitUntil { second.delivered }
        try #require(secondDelivered)
        #expect(result == nil)
        first.finish(with: firstURL)
        let completed = await waitUntil { result != nil }
        try #require(completed)
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
        ShelfTrayDrop.urls(from: [first, failed, last]) { result = $0 }
        let ready = await waitUntil { first.ready && failed.ready && last.ready }
        try #require(ready)
        last.finish(with: lastURL)
        let lastDelivered = await waitUntil { last.delivered }
        try #require(lastDelivered)
        failed.finish(with: nil)
        let failureDelivered = await waitUntil { failed.delivered }
        try #require(failureDelivered)
        #expect(result == nil)
        first.finish(with: firstURL)
        let completed = await waitUntil { result != nil }
        try #require(completed)
        #expect(result == [firstURL, lastURL])
    }
}
