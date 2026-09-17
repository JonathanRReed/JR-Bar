import Foundation
import Testing
@testable import JRBarApp

@Suite("Asking pane frontmost proof")
struct AskingPaneTests {
    /// A staged ancestry table: pid → parent. `nil` is the walk hitting
    /// a dead link — the kernel declined to say.
    static func table(_ edges: [Int32: Int32]) -> (Int32) -> Int32? {
        { edges[$0] }
    }

    @Test("a bundle miss is never the pane, no matter the pids")
    func bundleMismatch() {
        #expect(!AskingPane.isFrontmost(expectedBundleIDs: ["com.apple.Terminal"], sessionPID: 100,
                                        frontmostBundleID: "com.googlecode.iterm2", frontmostPID: 50,
                                        parentPID: Self.table([100: 50])))
    }

    @Test("no named process: the bundle match is the best signal there is")
    func bundleOnly() {
        #expect(AskingPane.isFrontmost(expectedBundleIDs: ["com.apple.Terminal"], sessionPID: nil,
                                       frontmostBundleID: "com.apple.Terminal", frontmostPID: 50))
    }

    @Test("the frontmost pid on the session's ancestry proves the pane")
    func ancestryProven() {
        // session 100 → shell 200 → terminal 50 → launchd 1.
        let table = Self.table([100: 200, 200: 50, 50: 1])
        #expect(AskingPane.isFrontmost(expectedBundleIDs: ["com.apple.Terminal"], sessionPID: 100,
                                       frontmostBundleID: "com.apple.Terminal", frontmostPID: 50,
                                       parentPID: table))
    }

    @Test("a different window of the same terminal keeps the noise — the daemon's other_window read")
    func siblingWindow() {
        // session 100 → shell 200 → terminal 60; the frontmost 50 is a
        // second terminal process, not this session's host.
        let table = Self.table([100: 200, 200: 60, 60: 1, 50: 1])
        #expect(!AskingPane.isFrontmost(expectedBundleIDs: ["com.apple.Terminal"], sessionPID: 100,
                                        frontmostBundleID: "com.apple.Terminal", frontmostPID: 50,
                                        parentPID: table))
    }

    @Test("unproven never quiets: no frontmost pid, a dead walk, a stale session pid")
    func unproven() {
        #expect(!AskingPane.isFrontmost(expectedBundleIDs: ["com.apple.Terminal"], sessionPID: 100,
                                        frontmostBundleID: "com.apple.Terminal", frontmostPID: nil))
        // The very first hop fails — an empty walk, the daemon's "could
        // not be determined", never a match.
        #expect(!AskingPane.isFrontmost(expectedBundleIDs: ["com.apple.Terminal"], sessionPID: 100,
                                        frontmostBundleID: "com.apple.Terminal", frontmostPID: 50,
                                        parentPID: { _ in nil }))
        #expect(!AskingPane.isFrontmost(expectedBundleIDs: ["com.apple.Terminal"], sessionPID: -1,
                                        frontmostBundleID: "com.apple.Terminal", frontmostPID: 50))
    }

    @Test("the walk tolerates a cycle instead of hanging")
    func cycleSafe() {
        let table = Self.table([100: 200, 200: 100])
        #expect(!AskingPane.isFrontmost(expectedBundleIDs: ["com.apple.Terminal"], sessionPID: 100,
                                        frontmostBundleID: "com.apple.Terminal", frontmostPID: 50,
                                        parentPID: table))
        #expect(AskingPane.ancestry(of: 100, parentPID: table).count <= AskingPane.ancestryDepth)
    }

    @Test("the real kernel read: this test process's parent is on its own ancestry")
    func liveRead() {
        let me = getpid()
        let parent = AskingPane.parentPID(me)
        #expect(parent != nil && parent! > 1)
        #expect(AskingPane.ancestry(of: me).first == parent)
        // …and the full decision end to end, with the test runner posing
        // as its own frontmost host.
        #expect(AskingPane.isFrontmost(expectedBundleIDs: ["dev.jr.tests"], sessionPID: Int(me),
                                       frontmostBundleID: "dev.jr.tests", frontmostPID: parent!))
    }
}
