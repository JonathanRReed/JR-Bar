import ApplicationServices
import Foundation
import Testing
@testable import JRBarApp

/// The switcher's keyboard: layout-correct type-ahead, the keys an open
/// strip owns, and the pointer gate behind hover-selects.
@MainActor
struct DockSwitcherKeysTests {
    @Test("type-ahead spells through the user's layout — Dvorak and AZERTY, not US positions")
    func layoutCorrectCharacters() throws {
        let dvorak = try #require(DockKeyboardLayout.layoutData(id: "com.apple.keylayout.Dvorak"),
                                  "Dvorak ships with every macOS")
        // The key where QWERTY has "s" types "o" on Dvorak.
        #expect(DockKeyboardLayout.translate(keyCode: 1, shift: false, command: false, layout: dvorak) == "o")
        #expect(DockKeyboardLayout.translate(keyCode: 0, shift: false, command: false, layout: dvorak) == "a")
        let french = try #require(DockKeyboardLayout.layoutData(id: "com.apple.keylayout.French"))
        // AZERTY: the QWERTY "q" position types "a", the "a" position "q".
        #expect(DockKeyboardLayout.translate(keyCode: 12, shift: false, command: false, layout: french) == "a")
        #expect(DockKeyboardLayout.translate(keyCode: 0, shift: false, command: false, layout: french) == "q")
        let us = try #require(DockKeyboardLayout.layoutData(id: "com.apple.keylayout.US"))
        #expect(DockKeyboardLayout.translate(keyCode: 18, shift: true, command: false, layout: us) == "!",
                "shift survives — ⇧1 is the waiting filter")
    }

    @Test("arrows, Return and Esc type nothing printable")
    func nonPrintingKeys() throws {
        let us = try #require(DockKeyboardLayout.layoutData(id: "com.apple.keylayout.US"))
        for code: UInt16 in [36, 53, 123, 124, 51, 48] {
            #expect(DockKeyboardLayout.translate(keyCode: code, shift: false, command: false, layout: us) == nil)
        }
        #expect(!DockKeyboardLayout.isPrintable("\u{1B}"))
        #expect(!DockKeyboardLayout.isPrintable("\u{F700}"))
        #expect(DockKeyboardLayout.isPrintable(" "))
        #expect(DockKeyboardLayout.isPrintable("é"))
    }

    @Test("with no layout readable the US table still spells")
    func fallback() {
        let keyboard = DockKeyboardLayout()
        keyboard.set(layout: nil)
        #expect(keyboard.character(for: 0) == "a")
        #expect(keyboard.character(for: 0, shift: true) == "A")
        #expect(keyboard.character(for: 123) == nil)
    }

    /// nil from `handle` is an eaten event.
    private func eaten(_ tap: SwitcherKeyTap, _ code: CGKeyCode, flags: CGEventFlags = []) throws -> Bool {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
        event.flags = flags
        return tap.handle(type: .keyDown, event: event)?.takeRetainedValue() == nil
    }

    @Test("an open strip eats every key — nothing typed while switching reaches the app")
    func openStripEatsEverything() throws {
        let tap = SwitcherKeyTap()
        tap.keyboard = DockKeyboardLayout()
        #expect(try !eaten(tap, 96), "closed: F5 passes through")
        tap.setOpen(true)
        #expect(try eaten(tap, 96), "open: a function key is the strip's")
        #expect(try eaten(tap, 126, flags: .maskAlternate), "⌥↑ no longer leaks")
        #expect(try eaten(tap, 0, flags: .maskControl), "a control chord neither")
        #expect(try eaten(tap, 0), "a letter types into the filter")
        tap.setOpen(false)
        #expect(try !eaten(tap, 0), "closing hands the keyboard back")
    }

    @Test("hover selects only once the pointer has moved since the strip opened")
    func hoverGate() {
        var gate = SwitcherHoverGate()
        gate.open(at: CGPoint(x: 100, y: 100))
        let jitter = gate.allows(CGPoint(x: 101, y: 100))
        #expect(!jitter, "a pointer resting under the strip keeps the pick")
        let moved = gate.allows(CGPoint(x: 140, y: 100))
        #expect(moved)
        let back = gate.allows(CGPoint(x: 100, y: 100))
        #expect(back, "once moved, every card entered selects")
        gate.open(at: CGPoint(x: 0, y: 0))
        let reopened = gate.allows(CGPoint(x: 1, y: 1))
        #expect(!reopened, "a new open re-arms the gate")
    }
}
