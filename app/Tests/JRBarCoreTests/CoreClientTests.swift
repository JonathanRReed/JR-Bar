import Darwin
import Foundation
import Testing
@testable import JRBarCore

/// A loopback Unix socket that accepts connections and optionally speaks
/// the greeting, for exercising CoreClient's deadlines against a daemon
/// that misbehaves in specific ways.
@Suite("Core client deadlines", .serialized)
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
                lock.lock()
                guard running else { lock.unlock(); close(descriptor); return }
                clients.append(descriptor)
                let greet = speakHello
                lock.unlock()
                if greet {
                    var nosig: Int32 = 1
                    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
                    let hello = "{\"t\":\"hello\",\"v\":1,\"core_version\":\"stub\",\"pid\":1,\"capabilities\":[]}\n"
                    _ = hello.withCString { Darwin.write(descriptor, $0, strlen($0)) }
                }
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
        struct Conn {
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
        /// Commands the client sent, per connection.
        private(set) var receivedCommands: [[String]] = []

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
                setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
                lock.lock()
                guard running else { lock.unlock(); close(descriptor); return }
                let index = connIndex
                connIndex += 1
                clientFDs.append(descriptor)
                receivedCommands.append([])
                let hello = hellos[min(index, hellos.count - 1)]
                let conn = index < replays.count ? replays[index] : nil
                let toPush = index < pushes.count ? pushes[index] : []
                lock.unlock()
                write(descriptor, hello + "\n")
                for frame in toPush { write(descriptor, frame + "\n") }
                Thread.detachNewThread { [weak self] in
                    self?.readCommands(descriptor, connIndex: index, conn: conn)
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
                    receivedCommands[connIndex].append(name)
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
                    }
                }
            }
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
            for descriptor in fds { close(descriptor) }
            unlink(path)
        }
    }

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [CoreClient.Event] = []
        var events: [CoreClient.Event] { lock.lock(); defer { lock.unlock() }; return _events }
        func add(_ event: CoreClient.Event) { lock.lock(); _events.append(event); lock.unlock() }
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

    static func wait(timeout: TimeInterval = 10, until condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
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

    @Test("send throws at its deadline even while the write is still blocked")
    func sendIsBoundedWhileWriteBlocked() async throws {
        let path = Self.temporarySocketPath()
        let server = StubCoreSocket(path: path, speakHello: true)
        try server.start()
        defer { server.stop() }

        let events = EventLog()
        let client = CoreClient(socketPath: path, replyTimeout: 0.4,
                                helloTimeout: 2, connectTimeout: 1,
                                writeTimeout: 5) { events.add($0) }
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
        #expect(Date().timeIntervalSince(started) < 4,
                "send stayed blocked on a peer that never reads")
        // The wedged connection is dropped, not parked.
        #expect(await Self.wait { !events.disconnectReasons.isEmpty })
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
