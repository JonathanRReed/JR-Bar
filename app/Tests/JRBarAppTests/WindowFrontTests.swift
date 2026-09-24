import AppKit
import Foundation
import Testing
@testable import JRBarApp

/// The one way a JR-Bar window comes in front of the app you're in.
/// Nothing here is shown or activated: the Space pull runs on windows
/// that are never ordered in, and the Launch Services fallback runs on
/// a stand-in clock.
@MainActor
@Suite("Window front")
struct WindowFrontTests {
    static func offscreenWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                 styleMask: [.titled, .closable], backing: .buffered, defer: true)
    }

    // MARK: The Space pull

    @Test("a window off the active Space moves for the order-in, then stays put")
    func spacePullIsOnlyForTheOrderIn() {
        let window = Self.offscreenWindow()
        var orders = 0
        var during: NSWindow.CollectionBehavior = []
        WindowFront.orderIn(window, isOnActiveSpace: false) { ordered in
            orders += 1
            during = ordered.collectionBehavior
        }
        #expect(orders == 1)
        #expect(during.contains(.moveToActiveSpace), "the order-in runs with the pull on")
        #expect(!window.collectionBehavior.contains(.moveToActiveSpace), "and it comes straight off")
        #expect(!window.isVisible, "nothing was ordered in")
    }

    @Test("a window already on the active Space is ordered in as it is")
    func onTheActiveSpaceNoPull() {
        let window = Self.offscreenWindow()
        let before = window.collectionBehavior
        var during: NSWindow.CollectionBehavior = [.moveToActiveSpace]
        WindowFront.orderIn(window, isOnActiveSpace: true) { ordered in
            during = ordered.collectionBehavior
        }
        #expect(!during.contains(.moveToActiveSpace))
        #expect(window.collectionBehavior == before)
    }

    @Test("a window's own behaviour survives, and an every-Space window is never given the pull")
    func ownBehaviourSurvives() {
        let moving = Self.offscreenWindow()
        moving.collectionBehavior = [.moveToActiveSpace]
        WindowFront.orderIn(moving, isOnActiveSpace: false) { _ in }
        #expect(moving.collectionBehavior.contains(.moveToActiveSpace))

        // AppKit throws from setCollectionBehavior: with both.
        let everywhere = Self.offscreenWindow()
        everywhere.collectionBehavior = [.canJoinAllSpaces]
        let before = everywhere.collectionBehavior
        var during: NSWindow.CollectionBehavior = []
        WindowFront.orderIn(everywhere, isOnActiveSpace: false) { ordered in
            during = ordered.collectionBehavior
        }
        #expect(!during.contains(.moveToActiveSpace))
        #expect(everywhere.collectionBehavior == before)
    }

    // MARK: The Launch Services fallback

    @Test("the fallback waits a quarter second and asks nothing up front")
    func fallbackWaits() {
        let probe = FallbackProbe()
        WindowFront.armFallback(probe.fallback)
        #expect(WindowFront.fallbackDelay == 0.25)
        #expect(probe.delays == [WindowFront.fallbackDelay])
        #expect(probe.opens == 0, "nothing is asked before the wait ends")
    }

    @Test("an app that came active during the wait is not opened again")
    func activeAppSkipsTheFallback() {
        let probe = FallbackProbe()
        WindowFront.armFallback(probe.fallback)
        probe.active = true
        probe.elapse()
        #expect(probe.opens == 0)
    }

    @Test("an app still inactive when the wait ends opens itself through Launch Services")
    func inactiveAppFallsBack() {
        let probe = FallbackProbe()
        // Active as the window came up, then another app took it back:
        // the flag is read when the wait ends, not when it starts.
        probe.active = true
        WindowFront.armFallback(probe.fallback)
        probe.active = false
        probe.elapse()
        #expect(probe.opens == 1)
    }

    // MARK: The call sites

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/JRBarApp")

    @Test("every window a click or a link opens comes forward through the one helper")
    func everyShowRoutesThroughTheHelper() throws {
        let files = ["ControlCenterWindowController.swift", "EffectStudioWindowController.swift",
                     "HistoryWindowController.swift", "SettingsWindowController.swift",
                     "Setup/SetupWindowController.swift", "Toys/Aquarium/AquariumWindowController.swift",
                     "UsageCenterWindowController.swift", "Overview/OverviewWindowController.swift",
                     "Utilities/DataHoarder/DataHoarderUtility.swift",
                     "WhatsNew/WhatsNewWindowController.swift"]
        for file in files {
            let text = try String(contentsOf: Self.sources.appending(path: file), encoding: .utf8)
            #expect(text.contains("WindowFront.bring("), "\(file) comes forward through WindowFront")
            #expect(!text.contains("NSRunningApplication.current.activate()"), "\(file) leaves activation to it")
            #expect(!text.contains("openApplication(at: Bundle.main.bundleURL"), "\(file) keeps no fallback copy")
        }
    }

    @Test("no source activates the app with the deprecated call")
    func noDeprecatedActivation() throws {
        let walker = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)
        var offenders: [String] = []
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "WindowFront.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("activate(ignoringOtherApps:") { offenders.append(url.lastPathComponent) }
        }
        #expect(offenders.isEmpty)
    }

    @Test("What's New's own showing orders in without taking the app active")
    func whatsNewGateNeverActivates() throws {
        let file = Self.sources.appending(path: "WhatsNew/WhatsNewWindowController.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(text.range(of: "private func present() {"))
        let end = try #require(text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex))
        let body = String(text[start.upperBound..<end.lowerBound])
        #expect(body.contains("orderFrontRegardless()"))
        #expect(!body.contains("WindowFront"))
        #expect(!body.contains("activate"))
    }
}

/// A stand-in for the fallback's clock and facts: records each wait and
/// runs it on demand, and counts the opens it was asked for.
@MainActor
private final class FallbackProbe {
    var delays: [TimeInterval] = []
    var waiting: [@MainActor () -> Void] = []
    var active = false
    var opens = 0

    var fallback: WindowFront.Fallback {
        WindowFront.Fallback(wait: { [unowned self] delay, then in
            self.delays.append(delay)
            self.waiting.append(then)
        }, isActive: { [unowned self] in
            self.active
        }, openSelf: { [unowned self] in
            self.opens += 1
        })
    }

    func elapse() {
        let due = waiting
        waiting = []
        for work in due { work() }
    }
}
