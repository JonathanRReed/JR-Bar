import CoreGraphics
import Foundation
import Testing
@testable import JRBarApp

/// The fold's session facts: read once at launch from the window
/// server's session dictionary, then kept by notifications. A dictionary
/// that says nothing must never bench the fold.
@Suite("Fold session state")
struct FoldSessionTests {
    @Test("an empty session dictionary reads as unlocked and on console")
    func emptyIsClear() {
        let state = FoldSessionState.parse([:])
        #expect(state.locked == false)
        #expect(state.onConsole == true)
    }

    @Test("the lock and console keys are read as booleans or numbers")
    func readsLockAndConsole() {
        let locked = FoldSessionState.parse([
            "CGSSessionScreenIsLocked": true,
            kCGSessionOnConsoleKey as String: true,
        ])
        #expect(locked.locked == true)
        #expect(locked.onConsole == true)
        let away = FoldSessionState.parse([
            "CGSSessionScreenIsLocked": NSNumber(value: 0),
            kCGSessionOnConsoleKey as String: NSNumber(value: 0),
        ])
        #expect(away.locked == false)
        #expect(away.onConsole == false)
    }

    @Test("the card's lid glyph opens from the hinge: shut, upright, leaning back")
    func lidGlyph() {
        let hinge = CGPoint(x: 10, y: 20)
        let shut = FoldLidGlyph.lidEnd(hinge: hinge, length: 10, degrees: 0)
        #expect(abs(shut.x - 20) < 1e-9 && abs(shut.y - 20) < 1e-9, "shut lies on the deck")
        let upright = FoldLidGlyph.lidEnd(hinge: hinge, length: 10, degrees: 90)
        #expect(abs(upright.x - 10) < 1e-9 && abs(upright.y - 10) < 1e-9)
        let back = FoldLidGlyph.lidEnd(hinge: hinge, length: 10, degrees: 135)
        #expect(back.x < hinge.x && back.y < hinge.y, "past upright it leans back")
        #expect(FoldLidGlyph.lidEnd(hinge: hinge, length: 10, degrees: 400)
                == FoldLidGlyph.lidEnd(hinge: hinge, length: 10, degrees: 180))
    }

    @Test("a mistyped key falls back to the clear reading")
    func mistypedFallsBack() {
        let state = FoldSessionState.parse([
            "CGSSessionScreenIsLocked": "yes",
            kCGSessionOnConsoleKey as String: "no",
        ])
        #expect(state.locked == false)
        #expect(state.onConsole == true)
    }
}
