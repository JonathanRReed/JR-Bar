import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

/// Following Alcove's capsule is opt-in by the renderer pick: the
/// setting alone never starts the window-list poll while JR-Bar draws
/// the notch.
@Suite("Alcove follower opt-in")
@MainActor
struct AlcoveFollowerTests {
    @Test("the setting alone does not follow; naming Alcove the renderer does")
    func optIn() {
        let before = AlcoveFollower.rendererChosen
        defer { AlcoveFollower.noteRenderer(chosen: before) }
        AlcoveFollower.noteRenderer(chosen: false)
        let follower = AlcoveFollower()
        follower.enabled = true
        #expect(!follower.isPolling, "JR-Bar draws the notch: no poll")
        #expect(follower.statusDescription == "off (JR-Bar draws the notch)")
        follower.enabled = false
        #expect(follower.statusDescription == "off")

        // The post is synchronous on this (main) thread, so the box is
        // only ever touched here.
        final class Heard: @unchecked Sendable { var count = 0 }
        let heard = Heard()
        let token = NotificationCenter.default.addObserver(
            forName: AlcoveFollower.rendererChangedNotification, object: nil, queue: nil) { _ in heard.count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        AlcoveFollower.noteRenderer(chosen: true)
        AlcoveFollower.noteRenderer(chosen: true)
        #expect(heard.count == 1, "only a change is announced")
        #expect(AlcoveFollower.rendererChosen)
    }
}

/// The accessibility read of Alcove 1.7.9's container window: it happens
/// off the main thread, one at a time, and a slow Alcove costs a late
/// update instead of a stalled JR-Bar. The window server, accessibility
/// and the running-apps list are all stood in for, and every wait is on a
/// gate with a bound.
@Suite("Alcove follower accessibility read")
@MainActor
struct AlcoveFollowerReadTests {
    private static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private static let container = CGRect(x: 444, y: 0, width: 624, height: 320)
    /// Controls Alcove lays out inside the capsule, near the container's top.
    private nonisolated static let content = [CGRect(x: 640, y: 6, width: 232, height: 30)]

    private static func world(trusted: Bool = true) -> AlcovePollContext {
        let row = AlcoveWindowRow(ownerName: AlcoveGeometry.ownerName, ownerPID: 4242, number: 7, layer: 25,
                                  bounds: container)
        return AlcovePollContext(rows: [row], screenFrame: screen, primaryHeight: screen.height, trusted: trusted)
    }

    private final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var entered = 0
        func wait() {
            lock.lock(); entered += 1; lock.unlock()
            _ = semaphore.wait(timeout: .now() + 10)
        }
        func open() { semaphore.signal() }
        var readers: Int { lock.lock(); defer { lock.unlock() }; return entered }
    }

    private final class Changes: @unchecked Sendable {
        var seen: [AlcoveCapsule?] = []
    }

    /// A follower on stand-ins: renderer chosen, Alcove running, the
    /// container window on screen, and `reader` for the accessibility read.
    private func makeFollower(trusted: Bool = true, chosen: Bool = true,
                          reader: @escaping @Sendable (pid_t, CGRect) -> [CGRect]?) -> (AlcoveFollower, Changes) {
        let follower = AlcoveFollower()
        let changes = Changes()
        follower.onChange = { changes.seen.append($0) }
        follower.context = { Self.world(trusted: trusted) }
        follower.readFrames = reader
        follower.alcoveRunning = { true }
        follower.rendererIsChosen = { chosen }
        return (follower, changes)
    }

    private func land(_ follower: AlcoveFollower, _ frames: [CGRect]?, token: Int? = nil) {
        follower.landed(frames, token: token ?? follower.generation, container: Self.container,
                        screenFrame: Self.screen, primaryHeight: Self.screen.height)
    }

    @Test("a slow reader does not block the poll, and the capsule lands when it answers")
    func slowReaderDoesNotBlock() async {
        let gate = Gate()
        let (follower, changes) = makeFollower { _, _ in gate.wait(); return Self.content }
        // Following starts the first poll. Enabled matters here: a stray
        // renderer announcement from another test then re-polls instead of
        // stopping this follower.
        follower.enabled = true
        #expect(follower.capsule == nil, "the poll returned before the reader answered")
        #expect(follower.pendingRead != nil)
        #expect(follower.isPolling)
        let read = follower.pendingRead
        gate.open()
        await read?.value
        #expect(follower.capsule != nil)
        #expect(follower.source == "accessibility")
        #expect(changes.seen.count == 1)
        follower.enabled = false
    }

    @Test("only one read runs at a time, however often the poll is asked for")
    func singleFlight() async {
        let gate = Gate()
        let (follower, _) = makeFollower { _, _ in gate.wait(); return Self.content }
        follower.enabled = true
        let first = follower.pendingRead
        let started = follower.generation
        #expect(first != nil)
        follower.poll()
        follower.poll()
        follower.poll()
        #expect(follower.pendingRead == first, "the read in flight is the only one")
        #expect(follower.generation == started, "no second read was started")
        gate.open()
        await first?.value
        follower.enabled = false
    }

    @Test("a stale landing is dropped")
    func staleLandingIsDropped() {
        let (follower, changes) = makeFollower { _, _ in nil }
        land(follower, Self.content, token: follower.generation - 1)
        #expect(follower.capsule == nil)
        #expect(changes.seen.isEmpty)
        #expect(follower.source == "none")
    }

    @Test("stopping overtakes a read in flight: a late answer cannot revive the follower")
    func stopOvertakesTheRead() async {
        let gate = Gate()
        let (follower, changes) = makeFollower { _, _ in gate.wait(); return Self.content }
        follower.enabled = true
        let read = follower.pendingRead
        #expect(follower.isPolling)
        // The renderer pick moves away (or Alcove quits, or the setting goes off).
        follower.rendererIsChosen = { false }
        follower.reconcile()
        gate.open()
        await read?.value
        #expect(follower.capsule == nil)
        #expect(changes.seen.isEmpty, "the late frames never repaint a capsule")
        #expect(!follower.isPolling, "and nothing re-arms after the stop")
    }

    @Test("the poll re-arms only after the read lands, and never once following has stopped")
    func rearmsOnLanding() async {
        let gate = Gate()
        let (follower, _) = makeFollower { _, _ in gate.wait(); return Self.content }
        follower.enabled = true
        let read = follower.pendingRead
        #expect(read != nil, "turning following on starts a read")
        #expect(!follower.hasArmedTimer, "no timer while the read is out")
        gate.open()
        await read?.value
        #expect(follower.hasArmedTimer, "the landing arms the next poll")
        follower.enabled = false
        #expect(!follower.hasArmedTimer)

        // With following off, a landing arms nothing.
        land(follower, Self.content)
        #expect(!follower.hasArmedTimer)
    }

    @Test("a stalled read keeps the last capsule and says so; an empty answer clears it")
    func stalledKeepsTheCapsule() {
        let (follower, changes) = makeFollower { _, _ in nil }
        land(follower, Self.content)
        let held = follower.capsule
        #expect(held != nil)
        #expect(changes.seen.count == 1)

        land(follower, nil)
        #expect(follower.capsule == held, "a stall is not the capsule going away")
        #expect(changes.seen.count == 1)
        #expect(follower.source.contains("slow"))

        land(follower, [])
        #expect(follower.capsule == nil, "a real answer with nothing in it is")
        #expect(changes.seen.count == 2)
        #expect(changes.seen.last == .some(nil))
        #expect(follower.source == "accessibility")
    }

    @Test("nothing is read unless Alcove is the renderer")
    func nothingIsReadWithoutTheOptIn() {
        let gate = Gate()
        let (follower, _) = makeFollower(chosen: false) { _, _ in gate.wait(); return Self.content }
        follower.enabled = true
        #expect(follower.pendingRead == nil)
        #expect(!follower.isPolling)
        #expect(gate.readers == 0)
        #expect(follower.statusDescription == "off (JR-Bar draws the notch)")
    }

    @Test("without accessibility access the container window is not read")
    func untrustedIsNotRead() {
        let gate = Gate()
        let (follower, _) = makeFollower(trusted: false) { _, _ in gate.wait(); return Self.content }
        follower.poll()
        #expect(follower.pendingRead == nil)
        #expect(follower.source == "container window, no accessibility access")
        #expect(gate.readers == 0)
        follower.enabled = false
    }
}

/// The walk over Alcove's accessibility tree, on a fake tree and a fake
/// clock passed in as arguments.
@Suite("Alcove content walk")
struct AlcoveContentWalkTests {
    private static let window = CGRect(x: 444, y: 0, width: 624, height: 320)

    private static func rect(_ id: Int) -> CGRect {
        CGRect(x: 450 + id, y: 4, width: 20, height: 10)
    }

    private final class Tree {
        var children: [Int: [Int]]
        var frames: [Int: CGRect]
        var framesRead: [Int] = []
        var stalls: Set<Int> = []
        var clock = 0.0
        var cost = 0.0
        init(children: [Int: [Int]], window: CGRect = AlcoveContentWalkTests.window) {
            self.children = children
            var frames: [Int: CGRect] = [:]
            for id in children.keys { frames[id] = AlcoveContentWalkTests.rect(id) }
            for kids in children.values { for id in kids { frames[id] = AlcoveContentWalkTests.rect(id) } }
            frames[0] = window
            self.frames = frames
        }
        func frame(_ id: Int) throws -> CGRect? {
            framesRead.append(id)
            clock += cost
            if stalls.contains(id) { throw AlcoveReadStalled() }
            return frames[id]
        }
        func kids(_ id: Int) throws -> [Int] { children[id] ?? [] }
    }

    private func walk(_ tree: Tree, roots: [Int] = [0], maxNodes: Int = 96, maxDepth: Int = 6,
                      deadline: TimeInterval = 0.75) -> [CGRect]? {
        AlcoveFollower.walkContent(roots: roots, window: Self.window, maxNodes: maxNodes, maxDepth: maxDepth,
                                   deadline: deadline, now: { tree.clock },
                                   frame: { try tree.frame($0) }, children: { try tree.kids($0) })
    }

    @Test("a tree read to the end returns every frame, depth first, and skips other windows")
    func fullTree() {
        let tree = Tree(children: [0: [1, 2], 1: [3], 2: [], 3: [], 9: [4]])
        tree.frames[9] = CGRect(x: 0, y: 0, width: 50, height: 50)
        let frames = walk(tree, roots: [9, 0])
        #expect(frames == [Self.window, Self.rect(1), Self.rect(3), Self.rect(2)])
        #expect(!tree.framesRead.contains(4), "another window's contents are never read")
    }

    @Test("an element with no frame is left out and its children are still read")
    func frameless() {
        let tree = Tree(children: [0: [1], 1: [2], 2: []])
        tree.frames[1] = nil
        let frames = walk(tree)
        #expect(frames == [Self.window, Self.rect(2)])
    }

    @Test("the walk stops at 96 visited elements")
    func nodeBudget() {
        let flat = Array(1...200)
        let tree = Tree(children: [0: flat])
        let frames = walk(tree)
        #expect(frames?.count == 96)
        #expect(tree.framesRead.count == 96)
    }

    @Test("the walk stops at depth 6")
    func depthLimit() {
        var chain: [Int: [Int]] = [:]
        for id in 0..<20 { chain[id] = [id + 1] }
        let tree = Tree(children: chain)
        let frames = walk(tree)
        #expect(frames?.count == 6)
        #expect(tree.framesRead == [0, 1, 2, 3, 4, 5])
    }

    @Test("a read that runs past its deadline is a stall, not a short answer")
    func deadline() {
        let tree = Tree(children: [0: [1, 2, 3, 4]])
        tree.cost = 0.3
        let frames = walk(tree)
        #expect(frames == nil)
        #expect(tree.framesRead == [0, 1, 2], "no element is read once the clock has passed the deadline")
    }

    @Test("the first element that cannot answer ends the walk and nothing further is read")
    func firstStallEndsTheWalk() {
        let tree = Tree(children: [0: [1, 2, 3], 1: [4]])
        tree.stalls = [2]
        let frames = walk(tree)
        #expect(frames == nil)
        #expect(tree.framesRead == [0, 1, 4, 2])
    }
}
