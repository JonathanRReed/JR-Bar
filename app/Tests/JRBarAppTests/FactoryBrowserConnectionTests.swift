import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("Factory browser connection")
struct FactoryBrowserConnectionTests {
    private let profile = FactorySessionProfile(browser: "zen", profile: "synthetic.default", label: "Zen · synthetic.default")

    @MainActor
    final class Calls {
        var loaded = 0
        var imported: [FactorySessionProfile] = []
        var disconnected = 0
        var changed = 0
    }

    @MainActor
    final class Gate {
        var continuation: CheckedContinuation<String, Never>?
        var started: CheckedContinuation<Void, Never>?

        func run() async -> String {
            await withCheckedContinuation {
                continuation = $0
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            if continuation != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func finish() { continuation?.resume(returning: "Imported."); continuation = nil }
    }

    @MainActor
    final class ProfileGate {
        var continuation: CheckedContinuation<[FactorySessionProfile], Never>?
        var started: CheckedContinuation<Void, Never>?

        func run() async -> [FactorySessionProfile] {
            await withCheckedContinuation {
                continuation = $0
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            if continuation != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func finish(_ profiles: [FactorySessionProfile]) {
            continuation?.resume(returning: profiles)
            continuation = nil
        }
    }

    @Test("a cancelled profile load allows an immediate reload and cannot clear its busy state")
    func cancelledLoadCanReload() async throws {
        let oldGate = ProfileGate()
        let newGate = ProfileGate()
        let selectedProfile = profile
        var loads = 0
        let connection = FactoryBrowserConnectionModel(available: false, load: {
            loads += 1
            return await (loads == 1 ? oldGate : newGate).run()
        }, importSession: { _ in "unused" }, disconnect: { "unused" })
        let oldLoad = Task { await connection.load() }
        await oldGate.waitUntilStarted()
        defer { oldGate.finish([]); newGate.finish([]) }
        connection.cancel()
        try #require(!connection.busy)
        connection.beginEditing()
        let newLoad = Task { await connection.load() }
        await newGate.waitUntilStarted()
        oldGate.finish([])
        await oldLoad.value
        #expect(connection.busy)
        #expect(connection.profiles.isEmpty)
        #expect(connection.selected == nil)
        #expect(connection.message == nil)
        #expect(!connection.approved)
        newGate.finish([selectedProfile])
        await newLoad.value
        #expect(connection.profiles == [selectedProfile])
        #expect(connection.selected == selectedProfile)
        #expect(!connection.busy)
    }

    @Test("a cancelled load cannot change a later import or its approval")
    func cancelledLoadCannotRetireImport() async throws {
        let oldGate = ProfileGate()
        let importGate = Gate()
        let selectedProfile = profile
        var loads = 0
        let connection = FactoryBrowserConnectionModel(available: false, load: {
            loads += 1
            if loads == 1 { return await oldGate.run() }
            return [selectedProfile]
        }, importSession: { _ in await importGate.run() }, disconnect: { "unused" })
        let oldLoad = Task { await connection.load() }
        await oldGate.waitUntilStarted()
        defer { oldGate.finish([]); importGate.finish() }
        connection.cancel()
        try #require(!connection.busy)
        connection.beginEditing()
        await connection.load()
        connection.approved = true
        let pendingImport = Task { await connection.connect() }
        await importGate.waitUntilStarted()
        oldGate.finish([])
        await oldLoad.value
        #expect(connection.busy)
        #expect(connection.approved)
        #expect(connection.profiles == [selectedProfile])
        #expect(connection.selected == selectedProfile)
        #expect(connection.message == nil)
        #expect(!(await connection.connect()))
        importGate.finish()
        #expect(await pendingImport.value)
        #expect(!connection.busy)
    }

    @Test("retired disconnects keep credential mutations serialized until they settle")
    func retiredDisconnect() async {
        let gate = Gate()
        let calls = Calls()
        let connection = FactoryBrowserConnectionModel(available: true,
            load: { calls.loaded += 1; return [] },
            importSession: { calls.imported.append($0); return "unused" },
            disconnect: { calls.disconnected += 1; return await gate.run() },
            onChanged: { calls.changed += 1 })
        let pending = Task { await connection.disconnect() }
        await gate.waitUntilStarted()
        connection.cancel()
        connection.beginEditing()
        await connection.load()
        await connection.disconnect()
        #expect(!(await connection.connect()))
        #expect(connection.busy)
        #expect(calls.disconnected == 1)
        #expect(calls.loaded == 0)
        #expect(calls.imported.isEmpty)
        gate.finish()
        await pending.value
        #expect(!connection.busy)
        #expect(connection.available)
        #expect(connection.message == nil)
        #expect(calls.changed == 0)
    }

    @Test("browser availability facts survive writes and retired results stay silent",
          arguments: [false, true], [(false, false), (false, true), (true, false), (true, true)])
    func availabilityDuringWrite(disconnecting: Bool, outcome: (Bool, Bool)) async {
        let (retired, fails) = outcome
        let gate = Gate()
        let calls = Calls()
        let selectedProfile = profile
        let operation: @MainActor () async throws -> String = {
            let result = await gate.run()
            if fails { throw CoreReplyError(code: "credential_unavailable", message: "synthetic-secret") }
            return result
        }
        let connection = FactoryBrowserConnectionModel(available: disconnecting,
            load: { [selectedProfile] }, importSession: { _ in try await operation() },
            disconnect: operation, onChanged: { calls.changed += 1 })
        await connection.load()
        connection.approved = true
        let pending = Task {
            if disconnecting { await connection.disconnect(); return false }
            return await connection.connect()
        }
        await gate.waitUntilStarted()
        defer { gate.finish() }
        connection.updateAvailability(disconnecting)
        connection.updateAvailability(!disconnecting)
        #expect(connection.available == disconnecting)
        if retired { connection.cancel() }
        gate.finish()
        let connected = await pending.value
        #expect(connection.available == !disconnecting)
        #expect(!connection.busy)
        #expect(calls.changed == ((!retired && !fails) ? 1 : 0))
        #expect(connected == (!disconnecting && !retired && !fails))
        if retired {
            #expect(connection.message == nil)
            #expect(!connection.approved)
        }
        #expect(connection.message?.contains("synthetic-secret") != true)
    }

    @Test("current browser acknowledgements supersede earlier facts", arguments: [false, true])
    func acknowledgementWins(disconnecting: Bool) async {
        let gate = Gate()
        let selectedProfile = profile
        let connection = FactoryBrowserConnectionModel(available: disconnecting,
            load: { [selectedProfile] }, importSession: { _ in await gate.run() },
            disconnect: { await gate.run() })
        await connection.load()
        connection.approved = true
        let pending = Task {
            if disconnecting { await connection.disconnect() } else { _ = await connection.connect() }
        }
        await gate.waitUntilStarted()
        defer { gate.finish() }
        connection.updateAvailability(disconnecting)
        gate.finish()
        await pending.value
        #expect(connection.available == !disconnecting)
    }

    @Test("availability arriving after import acknowledgement survives refresh", arguments: [false, true], [false, true])
    func availabilityDuringRefresh(retired: Bool, fails: Bool) async {
        let gate = Gate()
        let selectedProfile = profile
        var changes = 0
        let connection = FactoryBrowserConnectionModel(available: false,
            load: { [selectedProfile] }, importSession: { _ in "Saved." }, disconnect: { "unused" },
            refreshUsage: {
                let result = await gate.run()
                if fails { throw CoreReplyError(code: "usage_off", message: "synthetic-secret") }
                return result
            }, onChanged: { changes += 1 })
        await connection.load()
        connection.approved = true
        let pending = Task { await connection.connect() }
        await gate.waitUntilStarted()
        defer { gate.finish() }
        #expect(connection.available)
        connection.updateAvailability(true)
        connection.updateAvailability(false)
        if retired { connection.cancel() }
        gate.finish()
        #expect(await pending.value == !retired)
        #expect(!connection.available)
        #expect(!connection.busy)
        #expect(changes == (retired ? 0 : 1))
        if retired {
            #expect(connection.message == "Saved.")
            #expect(!connection.approved)
        }
        #expect(connection.message?.contains("synthetic-secret") != true)
    }

    @Test("profile discovery accepts availability immediately and keeps its busy state")
    func availabilityDuringProfileLoad() async {
        let gate = ProfileGate()
        let connection = FactoryBrowserConnectionModel(available: false,
            load: { await gate.run() }, importSession: { _ in "unused" }, disconnect: { "unused" })
        let pending = Task { await connection.load() }
        await gate.waitUntilStarted()
        defer { gate.finish([]) }
        connection.updateAvailability(true)
        #expect(connection.available)
        #expect(connection.busy)
        #expect(!connection.approved)
        gate.finish([])
        await pending.value
        #expect(connection.available)
        #expect(!connection.busy)
    }

    private func model(_ calls: Calls, available: Bool = false) -> FactoryBrowserConnectionModel {
        let selectedProfile = profile
        return FactoryBrowserConnectionModel(available: available,
            load: { calls.loaded += 1; return [selectedProfile] },
            importSession: { calls.imported.append($0); return "Browser sign-in imported." },
            disconnect: { calls.disconnected += 1; return "Browser sign-in removed." },
            onChanged: { calls.changed += 1 })
    }

    @Test("opening the model does not read a browser and connecting requires explicit approval")
    func approval() async {
        let calls = Calls()
        let connection = model(calls)
        #expect(calls.loaded == 0)
        #expect(!(await connection.connect()))
        await connection.load()
        #expect(calls.loaded == 1)
        #expect(!(await connection.connect()))
        #expect(calls.imported.isEmpty)
        connection.approved = true
        #expect(await connection.connect())
        #expect(calls.imported == [profile])
        #expect(connection.available)
        #expect(calls.changed == 1)
    }

    @Test("a retired sheet cannot import or retain its approval")
    func cancel() async {
        let calls = Calls()
        let connection = model(calls)
        await connection.load()
        connection.approved = true
        connection.cancel()
        #expect(!connection.approved)
        #expect(!(await connection.connect()))
        #expect(calls.imported.isEmpty)
        connection.beginEditing()
        #expect(!connection.approved)
        #expect(connection.selected == nil)
    }

    @Test("changing the selected profile withdraws the previous profile approval")
    func changeProfile() async {
        let calls = Calls()
        let connection = model(calls)
        await connection.load()
        connection.approved = true
        connection.selected = FactorySessionProfile(browser: "chrome", profile: "Default", label: "Chrome · Default")
        #expect(!connection.approved)
        #expect(!(await connection.connect()))
        #expect(calls.imported.isEmpty)
    }

    @Test("pending imports deduplicate and retired results cannot change a later sheet")
    func retiredImport() async {
        let gate = Gate()
        let calls = Calls()
        let selectedProfile = profile
        var refreshes = 0
        let connection = FactoryBrowserConnectionModel(available: false,
            load: { calls.loaded += 1; return [selectedProfile] },
            importSession: { calls.imported.append($0); return await gate.run() },
            disconnect: { calls.disconnected += 1; return "unused" },
            refreshUsage: { refreshes += 1; return "unused" },
            onChanged: { calls.changed += 1 })
        await connection.load()
        connection.approved = true
        let pending = Task { await connection.connect() }
        await gate.waitUntilStarted()
        #expect(connection.busy)
        #expect(!(await connection.connect()))
        connection.cancel()
        connection.beginEditing()
        await connection.load()
        await connection.disconnect()
        #expect(!(await connection.connect()))
        #expect(connection.busy)
        #expect(!connection.approved)
        #expect(calls.loaded == 1)
        #expect(calls.imported == [selectedProfile])
        #expect(calls.disconnected == 0)
        gate.finish()
        #expect(!(await pending.value))
        #expect(!connection.available)
        #expect(calls.changed == 0)
        #expect(refreshes == 0)
    }

    @Test("disconnect removes only the selected saved browser connection")
    func disconnect() async {
        let calls = Calls()
        let connection = model(calls, available: true)
        await connection.disconnect()
        #expect(calls.disconnected == 1)
        #expect(calls.imported.isEmpty)
        #expect(calls.loaded == 0)
        #expect(calls.changed == 1)
        #expect(!connection.available)
    }

    @Test("browser failures do not expose credential-bearing errors")
    func failure() async {
        let connection = FactoryBrowserConnectionModel(available: false,
            load: { throw CoreReplyError(code: "credential_unavailable", message: "synthetic-secret") },
            importSession: { _ in "unused" }, disconnect: { "unused" })
        await connection.load()
        #expect(connection.message?.contains("synthetic-secret") == false)
        #expect(connection.message?.contains("Keychain") == true)
    }

    @Test("a saved sign-in requests usage and preserves saved status when usage is off", arguments: [false, true])
    func savedSessionRefresh(usageOff: Bool) async {
        let selectedProfile = profile
        var refreshes = 0
        let connection = FactoryBrowserConnectionModel(available: false,
            load: { [selectedProfile] }, importSession: { _ in "Factory sign-in saved." },
            disconnect: { "unused" }, refreshUsage: {
                refreshes += 1
                if usageOff { throw CoreReplyError(code: "usage_off", message: "synthetic-private-error") }
                return "Factory usage refresh requested."
            })
        await connection.load()
        connection.approved = true
        #expect(await connection.connect())
        #expect(connection.available)
        #expect(refreshes == 1)
        #expect(connection.message?.contains(usageOff ? "Turn on" : "refresh requested") == true)
        #expect(connection.message?.contains("synthetic-private-error") == false)
    }

    @Test("a refresh failure keeps the saved sign-in and explains how to retry")
    func refreshFailureKeepsSavedSession() async {
        let selectedProfile = profile
        let connection = FactoryBrowserConnectionModel(available: false,
            load: { [selectedProfile] }, importSession: { _ in "Factory sign-in saved." },
            disconnect: { "unused" }, refreshUsage: { throw CoreClientError.notConnected })
        await connection.load()
        connection.approved = true
        #expect(await connection.connect())
        #expect(connection.available)
        #expect(connection.message?.contains("Refresh") == true)
    }

    @Test("a failed browser import never requests usage")
    func importFailureDoesNotRefresh() async {
        let selectedProfile = profile
        var refreshes = 0
        let connection = FactoryBrowserConnectionModel(available: false,
            load: { [selectedProfile] }, importSession: { _ in
                throw CoreReplyError(code: "browser_session_not_found")
            }, disconnect: { "unused" }, refreshUsage: { refreshes += 1; return "unused" })
        await connection.load()
        connection.approved = true
        #expect(!(await connection.connect()))
        #expect(!connection.available)
        #expect(refreshes == 0)
    }

    @Test("cancelling during usage refresh keeps the saved sign-in without late UI callbacks")
    func retiredRefresh() async {
        let selectedProfile = profile
        let gate = Gate()
        var changes = 0
        let connection = FactoryBrowserConnectionModel(available: false,
            load: { [selectedProfile] }, importSession: { _ in "Factory sign-in saved." },
            disconnect: { "unused" }, refreshUsage: { await gate.run() },
            onChanged: { changes += 1 })
        await connection.load()
        connection.approved = true
        let pending = Task { await connection.connect() }
        await gate.waitUntilStarted()
        #expect(connection.available)
        connection.cancel()
        gate.finish()
        #expect(!(await pending.value))
        #expect(connection.message == "Factory sign-in saved.")
        #expect(changes == 0)
    }
}
