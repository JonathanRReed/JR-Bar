import CoreGraphics
import Testing
import JRBarCore
@testable import JRBarApp

/// The stage model's answer for a notice's face: the shape's own travel
/// while a stage carries the drop, and a plain yes or no at rest.
@Suite("Notch notice follows the shape")
@MainActor
struct NotchNoticeFollowsShapeTests {
    private func model() -> NotchStageModel {
        let stage = NotchStageModel(directional: false)
        stage.noticeMorph = NotchMorph(rest: 32, open: 56, restWidth: 185, openWidth: 290)
        return stage
    }

    @Test("at rest the face is there or not, whatever the morph says")
    func atRest() {
        let stage = model()
        #expect(stage.noticeSheet(shown: true) == .settled)
        #expect(stage.noticeSheet(shown: false).opacity == 0)
        let bare = NotchStageModel(directional: false)
        #expect(bare.noticeSheet(shown: true) == .settled, "no morph, nothing to follow")
    }

    @Test("on a stage the opacity is the shape's travel, going down and coming back")
    func followsTheShape() {
        let stage = model()
        var seen: [CGFloat] = []
        for height in stride(from: CGFloat(32), through: 56, by: 4) {
            let width = 185 + (290 - 185) * (height - 32) / 24
            stage.shape = CGRect(x: 0, y: 0, width: width, height: height)
            seen.append(stage.noticeSheet(shown: true).opacity)
        }
        #expect(seen.first == 0 && seen.last == 1)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 })
        // The same shape gives the same face on the way back, shown or not:
        // the face is wherever the shape is.
        stage.shape = CGRect(x: 0, y: 0, width: 240, height: 46)
        #expect(stage.noticeSheet(shown: true) == stage.noticeSheet(shown: false))
    }

    @Test("a tall sliver of the notch's width shows nothing: the sides must be there too")
    func widthCounts() {
        let stage = model()
        stage.shape = CGRect(x: 0, y: 0, width: 185, height: 56)
        #expect(stage.noticeSheet(shown: true).opacity == 0)
    }
}
