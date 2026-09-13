import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Screen Recording permission facts. Preflight never prompts; Request
/// may, so it only runs from a button.
enum FoldCapturePermission {
    static var granted: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

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

/// Grabs the built-in display at 30 fps and pushes the newest frame to
/// the renderer. The capture is capped at 2560 px on the long edge —
/// the fold defocuses the picture anyway, and a full-Retina stream costs
/// quadruple the memory bandwidth for nothing anyone can see. No audio,
/// no cursor (cursor motion would mint frames nobody asked for), and
/// JR-Bar itself is excluded so the warped desktop can never feed back
/// into itself. Created and started lazily: at rest nothing runs.
@MainActor
final class FoldCapture {
    private let sink = Sink()
    private var stream: SCStream?
    /// Set by `stop` while `start` is still suspended inside an await —
    /// the start re-checks it before keeping the stream it just opened,
    /// so a pause can't orphan a live capture on a dropped FoldCapture.
    private var stopRequested = false
    /// Called once per accepted frame so the overlay can push + redraw.
    var onFrame: (@MainActor (CVPixelBuffer) -> Void)?
    /// True once at least one complete frame has been delivered.
    private(set) var hasFrame = false

    init() {
        sink.onFrame = { [weak self] buffer in
            let box = FrameBox(buffer)
            Task { @MainActor [weak self] in
                self?.hasFrame = true
                self?.onFrame?(box.buffer)
            }
        }
    }

    /// Starts capturing the built-in display, keeping JR-Bar's own
    /// windows (the overlay included) out of the frame. Safe to call
    /// again while running.
    func start() async throws {
        guard stream == nil else { return }
        stopRequested = false
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard !stopRequested else { return }
        guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }),
              let ownApp = content.applications.first(where: {
                  $0.processID == ProcessInfo.processInfo.processIdentifier })
        else { throw FoldCaptureError.noBuiltinDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [ownApp], exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = min(1, 2560.0 / Double(max(display.width, display.height)))
        config.width = max(2, Int(Double(display.width) * scale))
        config.height = max(2, Int(Double(display.height) * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(sink, type: .screen,
                                 sampleHandlerQueue: DispatchQueue(label: "jrbar.fold.capture"))
        try await stream.startCapture()
        if stopRequested {
            // A stop landed while start was suspended: close what just
            // opened instead of storing it where nobody can reach it.
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
    }

    func stop() async {
        stopRequested = true
        let stream = stream
        self.stream = nil
        hasFrame = false
        if let stream { try? await stream.stopCapture() }
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
/// complete one; a partial frame would tear under the projection.
private final class Sink: NSObject, SCStreamOutput, @unchecked Sendable {
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?

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
}
