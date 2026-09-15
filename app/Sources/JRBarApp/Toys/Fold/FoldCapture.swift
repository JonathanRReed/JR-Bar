import AppKit
import CoreMedia
import CoreVideo
import OSLog
import QuartzCore
import ScreenCaptureKit

/// Screen Recording permission facts. `CGPreflightScreenCaptureAccess`
/// is a TCCAccessRequest round-trip, and readers on the card's render
/// path — the status chip, the fold-detail row, the armed gate — were
/// asking it every observation pass: ~125 calls a second in `log show`
/// while the sensor polls. So the answer is cached: a read older than
/// `recheckAfter` re-asks TCC, `request` caches the answer it just got,
/// and `invalidate` drops the cache — the toy calls that when a capture
/// dies (a revoked grant is one way streams fail) and on re-activate,
/// the moment a granted permission actually lands.
@MainActor
enum FoldCapturePermission {
    /// How long a cached preflight stays fresh.
    static let recheckAfter: TimeInterval = 30
    private static var cached = false
    private static var checkedAt: TimeInterval = -.infinity

    /// The cached grant — never a TCC call more often than
    /// `recheckAfter`, so it is safe to read on the per-frame path.
    static var granted: Bool {
        if CACurrentMediaTime() - checkedAt < recheckAfter { return cached }
        return recheck()
    }

    /// Asks TCC now and caches the answer — the one place the preflight
    /// runs. The setup walkthrough's probe uses this so a refresh
    /// reports the truth, not whatever the cache happens to hold.
    @discardableResult
    static func recheck() -> Bool {
        cached = CGPreflightScreenCaptureAccess()
        checkedAt = CACurrentMediaTime()
        return cached
    }

    /// Drops the cache so the next `granted` read asks TCC again.
    static func invalidate() { checkedAt = -.infinity }

    /// Request may prompt, so it only runs from a button — and it
    /// caches the answer it just got, so the card flips at once.
    @discardableResult
    static func request() -> Bool {
        cached = CGRequestScreenCaptureAccess()
        checkedAt = CACurrentMediaTime()
        return cached
    }

    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}

enum FoldCaptureError: LocalizedError {
    case noBuiltinDisplay

    var errorDescription: String? {
        switch self {
        case .noBuiltinDisplay: return "no built-in display to capture"
        }
    }
}

/// The Portal fold's two ScreenCaptureKit streams on the built-in
/// display (`CGDisplayIsBuiltin`):
///
/// - **full** — the desktop as it is, minus JR-Bar itself: the source
///   the window cards are cut from and the Reduce-Motion fallback.
/// - **far** — the room's back wall: the display with every
///   application's windows excluded, so the wallpaper (and any
///   unowned system surface) is what shows behind the cards.
///
/// Both run at 60 fps, BGRA sRGB, no audio, no cursor (cursor motion
/// would mint frames nobody asked for), complete frames only, capped at
/// 2560 px on the long edge — the fold defocuses the picture anyway.
/// A timer polls the on-screen window list into `PortalDepth` cards at
/// 4 Hz; the card layout only changes when a window does.
///
/// Lifecycle belongs to `FoldArming`: `FoldToy` starts this object when
/// the lid enters the arming band and stops it on cooldown expiry or a
/// full close, so the Screen Recording indicator only shows while a
/// fold can actually be on screen.
@MainActor
final class FoldCapture {
    private let fullSink = Sink()
    private let farSink = Sink()
    private var fullStream: SCStream?
    private var farStream: SCStream?
    /// Set by `stop` while `start` is still suspended inside an await —
    /// the start re-checks it before keeping the streams it just opened,
    /// so a pause can't orphan a live capture on a dropped FoldCapture.
    private var stopRequested = false
    /// Called once per accepted full-frame so the overlay can push + redraw.
    var onFullFrame: (@MainActor (CVPixelBuffer) -> Void)?
    /// Called once per accepted far-wall frame.
    var onFarFrame: (@MainActor (CVPixelBuffer) -> Void)?
    /// Called when the card layout changes — windows open, close, move
    /// or reorder. Never per frame: the rects only matter while frames
    /// flow, and unchanged layouts don't re-emit.
    var onCards: (@MainActor ([PortalDepth.Card]) -> Void)?
    /// Called when the full stream dies on its own — SCK reports a
    /// stopped stream through its delegate, and without one a dead
    /// capture is silent: frames simply stop arriving with `hasFrame`
    /// left true. A dead far stream only logs; the full texture stands
    /// in as the far wall until the next start.
    var onError: (@MainActor (String) -> Void)?
    /// True once the full stream has delivered a complete frame — the
    /// overlay's gate.
    private(set) var hasFrame = false
    /// True once the far wall has delivered — until then the renderer
    /// stands the full texture in for it.
    private(set) var hasFarFrame = false
    /// The last stream-death reason, for the card's diagnostic line.
    private(set) var lastError: String?

    /// The window-layout poll: windows move rarely, and the poll is a
    /// sub-millisecond CGWindowList read.
    private var layoutTimer: Timer?
    /// The built-in display's Quartz frame (points, top-left origin) —
    /// the space `CGWindowListCopyWindowInfo` reports bounds in.
    private var displayFrameQuartz = CGRect.zero
    private var displayID: CGDirectDisplayID = 0
    private var lastCardRects: [CGRect] = []

    init() {
        fullSink.onFrame = { [weak self] buffer in
            let box = FrameBox(buffer)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.hasFrame {
                    FoldLog.log.notice("capture: first full frame delivered")
                }
                self.hasFrame = true
                self.onFullFrame?(box.buffer)
            }
        }
        fullSink.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                FoldLog.log.error("capture: full stream stopped: \(message, privacy: .public)")
                self?.lastError = message
                self?.onError?(message)
            }
        }
        farSink.onFrame = { [weak self] buffer in
            let box = FrameBox(buffer)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.hasFarFrame {
                    FoldLog.log.notice("capture: first far-wall frame delivered")
                }
                self.hasFarFrame = true
                self.onFarFrame?(box.buffer)
            }
        }
        farSink.onError = { message in
            Task { @MainActor in
                FoldLog.log.error("capture: far stream stopped: \(message, privacy: .public)")
            }
        }
    }

    /// Starts both streams. Safe to call again while running.
    func start() async throws {
        guard fullStream == nil else { return }
        stopRequested = false
        lastError = nil
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard !stopRequested else { return }
        guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }),
              let ownApp = content.applications.first(where: {
                  $0.processID == ProcessInfo.processInfo.processIdentifier })
        else { throw FoldCaptureError.noBuiltinDisplay }
        displayID = display.displayID
        displayFrameQuartz = CGDisplayBounds(display.displayID)

        let config = SCStreamConfiguration()
        let scale = min(1, 2560.0 / Double(max(display.width, display.height)))
        config.width = max(2, Int(Double(display.width) * scale))
        config.height = max(2, Int(Double(display.height) * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 4
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB

        // The room's two walls: everything minus ourselves, and the far
        // wall — the display with every application's windows excluded,
        // which is the wallpaper and any unowned system surface.
        let fullFilter = SCContentFilter(
            display: display, excludingApplications: [ownApp], exceptingWindows: [])
        let farFilter = SCContentFilter(
            display: display, excludingApplications: content.applications,
            exceptingWindows: [])
        let outputQueue = DispatchQueue(label: "jrbar.fold.capture")
        let full = SCStream(filter: fullFilter, configuration: config, delegate: fullSink)
        try full.addStreamOutput(fullSink, type: .screen, sampleHandlerQueue: outputQueue)
        let far = SCStream(filter: farFilter, configuration: config, delegate: farSink)
        try far.addStreamOutput(farSink, type: .screen, sampleHandlerQueue: outputQueue)
        try await full.startCapture()
        do {
            try await far.startCapture()
        } catch {
            // The far wall is the nice-to-have half: if its stream
            // refuses (some systems balk at an empty application set)
            // the full texture stands in and the fold still runs.
            FoldLog.log.error("capture: far stream failed, using full as far wall: \(error.localizedDescription, privacy: .public)")
        }
        FoldLog.log.notice("capture: streams started (60fps, dual)")
        if stopRequested {
            // A stop landed while start was suspended: close what just
            // opened instead of storing it where nobody can reach it.
            try? await full.stopCapture()
            try? await far.stopCapture()
            return
        }
        fullStream = full
        farStream = far
        startLayoutPolling()
    }

    func stop() async {
        stopRequested = true
        layoutTimer?.invalidate()
        layoutTimer = nil
        let full = fullStream, far = farStream
        fullStream = nil
        farStream = nil
        hasFrame = false
        hasFarFrame = false
        lastCardRects = []
        if let full { try? await full.stopCapture() }
        if let far { try? await far.stopCapture() }
    }

    // MARK: Window cards

    /// Polls the on-screen window list on the main actor — a
    /// sub-millisecond CGWindowList read — and emits only on change.
    private func startLayoutPolling() {
        pollWindowLayout()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollWindowLayout() }
        }
        RunLoop.main.add(timer, forMode: .common)
        layoutTimer = timer
    }

    private func pollWindowLayout() {
        let frame = displayFrameQuartz
        guard frame.width > 0 else { return }
        let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        var infos: [PortalDepth.WindowInfo] = []
        infos.reserveCapacity(min(entries.count, 24))
        for entry in entries {
            guard let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            infos.append(PortalDepth.WindowInfo(
                rect: rect,
                layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                ownerPID: Int32(entry[kCGWindowOwnerPID as String] as? Int ?? 0),
                alpha: entry[kCGWindowAlpha as String] as? Double ?? 1))
        }
        let rects = PortalDepth.cardRects(
            from: infos, displayFrame: frame,
            ownPID: ProcessInfo.processInfo.processIdentifier)
        guard rects != lastCardRects else { return }
        lastCardRects = rects
        onCards?(PortalDepth.cards(for: rects))
    }
}

/// A pixel buffer crossing the capture queue → main actor boundary.
/// CoreVideo buffers are reference-counted and safe to read from any
/// thread once retained; the wrapper just tells Swift that.
private struct FrameBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

/// Receives frames on the stream's own queue and keeps only the newest
/// complete one; a partial frame would tear under the projection. It is
/// also the stream's delegate, because the only place SCK reports a dead
/// stream is `didStopWithError` — a nil delegate makes a silent capture.
private final class Sink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(image)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onError?(error.localizedDescription)
    }
}
