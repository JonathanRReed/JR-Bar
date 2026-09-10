import Darwin
import Foundation

public enum CoreClientError: Error, Equatable, CustomStringConvertible {
    case notConnected
    case disconnected
    case timeout
    case writeFailed(Int32)
    case stopped

    public var description: String {
        switch self {
        case .notConnected: return "core is not connected"
        case .disconnected: return "core disconnected before replying"
        case .timeout: return "core did not reply in time"
        case .writeFailed(let errno): return "write failed: \(String(cString: strerror(errno)))"
        case .stopped: return "client stopped"
        }
    }
}

/// Where the daemon's socket lives: `JRBAR_CORE_SOCKET`, else
/// `$XDG_STATE_HOME/jrbar/core.sock`, else `~/.local/state/jrbar/core.sock`.
public enum CoreSocketPath {
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["JRBAR_CORE_SOCKET"], !override.isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
            return NSString(string: xdg).expandingTildeInPath + "/jrbar/core.sock"
        }
        return NSString(string: "~/.local/state/jrbar/core.sock").expandingTildeInPath
    }
}

/// The reconnect schedule from the protocol: 0.5 s, 1 s, 2 s, then capped at 5 s.
public enum CoreBackoff {
    public static let cap: TimeInterval = 5.0

    public static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = min(failures - 1, 8)
        return min(cap, 0.5 * pow(2.0, Double(exponent)))
    }
}

/// A Unix-socket NDJSON client for the core daemon.
///
/// One background thread owns the socket: connect, read, split frames,
/// decode, hand each message to the handler (on that thread; `CoreModel`
/// hops to the main actor). Writes come from any thread, serialised by a
/// lock, and each `command` waits for the `reply` carrying its id. When the
/// socket drops every pending command fails with `.disconnected` and the
/// thread reconnects on the protocol's backoff schedule.
public final class CoreClient: @unchecked Sendable {
    public enum Event: Sendable {
        case connecting(attempt: Int)
        case connected
        case message(CoreMessage)
        case decodeFailure(String)
        case disconnected(reason: String)
    }

    public let socketPath: String
    public let replyTimeout: TimeInterval
    private let handler: @Sendable (Event) -> Void

    private let lock = NSLock()
    private let wakeup = NSCondition()
    private var thread: Thread?
    private var stopped = false
    private var retryRequested = false
    private var fd: Int32 = -1
    private var commandCounter = 0
    private var pending: [String: CheckedContinuation<CoreReply, Error>] = [:]
    private var _isConnected = false
    /// The local user id the socket's peer must present (the daemon checks
    /// ours, we check theirs). Nil disables the check.
    public var expectedPeerUID: uid_t? = getuid()

    public init(socketPath: String = CoreSocketPath.resolve(), replyTimeout: TimeInterval = 10, handler: @escaping @Sendable (Event) -> Void) {
        self.socketPath = socketPath
        self.replyTimeout = replyTimeout
        self.handler = handler
    }

    deinit { stop() }

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isConnected
    }

    // MARK: Lifecycle

    public func start() {
        lock.lock()
        if thread != nil { lock.unlock(); return }
        stopped = false
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "jrbar.core.client"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        lock.unlock()
        thread.start()
    }

    public func stop() {
        lock.lock()
        stopped = true
        let fd = self.fd
        self.fd = -1
        _isConnected = false
        let waiting = pending
        pending.removeAll()
        thread = nil
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        for (_, continuation) in waiting { continuation.resume(throwing: CoreClientError.stopped) }
        wakeup.lock()
        wakeup.broadcast()
        wakeup.unlock()
    }

    /// Skip the rest of the current backoff wait (a socket file just appeared).
    public func retryNow() {
        wakeup.lock()
        retryRequested = true
        wakeup.broadcast()
        wakeup.unlock()
    }

    // MARK: Commands

    public func nextCommandID() -> String {
        lock.lock(); defer { lock.unlock() }
        commandCounter += 1
        return "c-\(commandCounter)"
    }

    /// Sends a command and waits for its reply (`ok` or not; an error
    /// reply is returned, not thrown). Throws when the socket is down.
    /// `timeout` overrides `replyTimeout` for one command (a cold
    /// `usage_history` scan can take tens of seconds).
    public func send(name: String, args: [String: JSONValue] = [:], timeout: TimeInterval? = nil) async throws -> CoreReply {
        let command = CoreCommand(id: nextCommandID(), name: name, args: args)
        let bytes = try CoreCodec.encode(command: command)
        let reply: CoreReply = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard _isConnected, fd >= 0 else {
                lock.unlock()
                continuation.resume(throwing: CoreClientError.notConnected)
                return
            }
            pending[command.id] = continuation
            let socket = fd
            lock.unlock()
            if let errno = writeAll(socket, bytes) {
                if let waiting = takePending(command.id) {
                    waiting.resume(throwing: CoreClientError.writeFailed(errno))
                }
                return
            }
            let timeout = timeout ?? replyTimeout
            let id = command.id
            Task.detached { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                if let waiting = self?.takePending(id) {
                    waiting.resume(throwing: CoreClientError.timeout)
                }
            }
        }
        return reply
    }

    /// Fire-and-forget variant; the reply is delivered as a `.message(.reply)` event.
    public func post(name: String, args: [String: JSONValue] = [:]) throws {
        let command = CoreCommand(id: nextCommandID(), name: name, args: args)
        let bytes = try CoreCodec.encode(command: command)
        lock.lock()
        let socket = fd
        let connected = _isConnected
        lock.unlock()
        guard connected, socket >= 0 else { throw CoreClientError.notConnected }
        if let errno = writeAll(socket, bytes) { throw CoreClientError.writeFailed(errno) }
    }

    private func takePending(_ id: String) -> CheckedContinuation<CoreReply, Error>? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }

    private let writeLock = NSLock()

    /// Returns errno on failure.
    private func writeAll(_ socket: Int32, _ data: Data) -> Int32? {
        writeLock.lock(); defer { writeLock.unlock() }
        var offset = 0
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32? in
            guard let base = raw.baseAddress else { return nil }
            while offset < raw.count {
                let written = Darwin.write(socket, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += written
            }
            return nil
        }
    }

    // MARK: Thread

    private func run() {
        var failures = 0
        while !isStopped {
            let attempt = failures + 1
            handler(.connecting(attempt: attempt))
            guard let socket = connect() else {
                failures += 1
                wait(CoreBackoff.delay(afterFailures: failures))
                continue
            }
            lock.lock()
            fd = socket
            _isConnected = true
            lock.unlock()
            handler(.connected)
            let (reason, sawHello) = readLoop(socket)
            lock.lock()
            let wasStopped = stopped
            if fd == socket { fd = -1 }
            _isConnected = false
            let waiting = pending
            pending.removeAll()
            lock.unlock()
            if !wasStopped { close(socket) }
            for (_, continuation) in waiting { continuation.resume(throwing: CoreClientError.disconnected) }
            handler(.disconnected(reason: reason))
            if wasStopped { break }
            // A connection that got as far as hello resets the schedule.
            failures = sawHello ? 1 : failures + 1
            wait(CoreBackoff.delay(afterFailures: failures))
        }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func wait(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let deadline = Date(timeIntervalSinceNow: seconds)
        wakeup.lock()
        while !retryRequested, !isStopped, Date() < deadline {
            wakeup.wait(until: deadline)
        }
        retryRequested = false
        wakeup.unlock()
    }

    private func connect() -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let length = socklen_t(MemoryLayout<sa_family_t>.size + MemoryLayout<UInt8>.size + pathBytes.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, length) }
        }
        guard result == 0 else {
            close(socket)
            return nil
        }
        if let expected = expectedPeerUID {
            var uid: uid_t = 0
            var gid: gid_t = 0
            if getpeereid(socket, &uid, &gid) == 0, uid != expected {
                close(socket)
                handler(.decodeFailure("refusing socket owned by uid \(uid)"))
                return nil
            }
        }
        return socket
    }

    /// Reads until EOF or error. Returns why, and whether a hello arrived.
    private func readLoop(_ socket: Int32) -> (String, Bool) {
        var splitter = NDJSONSplitter()
        var sawHello = false
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in Darwin.read(socket, raw.baseAddress, chunk) }
            if count == 0 { return ("core closed the socket", sawHello) }
            if count < 0 {
                if errno == EINTR { continue }
                if isStopped { return ("stopped", sawHello) }
                return (String(cString: strerror(errno)), sawHello)
            }
            for frame in splitter.feed(Data(buffer[0..<count])) {
                do {
                    let message = try CoreCodec.decode(frame: frame)
                    if case .hello = message { sawHello = true }
                    if case .reply(let reply) = message, let waiting = takePending(reply.id) {
                        waiting.resume(returning: reply)
                    }
                    handler(.message(message))
                } catch {
                    handler(.decodeFailure(String(describing: error)))
                }
            }
        }
    }
}
