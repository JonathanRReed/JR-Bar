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
        var onFarFrameInvalidated: (@MainActor () -> Void)?
        var onCards: (@MainActor ([PortalDepth.Card]) -> Void)?
        var onError: (@MainActor (String) -> Void)?
        func start() async throws {}
        func stop() async {}
    }

    @Test func copiedCallbacksCannotAffectReplacementOrRetiredDisplay() throws {
        let old = Source(), replacement = Source()
        @Captured var owner: Source? = old
        var display = 1
        var calls: [String] = []
        FoldCaptureCallbacks.install(on: old,
            isCurrent: { owner === old && display == 1 },
            full: { _ in calls.append("full") }, far: { _ in calls.append("far") },
            farInvalidated: {}, cards: { _ in calls.append("cards") }, failed: { _ in calls.append("error") })
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
        #expect(old.onFarFrameInvalidated == nil)
        #expect(old.onCards == nil)
        #expect(old.onError == nil)
    }

    @Test func farInvalidationChecksOwnershipAndRetiresCopiedFrames() throws {
        let source = Source(), replacement = Source()
        @Captured var owner: Source? = source
        var display = 1
        var calls: [String] = []
        FoldCaptureCallbacks.install(on: source,
            isCurrent: { owner === source && display == 1 },
            full: { _ in calls.append("full") }, far: { _ in calls.append("far") },
            farInvalidated: { calls.append("invalidate") }, cards: { _ in }, failed: { _ in })
        let farCallback = try #require(source.onFarFrame)
        let invalidation = try #require(source.onFarFrameInvalidated)
        let fullCallback = try #require(source.onFullFrame)
        var created: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2,
            kCVPixelFormatType_32BGRA, nil, &created) == kCVReturnSuccess)
        let frame = try #require(created)
        owner = replacement
        invalidation()
        #expect(calls.isEmpty)
        owner = source
        display = 2
        invalidation()
        #expect(calls.isEmpty)
        display = 1
        farCallback(frame)
        invalidation()
        farCallback(frame)
        invalidation()
        fullCallback(frame)
        #expect(calls == ["far", "invalidate", "full"])
        owner = nil
        FoldCaptureCallbacks.detach(from: source)
        invalidation()
        #expect(calls == ["far", "invalidate", "full"])
        #expect(source.onFarFrameInvalidated == nil)
    }
}
