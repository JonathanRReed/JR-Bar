import AppKit
import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The Menu Bar engine's plumbing: the asserter helper's handle
/// lifecycle, the trigger source's thread hop, the reconcile cadence and
/// the log gates. No screen, no agent — the helper is a shell script
/// that speaks the same one-line protocol.
@Suite("Menu Bar — engine internals")
struct MenuBarEngineTests {
    /// A stand-in `jrbar-asserter`: reads the allowlist line, answers
    /// "ok", then runs `body` (park on stdin, or exit on its own).
    private func fakeHelper(_ body: String) throws -> (url: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrbar-asserter-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake-asserter")
        try "#!/bin/sh\nread line\necho ok\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url, { try? FileManager.default.removeItem(at: dir) })
    }

    /// Up to 6 s: activate's 3 s answer timeout holds the handle until
    /// it fires, so a freed handle shows up just past that mark.
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    @Test("a released helper frees its handle — the exit source never keeps the pipes alive")
    func asserterReleaseFreesHandle() async throws {
        let helper = try fakeHelper("cat >/dev/null")
        defer { helper.cleanup() }
        let backend = MenuBarAsserterBackend(helperURL: helper.url)
        weak var handle: MenuBarAsserterBackend.Spawned?
        do {
            let token = try await backend.activate(allowedBundleIDs: ["a.app"])
            handle = token.object as? MenuBarAsserterBackend.Spawned
            #expect(handle != nil)
            #expect(backend.isAlive(token))
            backend.invalidate(token)
        }
        await waitUntil { handle == nil }
        #expect(handle == nil, "Spawned → exit source → handler → Spawned must break on exit")
    }

    @MainActor
    @Test("a helper that dies on its own reports the loss once and frees its handle")
    func asserterSelfDeathFreesHandle() async throws {
        let helper = try fakeHelper("sleep 0.2")
        defer { helper.cleanup() }
        let backend = MenuBarAsserterBackend(helperURL: helper.url)
        var losses = 0
        backend.onLoss = { _ in losses += 1 }
        weak var handle: MenuBarAsserterBackend.Spawned?
        do {
            let token = try await backend.activate(allowedBundleIDs: ["a.app"])
            handle = token.object as? MenuBarAsserterBackend.Spawned
        }
        await waitUntil { losses > 0 && handle == nil }
        #expect(losses == 1)
        #expect(handle == nil, "a self-exit must disarm the source and close both pipe ends")
    }
}
