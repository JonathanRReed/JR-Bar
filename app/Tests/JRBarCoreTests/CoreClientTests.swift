import Darwin
import Foundation
import JRBarTestSupport
import Testing
@testable import JRBarCore

/// A loopback Unix socket that accepts connections and optionally speaks
/// the greeting, for exercising CoreClient's deadlines against a daemon
/// that misbehaves in specific ways.
@Suite("Core client deadlines", .serialized, .timeLimit(.minutes(1)))
struct CoreClientTests {
    final class StubCoreSocket: @unchecked Sendable {
        let path: String
        let speakHello: Bool
        private let lock = NSLock()
        private var listenFD: Int32 = -1
        private var clients: [Int32] = []
        private var running = false

        init(path: String, speakHello: Bool) {
            self.path = path
            self.speakHello = speakHello
        }

        func start() throws {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            precondition(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard listenFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            unlink(path)
            let length = socklen_t(MemoryLayout<sa_family_t>.size + MemoryLayout<UInt8>.size + bytes.count + 1)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listenFD, $0, length)
                }
            }
            guard bound == 0, Darwin.listen(listenFD, 4) == 0 else {
                let code = errno
                close(listenFD)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            lock.lock(); running = true; lock.unlock()
            Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        }

        var acceptCount: Int {
            lock.lock(); defer { lock.unlock() }
            return clients.count
        }

        private func acceptLoop() {
            while true {
                let descriptor = accept(listenFD, nil, nil)
                guard descriptor >= 0 else { return }
                var nosig: Int32 = 1
                guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &nosig,
                                 socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    close(descriptor)
                    continue
                }
                lock.lock()
                guard running else { lock.unlock(); close(descriptor); return }
                clients.append(descriptor)
                let greet = speakHello
                if greet {
                    let hello = "{\"t\":\"hello\",\"v\":1,\"core_version\":\"stub\",\"pid\":1,\"capabilities\":[]}\n"
                    _ = hello.withCString { Darwin.write(descriptor, $0, strlen($0)) }
                }
                lock.unlock()
                // Never read and never write again: the peer is wedged.
            }
        }

        func stop() {
            lock.lock()
            running = false
            let fds = clients
            clients = []
            let listener = listenFD
            listenFD = -1
            lock.unlock()
            if listener >= 0 {
                shutdown(listener, SHUT_RDWR)
                close(listener)
            }
            for descriptor in fds { close(descriptor) }
            unlink(path)
        }
    }

    /// A stub daemon that speaks the resumable-stream protocol: hello
    /// carries `stream`/`cursor`, event frames carry `cursor`, and the
    /// `replay_events` command gets a scripted reply. Each accepted
    /// connection is scripted; dropping a client fd drives a reconnect.
    final class ReplayStubCore: @unchecked Sendable {
        /// Test-only values, read on the stub's own threads after being set up.
        struct Conn: @unchecked Sendable {
            let fd: Int32
            var hello: String
            var replayEvents: [[String: Any]] = []
            var replayCursor: String?
            var resyncRequired = false
        }
        let path: String
        private let lock = NSLock()
        private var listenFD: Int32 = -1
        private var running = false
        private var clientFDs: [Int32] = []
        private var connIndex = 0
        /// Scripted hellos per connection, in accept order.
        var hellos: [String] = []
        /// What `replay_events` should answer on each connection.
        var replays: [Conn] = []
        /// Event frames to push per connection, after hello.
        var pushes: [[String]] = []
        var replyToCommands = false
        /// Commands the client sent, per connection.
        private var _receivedCommands: [[String]] = []
        var receivedCommands: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return _receivedCommands
        }

        init(path: String) { self.path = path }

        func start() throws {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard listenFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            unlink(path)
            let length = socklen_t(MemoryLayout<sa_family_t>.size + MemoryLayout<UInt8>.size + bytes.count + 1)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listenFD, $0, length)
                }
            }
            guard bound == 0, Darwin.listen(listenFD, 4) == 0 else {
                let code = errno
                close(listenFD)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            lock.lock(); running = true; lock.unlock()
            Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        }

        private func write(_ descriptor: Int32, _ frame: String) {
            _ = frame.withCString { Darwin.write(descriptor, $0, strlen($0)) }
        }

        private func acceptLoop() {
            while true {
                let descriptor = accept(listenFD, nil, nil)
                guard descriptor >= 0 else { return }
                var nosig: Int32 = 1
                guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &nosig,
                                 socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    close(descriptor)
                    continue
                }
                lock.lock()
                guard running else { lock.unlock(); close(descriptor); return }
                let ownedDescriptor = dup(descriptor)
                guard ownedDescriptor >= 0 else {
                    lock.unlock()
                    close(descriptor)
                    continue
                }
                let index = connIndex
                connIndex += 1
                clientFDs.append(descriptor)
                _receivedCommands.append([])
                let hello = hellos[min(index, hellos.count - 1)]
                let conn = index < replays.count ? replays[index] : nil
                let toPush = index < pushes.count ? pushes[index] : []
                lock.unlock()
                Thread.detachNewThread { [weak self] in
                    defer { close(ownedDescriptor) }
                    guard let self else { return }
                    self.write(ownedDescriptor, hello + "\n")
                    for frame in toPush { self.write(ownedDescriptor, frame + "\n") }
                    self.readCommands(ownedDescriptor, connIndex: index, conn: conn)
                }
            }
        }

        private func readCommands(_ descriptor: Int32, connIndex: Int, conn: Conn?) {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(descriptor, &chunk, chunk.count)
                guard count > 0 else { return }
                buffer.append(contentsOf: chunk[0..<count])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let name = object["name"] as? String else { continue }
                    lock.lock()
                    _receivedCommands[connIndex].append(name)
                    lock.unlock()
                    if name == "replay_events", let conn, let commandID = object["id"] as? String {
                        let events = conn.replayEvents.compactMap {
                            try? JSONSerialization.data(withJSONObject: $0)
                        }.compactMap { String(data: $0, encoding: .utf8) }
                        let joined = events.joined(separator: ",")
                        var result = "\"events\":[\(joined)],\"resync_required\":\(conn.resyncRequired)"
                        if let cursor = conn.replayCursor {
                            result += ",\"cursor\":\"\(cursor)\""
                        }
                        if conn.resyncRequired {
                            result += ",\"reason\":\"cursor_expired\""
                        }
                        write(descriptor,
                              "{\"t\":\"reply\",\"v\":1,\"id\":\"\(commandID)\",\"ok\":true,\"result\":{\(result)}}\n")
                    } else if replyToCommands, let commandID = object["id"] as? String {
                        write(descriptor,
                              "{\"t\":\"reply\",\"v\":1,\"id\":\"\(commandID)\",\"ok\":true}\n")
                    }
                }
            }
        }

        func pushFrame(_ frame: String) {
            lock.lock(); defer { lock.unlock() }
            if let descriptor = clientFDs.last { write(descriptor, frame + "\n") }
        }

        /// Close the newest client connection; the client should reconnect.
        func dropClient() {
            lock.lock()
            let descriptor = clientFDs.popLast()
            lock.unlock()
            if let descriptor { shutdown(descriptor, SHUT_RDWR); close(descriptor) }
        }

        func stop() {
            lock.lock()
            running = false
            let fds = clientFDs
            clientFDs = []
            let listener = listenFD
            listenFD = -1
            lock.unlock()
            if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener) }
            for descriptor in fds { shutdown(descriptor, SHUT_RDWR); close(descriptor) }
            unlink(path)
        }
    }

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private let changed = TestSignal()
        private var _events: [CoreClient.Event] = []
        var events: [CoreClient.Event] { lock.lock(); defer { lock.unlock() }; return _events }
        func add(_ event: CoreClient.Event) {
            lock.lock(); _events.append(event); lock.unlock()
            changed.signal()
        }
        func waitForConnections(_ count: Int) async -> Bool {
            while connectedCount < count, !Task.isCancelled {
                guard await changed.wait() else { return false }
            }
            return connectedCount >= count
        }
        private var connectedCount: Int {
            events.reduce(0) { count, event in
                if case .connected = event { return count + 1 }
                return count
            }
        }
        var connectAttempts: Int {
            events.reduce(0) { count, event in
                if case .connecting = event { return count + 1 }
                return count
            }
        }
        var disconnectReasons: [String] {
            events.compactMap { event in
                if case .disconnected(let reason) = event { return reason }
                return nil
            }
        }
    }

    static func temporarySocketPath() -> String {
        let name = "jrbar-client-test-\(UUID().uuidString.prefix(8)).sock"
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    }

    static func wait(until condition: @escaping @Sendable () -> Bool) async -> Bool {
        while !condition(), !Task.isCancelled { await Task.yield() }
        return condition()
    }

    @Test("a daemon that accepts but never speaks is dropped at the hello deadline, then retried")
    func silentDaemonDropsAtHelloDeadline() async throws {
        let path = Self.temporarySocketPath()
        let server = StubCoreSocket(path: path, speakHello: false)
        try server.start()
        defer { server.stop() }

        let events = EventLog()
        let client = CoreClient(socketPath: path, replyTimeout: 1,
                                helloTimeout: 0.3, connectTimeout: 1) { events.add($0) }
        client.start()
        defer { client.stop() }

        #expect(await Self.wait { !events.disconnectReasons.isEmpty },
                "a silent daemon must be disconnected at the hello deadline")
        #expect(events.disconnectReasons.contains { $0.contains("no hello") },
                "reasons were \(events.disconnectReasons)")
        // The disconnect is a reconnect, not a park.
        #expect(await Self.wait { events.connectAttempts >= 2 })
        #expect(await Self.wait { server.acceptCount >= 2 },
                "the client must keep retrying the socket")
    }

    @Test("stop then start waits for the old socket owner to retire")
    func stopStartHasOneRunOwner() async throws {
        let path = Self.temporarySocketPath()
        let server = StubCoreSocket(path: path, speakHello: true)
        try server.start()
        defer { server.stop() }

        let events = EventLog()
        let client = CoreClient(socketPath: path, helloTimeout: 1, connectTimeout: 1) { events.add($0) }
        client.start()
        #expect(await events.waitForConnections(1))

        client.stop()
        client.start()
        defer { client.stop() }
        #expect(await events.waitForConnections(2), "a start during teardown must launch after the old owner returns")
        #expect(client.isConnected, "the retired owner must not close the replacement socket")
    }

    @MainActor
    @Test("CoreModel ignores an event queued by a stopped client")
    func modelRejectsRetiredClientEvent() {
        let model = CoreModel(socketPath: Self.temporarySocketPath())
        model.start()
        let retired = model.eventGeneration
        model.stop()
        model.handle(.connected, generation: retired)
        #expect(model.connection == .idle)

        model.start()
        let current = model.eventGeneration
        model.handle(.connected, generation: current)
        #expect(model.connection == .connected)
        model.handle(.disconnected(reason: "retired"), generation: retired)
        #expect(model.connection == .connected, "an obsolete disconnect must not overwrite the replacement")
        model.stop()
    }

    @Test("send throws at its deadline even while the write is still blocked")
    func sendIsBoundedWhileWriteBlocked() async throws {
        let path = Self.temporarySocketPath()
        let server = StubCoreSocket(path: path, speakHello: true)
        try server.start()
        defer { server.stop() }

        let events = EventLog()
        let client = CoreClient(socketPath: path, replyTimeout: 0.4,
                                helloTimeout: 2, connectTimeout: 1,
                                writeTimeout: 30) { events.add($0) }
        client.start()
        defer { client.stop() }
        #expect(await Self.wait { client.isConnected })

        // Larger than any socket buffer: writeAll cannot drain it while
        // the peer never reads. The armed-before-write deadline must fire.
        let blob = String(repeating: "x", count: 8 * 1024 * 1024)
        let started = Date()
        do {
            _ = try await client.send(name: "fill",
                                      args: ["blob": .string(blob)],
                                      timeout: 0.4)
            Issue.record("send to a never-reading daemon should throw")
        } catch let error as CoreClientError {
            switch error {
            case .timeout, .writeFailed:
                break
            default:
                Issue.record("unexpected error: \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // The deadline is 0.4 s and the write timeout 30 s: anything well
        // short of 30 proves the deadline fired, even on a loaded runner.
        #expect(Date().timeIntervalSince(started) < 15,
                "send stayed blocked on a peer that never reads")
        // The wedged connection is dropped, not parked.
        #expect(await Self.wait { !events.disconnectReasons.isEmpty })
    }

    /// One thread holds and releases the writer while the async test advances.
    final class WriteBarrier {
        private let releaseGate: TestGate
        private let acquiredGate = TestSignal()
        func acquired() async -> Bool { await acquiredGate.wait() }
        private var held = true
        init(_ lock: NSLock) {
            let acquiredGate = self.acquiredGate
            let releaseGate = TestGate()
            self.releaseGate = releaseGate
            Thread.detachNewThread {
                lock.lock()
                acquiredGate.signal()
                releaseGate.wait()
                lock.unlock()
            }
        }
        func release() {
            guard held else { return }
            held = false
            releaseGate.signal()
        }
    }

    @Test("a command that expires behind another writer never reaches a healthy daemon")
    func expiredQueuedCommandIsNotWritten() async throws {
        let path = Self.temporarySocketPath()
        let server = ReplayStubCore(path: path)
        server.hellos = ["{\"t\":\"hello\",\"v\":1,\"capabilities\":[]}"]
        server.replyToCommands = true
        try server.start()
        defer { server.stop() }

        let events = EventLog()
        let client = CoreClient(socketPath: path, helloTimeout: 2, connectTimeout: 1) { events.add($0) }
        client.start()
        defer { client.stop() }
        try #require(await Self.wait { client.isConnected && !server.receivedCommands.isEmpty })

        let barrier = WriteBarrier(client.writeLock)
        defer { barrier.release() }
        try #require(await barrier.acquired())
        let command = Task.detached {
            try await client.send(name: "set_setting", args: ["key": .string("test")], timeout: 1)
        }
        try #require(await Self.wait { client.pendingCommandCount == 1 })
        server.pushFrame("{\"t\":\"event\",\"v\":1,\"id\":\"healthy\",\"kind\":\"completed\"}")
        try #require(await Self.wait { events.receivedEventIDs == ["healthy"] })
        try #require(await Self.wait { client.pendingCommandCount == 0 })
        #expect(client.isConnected, "traffic during the deadline must keep this connection open")
        barrier.release()

        do {
            _ = try await command.value
            Issue.record("the queued command must time out")
        } catch let error as CoreClientError {
            #expect(error == .timeout)
        }
        let reply = try await client.send(name: "ping", timeout: 2)
        #expect(reply.ok)
        #expect(server.receivedCommands == [["ping"]],
                "the expired mutation must not arrive before the successful ping")
        #expect(events.disconnectReasons.isEmpty)
    }

    @Test("a cancelled command waiting for the writer never reaches the daemon")
    func cancelledQueuedCommandIsNotWritten() async throws {
        let server = ReplayStubCore(path: Self.temporarySocketPath())
        server.hellos = ["{\"t\":\"hello\",\"v\":1,\"capabilities\":[]}"]
        server.replyToCommands = true
        try server.start()
        defer { server.stop() }
        let events = EventLog()
        let client = CoreClient(socketPath: server.path, helloTimeout: 2, connectTimeout: 1) { events.add($0) }
        client.start()
        defer { client.stop() }
        try #require(await Self.wait { client.isConnected && !server.receivedCommands.isEmpty })
        let barrier = WriteBarrier(client.writeLock)
        defer { barrier.release() }
        try #require(await barrier.acquired())
        let command = Task.detached { try await client.send(name: "set_setting") }
        try #require(await Self.wait { client.pendingCommandCount == 1 })
        command.cancel()
        try #require(await Self.wait { client.pendingCommandCount == 0 })
        barrier.release()
        do {
            _ = try await command.value
            Issue.record("the queued command must report cancellation")
        } catch is CancellationError {}
        #expect(try await client.send(name: "ping", timeout: 2).ok)
        #expect(server.receivedCommands == [["ping"]])
        #expect(events.disconnectReasons.isEmpty)
    }

    @Test("cancelling a command already written retires its reply without dropping the shared socket")
    func cancelledWrittenCommandKeepsConnection() async throws {
        let server = ReplayStubCore(path: Self.temporarySocketPath())
        server.hellos = ["{\"t\":\"hello\",\"v\":1,\"capabilities\":[]}"]
        try server.start()
        defer { server.stop() }
        let client = CoreClient(socketPath: server.path, helloTimeout: 2, connectTimeout: 1) { _ in }
        client.start()
        defer { client.stop() }
        try #require(await Self.wait { client.isConnected })
        let command = Task.detached { try await client.send(name: "ping", timeout: 5) }
        try #require(await Self.wait { server.receivedCommands == [["ping"]] })
        command.cancel()
        do {
            _ = try await command.value
            Issue.record("the pending reply must report cancellation")
        } catch is CancellationError {}
        #expect(client.pendingCommandCount == 0)
        #expect(client.isConnected)
    }

    @Test("a task cancelled before send does not register a command")
    func alreadyCancelledCommandIsNotRegistered() async throws {
        let client = CoreClient(socketPath: Self.temporarySocketPath()) { _ in }
        let command = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.send(name: "set_setting")
        }
        do {
            _ = try await command.value
            Issue.record("the command must report cancellation before checking connection")
        } catch is CancellationError {}
        #expect(client.pendingCommandCount == 0)
        #expect(client.authenticationWaiterCount == 0)
    }
}

extension CoreClientTests.EventLog {
    var receivedEventIDs: [String] {
        events.compactMap { event in
            if case .message(.event(let coreEvent)) = event { return coreEvent.id }
            return nil
        }
    }
}

extension CoreClientTests {

    @Test("same-stream socket reconnect forwards durable reset reoffers while deduplicating cursor events")
    func durableResetReoffersAcrossReconnect() async throws {
        let stub = ReplayStubCore(path: Self.temporarySocketPath())
        stub.hellos = [
            #"{"t":"hello","v":1,"stream":"s1","cursor":"s1:ev-0","capabilities":[]}"#,
            #"{"t":"hello","v":1,"stream":"s1","cursor":"s1:ev-1","capabilities":[]}"#,
        ]
        let durable = #"{"t":"event","v":1,"id":"synthetic-stable-reset","kind":"quota_reset","provider":"kimi","lane":"monthly","event_id":"synthetic-stable-reset","notify":false}"#
        let cursorReset = #"{"t":"event","v":1,"id":"ev-1","kind":"quota_reset","event_id":"synthetic-cursor-reset","notify":false,"cursor":"s1:ev-1"}"#
        let completion = #"{"t":"event","v":1,"id":"ev-2","kind":"completed","cursor":"s1:ev-2"}"#
        stub.pushes = [[durable, cursorReset], [durable, cursorReset, completion, completion]]
        try stub.start()
        defer { stub.stop() }
        let events = EventLog()
        let client = CoreClient(socketPath: stub.path, helloTimeout: 2, connectTimeout: 1) { events.add($0) }
        client.start()
        defer { client.stop() }
        try #require(await Self.wait { events.receivedEventIDs == ["synthetic-stable-reset", "ev-1"] })
        stub.dropClient()
        try #require(await Self.wait { events.receivedEventIDs.contains("ev-2") })
        #expect(events.receivedEventIDs == ["synthetic-stable-reset", "ev-1", "synthetic-stable-reset", "ev-2"])
    }

    @Test("reconnect at the same stream tail keeps event deduplication")
    func sameStreamTailReconnectKeepsDedupe() async throws {
        let path = Self.temporarySocketPath()
        let stub = ReplayStubCore(path: path)
        stub.hellos = [
            "{\"t\":\"hello\",\"v\":1,\"stream\":\"s1\",\"cursor\":\"s1:ev-0\",\"capabilities\":[]}",
            "{\"t\":\"hello\",\"v\":1,\"stream\":\"s1\",\"cursor\":\"s1:ev-1\",\"capabilities\":[]}",
        ]
        let repeated = "{\"t\":\"event\",\"v\":1,\"id\":\"ev-1\",\"kind\":\"quota_reset\",\"cursor\":\"s1:ev-1\"}"
        stub.pushes = [
            [repeated],
            [repeated, "{\"t\":\"event\",\"v\":1,\"id\":\"ev-2\",\"kind\":\"completed\",\"cursor\":\"s1:ev-2\"}"],
        ]
        try stub.start()
        defer { stub.stop() }

        let events = EventLog()
        let client = CoreClient(socketPath: path, helloTimeout: 2, connectTimeout: 1) { events.add($0) }
        client.start()
        defer { client.stop() }
        try #require(await Self.wait { events.receivedEventIDs == ["ev-1"] })
        stub.dropClient()
        try #require(await Self.wait { events.receivedEventIDs.contains("ev-2") })
        #expect(events.receivedEventIDs == ["ev-1", "ev-2"],
                "the greeting's repeated quota event must only reach the handler once")
        #expect(!stub.receivedCommands.dropFirst().contains { $0.contains("replay_events") })
    }

    /// Reconnecting onto the SAME stream replays exactly the frames the
    /// drop ate — and a frame the socket already fanned out is not
    /// delivered a second time when the replay suffix repeats it.
    @Test("reconnect on the same stream replays the missed suffix without duplicating live frames")
    func sameStreamReconnectReplaysSuffix() async throws {
        let path = Self.temporarySocketPath()
        let stub = ReplayStubCore(path: path)
        stub.hellos = [
            "{\"t\":\"hello\",\"v\":1,\"stream\":\"s1\",\"cursor\":\"s1:ev-1\",\"capabilities\":[]}",
            "{\"t\":\"hello\",\"v\":1,\"stream\":\"s1\",\"cursor\":\"s1:ev-4\",\"capabilities\":[]}",
        ]
        // Connection 1 pushes ev-2 live; the client anchors at ev-2.
        stub.pushes = [
            ["{\"t\":\"event\",\"v\":1,\"id\":\"ev-2\",\"kind\":\"completed\",\"cursor\":\"s1:ev-2\"}"],
            // Connection 2: ev-4 lands on the wire BEFORE the replay
            // reply repeats it — the dup must be dropped by id.
            ["{\"t\":\"event\",\"v\":1,\"id\":\"ev-4\",\"kind\":\"completed\",\"cursor\":\"s1:ev-4\"}"],
        ]
        let replay = ReplayStubCore.Conn(
            fd: -1,
            hello: "",
            replayEvents: [
                ["t": "event", "v": 1, "id": "ev-3", "kind": "asked", "cursor": "s1:ev-3"],
                ["t": "event", "v": 1, "id": "ev-4", "kind": "completed", "cursor": "s1:ev-4"],
            ],
            replayCursor: "s1:ev-4")
        stub.replays = [replay, replay]
        try stub.start()
        defer { stub.stop() }

        let events = EventLog()
        let client = CoreClient(socketPath: path, replyTimeout: 1,
                                helloTimeout: 2, connectTimeout: 1) { events.add($0) }
        client.start()
        defer { client.stop() }

        #expect(await Self.wait { events.receivedEventIDs == ["ev-2"] },
                "first connection delivered \(events.receivedEventIDs)")
        stub.dropClient()
        #expect(await Self.wait { stub.receivedCommands.count >= 2 && stub.receivedCommands[1].contains("replay_events") },
                "a same-stream reconnect must ask replay_events")
        #expect(await Self.wait { events.receivedEventIDs == ["ev-2", "ev-4", "ev-3"] },
                "delivered \(events.receivedEventIDs)")
        // The replay reply reached nobody as a `.reply` message — the
        // client consumed it internally.
        let replies = events.events.compactMap { event -> String? in
            if case .message(.reply) = event { return "reply" }
            return nil
        }
        #expect(replies.isEmpty)
    }

    /// A different stream in `hello` is a restarted journal: the client
    /// anchors at the new tail, sends no replay, and the new stream's
    /// `ev-1` is delivered even though the id collides with the old
    /// stream's.
    @Test("a new stream incarnation anchors without replaying")
    func foreignStreamAnchorsWithoutReplay() async throws {
        let path = Self.temporarySocketPath()
        let stub = ReplayStubCore(path: path)
        stub.hellos = [
            "{\"t\":\"hello\",\"v\":1,\"stream\":\"s1\",\"cursor\":\"s1:ev-9\",\"capabilities\":[]}",
            "{\"t\":\"hello\",\"v\":1,\"stream\":\"s2\",\"cursor\":\"s2:ev-1\",\"capabilities\":[]}",
        ]
        stub.pushes = [
            ["{\"t\":\"event\",\"v\":1,\"id\":\"ev-10\",\"kind\":\"completed\",\"cursor\":\"s1:ev-10\"}"],
            ["{\"t\":\"event\",\"v\":1,\"id\":\"ev-1\",\"kind\":\"completed\",\"cursor\":\"s2:ev-1\"}"],
        ]
        try stub.start()
        defer { stub.stop() }

        let events = EventLog()
        let client = CoreClient(socketPath: path, replyTimeout: 1,
                                helloTimeout: 2, connectTimeout: 1) { events.add($0) }
        client.start()
        defer { client.stop() }

        #expect(await Self.wait { events.receivedEventIDs == ["ev-10"] })
        stub.dropClient()
        #expect(await Self.wait { events.receivedEventIDs == ["ev-10", "ev-1"] },
                "new stream's ev-1 must deliver despite the old stream's ids; got \(events.receivedEventIDs)")
        let replaySent = stub.receivedCommands.dropFirst().contains { $0.contains("replay_events") }
        #expect(!replaySent, "a foreign stream must not trigger replay")
    }
}
