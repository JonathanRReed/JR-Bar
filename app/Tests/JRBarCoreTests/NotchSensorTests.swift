import Foundation
import Testing
@testable import JRBarCore

/// The island's privacy dots as layout facts: `NotchSensorState` is
/// the reading, `idleLayout`/`idleContentWidth` decide where the dots
/// live and how wide they make the resting island.
@Suite("Notch sensor indicators")
struct NotchSensorTests {
    @Test("a quiet machine draws nothing")
    func quiet() {
        let s = NotchSensorState()
        #expect(!s.anyInUse)
        #expect(s.dotCount == 0)
        #expect(NotchIsland.idleLayout(NotchIslandSummary(), media: nil,
                                       earsDrawn: false, sensors: s) == NotchIdleLayout())
    }

    @Test("each live sensor earns a dot")
    func counts() {
        #expect(NotchSensorState(microphoneInUse: true).dotCount == 1)
        #expect(NotchSensorState(cameraInUse: true).dotCount == 1)
        #expect(NotchSensorState(microphoneInUse: true, cameraInUse: true).dotCount == 2)
    }

    @Test("the dots share the right shoulder, hugging the notch")
    func rightShoulder() {
        // Sensors alone: the right shoulder is theirs.
        let mic = NotchSensorState(microphoneInUse: true)
        var layout = NotchIsland.idleLayout(NotchIslandSummary(), media: nil,
                                            earsDrawn: false, sensors: mic)
        #expect(layout.sensors == mic)
        #expect(layout.right == .nothing)
        #expect(layout.rightWidth == 5, "one 5 pt dot")
        #expect(layout.rightShoulder == 5 + 2 * NotchIslandLayout.shoulderPad)
        // Both dots, side by side at the provider dots' rhythm.
        let both = NotchSensorState(microphoneInUse: true, cameraInUse: true)
        layout = NotchIsland.idleLayout(NotchIslandSummary(), media: nil,
                                        earsDrawn: false, sensors: both)
        #expect(layout.rightWidth == 14, "two dots, one gap")
        // Attention moves over rather than hide them.
        var s = NotchIslandSummary()
        s.waiting = 3
        layout = NotchIsland.idleLayout(s, media: nil, earsDrawn: false, sensors: mic)
        #expect(layout.right == .attention(count: 3))
        #expect(layout.rightWidth == 5 + NotchIsland.sensorSeparatorWidth + 22,
                "mic dot, separator, then the amber dot and count")
        // Media too.
        layout = NotchIsland.idleLayout(NotchIslandSummary(),
                                        media: AlcoveMedia(title: "Papillon", playing: true),
                                        earsDrawn: false, sensors: mic)
        #expect(layout.right == .media)
        #expect(layout.rightWidth == 5 + NotchIsland.sensorSeparatorWidth + NotchIsland.mediaContentWidth)
    }

    @Test("the Screen Bar's ears suppress the dots with everything else")
    func bare() {
        let live = NotchSensorState(microphoneInUse: true, cameraInUse: true)
        let layout = NotchIsland.idleLayout(NotchIslandSummary(), media: nil,
                                            earsDrawn: true, sensors: live)
        #expect(layout.bare)
        #expect(layout.sensors == NotchSensorState())
        #expect(layout.rightWidth == 0)
    }

    @Test("the floating pill pays the dots their width")
    func contentWidth() {
        let empty = NotchIsland.idleContentWidth(NotchIslandSummary())
        #expect(empty == 4)
        let mic = NotchSensorState(microphoneInUse: true)
        #expect(NotchIsland.idleContentWidth(NotchIslandSummary(), media: nil, sensors: mic)
                == empty + NotchIsland.sensorSeparatorWidth + 5)
        let both = NotchSensorState(microphoneInUse: true, cameraInUse: true)
        #expect(NotchIsland.idleContentWidth(NotchIslandSummary(), media: nil, sensors: both)
                == empty + NotchIsland.sensorSeparatorWidth + 14)
    }
}
