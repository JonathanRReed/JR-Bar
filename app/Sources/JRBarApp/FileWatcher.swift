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
    private var descriptor: Int32 = -1
    private let handler: Handler
    private let mask: DispatchSource.FileSystemEvent

    init(path: String, mask: DispatchSource.FileSystemEvent = [.write, .extend, .attrib, .delete, .rename, .revoke, .link], handler: @escaping Handler) {
        self.path = path
        self.mask = mask
        self.handler = handler
    }

    var isActive: Bool { source != nil }

    /// Returns false when the path cannot be opened (missing volume, missing file).
    @discardableResult
    func start() -> Bool {
        stop()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return false }
        descriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        let handler = self.handler
        source.setEventHandler { [source] in
            let event = source.data
            MainActor.assumeIsolated { handler(event) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }
}
