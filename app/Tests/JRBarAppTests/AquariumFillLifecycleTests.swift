import AppKit
import Foundation
import JRBarCore
import Testing
import os
@testable import JRBarApp

@MainActor
@Suite("Aquarium fill lifecycle", .serialized)
struct AquariumFillLifecycleTests {
    private final class Center: NotificationCenter, @unchecked Sendable {
        private let removed = OSAllocatedUnfairLock(initialState: 0)
        var removals: Int { removed.withLock { $0 } }
        override func removeObserver(_ observer: Any) {
            removed.withLock { $0 += 1 }
            super.removeObserver(observer)
        }
    }

    private final class Screens {
        var current: NSRect? = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        var visible = [NSRect(x: 0, y: 40, width: 1920, height: 1040)]
    }

    @MainActor
    private struct Fixture {
        let toys: ToysStore
        let window: NSWindow
        let controller: AquariumWindowController
        let center: Center
        let screens: Screens
        let originalFrame: NSRect
        let save: AquariumSaveFile

        init(center: Center = Center(), screens: Screens = Screens(),
             bring: @escaping @MainActor (NSWindow) -> Void = { _ in }) throws {
            let core = CoreModel()
            let file = AquariumToy.scratchSave()
            let owner = ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                                  cardModel: makeTestCardModel(), notchRuntimeEnabled: false,
                                  nativeSourcesEnabled: false, aquariumSave: file)
            let tank = try #require(owner.aquarium)
            let hidden = NSWindow(contentRect: NSRect(x: 120, y: 180, width: 640, height: 400),
                                  styleMask: AquariumWindowController.styleMask, backing: .buffered, defer: true)
            hidden.isReleasedWhenClosed = false
            hidden.level = .floating
            self.toys = owner
            self.window = hidden
            self.originalFrame = hidden.frame
            self.center = center
            self.screens = screens
            self.save = file
            self.controller = AquariumWindowController(toy: tank, window: hidden, notificationCenter: center,
                                                       bring: bring, screenFrame: { _ in screens.current },
                                                       visibleFrames: { screens.visible })
        }

        func close() {
            controller.close()
            toys.shutdown()
            try? FileManager.default.removeItem(at: save.url.deletingLastPathComponent())
        }

        func expectRestored() {
            #expect(!controller.filled)
            #expect(window.styleMask == AquariumWindowController.styleMask)
            #expect(window.level == .floating)
            #expect(window.frame == originalFrame)
            #expect(!window.isVisible && !window.isKeyWindow)
        }
    }

    @Test("another JR-Bar main window releases the filled tank without deactivating the app")
    func anotherMainWindowRestoresTank() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.controller.fillScreen()
        #expect(fixture.controller.filled && fixture.window.level == .screenSaver)
        let other = WindowFrontTests.offscreenWindow()
        fixture.center.post(name: NSWindow.didBecomeMainNotification, object: other)
        fixture.expectRestored()
    }

    @Test("the tank becoming main or a transient panel becoming key preserves fill mode")
    func ownMainAndPanelKeyKeepFill() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.controller.fillScreen()
        fixture.center.post(name: NSWindow.didBecomeMainNotification, object: fixture.window)
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 200, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: true)
        fixture.center.post(name: NSWindow.didBecomeKeyNotification, object: panel)
        fixture.center.post(name: NSWindow.didBecomeMainNotification, object: nil)
        #expect(fixture.controller.filled && fixture.window.level == .screenSaver)
        #expect(fixture.window.frame == fixture.screens.current)
        #expect(!fixture.window.isVisible && !panel.isVisible)
    }

    @Test("app deactivation restores frame, level and chrome")
    func deactivationRestoresTank() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.controller.fillScreen()
        fixture.center.post(name: NSApplication.didResignActiveNotification, object: nil)
        fixture.expectRestored()
    }

    @Test("fill observers are armed before bringing the tank forward", arguments: [false, true])
    func handoffDuringBring(isMainWindow: Bool) throws {
        let center = Center()
        let other = WindowFrontTests.offscreenWindow()
        let fixture = try Fixture(center: center, bring: { _ in
            if isMainWindow { center.post(name: NSWindow.didBecomeMainNotification, object: other) }
            else { center.post(name: NSApplication.didResignActiveNotification, object: nil) }
        })
        defer { fixture.close() }
        fixture.controller.fillScreen()
        fixture.expectRestored()
    }

    @Test("repeated fill and restore keep the first saved frame and retire watches once")
    func repeatedTransitions() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        for _ in 0..<3 {
            fixture.controller.fillScreen()
            fixture.controller.fillScreen()
            fixture.controller.restoreScreen()
            fixture.expectRestored()
            let removed = fixture.center.removals
            fixture.controller.restoreScreen()
            #expect(fixture.center.removals == removed)
        }
        #expect(fixture.center.removals == 6)
    }

    @Test("display changes resize fill and restoration uses the remaining usable display")
    func displayRemoval() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.controller.fillScreen()
        let remaining = NSRect(x: -1280, y: 30, width: 1280, height: 770)
        fixture.screens.current = NSRect(x: -1280, y: 0, width: 1280, height: 800)
        fixture.screens.visible = [remaining]
        fixture.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(fixture.window.frame == fixture.screens.current)
        fixture.controller.restoreScreen()
        #expect(!fixture.controller.filled && fixture.window.level == .floating)
        #expect(fixture.window.styleMask == AquariumWindowController.styleMask)
        #expect(remaining.contains(fixture.window.frame))
        #expect(!fixture.window.isVisible)
    }

    @Test("closing a filled hidden window retires all observation and later fill does nothing")
    func closeRetiresObservers() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.controller.fillScreen()
        fixture.controller.close()
        #expect(!fixture.controller.filled)
        #expect(fixture.center.removals == 4)
        let frame = fixture.window.frame
        fixture.center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        fixture.center.post(name: NSApplication.didResignActiveNotification, object: nil)
        fixture.center.post(name: NSWindow.didBecomeMainNotification, object: WindowFrontTests.offscreenWindow())
        fixture.controller.fillScreen()
        #expect(!fixture.controller.filled && fixture.window.frame == frame)
        #expect(fixture.center.removals == 4)
        #expect(!fixture.window.isVisible)
    }

    @Test("missing display geometry leaves the normal window alone")
    func noScreen() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.screens.current = nil
        fixture.controller.fillScreen()
        fixture.expectRestored()
        #expect(fixture.center.removals == 0)
    }
}
