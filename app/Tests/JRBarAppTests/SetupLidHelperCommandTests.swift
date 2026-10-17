import Foundation
import Testing
@testable import JRBarApp

/// The closed-lid helper's copied command runs a fixed `/bin/sh` script as
/// root, never a program inside the app bundle that the person's own
/// account could swap. These run that script against a scratch folder and
/// a stand-in `visudo`, so nothing touches `/etc` and no root is needed.
@MainActor
@Suite struct SetupLidHelperCommandTests {
    /// The same two lines `lid_sleep.sleep_helper_sudoers_rule` writes.
    static let expectedRule =
        "casey ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"

    struct Outcome {
        var status: Int32
        var files: [String]
        var rule: String?
        var mode: Int?
    }

    private func run(user: String?, visudoExit: Int32) throws -> Outcome {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("jrbar-lid-command-\(UUID().uuidString)")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let sudoers = scratch.appendingPathComponent("sudoers.d")
        try fileManager.createDirectory(at: sudoers, withIntermediateDirectories: true)
        let visudo = scratch.appendingPathComponent("visudo")
        try "#!/bin/sh\nexit \(visudoExit)\n".write(to: visudo, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: visudo.path)

        let script = SetupModel.lidHelperScript(sudoersDirectory: sudoers.path, visudo: visudo.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SUDO_USER")
        if let user { environment["SUDO_USER"] = user }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let installed = sudoers.appendingPathComponent("jrbar-disablesleep")
        // A leftover dotted temporary would show in this listing too.
        let files = try fileManager.contentsOfDirectory(atPath: sudoers.path).sorted()
        let mode = (try? fileManager.attributesOfItem(atPath: installed.path)[.posixPermissions]) as? Int
        return Outcome(status: process.terminationStatus, files: files,
                       rule: try? String(contentsOf: installed, encoding: .utf8), mode: mode)
    }

    @Test func theCommandIsAFixedShellScriptNotABundledProgram() {
        let command = SetupModel.lidHelperCommand()
        #expect(command.hasPrefix("sudo /bin/sh -c '"))
        #expect(command.hasSuffix("'"))
        #expect(!command.contains(".app"))
        #expect(!command.contains("jrbar-core"))
        #expect(command.contains("/usr/sbin/visudo -cf"))
        #expect(command.contains("/etc/sudoers.d/jrbar-disablesleep"))
        // One quoted argument: the script between the quotes holds none.
        let body = command.dropFirst("sudo /bin/sh -c '".count).dropLast()
        #expect(!body.contains("'"))
    }

    @Test func aGoodRuleLandsAtMode0440() throws {
        let outcome = try run(user: "casey", visudoExit: 0)
        #expect(outcome.status == 0)
        #expect(outcome.files == ["jrbar-disablesleep"])
        #expect(outcome.rule == Self.expectedRule)
        #expect(outcome.mode == 0o440)
    }

    @Test func aRuleVisudoRefusesLeavesNothingBehind() throws {
        let outcome = try run(user: "casey", visudoExit: 1)
        #expect(outcome.status != 0)
        #expect(outcome.files.isEmpty)
    }

    @Test func aMissingOrOddUserWritesNothing() throws {
        let users: [String?] = [nil, "", "a b", "x;rm", "$(id)", "a\"b"]
        for user in users {
            let outcome = try run(user: user, visudoExit: 0)
            #expect(outcome.status != 0)
            #expect(outcome.files.isEmpty)
        }
    }
}
