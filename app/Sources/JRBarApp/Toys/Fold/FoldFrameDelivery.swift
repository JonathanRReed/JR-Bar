import CoreVideo
import Foundation

/// Holds one pending frame while the main actor is busy.
final class FoldFrameDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CVPixelBuffer?
    private var queued = false
    private var generation: UInt64 = 0
    private let enqueue: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let deliver: @MainActor @Sendable (CVPixelBuffer) -> Void

    init(enqueue: @escaping @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { work in
        Task { @MainActor in work() }
    }, deliver: @escaping @MainActor @Sendable (CVPixelBuffer) -> Void) {
        self.enqueue = enqueue
        self.deliver = deliver
    }

    func submit(_ frame: CVPixelBuffer) {
        lock.lock()
        pending = frame
        guard !queued else { lock.unlock(); return }
        queued = true
        let ticket = generation
        lock.unlock()
        enqueue { [weak self] in self?.drain(ticket) }
    }

    func discard() {
        lock.lock()
        generation &+= 1
        pending = nil
        queued = false
        lock.unlock()
    }

    @MainActor
    private func drain(_ ticket: UInt64) {
        lock.lock()
        guard ticket == generation else { lock.unlock(); return }
        let frame = pending
        pending = nil
        queued = false
        lock.unlock()
        if let frame { deliver(frame) }
    }
}
