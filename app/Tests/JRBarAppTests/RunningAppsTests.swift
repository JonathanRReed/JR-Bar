import AppKit
import Observation
import Testing
@testable import JRBarApp

/// The running-app index every rivals check, menu-bar scan and card
/// list reads: it follows launches and quits from its feed, answers from
/// what it read once, and tells its listeners. Every app here is
/// synthetic; no test reads the workspace.
@Suite("Running apps index")
@MainActor
struct RunningAppsTests {
    /// A feed the test drives by hand.
    final class FakeFeed: RunningAppsFeed {
        var initial: [RunningApp]
        private var onChange: (@MainActor ([RunningApp], [pid_t]) -> Void)?
        init(_ initial: [RunningApp]) { self.initial = initial }
        func start(onChange: @escaping @MainActor ([RunningApp], [pid_t]) -> Void) -> [RunningApp] {
            self.onChange = onChange
            return initial
        }
        func launch(_ apps: RunningApp...) { onChange?(apps, []) }
        func quit(_ pids: pid_t...) { onChange?([], pids) }
    }

    final class Tripped: @unchecked Sendable { var fired = false }

    static func app(_ pid: pid_t, _ bundleID: String?, _ name: String?,
                    policy: NSApplication.ActivationPolicy = .regular) -> RunningApp {
        RunningApp(pid: pid, bundleID: bundleID, name: name, policy: policy)
    }

    @Test("the index starts from the feed's apps and follows launches and quits")
    func followsLaunchAndQuit() {
        let feed = FakeFeed([Self.app(101, "io.example.editor", "Editor"),
                             Self.app(102, "io.example.helper", "Helper", policy: .prohibited)])
        let index = RunningApps(feed: feed)
        #expect(index.apps.map(\.pid) == [101, 102])
        #expect(index.bundleIDs == ["io.example.editor", "io.example.helper"])
        let version = index.version

        feed.launch(Self.app(103, "io.example.notes", "Notes"))
        #expect(index.apps.map(\.pid) == [101, 102, 103])
        #expect(index.isRunning(bundleID: "io.example.notes"))
        #expect(index.app(pid: 103)?.name == "Notes")
        #expect(index.version == version + 1)

        feed.quit(101)
        #expect(index.apps.map(\.pid) == [102, 103])
        #expect(!index.isRunning(bundleID: "io.example.editor"))
        #expect(index.app(pid: 101) == nil)
        #expect(index.version == version + 2)

        feed.quit(999)
        #expect(index.version == version + 2, "a quit the index never knew changes nothing")
    }

    @Test("names match ignoring case, as the rivals' rule does")
    func namesIgnoreCase() {
        let feed = FakeFeed([Self.app(201, nil, "notchnook")])
        let index = RunningApps(feed: feed)
        #expect(index.isRunning(named: "NotchNook"))
        #expect(!index.isRunning(named: "Notchy"))
        feed.launch(Self.app(202, nil, "NOTCHY"))
        #expect(index.isRunning(named: "Notchy"), "the name set is rebuilt after a launch")
    }

    @Test("listeners hear launches and quits, with the quit app as it was known")
    func listenersHearChanges() {
        let feed = FakeFeed([Self.app(301, "io.example.a", "A")])
        let index = RunningApps(feed: feed)
        var heard: [RunningAppsChange] = []
        let token = index.addListener { heard.append($0) }
        feed.launch(Self.app(302, "io.example.b", "B", policy: .accessory))
        feed.quit(301)
        #expect(heard.count == 2)
        #expect(heard.first?.launched.map(\.pid) == [302])
        #expect(heard.first?.launched.first?.policy == .accessory)
        #expect(heard.last?.quit.first?.bundleID == "io.example.a")
        index.removeListener(token)
        feed.launch(Self.app(303, nil, "C"))
        #expect(heard.count == 2, "a removed listener hears nothing")
    }

    @Test("a view reading the index is told when an app launches")
    func observationFollowsLaunches() {
        let feed = FakeFeed([])
        let index = RunningApps(feed: feed)
        let tripped = Tripped()
        withObservationTracking {
            _ = index.apps
        } onChange: {
            tripped.fired = true
        }
        feed.launch(Self.app(401, "io.example.new", "New"))
        #expect(tripped.fired)
    }

    @Test("a rival's launch flips the answer at once, and its quit flips it back")
    func rivalLaunchFlips() {
        let feed = FakeFeed([Self.app(501, "io.example.editor", "Editor")])
        let index = RunningApps(feed: feed)
        #expect(UtilityRivals.running(for: .shelfGesture, among: index).isEmpty)
        feed.launch(Self.app(502, "me.damir.dropover-mac", "Dropover", policy: .accessory))
        #expect(UtilityRivals.running(for: .shelfGesture, among: index).map(\.name) == ["Dropover"])
        feed.quit(502)
        #expect(UtilityRivals.running(for: .shelfGesture, among: index).isEmpty)
    }

    @Test("the index's rivals answer agrees with the table's own matching")
    func indexAgreesWithTable() {
        let apps = [
            Self.app(601, "me.damir.dropover-mac", "Dropover"),
            Self.app(602, "io.example.side-load", "Dropzone 4"),
            Self.app(603, nil, "notchnook"),
            Self.app(604, "com.if.Amphetamine", "Amphetamine"),
            Self.app(605, "com.ethanbills.DockDoor", "DockDoor"),
            Self.app(606, "theboringteam.boringnotch", "boring.notch"),
            Self.app(607, "io.example.editor", "Editor"),
        ]
        let index = RunningApps(feed: FakeFeed(apps))
        let pairs = apps.map { (bundleID: $0.bundleID, name: $0.name) }
        for role in UtilityRivals.Role.allCases {
            #expect(UtilityRivals.running(for: role, among: index).map(\.name)
                == UtilityRivals.running(for: role, in: pairs).map(\.name), "role \(role)")
        }
    }

    @Test("the rivals watch moves for a rival's launch or quit, not for every app")
    func watchMovesOnlyForRivals() {
        let feed = FakeFeed([])
        let index = RunningApps(feed: feed)
        let watch = UtilityRivalsWatch(index: index)
        feed.launch(Self.app(701, "io.example.helper", "Helper", policy: .prohibited))
        #expect(watch.version == 0, "a helper starting redraws no rivals note")
        feed.launch(Self.app(702, "at.EternalStorms.Yoink", "Yoink"))
        #expect(watch.version == 1)
        feed.quit(701)
        #expect(watch.version == 1)
        feed.quit(702)
        #expect(watch.version == 2)
    }

    @Test("a relaunch under a reused pid replaces the app")
    func pidReuse() {
        let feed = FakeFeed([Self.app(801, "io.example.old", "Old")])
        let index = RunningApps(feed: feed)
        feed.quit(801)
        feed.launch(Self.app(801, "io.example.new", "New"))
        #expect(index.app(pid: 801)?.bundleID == "io.example.new")
        #expect(index.bundleIDs == ["io.example.new"])
    }

    // MARK: The workspace feed's bookkeeping

    @Test("a quit is known by the object its launch handed over, whatever pid it reads now")
    func ledgerRemovesByObject() {
        var ledger = RunningAppsLedger<String>()
        let kept = [ledger.insert("editor", pid: 901), ledger.insert("notes", pid: 902),
                    ledger.insert("gone-already", pid: -1)]
        #expect(kept == [true, true, false], "an app that reads pid -1 is not kept")
        let quit = ledger.remove(["editor"])
        #expect(quit == [901])
        #expect(ledger.pids == ["notes": 902])
    }

    @Test("a quit object nobody handed over asks for a resync instead of a guess")
    func ledgerUnknownRemovalResyncs() {
        var ledger = RunningAppsLedger<String>()
        ledger.insert("notes", pid: 902)
        let quit = ledger.remove(["stranger", "notes"])
        #expect(quit == nil)
        #expect(ledger.pids == ["notes": 902], "nothing is dropped on a guess")
    }

    @Test("a resync by pid reads only the new apps and names the ones that quit")
    func ledgerResyncByPID() {
        var ledger = RunningAppsLedger<String>()
        ledger.insert("a", pid: 1001)
        ledger.insert("b", pid: 1002)
        // The workspace's fresh objects for the same apps, one quit, one new.
        let result = ledger.resync([(key: "a2", pid: 1001), (key: "c2", pid: 1003), (key: "dead", pid: -1)])
        #expect(result.added == ["c2"], "only the new pid is read")
        #expect(result.quit == [1002])
        #expect(ledger.pids == ["a2": 1001, "c2": 1003], "the ledger holds the fresh objects")
        let quit = ledger.remove(["a2"])
        #expect(quit == [1001])
    }
}
