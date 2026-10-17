import AppKit
import Testing
@testable import JRBarApp

@MainActor
@Suite struct DockPanelWatchersTests {
    @Test("handled preview keys are consumed only over the panel")
    func navigationConsumption() {
        let watchers = DockPanelWatchers()
        var inside = true
        var handled: [UInt16] = []
        watchers.isInside = { inside }
        watchers.onKey = { code in
            handled.append(code)
            return code == 124
        }

        #expect(watchers.handleKey(124))
        #expect(!watchers.handleKey(0))
        inside = false
        #expect(!watchers.handleKey(124))
        #expect(handled == [124, 0])
    }

    @Test("modified shortcuts pass through without moving preview selection")
    func modifiedKeysPassThrough() {
        let watchers = DockPanelWatchers()
        watchers.isInside = { true }
        var handled = 0
        watchers.onKey = { _ in handled += 1; return true }
        watchers.onEscape = { handled += 1 }

        for flag in [NSEvent.ModifierFlags.command, .control, .option, .shift] {
            #expect(!watchers.handleKey(124, modifiers: flag))
            #expect(!watchers.handleKey(53, modifiers: flag))
        }
        #expect(handled == 0)
    }

    @Test("bare Escape dismisses from outside the panel and is consumed")
    func escapeConsumption() {
        let watchers = DockPanelWatchers()
        var dismissed = 0
        watchers.onEscape = { dismissed += 1 }
        #expect(watchers.handleKey(53))
        #expect(dismissed == 1)
        watchers.onEscape = nil
        #expect(!watchers.handleKey(53))
    }
}
