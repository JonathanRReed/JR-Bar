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

/// Grabs the built-in display at 30 fps and keeps the newest frame as a
/// `CVPixelBuffer` for the renderer to texture from. No audio, and the
/// overlay window is asked out of the frame — its `sharingType = .none`
/// already hides it from capture, so the warped desktop can never feed
/// back into itself. Created and started lazily: at rest nothing runs.
@MainActor
final class FoldCapture {
    private let sink = Sink()
    private var stream: SCStream?
    /// Called once per delivered frame so the overlay can redraw.
    var onFrame: (@MainActor () -> Void)?

    init() {
        sink.onFrame = { [weak self] in
            Task { @MainActor [weak self] in self?.onFrame?() }
        }
    }

    /// The newest frame, pulled by the draw call.
    nonisolated func latestPixelBuffer() -> CVPixelBuffer? { sink.latest }

    /// Starts capturing `display`, excluding the overlay window when it
    /// is visible to the window server. Safe to call again while running.
    func start(excluding overlay: NSWindow?) async throws {
        guard stream == nil else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) else {
            throw FoldCaptureError.noBuiltinDisplay
        }
        let excluded = content.windows.filter { window in
            guard let overlay else { return false }
            return window.windowID == CGWindowID(truncatingIfNeeded: overlay.windowNumber)
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 4
        config.showsCursor = true
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "jrbar.fold.capture"))
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        let stream = stream
        self.stream = nil
        if let stream { try? await stream.stopCapture() }
    }
}

/// Receives frames on the stream's own queue and keeps only the newest;
/// the renderer pulls it when it draws, so a slow draw never piles up
/// sample buffers.
private final class Sink: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    var onFrame: (@Sendable () -> Void)?

    var latest: CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        buffer = image
        lock.unlock()
        onFrame?()
    }
}
