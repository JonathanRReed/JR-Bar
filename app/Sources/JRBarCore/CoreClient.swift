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
    /// `$XDG_STATE_HOME/jrbar`, else `~/.local/state/jrbar` — the flat state
    /// directory `state_paths.default_state_dir` defines, where `latest.json`,
    /// `core.sock` and the logs land. The pre-rename `sidepulse/` tree is
    /// migrated once (and `agent-monitor/` is not even copied) and never
    /// written again: nothing here may read it.
    public static func stateDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
            return NSString(string: xdg).expandingTildeInPath + "/jrbar"
        }
        return NSString(string: "~/.local/state/jrbar").expandingTildeInPath
    }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["JRBAR_CORE_SOCKET"], !override.isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        return stateDirectory(environment: environment) + "/core.sock"
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
    /// How long a connected daemon may take to speak its `hello` before
    /// the client drops the socket and reconnects instead of parking at
    /// "connected, waiting for state" forever.
    public let helloTimeout: TimeInterval
    /// Bound on the nonblocking connect handshake.
    public let connectTimeout: TimeInterval
    /// Kernel-level per-send bound (SO_SNDTIMEO): a daemon that stops
    /// draining the socket can never block a write past this.
    public let writeTimeout: TimeInterval
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

    // MARK: Resumable event stream

    /// One daemon incarnation, one event stream. `lastEventCursor` is the
    /// resume point: every event frame carries `<stream>:<event id>` and
    /// `hello` carries the journal's tail, so a reconnect on the SAME
    /// stream asks `replay_events` for exactly the frames the drop ate.
    /// A different stream means the journal restarted — we anchor at its
    /// tail and never replay history this client never subscribed to.
    private var lastStream: String?
    private var lastEventCursor: String?
    private var lastEventSeq: Int?
    /// The in-flight `replay_events` command id; its reply is consumed
    /// here (replayed frames) instead of reaching the handler as a reply.
    private var replayReplyID: String?
    /// Bounded id ring for dedupe: replayed events overlap live ones —
    /// the journal answers with events the socket may already have fanned
    /// out — so an id delivered once is never delivered twice.
    private var deliveredEventIDs: [String] = []
    private var deliveredEventIDSet: Set<String> = []
    private let deliveredEventIDCap = 1024

    public init(socketPath: String = CoreSocketPath.resolve(), replyTimeout: TimeInterval = 10,
                helloTimeout: TimeInterval = 10, connectTimeout: TimeInterval = 5,
                writeTimeout: TimeInterval = 5,
                handler: @escaping @Sendable (Event) -> Void) {
        self.socketPath = socketPath
        self.replyTimeout = replyTimeout
        self.helloTimeout = helloTimeout
        self.connectTimeout = connectTimeout
        self.writeTimeout = writeTimeout
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
            // Arm the deadline BEFORE the write: it covers the whole
            // operation (a blocked write, a lost reply), not just the
            // wait for the reply frame.
            let timeout = timeout ?? replyTimeout
            let id = command.id
            Task.detached { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, let waiting = self.takePending(id) else { return }
                waiting.resume(throwing: CoreClientError.timeout)
                // A reply that never came means the daemon may be wedged
                // mid-read; drop the socket so the run loop reconnects
                // instead of leaving the connection half-dead.
                self.dropConnection(socket)
            }
            if let errno = writeAll(socket, bytes) {
                if let waiting = takePending(command.id) {
                    waiting.resume(throwing: CoreClientError.writeFailed(errno))
                }
                dropConnection(socket)
                return
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
        if let errno = writeAll(socket, bytes) {
            dropConnection(socket)
            throw CoreClientError.writeFailed(errno)
        }
    }

    /// Forces the read loop out of its blocking read so the run loop
    /// tears down and reconnects. `shutdown`, never `close`: the run
    /// loop owns the descriptor and closes it after `readLoop` returns;
    /// a second close could land on a recycled fd number.
    private func dropConnection(_ socket: Int32) {
        lock.lock()
        let current = fd == socket
        lock.unlock()
        if current { shutdown(socket, SHUT_RDWR) }
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
                // A zero write on a live descriptor is a silent stall;
                // treat it as a failure rather than spinning forever.
                if written == 0 { return EIO }
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
        // Kernel send deadline: every write(2) on this socket returns
        // EAGAIN instead of blocking past writeTimeout, so `writeAll`
        // (and therefore `send`/`post`) can never park on a peer that
        // stopped draining its receive buffer.
        var sendTimeout = timeval(
            tv_sec: Int(writeTimeout),
            tv_usec: Int32((writeTimeout - TimeInterval(Int(writeTimeout))) * 1_000_000)
        )
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        // A full listen backlog makes connect(2) block: run it
        // nonblocking and bound the handshake with poll.
        let previousFlags = fcntl(socket, F_GETFL)
        _ = fcntl(socket, F_SETFL, previousFlags | O_NONBLOCK)
        let length = socklen_t(MemoryLayout<sa_family_t>.size + MemoryLayout<UInt8>.size + pathBytes.count + 1)
        var result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, length) }
        }
        if result != 0, errno == EINPROGRESS {
            var descriptor = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
            let remaining = Int32(max(1, connectTimeout * 1000))
            let polled = poll(&descriptor, 1, remaining)
            if polled > 0 {
                var socketError: Int32 = 0
                var errorLength = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(socket, SOL_SOCKET, SO_ERROR, &socketError, &errorLength)
                result = socketError == 0 ? 0 : -1
            } else {
                result = -1
            }
        }
        // Back to blocking mode; writes stay bounded by SO_SNDTIMEO.
        _ = fcntl(socket, F_SETFL, previousFlags >= 0 ? previousFlags : 0)
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
        // A daemon that accepts but never speaks must not park the app at
        // "connected, waiting for state" forever: until hello lands, every
        // read is preceded by a poll bounded by the hello deadline.
        let helloDeadline = Date(timeIntervalSinceNow: helloTimeout)
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        while true {
            if !sawHello {
                let remaining = helloDeadline.timeIntervalSinceNow
                if remaining <= 0 {
                    return ("core sent no hello within \(Int(helloTimeout)) s", false)
                }
                var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
                let polled = poll(&descriptor, 1, Int32(max(1, remaining * 1000)))
                if polled == 0 {
                    return ("core sent no hello within \(Int(helloTimeout)) s", false)
                }
                if polled < 0 {
                    if errno == EINTR { continue }
                    if isStopped { return ("stopped", sawHello) }
                    return (String(cString: strerror(errno)), sawHello)
                }
                // Readable (or a hangup/error the read below reports).
            }
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
                    if case .hello(let hello) = message {
                        sawHello = true
                        beginResumableStream(hello: hello, socket: socket)
                    }
                    if case .reply(let reply) = message {
                        lock.lock()
                        let isReplay = reply.id == replayReplyID
                        if isReplay { replayReplyID = nil }
                        lock.unlock()
                        if isReplay {
                            deliverReplayedEvents(reply)
                            continue
                        }
                        if let waiting = takePending(reply.id) {
                            waiting.resume(returning: reply)
                        }
                    }
                    if case .event(let event) = message {
                        if markEventDelivered(event.id) { continue }
                        noteEventCursor(event.cursor)
                    }
                    handler(.message(message))
                } catch {
                    handler(.decodeFailure(String(describing: error)))
                }
            }
        }
    }

    // MARK: Replay (read thread only)

    /// Splits `<stream>:<event id>`; `ev-N` ids yield their sequence,
    /// custom ids yield nil (the journal still matches them by cursor).
    private static func splitCursor(_ cursor: String) -> (stream: String, seq: Int?)? {
        guard let colon = cursor.firstIndex(of: ":") else { return nil }
        let stream = String(cursor[cursor.startIndex..<colon])
        let identifier = String(cursor[cursor.index(after: colon)...])
        let seq = identifier.hasPrefix("ev-") ? Int(identifier.dropFirst(3)) : nil
        return (stream, seq)
    }

    /// Called when `hello` lands. Same stream + a cursor behind the
    /// daemon's tail means the drop ate frames: ask `replay_events` for
    /// the suffix. A new stream (first connect, daemon restart) anchors
    /// at the tail instead — replaying a restarted journal would surface
    /// events this client never subscribed to.
    private func beginResumableStream(hello: CoreHello, socket: Int32) {
        guard let stream = hello.stream else { return }
        lock.lock()
        let sameStream = stream == lastStream
        let resumeFrom = lastEventCursor
        lock.unlock()
        if sameStream, let resumeFrom, resumeFrom != hello.cursor {
            let command = CoreCommand(id: nextCommandID(), name: "replay_events",
                                      args: ["after": .string(resumeFrom)])
            guard let bytes = try? CoreCodec.encode(command: command) else { return }
            lock.lock()
            replayReplyID = command.id
            lock.unlock()
            // A failed write leaves the socket half-dead; the read below
            // fails, the loop reconnects, and the next hello retries the
            // replay — resumeFrom still points where it did.
            if writeAll(socket, bytes) != nil {
                lock.lock()
                replayReplyID = nil
                lock.unlock()
            }
            return
        }
        lock.lock()
        lastStream = stream
        lastEventCursor = hello.cursor
        lastEventSeq = hello.cursor.flatMap { Self.splitCursor($0)?.seq } ?? nil
        // Ids restart with the stream; keeping the old ring would let a
        // new incarnation's `ev-1` look like a duplicate.
        deliveredEventIDs.removeAll()
        deliveredEventIDSet.removeAll()
        replayReplyID = nil
        lock.unlock()
    }

    /// Advances the resume point, never backwards: a replayed cursor is
    /// older than live frames that raced past the reply, so a stale
    /// sequence must not pull `lastEventCursor` back.
    private func noteEventCursor(_ cursor: String?) {
        guard let cursor, let (stream, seq) = Self.splitCursor(cursor) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard stream == lastStream else { return }
        if let seq, let last = lastEventSeq, seq <= last { return }
        if seq != nil { lastEventSeq = seq }
        lastEventCursor = cursor
    }

    /// True when this event id already reached the handler — the frame
    /// is a replay/live overlap and must not be delivered twice.
    private func markEventDelivered(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if deliveredEventIDSet.contains(id) { return true }
        deliveredEventIDs.append(id)
        deliveredEventIDSet.insert(id)
        if deliveredEventIDs.count > deliveredEventIDCap {
            deliveredEventIDSet.remove(deliveredEventIDs.removeFirst())
        }
        return false
    }

    /// Consumes the `replay_events` reply on the read thread. Journal
    /// entries decode exactly like wire events and run through the same
    /// dedupe, so the suffix lands once even when the socket already
    /// fanned some of it out. `resync_required` re-anchors at the live
    /// tail the daemon returned — the gap stays honest (state snapshots
    /// resync the UI; nothing here fabricates events).
    private func deliverReplayedEvents(_ reply: CoreReply) {
        guard reply.ok, let result = reply.result else { return }
        if result["resync_required"]?.boolValue == true {
            if let cursor = result["cursor"]?.stringValue {
                noteEventCursor(cursor)
            }
            return
        }
        guard let events = result["events"]?.arrayValue else { return }
        for value in events {
            guard let data = try? JSONEncoder().encode(value),
                  let event = try? JSONDecoder().decode(CoreEvent.self, from: data) else { continue }
            if markEventDelivered(event.id) { continue }
            handler(.message(.event(event)))
        }
        // The reply's cursor is the last RETURNED event's position —
        // advancing to it once keeps a live frame that raced past the
        // reply from being pulled backwards by a replayed one.
        if let cursor = result["cursor"]?.stringValue {
            noteEventCursor(cursor)
        }
    }
}
