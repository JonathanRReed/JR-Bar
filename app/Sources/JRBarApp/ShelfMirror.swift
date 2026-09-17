import AppKit
import AVFoundation
import Observation

/// The card's mirror row — boring.notch's Mirror: a live feed from the
/// Mac's own camera, behind the `mirror` setting so the lens never
/// opens without the person turning it on. Consent is asked once, on
/// the toggle; the session lives on a private queue (startRunning can
/// take a second — never on main) and the layer's frames flow through
/// `AVCaptureVideoPreviewLayer`, no frame-by-frame copy.
@MainActor
@Observable
final class ShelfMirrorModel {
    enum State: Equatable {
        /// The setting is off — no session, no camera.
        case off
        /// The session is up and frames are flowing.
        case live
        /// The owner said no (or Screen Time did). The row shows the
        /// way to undo it in Settings.
        case denied
        /// No camera on this Mac, or the input wouldn't attach.
        case unavailable
    }

    private(set) var state: State = .off
    /// The preview's backing view — one instance, the layer keeps the
    /// session across card opens.
    let preview = MirrorPreviewView()

    private let queue = DispatchQueue(label: "devin.jrbar.mirror", qos: .userInitiated)
    /// The session is the queue's object — every touch (build, start,
    /// stop) happens inside `queue.async`. The box is what makes that
    /// honest: `session` sits off the actor entirely, so the queue
    /// closures never borrow main-actor state (`startRunning` can take
    /// a second and must never reach main).
    private final class SessionBox: @unchecked Sendable {
        var session: AVCaptureSession?
    }
    private let box = SessionBox()

    /// The card pins: the setting's vote decides whether the lens
    /// opens or closes. Unpinning always closes it — an open lens with
    /// no visible preview would be the camera-indicator trap.
    func sync(enabled: Bool) {
        if enabled {
            start()
        } else {
            stop()
        }
    }

    /// A consent prompt is already up — pinning in and out while TCC
    /// waits must not stack `requestAccess` calls behind it.
    private var authAsked = false

    private func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            // The toggle on is the explicit action — ask now, once.
            guard !authAsked else { return }
            authAsked = true
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { self.run() } else { self.state = .denied }
                }
            }
        default:
            state = .denied
        }
    }

    private func run() {
        let box = box
        queue.async { [weak self] in
            if box.session == nil {
                let candidate = AVCaptureSession()
                candidate.sessionPreset = .medium
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      candidate.canAddInput(input)
                else {
                    Task { @MainActor in self?.state = .unavailable }
                    return
                }
                candidate.addInput(input)
                box.session = candidate
                Task { @MainActor in self?.preview.attach(candidate) }
            }
            box.session?.startRunning()
            Task { @MainActor in self?.state = .live }
        }
    }

    private func stop() {
        // The session is the queue's object — even its reads go there.
        let box = box
        queue.async { box.session?.stopRunning() }
        state = .off
    }
}

/// The preview's AppKit backing — an `AVCaptureVideoPreviewLayer` in a
/// layer-backed view, so the camera's frames never leave the GPU path.
@MainActor
final class MirrorPreviewView: NSView {
    private let videoLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        videoLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(videoLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func attach(_ session: AVCaptureSession) {
        videoLayer.session = session
    }

    override func layout() {
        super.layout()
        videoLayer.frame = bounds
    }
}
