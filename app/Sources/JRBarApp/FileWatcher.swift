import Foundation

/// A kqueue vnode watch on one path, delivered on the main queue.
///
/// Opened with `O_EVTONLY` so the descriptor never pins a removable volume,
/// and torn down on delete/rename/revoke so a caller can re-arm once the path
/// exists again. No polling: the kernel wakes us.
@MainActor
final class FileWatcher {
    typealias Handler = @MainActor (DispatchSource.FileSystemEvent) -> Void

    let path: String
    private var source: DispatchSourceFileSystemObject?
    private var generation = 0
    private var opening: Task<Void, Never>?
    private let handler: Handler
    private let mask: DispatchSource.FileSystemEvent

    init(path: String, mask: DispatchSource.FileSystemEvent = [.write, .extend, .attrib, .delete, .rename, .revoke, .link], handler: @escaping Handler) {
        self.path = path
        self.mask = mask
        self.handler = handler
    }

    var isActive: Bool { source != nil }

    /// Schedules the open. A missing path stays inactive; a late open is closed.
    @discardableResult
    func start() -> Bool {
        stop()
        let current = generation
        let path = self.path
        opening = Task { [weak self] in
            let opened = await Self.opens.resolve(OpenRequest(path: path, generation: UUID()))
            guard let opened else { return }
            guard let self, self.generation == current, !Task.isCancelled else { opened.discard(); return }
            let fd = opened.take()
            guard fd >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: self.mask, queue: .main)
            let handler = self.handler
            source.setEventHandler { [source] in
                let event = source.data
                MainActor.assumeIsolated { handler(event) }
            }
            source.setCancelHandler { DispatchQueue.global(qos: .utility).async { close(fd) } }
            source.resume()
            self.source = source
        }
        return true
    }

    private struct OpenRequest: Hashable, Sendable {
        let path: String
        let generation: UUID
    }

    private final class Opened: @unchecked Sendable {
        private var fd: Int32
        init(_ fd: Int32) { self.fd = fd }
        func take() -> Int32 { let result = fd; fd = -1; return result }
        func discard() {
            let descriptor = take()
            if descriptor >= 0 { DispatchQueue.global(qos: .utility).async { close(descriptor) } }
        }
        deinit {
            let descriptor = fd
            if descriptor >= 0 { DispatchQueue.global(qos: .utility).async { close(descriptor) } }
        }
    }

    private static let opens = BackgroundLookupCache<OpenRequest, Opened>(load: { request in
        let fd = open(request.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        return fd >= 0 ? Opened(fd) : nil
    })

    func stop() {
        generation += 1
        opening?.cancel()
        opening = nil
        source?.cancel()
        source = nil
    }
}
