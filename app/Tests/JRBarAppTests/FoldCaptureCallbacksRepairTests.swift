import CoreVideo
import Testing
@testable import JRBarApp

@Suite("Fold callback ownership", .serialized)
@MainActor
struct FoldCaptureCallbacksRepairTests {
    private final class Source: FoldFrameSource {
        var hasFrame = false
        var lastError: String?
        var onFullFrame: (@MainActor (CVPixelBuffer) -> Void)?
        var onFarFrame: (@MainActor (CVPixelBuffer) -> Void)?
        var onCards: (@MainActor ([PortalDepth.Card]) -> Void)?
        var onError: (@MainActor (String) -> Void)?
        func start() async throws {}
        func stop() async {}
    }

    @Test func copiedCallbacksCannotAffectReplacementOrRetiredDisplay() throws {
        let old = Source(), replacement = Source()
        var owner: Source? = old
        var display = 1
        var calls: [String] = []
        FoldCaptureCallbacks.install(on: old,
            isCurrent: { owner === old && display == 1 },
            full: { _ in calls.append("full") }, far: { _ in calls.append("far") },
            cards: { _ in calls.append("cards") }, failed: { _ in calls.append("error") })
        let full = try #require(old.onFullFrame), far = try #require(old.onFarFrame)
        let cards = try #require(old.onCards), error = try #require(old.onError)
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 2, 2,
                                        kCVPixelFormatType_32BGRA, nil, &created)
        #expect(status == kCVReturnSuccess)
        let frame = try #require(created)
        full(frame); far(frame); cards([]); error("current")
        #expect(calls == ["full", "far", "cards", "error"])
        calls.removeAll()
        owner = replacement
        full(frame); far(frame); cards([]); error("old source")
        #expect(calls.isEmpty)
        #expect(owner === replacement)
        owner = old
        display = 2
        full(frame); far(frame); cards([]); error("old display")
        #expect(calls.isEmpty)
        owner = nil
        FoldCaptureCallbacks.detach(from: old)
        full(frame); far(frame); cards([]); error("already queued")
        #expect(calls.isEmpty)
        #expect(old.onFullFrame == nil)
        #expect(old.onFarFrame == nil)
        #expect(old.onCards == nil)
        #expect(old.onError == nil)
    }
}
