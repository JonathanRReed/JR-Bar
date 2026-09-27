import Testing
@testable import JRBarApp

@Suite("Fold reports readiness before the displayed angle")
struct FoldReadinessRepairTests {
    @Test(arguments: [true, false])
    func armedWithoutFrameReportsCaptureWaitNotParked(movement: Bool) {
        let detail = FoldReadiness.detail(tilted: 0, movement: movement, activationAngle: 110,
                                           captureStarted: true, hasFrame: false,
                                           hasTexture: false, visible: false)
        #expect(detail == "Waiting for a screen frame")
    }

    @Test func aRestingFoldIsStillParkedWithoutStartingCapture() {
        let detail = FoldReadiness.detail(tilted: 0, movement: true, activationAngle: 110,
                                           captureStarted: false, hasFrame: false,
                                           hasTexture: false, visible: false)
        #expect(detail == "Parked — the next move folds from here")
    }

    @Test func fixedAngleReferenceIsPreserved() {
        let detail = FoldReadiness.detail(tilted: 0, movement: false, activationAngle: 110,
                                           captureStarted: false, hasFrame: false,
                                           hasTexture: false, visible: false)
        #expect(detail == "Parked — close the lid past 110°")
    }

    @Test func framesAndGPUAndVisibilityAreDifferentStages() {
        let gpu = FoldReadiness.detail(tilted: 12, movement: true, activationAngle: 110,
                                        captureStarted: true, hasFrame: true,
                                        hasTexture: false, visible: false)
        #expect(gpu == "Tilted 12° — frames not reaching the GPU")
        let hidden = FoldReadiness.detail(tilted: 12, movement: true, activationAngle: 110,
                                           captureStarted: true, hasFrame: true,
                                           hasTexture: true, visible: false)
        #expect(hidden == "Tilted 12° — overlay hidden")
        let shown = FoldReadiness.detail(tilted: 12, movement: true, activationAngle: 110,
                                          captureStarted: true, hasFrame: true,
                                          hasTexture: true, visible: true)
        #expect(shown == "Holding 12° of tilt")
    }
}
