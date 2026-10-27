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
        case .notConnected: return MonitorWords.sentence
        case .disconnected: return "\(MonitorWords.sentence) The command was interrupted."
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

/// Reply deadlines use elapsed time in the app and a manual clock in tests.
public struct CoreReplyClock: Sendable {
    public let schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    public init(schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void) {
        self.schedule = schedule
    }

    public static let continuous = CoreReplyClock { seconds, expire in
        _ = Task.detached {
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            expire()
        }
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
        /// A `state` frame could not be used: too big, broken, or from a
        /// protocol this app does not speak. The model it replaces is no
        /// longer current; the next good frame clears this.
        case stateRejected(String)
        case disconnected(reason: String)
        /// The daemon accepted this connection's proof: privileged commands
        /// (`answer_ask`, `set_setting` for a consent key, ...) now work on it.
        case authenticated
        /// This connection could not be authenticated. It stays open for the
        /// reads the daemon gives every client, and the app decides what to do.
        case authRefused(CoreAuthRefusal)
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
    /// Probe a quiet connection with the protocol's existing ping command.
    /// Busy connections already have command deadlines and are left alone.
    public let idleProbeInterval: TimeInterval
    private let replyClock: CoreReplyClock
    private let handler: @Sendable (Event) -> Void
    /// The app's secret and the pid of the daemon it started. Nil: this client
    /// never authenticates (a client of a daemon the app did not start).
    private let auth: CoreAuthSecret?

    private let lock = NSLock()
    private let wakeup = NSCondition()
    private var thread: Thread?
    /// A restart waits until the current socket owner has finished stopping.
    private var restartAfterStop = false
    private var stopped = false
    private var retryRequested = false
    private var fd: Int32 = -1
    private var connectionGeneration: UInt64 = 0
    private var commandCounter = 0
    private var pending: [String: CheckedContinuation<CoreReply, Error>] = [:]
    private var _isConnected = false
    // Authentication, per connection (guarded by `lock`). A client holding a
    // secret sends nothing else until the `auth` exchange has settled, one way
    // or the other, so a privileged command is never the first to arrive.
    private var authExpected = false
    private var authSettled = true
    private var _isAuthenticated = false
    private var authReplyID: String?
    private var authWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    /// Decoded-frame counter, bumped on the read thread. A reply timeout
    /// that watched frames arrive knows the daemon is alive — the command
    /// is queued behind a slow sibling (dispatch serializes per socket),
    /// not lost to a wedged read path — so the socket survives.
    private var framesSeen: UInt64 = 0
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
    /// A lost replay reply must not suppress transport checks forever.
    /// Keep its id after this deadline so a late replay still lands.
    private var replayBusyUntil: ContinuousClock.Instant?
    /// Bounded id ring for dedupe: replayed events overlap live ones —
    /// the journal answers with events the socket may already have fanned
    /// out — so an id delivered once is never delivered twice.
    private var deliveredEventIDs: [String] = []
    private var deliveredEventIDSet: Set<String> = []
    private let deliveredEventIDCap = 1024

    public init(socketPath: String = CoreSocketPath.resolve(), replyTimeout: TimeInterval = 10,
                helloTimeout: TimeInterval = 10, connectTimeout: TimeInterval = 5,
                writeTimeout: TimeInterval = 5, idleProbeInterval: TimeInterval = 30,
                replyClock: CoreReplyClock = .continuous,
                auth: CoreAuthSecret? = nil,
                handler: @escaping @Sendable (Event) -> Void) {
        self.auth = auth
        self.replyClock = replyClock
        self.socketPath = socketPath
        self.replyTimeout = replyTimeout
        self.helloTimeout = helloTimeout
        self.connectTimeout = connectTimeout
        self.writeTimeout = writeTimeout
        self.idleProbeInterval = idleProbeInterval.isFinite && idleProbeInterval > 0 ? idleProbeInterval : 30
        self.handler = handler
    }

    deinit { stop() }

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isConnected
    }

    /// Whether the daemon has accepted this connection's proof.
    public var isAuthenticated: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isAuthenticated
    }

    // MARK: Lifecycle

    public func start() {
        lock.lock()
        if thread != nil {
            if stopped { restartAfterStop = true }
            lock.unlock()
            return
        }
        stopped = false
        let thread = makeThread()
        self.thread = thread
        lock.unlock()
        thread.start()
    }

    private func makeThread() -> Thread {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "jrbar.core.client"
        thread.qualityOfService = .userInitiated
        return thread
    }

    public func stop() {
        lock.lock()
        stopped = true
        restartAfterStop = false
        let fd = self.fd
        _isConnected = false
        let waiting = pending
        pending.removeAll()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
        }
        lock.unlock()
        for (_, continuation) in waiting { continuation.resume(throwing: CoreClientError.stopped) }
        settleAuth()
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
    /// Cancellation retires queued commands and pending replies. It cannot
    /// undo a write already admitted, and never closes the shared socket.
    public func send(name: String, args: [String: JSONValue] = [:], timeout: TimeInterval? = nil) async throws -> CoreReply {
        try await send(name: name, args: args, timeout: timeout, idleGeneration: nil)
    }

    private func send(name: String, args: [String: JSONValue] = [:], timeout: TimeInterval? = nil,
                      idleGeneration: UInt64?) async throws -> CoreReply {
        try Task.checkCancellation()
        let command = CoreCommand(id: nextCommandID(), name: name, args: args)
        let bytes = try CoreCodec.encode(command: command)
        if idleGeneration == nil { try await waitUntilAuthSettled(id: command.id) }
        try Task.checkCancellation()
        let reply: CoreReply = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard _isConnected, fd >= 0 else {
                    lock.unlock()
                    continuation.resume(throwing: CoreClientError.notConnected)
                    return
                }
                if let idleGeneration,
                   !Self.idleProbeEligible(connected: _isConnected, stopped: stopped,
                                           authSettled: authSettled, pendingCount: pending.count,
                                           replayPending: replayIsBusy(),
                                           generation: connectionGeneration, expectedGeneration: idleGeneration) {
                    lock.unlock()
                    continuation.resume(throwing: CoreClientError.notConnected)
                    return
                }
                pending[command.id] = continuation
                let socket = fd
                let generation = connectionGeneration
                let framesAtSend = framesSeen
                lock.unlock()
                // Arm the deadline BEFORE the write: it covers the whole
                // operation (a blocked write, a lost reply), not just the
                // wait for the reply frame.
                let timeout = timeout ?? replyTimeout
                let id = command.id
                replyClock.schedule(timeout) { [weak self] in
                    guard let self, let waiting = self.takePending(id) else { return }
                    waiting.resume(throwing: CoreClientError.timeout)
                    // Frames arriving during the wait prove the daemon is
                    // alive and the socket healthy — commands serialize per
                    // connection, so a slow sibling (a cold usage scan) is
                    // what delayed this reply. Dropping here would kill the
                    // in-flight command too; only a silent socket is dropped.
                    if self.framesSeenCount() == framesAtSend {
                        if idleGeneration != nil { self.dropIdleConnection(socket, generation: generation) }
                        else { self.dropConnection(socket, generation: generation) }
                    }
                }
                if let errno = writeAll(socket, bytes, generation: generation, commandID: command.id) {
                    if let waiting = takePending(command.id) {
                        waiting.resume(throwing: CoreClientError.writeFailed(errno))
                    }
                    dropConnection(socket, generation: generation)
                    return
                }
            }
        } onCancel: {
            self.takePending(command.id)?.resume(throwing: CancellationError())
        }
        return reply
    }

    /// Forces the read loop out of its blocking read so the run loop
    /// tears down and reconnects. `shutdown`, never `close`: the run
    /// loop owns the descriptor and closes it after `readLoop` returns;
    /// a second close could land on a recycled fd number.
    private func dropConnection(_ socket: Int32, generation: UInt64) {
        lock.lock()
        if fd == socket && connectionGeneration == generation { shutdown(socket, SHUT_RDWR) }
        lock.unlock()
    }

    /// A real command admitted after the probe owns its own deadline.
    /// Check and shut down atomically so a slow usage scan is not cut off.
    private func dropIdleConnection(_ socket: Int32, generation: UInt64) {
        lock.lock()
        if fd == socket,
           Self.idleProbeEligible(connected: _isConnected, stopped: stopped,
                                  authSettled: authSettled, pendingCount: pending.count,
                                  replayPending: replayIsBusy(),
                                  generation: connectionGeneration, expectedGeneration: generation) {
            shutdown(socket, SHUT_RDWR)
        }
        lock.unlock()
    }

    /// Synchronous lock wrapper — `NSLock` is banned inside async
    /// contexts, so the timeout task reads the counter through here.
    private func framesSeenCount() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return framesSeen
    }

    private func takePending(_ id: String) -> CheckedContinuation<CoreReply, Error>? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }

    // Internal so tests can hold writes until a queued command expires.
    let writeLock = NSLock()

    var pendingCommandCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    var pendingReplayCommandID: String? {
        lock.lock(); defer { lock.unlock() }
        return replayReplyID
    }

    var authenticationWaiterCount: Int {
        lock.lock(); defer { lock.unlock() }
        return authWaiters.count
    }

    /// Returns errno on failure.
    private func writeAll(_ socket: Int32, _ data: Data, generation: UInt64? = nil,
                          commandID: String? = nil) -> Int32? {
        writeLock.lock(); defer { writeLock.unlock() }
        lock.lock()
        // Admission and timeout removal share this lock. A command that
        // expired while waiting for the writer must never reach the daemon.
        // Once admitted, its write may already be in progress at its deadline.
        if let commandID, pending[commandID] == nil {
            lock.unlock()
            return nil
        }
        guard !stopped, _isConnected, fd == socket,
              generation == nil || generation == connectionGeneration else {
            lock.unlock()
            return ENOTCONN
        }
        let writer = dup(socket)
        let duplicationError = errno
        lock.unlock()
        guard writer >= 0 else { return duplicationError }
        defer { close(writer) }
        var offset = 0
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32? in
            guard let base = raw.baseAddress else { return nil }
            while offset < raw.count {
                let written = Darwin.write(writer, base.advanced(by: offset), raw.count - offset)
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

    static func idleProbeEligible(connected: Bool, stopped: Bool, authSettled: Bool,
                                  pendingCount: Int, replayPending: Bool,
                                  generation: UInt64, expectedGeneration: UInt64) -> Bool {
        connected && !stopped && authSettled && pendingCount == 0 && !replayPending
            && generation == expectedGeneration
    }

    // Caller holds lock. ContinuousClock includes time spent asleep.
    private func replayIsBusy() -> Bool {
        Self.replayIsBusy(replyPending: replayReplyID != nil,
                          deadline: replayBusyUntil, now: ContinuousClock.now)
    }

    static func replayIsBusy(replyPending: Bool, deadline: ContinuousClock.Instant?,
                             now: ContinuousClock.Instant) -> Bool {
        replyPending && deadline.map { now < $0 } == true
    }

    private func beginIdleProbes() -> Task<Void, Never> {
        lock.lock()
        let generation = connectionGeneration
        lock.unlock()
        let interval = idleProbeInterval
        return Task.detached { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
                guard let self else { return }
                // Admission is checked under the same lock that inserts a
                // command. An old loop cannot send into a new connection.
                _ = try? await self.send(name: "ping", idleGeneration: generation)
            }
        }
    }

    private func run() {
        defer { runDidFinish() }
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
            if stopped {
                lock.unlock()
                close(socket)
                break
            }
            fd = socket
            connectionGeneration &+= 1
            _isConnected = true
            authExpected = auth?.current != nil
            authSettled = !authExpected
            _isAuthenticated = false
            authReplyID = nil
            replayReplyID = nil
            replayBusyUntil = nil
            lock.unlock()
            handler(.connected)
            let (reason, sawHello) = readLoop(socket)
            lock.lock()
            let wasStopped = stopped
            if fd == socket { fd = -1 }
            // The read loop owns close. Stop only shuts down the socket,
            // so a borrowed descriptor cannot be reused by another thread.
            close(socket)
            _isConnected = false
            _isAuthenticated = false
            replayReplyID = nil
            replayBusyUntil = nil
            let waiting = pending
            pending.removeAll()
            lock.unlock()
            for (_, continuation) in waiting { continuation.resume(throwing: CoreClientError.disconnected) }
            settleAuth()
            handler(.disconnected(reason: reason))
            if wasStopped { break }
            // A connection that got as far as hello resets the schedule.
            failures = sawHello ? 1 : failures + 1
            wait(CoreBackoff.delay(afterFailures: failures))
        }
    }

    /// Start the pending replacement after the old socket owner retires.
    private func runDidFinish() {
        lock.lock()
        thread = nil
        guard restartAfterStop else {
            lock.unlock()
            return
        }
        restartAfterStop = false
        stopped = false
        let replacement = makeThread()
        thread = replacement
        lock.unlock()
        replacement.start()
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
        var idleProbes: Task<Void, Never>?
        defer { idleProbes?.cancel() }
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
            let droppedBefore = splitter.droppedOversizedFrames
            let frames = splitter.feed(Data(buffer[0..<count]))
            if splitter.droppedOversizedFrames > droppedBefore {
                let why = "a frame over \(CoreCodec.maxFrameBytes) bytes was dropped"
                handler(.decodeFailure(why))
                let type = splitter.lastDroppedOversizedType
                if type == "state" || type == "state_delta" { handler(.stateRejected(why)) }
                if type == "state_delta" { return (why, sawHello) }
            }
            for frame in frames {
                lock.lock()
                framesSeen &+= 1
                lock.unlock()
                do {
                    let message = try CoreCodec.decode(frame: frame)
                    if case .hello(let hello) = message {
                        sawHello = true
                        beginAuthentication(hello: hello, socket: socket)
                        beginResumableStream(hello: hello, socket: socket)
                        if hello.capabilities.contains("state_slices") {
                            let subscription = CoreCommand(id: nextCommandID(), name: "subscribe",
                                                           args: ["state_slices": .bool(true)])
                            if let bytes = try? CoreCodec.encode(command: subscription) {
                                if let error = writeAll(socket, bytes) { return (String(cString: strerror(error)), sawHello) }
                            }
                        }
                        if idleProbes == nil { idleProbes = beginIdleProbes() }
                    }
                    if case .reply(let reply) = message {
                        lock.lock()
                        let isReplay = reply.id == replayReplyID
                        if isReplay {
                            replayReplyID = nil
                            replayBusyUntil = nil
                        }
                        let isAuth = reply.id == authReplyID
                        if isAuth { authReplyID = nil }
                        lock.unlock()
                        if isReplay {
                            deliverReplayedEvents(reply)
                            continue
                        }
                        if isAuth {
                            finishAuthentication(reply, socket: socket)
                            continue
                        }
                        if let waiting = takePending(reply.id) {
                            waiting.resume(returning: reply)
                        }
                    }
                    if case .event(let event) = message {
                        if markEventDelivered(event.id), !event.isDurableResetReplay { continue }
                        noteEventCursor(event.cursor)
                    }
                    handler(.message(message))
                } catch {
                    let why = String(describing: error)
                    handler(.decodeFailure(why))
                    let type = CoreCodec.declaredType(ofFrame: frame)
                    if type == "state" || type == "state_delta" { handler(.stateRejected(why)) }
                    if type == "state_delta" { return (why, sawHello) }
                }
            }
        }
    }

    // MARK: Authentication (read thread, except `waitUntilAuthSettled`)

    /// Called when `hello` lands. With a secret, answers the daemon's nonce
    /// with the `auth` command before anything else is written; without
    /// one, there is nothing to do. Commands wait on `waitUntilAuthSettled`.
    private func beginAuthentication(hello: CoreHello, socket: Int32) {
        lock.lock()
        let expected = authExpected
        lock.unlock()
        guard expected, let keeper = auth, let secret = keeper.current else {
            settleAuth()
            return
        }
        // Whoever answers on the socket must be the daemon this app started
        // (or a child of it): a proof is never sent to anything else.
        guard CoreSocketPeer.isSupervised(peer: CoreSocketPeer.pid(of: socket), supervised: keeper.supervisedPID) else {
            refuseAuthentication(.peerIsNotOurDaemon)
            return
        }
        guard let challenge = hello.auth else {
            refuseAuthentication(.daemonOffersNoChallenge)
            return
        }
        let proof = CoreAuthSecret.proof(secret: secret, nonce: challenge.nonce)
        let command = CoreCommand(id: nextCommandID(), name: "auth", args: ["proof": .string(proof)])
        guard let bytes = try? CoreCodec.encode(command: command) else {
            refuseAuthentication(.noReply)
            return
        }
        lock.lock()
        authReplyID = command.id
        let generation = connectionGeneration
        lock.unlock()
        if writeAll(socket, bytes) != nil {
            // The socket is half-dead; the read below fails and reconnects.
            lock.lock()
            authReplyID = nil
            lock.unlock()
            settleAuth()
            return
        }
        let id = command.id
        let deadline = replyTimeout
        replyClock.schedule(deadline) { [weak self] in
            guard let self, self.takeAuthReplyIfPending(id) else { return }
            self.refuseAuthentication(.noReply)
            self.dropConnection(socket, generation: generation)
        }
    }

    private func takeAuthReplyIfPending(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard authReplyID == id else { return false }
        authReplyID = nil
        return true
    }

    private func finishAuthentication(_ reply: CoreReply, socket: Int32) {
        if reply.ok {
            lock.lock()
            _isAuthenticated = true
            lock.unlock()
            settleAuth()
            handler(.authenticated)
            return
        }
        // The daemon closes a connection whose proof it refused.
        refuseAuthentication(.proofRejected(reply.error?.code ?? "refused"))
    }

    private func refuseAuthentication(_ reason: CoreAuthRefusal) {
        settleAuth()
        handler(.authRefused(reason))
    }

    /// Lets the commands parked behind the exchange go. Idempotent.
    private func settleAuth() {
        lock.lock()
        authSettled = true
        let waiters = authWaiters
        authWaiters.removeAll()
        lock.unlock()
        for waiter in waiters.values { waiter.resume() }
    }

    /// Returns at once unless a secret is held and the exchange on the current
    /// connection has not finished. Ends with the connection, so a command
    /// parked here never outlives the socket it was waiting on.
    private func waitUntilAuthSettled(id: String) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                guard !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if authSettled || !_isConnected {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                authWaiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            self.takeAuthWaiter(id)?.resume(throwing: CancellationError())
        }
    }

    private func takeAuthWaiter(_ id: String) -> CheckedContinuation<Void, Error>? {
        lock.lock(); defer { lock.unlock() }
        return authWaiters.removeValue(forKey: id)
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
            replayBusyUntil = ContinuousClock.now.advanced(by: .seconds(replyTimeout))
            lock.unlock()
            // A failed write leaves the socket half-dead; the read below
            // fails, the loop reconnects, and the next hello retries the
            // replay — resumeFrom still points where it did.
            if writeAll(socket, bytes) != nil {
                lock.lock()
                replayReplyID = nil
                replayBusyUntil = nil
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
        if !sameStream {
            deliveredEventIDs.removeAll()
            deliveredEventIDSet.removeAll()
        }
        replayReplyID = nil
        replayBusyUntil = nil
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
            if markEventDelivered(event.id), !event.isDurableResetReplay { continue }
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
