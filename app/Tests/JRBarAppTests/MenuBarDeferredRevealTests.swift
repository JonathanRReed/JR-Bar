import AppKit
import Testing
@testable import JRBarApp
@testable import JRBarCore

@MainActor
@Suite("Menu Bar deferred focus hide")
struct MenuBarDeferredRevealTests {
    @MainActor
    private final class Harness {
        let reveal = MenuBarReveal()
        var settings = MenuBarSettings()
        var suppressed = false
        var menuOpen = false
        var hides = 0
        var fires: [@MainActor () -> Void] = []

        init() {
            settings.rehideMode = .focusChange
            reveal.settings = { [weak self] in self?.settings ?? MenuBarSettings() }
            reveal.suppressed = { [weak self] in self?.suppressed ?? false }
            reveal.itemMenuOpen = { [weak self] in self?.menuOpen ?? false }
            reveal.row = { nil }
            reveal.barFrame = { nil }
            reveal.mouseLocation = { .zero }
            reveal.onHide = { [weak self] in self?.hides += 1 }
            reveal.scheduleRehide = { [weak self] _, fire in
                self?.fires.append(fire)
                // Deliberately allow cancelled callbacks to be delivered.
                return {}
            }
        }
    }

    @Test("a focus change during drag hides once the suppression clears")
    func suppressionClears() {
        let h = Harness()
        defer { h.reveal.stop() }
        h.reveal.triggerReveal()
        h.suppressed = true
        h.reveal.frontAppChanged()
        #expect(h.fires.count == 1)
        h.fires[0]()
        #expect(h.hides == 0)
        #expect(h.fires.count == 2)
        h.suppressed = false
        h.fires[1]()
        #expect(h.hides == 1)
        #expect(!h.reveal.revealed)
        h.fires[1]()
        #expect(h.hides == 1)
    }

    @Test("a deferred hide holds while an item menu is open and folds after it closes")
    func menuCloses() {
        let h = Harness()
        defer { h.reveal.stop() }
        h.reveal.triggerReveal()
        h.menuOpen = true
        h.reveal.frontAppChanged()
        h.fires[0]()
        #expect(h.hides == 0)
        h.menuOpen = false
        h.fires[1]()
        #expect(h.hides == 1)
    }

    @Test("an open Item Bar protects the reveal until its hold ends")
    func itemBarHold() {
        let h = Harness()
        defer { h.reveal.stop() }
        h.reveal.triggerReveal()
        h.reveal.holdOpen = true
        h.reveal.frontAppChanged()
        h.fires[0]()
        #expect(h.hides == 0)
        h.reveal.holdOpen = false
        h.fires[1]()
        #expect(h.hides == 1)
    }

    @Test("a fresh reveal retires the old deferred callback")
    func freshRevealRetiresCallback() {
        let h = Harness()
        defer { h.reveal.stop() }
        h.reveal.triggerReveal()
        h.suppressed = true
        h.reveal.frontAppChanged()
        h.suppressed = false
        h.reveal.triggerReveal()
        h.fires[0]()
        #expect(h.hides == 0)
        #expect(h.reveal.revealed)
        #expect(h.fires.count == 1)
    }

    @Test("changing rehide mode retires the deferred focus callback")
    func modeChangeRetiresCallback() {
        let h = Harness()
        defer { h.reveal.stop() }
        h.reveal.triggerReveal()
        h.suppressed = true
        h.reveal.frontAppChanged()
        h.suppressed = false
        h.settings.rehideMode = .untilClick
        h.fires[0]()
        h.settings.rehideMode = .focusChange
        h.fires[0]()
        #expect(h.hides == 0)
        #expect(h.reveal.revealed)
    }

    @Test("stop and cancel retire deferred callbacks")
    func stopAndCancel() {
        for stop in [false, true] {
            let h = Harness()
            defer { h.reveal.stop() }
            h.reveal.triggerReveal()
            h.suppressed = true
            h.reveal.frontAppChanged()
            if stop { h.reveal.stop() } else { h.reveal.cancelReveal() }
            h.suppressed = false
            h.fires[0]()
            #expect(h.hides == 0)
            #expect(!h.reveal.revealed)
        }
    }

    @Test("an unheld focus change still hides without arming a timer")
    func ordinaryFocusChangeHasNoTimer() {
        let h = Harness()
        defer { h.reveal.stop() }
        h.reveal.triggerReveal()
        h.reveal.frontAppChanged()
        #expect(h.hides == 1)
        #expect(h.fires.isEmpty)
    }
}
