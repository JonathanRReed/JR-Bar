import Darwin
import Foundation

/// Each child keeps its own partial lines. Reads and delivery share the supervisor queue.
final class CoreProcessOutput: @unchecked Sendable {
    // Darwin sys/filio.h: _IOR('f', 127, int) is not imported into Swift.
    private static let readableByteCountRequest: UInt = 0x4004667f
    private enum Stream: String, Sendable { case stdout, stderr }
    private let stdout: FileHandle
    private let stderr: FileHandle
    private let queue: DispatchQueue
    private let emit: @Sendable (String, String) -> Void
    private let lock = NSLock()
    private var pending: Set<Stream> = []
    private var ended: Set<Stream> = []
    private var finishing = false
    private var prepared = false
    private var stdoutSplitter = NDJSONSplitter()
    private var stderrSplitter = NDJSONSplitter()

    init(stdout: FileHandle, stderr: FileHandle, queue: DispatchQueue,
         emit: @escaping @Sendable (String, String) -> Void) {
        self.stdout = stdout
        self.stderr = stderr
        self.queue = queue
        self.emit = emit
    }

    func start() throws {
        for handle in [stdout, stderr] {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        lock.withLock { prepared = true }
        stdout.readabilityHandler = { [weak self] _ in self?.requestRead(.stdout) }
        stderr.readabilityHandler = { [weak self] _ in self?.requestRead(.stderr) }
    }

    private func handle(_ stream: Stream) -> FileHandle { stream == .stdout ? stdout : stderr }

    private func requestRead(_ stream: Stream) {
        lock.lock()
        guard !finishing, !ended.contains(stream), pending.insert(stream).inserted else { lock.unlock(); return }
        queue.async { [self] in
            readSnapshot(stream)
            lock.withLock { _ = pending.remove(stream) }
            if (bufferedBytes(stream) ?? 0) > 0 { requestRead(stream) }
        }
        lock.unlock()
    }

    private func bufferedBytes(_ stream: Stream) -> Int? {
        var count: Int32 = 0
        while true {
            let result = ioctl(handle(stream).fileDescriptor, Self.readableByteCountRequest, &count)
            let error = errno
            if result == 0 { return max(0, Int(count)) }
            if error != EINTR { return nil }
        }
    }

    private func readSnapshot(_ stream: Stream) {
        let reader = handle(stream)
        // A finite snapshot also finishes when a descendant keeps writing.
        var remaining = max(1, bufferedBytes(stream) ?? 64 * 1024)
        var bytes = [UInt8](repeating: 0, count: min(64 * 1024, remaining))
        while remaining > 0 {
            let length = min(bytes.count, remaining)
            let (count, error) = bytes.withUnsafeMutableBytes { raw in
                let count = Darwin.read(reader.fileDescriptor, raw.baseAddress, length)
                return (count, errno)
            }
            if count > 0 {
                let data = Data(bytes[0..<count])
                let frames = stream == .stdout ? stdoutSplitter.feed(data) : stderrSplitter.feed(data)
                for frame in frames { emit(stream.rawValue, String(decoding: frame, as: UTF8.self)) }
                remaining -= count
            } else if count == 0 {
                lock.withLock { _ = ended.insert(stream) }
                reader.readabilityHandler = nil
                return
            } else if error != EINTR {
                return
            }
        }
    }

    func finish(then completion: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !finishing else { lock.unlock(); return }
        finishing = true
        queue.async { [self] in
            stdout.readabilityHandler = nil
            stderr.readabilityHandler = nil
            if lock.withLock({ prepared }) {
                readSnapshot(.stdout)
                readSnapshot(.stderr)
            }
            if let tail = stdoutSplitter.finish() { emit("stdout", String(decoding: tail, as: UTF8.self)) }
            if let tail = stderrSplitter.finish() { emit("stderr", String(decoding: tail, as: UTF8.self)) }
            try? stdout.close()
            try? stderr.close()
            completion()
        }
        lock.unlock()
    }
}
