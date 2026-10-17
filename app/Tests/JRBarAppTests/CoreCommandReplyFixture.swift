import Foundation
import Testing
@testable import JRBarCore

@MainActor
final class CoreCommandReplyFixture {
    let root: URL
    let core: CoreModel
    private let process = Process()

    init() throws {
        root = URL(fileURLWithPath: "/tmp/jrbar-clear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        core = CoreModel(socketPath: root.appendingPathComponent("s").path)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.script, core.socketPath]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path,
                               "PYTHONDONTWRITEBYTECODE": "1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    func start() async throws {
        try process.run()
        try #require(await until { FileManager.default.fileExists(atPath: core.socketPath) || !process.isRunning })
        try #require(process.isRunning)
        core.start()
        try #require(await until { core.isLive })
    }

    func stop() async {
        core.stop()
        if process.isRunning { process.terminate() }
        #expect(await until { !process.isRunning })
        try? FileManager.default.removeItem(at: root)
    }

    func until(_ predicate: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !predicate(), clock.now < deadline, !Task.isCancelled { await Task.yield() }
        return predicate()
    }

    func pending(_ count: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline, !Task.isCancelled {
            let reply = try await core.send("fixture_pending")
            if reply.result?["count"]?.intValue == count { return }
            await Task.yield()
        }
        Issue.record("Synthetic command did not reach the held-reply queue")
        throw CoreClientError.timeout
    }

    func release(index: Int = 0, batch: String? = nil, error: String? = nil, message: String? = nil, cleared: [String]? = nil, result: [String: JSONValue]? = nil) async throws {
        var args: [String: JSONValue] = ["index": .number(Double(index))]
        if let batch { args["batch"] = .string(batch) }
        if let error { args["error"] = .string(error) }
        if let message { args["message"] = .string(message) }
        if let cleared { args["cleared"] = .array(cleared.map(JSONValue.string)) }
        if let result { args["result"] = .object(result) }
        let reply = try await core.send("fixture_release", args: args)
        try #require(reply.ok)
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
connection, _ = server.accept()
connection.settimeout(15)
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
for line in stream:
    request = json.loads(line)
    name, args = request.get('name'), request.get('args', {})
    if name in ('clear_completed', 'undo_clear', 'quiet', 'quiet_lease', 'scene_lease', 'list_effects', 'list_assignments', 'set_assignment', 'set_setting', 'clear_assignment'):
        pending.append(request)
    elif name == 'fixture_pending':
        reply(request, {'count': len(pending), 'requests': pending})
    elif name == 'fixture_release':
        held = pending.pop(args.get('index', 0))
        result = {'batch': args.get('batch'), 'cleared': args.get('cleared', ['codex:synthetic']), 'restored': ['codex:synthetic']}
        reply(held, args.get('result', result), args.get('error'), args.get('message'))
        reply(request)
    elif name == 'list_history':
        reply(request, {'rows': []})
    else:
        reply(request)
"""#
}
