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
        return tap.handle(type: .keyDown, event: event)?.takeUnretainedValue() == nil
    }

    @Test("a passed event goes back at +0 — the tap keeps nothing of the keys it lets through")
    func passesWithoutRetaining() throws {
        let tap = SwitcherKeyTap()
        tap.keyboard = DockKeyboardLayout()
        let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 96, keyDown: true))
        let click = try #require(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
                                         mouseCursorPosition: CGPoint(x: 10, y: 10), mouseButton: .right))
        let keyCount = CFGetRetainCount(key), clickCount = CFGetRetainCount(click)
        for _ in 0..<50 {
            #expect(tap.handle(type: .keyDown, event: key) != nil)
            #expect(tap.handle(type: .flagsChanged, event: key) != nil)
            #expect(tap.handle(type: .rightMouseDown, event: click) != nil)
        }
        #expect(CFGetRetainCount(key) == keyCount, "a retain per pass-through was a leaked event per key")
        #expect(CFGetRetainCount(click) == clickCount)
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

    /// A modifier change as the tap sees it — `flags` is what is still held.
    private func modifiers(_ tap: SwitcherKeyTap, _ flags: CGEventFlags) throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 58, keyDown: true))
        event.flags = flags
        #expect(tap.handle(type: .flagsChanged, event: event) != nil, "a modifier change is never eaten")
    }

    /// Every block the tap has handed main so far has run — the queue is
    /// FIFO, so a block enqueued behind them runs last.
    private func drainMain() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    @Test("a quick ⌥⇥ or ⌘⇥ commits even when its release reaches the tap before the open does")
    func releaseBeforeOpen() async throws {
        let tap = SwitcherKeyTap()
        tap.keyboard = DockKeyboardLayout()
        var calls: [String] = []
        tap.onTab = { _ in calls.append("tab") }
        tap.onCommit = { calls.append("commit") }
        tap.onCmdTab = { _ in calls.append("cmdTab") }
        tap.onCmdCommit = { calls.append("cmdCommit") }

        // Main never gets as far as `setOpen`: the strip is still being
        // built when option lifts.
        try modifiers(tap, [])
        #expect(try eaten(tap, 48, flags: .maskAlternate))
        try modifiers(tap, [])
        try modifiers(tap, [.maskShift])
        await drainMain()
        #expect(calls == ["tab", "commit"], "an unarmed change commits nothing; the arm fires once, after the open")

        calls = []
        tap.setCmdEnabled(true)
        #expect(try eaten(tap, 48, flags: .maskCommand))
        try modifiers(tap, [])
        await drainMain()
        #expect(calls == ["cmdTab", "cmdCommit"])

        // ⌘⇥ under a held ⌥⇥ takes the strip over: option lifting first
        // is no longer a commit, command's release is.
        calls = []
        #expect(try eaten(tap, 48, flags: .maskAlternate))
        #expect(try eaten(tap, 48, flags: [.maskAlternate, .maskCommand]))
        try modifiers(tap, .maskCommand)
        try modifiers(tap, [])
        await drainMain()
        #expect(calls == ["tab", "cmdTab", "cmdCommit"])

        // An open strip with no arm still commits on option's release.
        calls = []
        tap.setOpen(true)
        try modifiers(tap, .maskAlternate)
        try modifiers(tap, [])
        await drainMain()
        #expect(calls == ["commit"])
        tap.setOpen(false)
    }

    @Test("⌘/ pins the ⌘⇥ strip for typing; closing it forgets the latch")
    func searchLatch() throws {
        let tap = SwitcherKeyTap()
        let keyboard = DockKeyboardLayout()
        keyboard.set(layout: DockKeyboardLayout.layoutData(id: "com.apple.keylayout.US"))
        tap.keyboard = keyboard
        tap.setCmdOpen(true)
        #expect(try eaten(tap, 44, flags: .maskCommand))
        #expect(tap.isLatched, "set on the tap thread, before ⌘'s release can race it")
        tap.setCmdOpen(false)
        #expect(!tap.isLatched)
        // The ⌥⇥ strip has no latch — ⌘/ there is just eaten.
        tap.setOpen(true)
        #expect(try eaten(tap, 44, flags: .maskCommand))
        #expect(!tap.isLatched)
        tap.setOpen(false)
    }

    @Test("⌥⌘ arrows and ↑ are the strip's; the verb row names what ⌘ does now")
    func arrowsAndHints() throws {
        let tap = SwitcherKeyTap()
        tap.keyboard = DockKeyboardLayout()
        tap.setOpen(true)
        #expect(try eaten(tap, 123, flags: [.maskAlternate, .maskCommand]))
        #expect(try eaten(tap, 126))
        tap.setOpen(false)
        #expect(try !eaten(tap, 126), "closed, ↑ belongs to the front app")
        #expect(DockSwitcherList.verbHints(appMode: true, drilled: false).contains("/ search"))
        #expect(DockSwitcherList.verbHints(appMode: false, drilled: true).contains("↑ apps"))
        #expect(DockSwitcherList.verbHints(appMode: false, drilled: false).contains("tile"))
    }

    @Test("a ⌘-right-click on a quick-quit tile is eaten, down and up; every other right click passes")
    func quickQuitClick() throws {
        let tap = SwitcherKeyTap()
        func click(_ type: CGEventType, at point: CGPoint, command: Bool) throws -> Bool {
            let event = try #require(CGEvent(mouseEventSource: nil, mouseType: type,
                                             mouseCursorPosition: point, mouseButton: .right))
            event.flags = command ? .maskCommand : []
            return tap.handle(type: type, event: event)?.takeUnretainedValue() == nil
        }
        // Two app tiles on a bottom Dock whose list spans 400–1040 × 1110–1170.
        let tiles = [CGRect(x: 420, y: 1112, width: 56, height: 56),
                     CGRect(x: 480, y: 1112, width: 56, height: 56)]
        let inside = CGPoint(x: 500, y: 1140), outside = CGPoint(x: 500, y: 300)
        #expect(try !click(.rightMouseDown, at: inside, command: true), "no tiles mirrored: nothing eaten")
        tap.setQuickQuitTargets(tiles)
        #expect(try click(.rightMouseDown, at: inside, command: true))
        #expect(try click(.rightMouseUp, at: inside, command: true), "its up edge goes with it")
        #expect(try !click(.rightMouseUp, at: inside, command: true), "…once")
        #expect(try !click(.rightMouseDown, at: inside, command: false), "a plain right click is the Dock's menu")
        #expect(try !click(.rightMouseDown, at: outside, command: true), "outside the Dock, ⌘-right-click is the app's")
        #expect(try !click(.rightMouseDown, at: CGPoint(x: 500, y: 1062), command: true),
                "50 pt above the list is a window's own click, not the Dock's")
        #expect(try !click(.rightMouseDown, at: CGPoint(x: 900, y: 1140), command: true),
                "a folder, the Trash or a separator keeps its click")
        tap.setQuickQuitTargets([])
        #expect(try !click(.rightMouseDown, at: inside, command: true), "the watcher stopping clears them")
    }

    @Test("quick quit's targets are running apps' tiles — never a folder, a pinned app at rest, or JR-Bar")
    func quickQuitTargets() {
        let a = CGRect(x: 0, y: 0, width: 50, height: 50), b = CGRect(x: 60, y: 0, width: 50, height: 50)
        let c = CGRect(x: 120, y: 0, width: 50, height: 50), d = CGRect(x: 180, y: 0, width: 50, height: 50)
        let e = CGRect(x: 240, y: 0, width: 50, height: 50)
        let own = Bundle.main.bundleIdentifier
        let targets = DockEnhanceController.quickQuitTargets([
            (a, .app, "com.apple.Safari"),
            (b, .app, "com.example.pinned"),
            (c, .folder, nil),
            (d, .minimizedWindow, "com.apple.Safari"),
            (e, .app, own),
        ], running: Set(["com.apple.Safari", "com.example.other"] + [own].compactMap { $0 }))
        #expect(targets == [a])
    }

    @Test("the preview's action keys are eaten only while it asked for them")
    func previewActionKeys() throws {
        let tap = SwitcherKeyTap()
        let keyboard = DockKeyboardLayout()
        keyboard.set(layout: DockKeyboardLayout.layoutData(id: "com.apple.keylayout.US"))
        tap.keyboard = keyboard
        tap.setPreviewOpen(true)
        #expect(try !eaten(tap, 13), "no card walked: W types into the front app")
        tap.setPreviewChars(DockEnhanceController.previewChars(walked: true, media: false, pointerInPanel: false))
        #expect(try eaten(tap, 13), "a walked card: W closes it")
        #expect(try eaten(tap, 123, flags: .maskAlternate), "⌥← tiles it")
        #expect(try !eaten(tap, 49), "Space is only the player's, with the pointer on it")
        #expect(try !eaten(tap, 13, flags: .maskCommand), "⌘W is never the preview's")
        tap.setPreviewChars(DockEnhanceController.previewChars(walked: false, media: true, pointerInPanel: true))
        #expect(try eaten(tap, 49))
        #expect(try !eaten(tap, 13))
        tap.setPreviewOpen(false)
        #expect(try !eaten(tap, 49), "a closed preview owns nothing")
    }

    @Test("a modified arrow or Esc passes through the open preview — ⇧→ still selects in the front app")
    func previewPassesModifiedKeys() throws {
        let tap = SwitcherKeyTap()
        tap.keyboard = DockKeyboardLayout()
        tap.setPreviewOpen(true)
        #expect(try eaten(tap, 124), "a bare → walks the cards")
        #expect(try !eaten(tap, 124, flags: .maskShift), "⇧→ extends the selection")
        #expect(try !eaten(tap, 123, flags: .maskCommand), "⌘← goes to the line's start")
        #expect(try !eaten(tap, 124, flags: .maskControl))
        #expect(try !eaten(tap, 124, flags: .maskAlternate), "no card walked: ⌥→ jumps a word")
        #expect(try !eaten(tap, 53, flags: .maskShift))
        #expect(try eaten(tap, 124, flags: .maskSecondaryFn),
                "an arrow's own fn bit is not a modifier")
        tap.setPreviewChars(DockEnhanceController.previewChars(walked: true, media: false, pointerInPanel: false))
        #expect(try eaten(tap, 124, flags: .maskAlternate), "a walked card: ⌥→ tiles it")
        #expect(try !eaten(tap, 124, flags: [.maskAlternate, .maskShift]), "⇧⌥→ still selects a word")
        #expect(try !eaten(tap, 124, flags: .maskShift))
        #expect(try eaten(tap, 76), "keypad Enter raises the walked card")
        tap.setPreviewOpen(false)
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

    @Test("⌥` previews the front app only when opted in, never under a strip or with ⌘")
    func frontAppChord() async throws {
        let tap = SwitcherKeyTap()
        tap.keyboard = DockKeyboardLayout()
        var fired = 0
        tap.onFrontPreview = { fired += 1 }
        #expect(try !eaten(tap, 50, flags: .maskAlternate), "off: ⌥` stays the accent key")
        tap.setFrontEnabled(true)
        #expect(try eaten(tap, 50, flags: .maskAlternate))
        #expect(try !eaten(tap, 50, flags: [.maskAlternate, .maskCommand]), "⌥⌘` is someone else's")
        #expect(try !eaten(tap, 50, flags: [.maskAlternate, .maskShift]))
        #expect(try !eaten(tap, 50), "a bare ` types")
        // The eaten chord hops to the main queue; wait for the hop (as
        // long as a loaded machine needs), not a fixed beat.
        for _ in 0..<500 where fired == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(fired == 1, "the one eaten chord reached the watcher")
    }

    @Test("⌥` finds the front app's tile by bundle, else by name, and walks to its next window")
    func frontAppTile() {
        let tiles: [(url: URL?, title: String?, isApp: Bool)] = [
            (URL(fileURLWithPath: "/Users/me/Downloads/"), "Downloads", false),
            (URL(string: "file:///Applications/Ghostty.app/"), "Ghostty", true),
            (nil, "Safari", true),
        ]
        #expect(DockEnhanceMath.frontTileIndex(bundleURL: URL(fileURLWithPath: "/Applications/Ghostty.app"),
                                               name: "Ghostty", tiles: tiles) == 1)
        #expect(DockEnhanceMath.frontTileIndex(bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
                                               name: "Safari", tiles: tiles) == 2, "a tile without a URL matches by name")
        #expect(DockEnhanceMath.frontTileIndex(bundleURL: nil, name: "Downloads", tiles: tiles) == nil,
                "a folder tile is never the front app")
        func card(_ id: Int, _ minimized: Bool = false) -> DockPreviewWindow {
            DockPreviewWindow(id: id, title: "w", minimized: minimized, fullScreen: nil, frame: nil,
                              thumbnail: nil, element: nil)
        }
        #expect(DockEnhanceMath.frontWalkStart([card(1), card(2), card(3)]) == 2, "the next window, like ⌥⇥")
        #expect(DockEnhanceMath.frontWalkStart([card(1), card(2, true)]) == 1)
        #expect(DockEnhanceMath.frontWalkStart([card(4, true)]) == 4)
        #expect(DockEnhanceMath.frontWalkStart([]) == nil)
    }
}

