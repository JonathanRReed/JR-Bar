import CoreVideo

/// Every callback is checked at delivery, including a closure already copied
/// out of a source before it was detached. Ownership is supplied by the toy;
/// the gate never reads sensors, requests permission, or starts a stream.
@MainActor
enum FoldCaptureCallbacks {
    static func install(on source: any FoldFrameSource,
                        isCurrent: @escaping @MainActor () -> Bool,
                        full: @escaping @MainActor (CVPixelBuffer) -> Void,
                        far: @escaping @MainActor (CVPixelBuffer) -> Void,
                        farInvalidated: @escaping @MainActor () -> Void,
                        cards: @escaping @MainActor ([PortalDepth.Card]) -> Void,
                        failed: @escaping @MainActor (String) -> Void) {
        var farAvailable = true
        source.onFullFrame = { frame in
            guard isCurrent() else { return }
            full(frame)
        }
        source.onFarFrame = { frame in
            guard isCurrent(), farAvailable else { return }
            far(frame)
        }
        source.onFarFrameInvalidated = {
            guard isCurrent(), farAvailable else { return }
            farAvailable = false
            farInvalidated()
        }
        source.onCards = { layout in
            guard isCurrent() else { return }
            cards(layout)
        }
        source.onError = { message in
            guard isCurrent() else { return }
            failed(message)
        }
    }

    static func detach(from source: any FoldFrameSource) {
        source.onFullFrame = nil
        source.onFarFrame = nil
        source.onFarFrameInvalidated = nil
        source.onCards = nil
        source.onError = nil
    }

    static func retire(_ source: (any FoldFrameSource)?, invalidateFar: @MainActor () -> Void) {
        invalidateFar()
        if let source { detach(from: source) }
    }
}
