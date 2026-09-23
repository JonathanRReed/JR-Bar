import Foundation
import Testing
@testable import JRBarApp

/// The `jrbar` link: created where nothing is, moved off an older
/// JR-Bar, never written over somebody else's file. Everything happens
/// in a throwaway folder.
@Suite struct CommandLineToolTests {
    private func sandbox() throws -> (root: URL, link: URL, bundled: String) {
        let root = FileManager.default.temporaryDirectory.appending(path: "jrbar-cli-\(UUID().uuidString)")
        let helpers = root.appending(path: "JR-Bar.app/Contents/Helpers/jrbar-core.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let binary = helpers.appending(path: "jrbar-core")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        return (root, root.appending(path: "bin/jrbar"), binary.path)
    }

    @Test func aDevRunHasNothingToLink() {
        #expect(CommandLineTool.state(link: URL(fileURLWithPath: "/nowhere/jrbar"), bundled: nil) == .unavailable)
    }

    @Test func installLinksAndRemoveUnlinks() throws {
        let box = try sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        #expect(CommandLineTool.state(link: box.link, bundled: box.bundled) == .notInstalled)
        try CommandLineTool.install(link: box.link, bundled: box.bundled)
        #expect(CommandLineTool.state(link: box.link, bundled: box.bundled) == .installed)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.link.path) == box.bundled)
        try CommandLineTool.uninstall(link: box.link, bundled: box.bundled)
        #expect(CommandLineTool.state(link: box.link, bundled: box.bundled) == .notInstalled)
    }

    @Test func anOlderJRBarsLinkIsMovedToThisOne() throws {
        let box = try sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try FileManager.default.createDirectory(at: box.link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = "/Applications/JR-Bar.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core"
        try FileManager.default.createSymbolicLink(atPath: box.link.path, withDestinationPath: old)
        #expect(CommandLineTool.state(link: box.link, bundled: box.bundled) == .stale(old))
        try CommandLineTool.install(link: box.link, bundled: box.bundled)
        #expect(CommandLineTool.state(link: box.link, bundled: box.bundled) == .installed)
    }

    @Test func someoneElsesFileIsNeverTouched() throws {
        let box = try sandbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try FileManager.default.createDirectory(at: box.link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: box.link)
        #expect(CommandLineTool.state(link: box.link, bundled: box.bundled) == .occupied)
        #expect(throws: (any Error).self) { try CommandLineTool.install(link: box.link, bundled: box.bundled) }
        try CommandLineTool.uninstall(link: box.link, bundled: box.bundled)
        #expect(try String(contentsOf: box.link, encoding: .utf8) == "theirs")
        // A link to some other tool is theirs too.
        try FileManager.default.removeItem(at: box.link)
        try FileManager.default.createSymbolicLink(atPath: box.link.path, withDestinationPath: "/opt/homebrew/bin/jrbar")
        #expect(CommandLineTool.state(link: box.link, bundled: box.bundled) == .occupied)
    }
}
