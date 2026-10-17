import AppKit
import Testing
@testable import JRBarApp

@MainActor
@Suite("Aquarium window restoration")
struct AquariumWindowRestoreTests {
    @Test("a visible sliver cannot strand the tank outside its usable title bar", arguments: [
        NSRect(x: 1430, y: 200, width: 640, height: 400),
        NSRect(x: 200, y: 880, width: 640, height: 400),
        NSRect(x: 200, y: -395, width: 640, height: 400),
    ])
    func unusableOverlap(frame: NSRect) {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let restored = AquariumWindowController.restoreFrame(frame, visibleScreens: [screen])
        #expect(screen.contains(restored))
        #expect(restored.size == frame.size)
    }

    @Test("an unplugged display restores the tank within the remaining usable display")
    func removedDisplay() {
        let saved = NSRect(x: 2100, y: 200, width: 800, height: 500)
        let screen = NSRect(x: 0, y: 40, width: 1440, height: 830)
        let restored = AquariumWindowController.restoreFrame(saved, visibleScreens: [screen])
        #expect(screen.contains(restored))
        #expect(restored.size == saved.size)
    }

    @Test("a smaller replacement screen fits the restored tank")
    func smallerScreen() {
        let screen = NSRect(x: -900, y: 20, width: 600, height: 400)
        let restored = AquariumWindowController.restoreFrame(
            NSRect(x: 2000, y: 0, width: 800, height: 600), visibleScreens: [screen])
        #expect(restored == screen)
    }

    @Test("a saved position on a connected display remains unchanged")
    func existingPosition() {
        let frame = NSRect(x: -200, y: 100, width: 640, height: 400)
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(AquariumWindowController.restoreFrame(frame, visibleScreens: [screen]) == frame)
        #expect(AquariumWindowController.restoreFrame(frame, visibleScreens: []) == frame)
    }

    @Test("restoration chooses the nearest remaining display")
    func nearestDisplay() {
        let near = NSRect(x: -1000, y: 0, width: 900, height: 700)
        let far = NSRect(x: 0, y: 0, width: 1400, height: 900)
        let saved = NSRect(x: -2100, y: 100, width: 640, height: 400)
        #expect(near.contains(AquariumWindowController.restoreFrame(saved, visibleScreens: [far, near])))
    }
}
