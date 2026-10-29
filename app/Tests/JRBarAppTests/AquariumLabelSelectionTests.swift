import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("Aquarium label selection")
struct AquariumLabelSelectionTests {
    @Test("the chip pass reserves the current frontmost nameplate, including fry")
    func currentFrameTarget() {
        let now = Date(timeIntervalSince1970: 100)
        let back = Fish(id: "back", label: "Test fish", providerID: "codex", state: .swimming,
                        lane: 0.5, speed: 0.1, direction: 1, stateSince: now, enteredAt: .distantPast)
        var front = back
        front.id = "front"
        var fry = back
        fry.id = "fry"
        fry.isFry = true
        fry.anchorID = back.id
        let tank = AquariumView(fixture: .init(fish: [back, front, fry]))
        var pose = AquariumView.Layout()
        pose.x = 150
        pose.y = 150
        pose.scale = 1
        let point = CGPoint(x: 150, y: 150)
        var layouts = [back.id: pose, front.id: pose, fry.id: pose]
        #expect(tank.nameplateTarget(in: [back, front], layouts: layouts, point: point, now: now) == front.id)
        // The front fish moved since the last frame. Its old box must not reserve the chip.
        layouts[front.id]?.x = 350
        #expect(tank.nameplateTarget(in: [back, front], layouts: layouts, point: point, now: now) == back.id)
        #expect(tank.nameplateTarget(in: [back, front, fry], layouts: layouts, point: point, now: now) == fry.id)
        #expect(tank.nameplateTarget(in: [back, front], layouts: layouts,
                                     point: CGPoint(x: 700, y: 700), now: now) == nil)
    }
}
