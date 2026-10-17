import CoreVideo
import Foundation
import Testing
@testable import JRBarApp

@Suite("Fold latest frame delivery")
@MainActor
struct FoldFrameDeliveryTests {
    private final class Scheduler: @unchecked Sendable {
        private let lock = NSLock()
        private var jobs: [@MainActor @Sendable () -> Void] = []

        func enqueue(_ work: @escaping @MainActor @Sendable () -> Void) {
            lock.withLock { jobs.append(work) }
        }

        var count: Int { lock.withLock { jobs.count } }

        @MainActor
        func runNext() {
            let work = lock.withLock { jobs.removeFirst() }
            work()
        }
    }

    private func frame(_ width: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, 2,
                                         kCVPixelFormatType_32BGRA, nil, &buffer)
        #expect(result == kCVReturnSuccess)
        return try #require(buffer)
    }

    @Test("a busy main actor receives the latest frame without a task per frame")
    func latestOnly() throws {
        let queue = Scheduler()
        var widths: [Int] = []
        let delivery = FoldFrameDelivery(enqueue: { queue.enqueue($0) }, deliver: {
            widths.append(CVPixelBufferGetWidth($0))
        })
        for width in 1...20 { delivery.submit(try frame(width)) }
        #expect(queue.count == 1)
        queue.runNext()
        #expect(widths == [20])
        delivery.submit(try frame(21))
        #expect(queue.count == 1)
        queue.runNext()
        #expect(widths == [20, 21])
    }

    @Test("a discarded callback cannot consume a replacement run's frame")
    func discardPending() throws {
        let queue = Scheduler()
        var widths: [Int] = []
        let delivery = FoldFrameDelivery(enqueue: { queue.enqueue($0) }, deliver: {
            widths.append(CVPixelBufferGetWidth($0))
        })
        delivery.submit(try frame(1))
        delivery.discard()
        delivery.submit(try frame(2))
        #expect(queue.count == 2)
        queue.runNext()
        #expect(widths.isEmpty)
        queue.runNext()
        #expect(widths == [2])
    }

    @Test("delivery can accept another frame without holding the mailbox lock")
    func reentrantSubmission() throws {
        let queue = Scheduler()
        @Captured var delivery: FoldFrameDelivery? = nil
        defer { delivery = nil }
        let next = try frame(2)
        var widths: [Int] = []
        delivery = FoldFrameDelivery(enqueue: { queue.enqueue($0) }, deliver: {
            widths.append(CVPixelBufferGetWidth($0))
            if widths.count == 1 { delivery?.submit(next) }
        })
        delivery?.submit(try frame(1))
        queue.runNext()
        #expect(widths == [1])
        #expect(queue.count == 1)
        queue.runNext()
        #expect(widths == [1, 2])
    }
}
