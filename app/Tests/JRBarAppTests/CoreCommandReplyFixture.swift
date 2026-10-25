import Foundation
import Testing
import Observation
@testable import JRBarCore

@MainActor
final class CoreCommandReplyFixture {
    let root: URL
    let core: CoreModel
    private let process = Process()
    private let ready = Pipe()
    private var started = false
    let replyClock = TestReplyClock()
    private let exits = AsyncStream<Void>.makeStream()

    init() throws {
        root = URL(fileURLWithPath: "/tmp/jrbar-clear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        core = CoreModel(socketPath: root.appendingPathComponent("s").path, replyClock: replyClock.clock)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.script, core.socketPath]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path,
                               "PYTHONDONTWRITEBYTECODE": "1"]
        process.standardOutput = ready
        let exit = exits.continuation
        process.terminationHandler = { _ in exit.yield(()); exit.finish() }
        process.standardError = FileHandle.nullDevice
    }

    func start() async throws {
        try process.run()
        started = true
        core.start()
        ready.fileHandleForWriting.closeFile()
        let readiness = await Task.detached { [ready] in ready.fileHandleForReading.availableData }.value
        try #require(readiness == Data([0x52]))
        try #require(process.isRunning)
        try #require(await until { core.isLive })
    }

    func stop() async {
        core.stop()
        if process.isRunning { process.terminate() }
        if started { for await _ in exits.stream { break } }
        #expect(!process.isRunning)
        try? FileManager.default.removeItem(at: root)
    }

    func until(_ predicate: () -> Bool) async -> Bool {
        await waitForObservedState(predicate)
    }

    func pending(_ count: Int) async throws {
        let reply = try await send("fixture_wait_pending", args: ["count": .number(Double(count))])
        try #require((reply.result?["count"]?.intValue ?? 0) >= count)
    }

    func request(count: Int = 1) async throws -> [String: JSONValue] {
        let reply = try await send("fixture_wait_pending", args: ["count": .number(Double(count))])
        return try #require(reply.result?["requests"]?.arrayValue?.first?.objectValue)
    }

    func release(index: Int = 0, batch: String? = nil, error: String? = nil, message: String? = nil, cleared: [String]? = nil, result: [String: JSONValue]? = nil) async throws {
        var args: [String: JSONValue] = ["index": .number(Double(index))]
        if let batch { args["batch"] = .string(batch) }
        if let error { args["error"] = .string(error) }
        if let message { args["message"] = .string(message) }
        if let cleared { args["cleared"] = .array(cleared.map(JSONValue.string)) }
        if let result { args["result"] = .object(result) }
        let reply = try await send("fixture_release", args: args)
        try #require(reply.ok)
    }

    private func send(_ name: String, args: [String: JSONValue]) async throws -> CoreReply {
        try await core.send(name, args: args)
    }

    func seed(_ batch: String) async throws {
        let clear = Task { try await core.clearCompletedNow() }
        try await pending(1)
        try await release(batch: batch)
        _ = try await clear.value
    }

    private static let script = #"""
import json, socket, sys
server = socket.socket(socket.AF_UNIX)
server.bind(sys.argv[1])
server.listen(1)
server.settimeout(120)
sys.stdout.write("R")
sys.stdout.flush()
connection, _ = server.accept()
connection.settimeout(120)
stream = connection.makefile('rb')
def send(value):
    connection.sendall((json.dumps(value) + '\n').encode())
def reply(request, result=None, error=None, message=None):
    value = {'t': 'reply', 'v': 1, 'id': request['id'], 'ok': error is None}
    if error:
        value['error'] = {'code': error, 'message': message or 'Synthetic ' + error}
    else:
        value['result'] = result or {}
    send(value)
send({'t': 'hello', 'v': 1, 'core_version': 'synthetic', 'pid': 1, 'capabilities': []})
send({'t': 'state', 'v': 1, 'generation': 1, 'sessions': []})
pending = []
waiters = []
def pending_changed():
    for waiter in list(waiters):
        if len(pending) >= waiter.get("args", {}).get("count", 0):
            reply(waiter, {"count": len(pending), "requests": list(pending)})
            waiters.remove(waiter)
for line in stream:
    request = json.loads(line)
    name, args = request.get('name'), request.get('args', {})
    if name in ('clear_completed', 'undo_clear', 'quiet', 'quiet_lease', 'scene_lease', 'list_effects', 'list_assignments', 'set_assignment', 'set_setting', 'clear_assignment'):
        pending.append(request)
        pending_changed()
    elif name == 'fixture_wait_pending':
        waiters.append(request)
        pending_changed()
    elif name == 'fixture_pending':
        reply(request, {'count': len(pending), 'requests': pending})
    elif name == 'fixture_release':
        held = pending.pop(args.get('index', 0))
        result = {'batch': args.get('batch'), 'cleared': args.get('cleared', ['codex:synthetic']), 'restored': ['codex:synthetic']}
        reply(held, args.get('result', result), args.get('error'), args.get('message'))
        reply(request)
        pending_changed()
    elif name == 'list_history':
        reply(request, {'rows': []})
    else:
        reply(request)
"""#
}
