import Foundation

/// A folder deadline can finish while its filesystem read is still blocked.
/// Only the first result reaches the preview.
@MainActor
final class DockFolderLoad {
    @MainActor
    final class Lane {
        static let shared = Lane()
        private var activeReads = 0
        private let limit = 2

        func acquire() -> Bool {
            guard activeReads < limit else { return false }
            activeReads += 1
            return true
        }

        func release() { activeReads -= 1 }
    }

    private var receive: (@MainActor (DockFolderListing?) -> Void)?

    private init(receive: @escaping @MainActor (DockFolderListing?) -> Void) {
        self.receive = receive
    }

    private func finish(_ listing: DockFolderListing?) {
        let callback = receive
        receive = nil
        callback?(listing)
    }

    @discardableResult
    static func start(
        lane: Lane = .shared,
        read: @escaping @MainActor () async -> DockFolderListing,
        waitForDeadline: @escaping @MainActor () async throws -> Void = {
            try await Task.sleep(for: .seconds(6))
        },
        receive: @escaping @MainActor (DockFolderListing?) -> Void
    ) -> Task<Void, Never> {
        let load = DockFolderLoad(receive: receive)
        guard lane.acquire() else {
            load.finish(nil)
            return Task {}
        }
        let deadline = Task { @MainActor in
            do { try await waitForDeadline() } catch { return }
            guard !Task.isCancelled else { return }
            load.finish(nil)
        }
        return Task { @MainActor in
            // A timeout ends the preview, not an uninterruptible filesystem read.
            defer { lane.release(); deadline.cancel() }
            let listing = await read()
            load.finish(listing)
        }
    }
}
