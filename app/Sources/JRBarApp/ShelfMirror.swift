import AppKit
import AVFoundation
import Observation

/// The card's mirror row — boring.notch's Mirror: a live feed from the
/// Mac's own camera, behind the `mirror` setting and summoned per open
/// (⌥-click at the notch, the card header's camera button), so the lens
/// never opens without the person asking for it. Consent is asked once,
/// the first time it opens; the session lives on a private queue
/// (startRunning can take a second — never on main) and the layer's
/// frames flow through `AVCaptureVideoPreviewLayer`, no frame-by-frame
/// copy.
@MainActor
@Observable
final class ShelfMirrorModel {
    enum State: Equatable {
        /// The setting is off — no session, no camera.
        case off
        case requestingPermission
        case starting
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

    nonisolated let queue: DispatchQueue
    private let driver: any ShelfMirrorSessionDriver
    private let runGate = ShelfMirrorRunGate()
    @ObservationIgnored var authorization: () -> AVAuthorizationStatus
    private let requestAccess: (@escaping @Sendable (Bool) -> Void) -> Void

    init(driver: (any ShelfMirrorSessionDriver)? = nil,
         queue: DispatchQueue = DispatchQueue(label: "devin.jrbar.mirror", qos: .userInitiated),
         authorization: @escaping () -> AVAuthorizationStatus = {
             AVCaptureDevice.authorizationStatus(for: .video)
         },
         requestAccess: @escaping (@escaping @Sendable (Bool) -> Void) -> Void = { completion in
             _ = Task { @MainActor in
                 let status = await SetupModel.requestCamera()
                 completion(status == .granted)
             }
         }) {
        self.driver = driver ?? ShelfMirrorCameraDriver()
        self.queue = queue
        self.authorization = authorization
        self.requestAccess = requestAccess
    }

    /// The pin × setting vote as last seen — the async paths (TCC
    /// answer, queued session build) consult it before touching state
    /// or the lens. Without it an unpin landing while the consent
    /// prompt is up would still let the grant turn the camera on with
    /// no preview on screen.
    private var enabled = false
    /// Bumps on every sync transition. Queued start blocks stamp the
    /// generation they were issued under; a state hop that finds the
    /// model has moved on shuts the lamp instead of resurrecting it.
    private var generation = 0

    /// The card pins: the setting's vote decides whether the lens
    /// opens or closes. Unpinning always closes it — an open lens with
    /// no visible preview would be the camera-indicator trap.
    func sync(enabled: Bool) {
        guard enabled != self.enabled else {
            if enabled, state == .denied, authorization() == .authorized { retry() }
            return
        }
        self.enabled = enabled
        generation += 1
        runGate.update(enabled: enabled, generation: generation)
        if enabled {
            start()
        } else {
            stop()
        }
    }

    /// A consent prompt is already up — pinning in and out while TCC
    /// waits must not stack `requestAccess` calls behind it.
    private(set) var permissionRequestPending = false

    func retry() {
        guard enabled, state == .unavailable || state == .denied else { return }
        generation += 1
        runGate.update(enabled: true, generation: generation)
        start()
    }

    private func start() {
        switch authorization() {
        case .authorized:
            run()
        case .notDetermined:
            // The toggle on is the explicit action — ask now, once.
            state = .requestingPermission
            guard !permissionRequestPending else { return }
            permissionRequestPending = true
            requestAccess { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.permissionRequestPending = false
                    // The answer can land minutes later — unpin or a
                    // toggle-off in the meantime means the lens stays
                    // shut even though the person said yes.
                    guard self.enabled, self.state == .requestingPermission else { return }
                    if granted { self.run() } else { self.state = .denied }
                }
            }
        default:
            state = .denied
        }
    }

    private func run() {
        state = .starting
        let driver = driver
        let gate = runGate
        let gen = generation
        queue.async { [weak self] in
            guard gate.permits(gen) else { return }
            let prepared = driver.prepare()
            guard gate.permits(gen) else { return }
            guard prepared else {
                Task { @MainActor in
                    guard let self, self.enabled, self.generation == gen else { return }
                    self.state = .unavailable
                }
                return
            }
            driver.start()
            Task { @MainActor in
                guard let self, self.enabled, self.generation == gen else { return }
                driver.attach(to: self.preview)
                self.state = .live
            }
        }
    }

    private func stop() {
        let driver = driver
        queue.async { driver.stop() }
        state = .off
    }
}

/// Session operations stay on the model's serial queue; only the preview attaches on main.
protocol ShelfMirrorSessionDriver: AnyObject, Sendable {
    func prepare() -> Bool
    func start()
    func stop()
    @MainActor func attach(to preview: MirrorPreviewView)
}

private final class ShelfMirrorCameraDriver: ShelfMirrorSessionDriver, @unchecked Sendable {
    // Assigned on the serial queue, retained across opens, and handed to the preview on main.
    private var session: AVCaptureSession?

    func prepare() -> Bool {
        if session != nil { return true }
        let candidate = AVCaptureSession()
        candidate.sessionPreset = .medium
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              candidate.canAddInput(input) else { return false }
        candidate.addInput(input)
        session = candidate
        return true
    }

    func start() { session?.startRunning() }
    func stop() { session?.stopRunning() }
    @MainActor func attach(to preview: MirrorPreviewView) {
        if let session { preview.attach(session) }
    }
}

/// A fold invalidates queued camera work without waiting for a session operation.
private final class ShelfMirrorRunGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var generation = 0

    func update(enabled: Bool, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.enabled = enabled
        self.generation = generation
    }

    func permits(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled && self.generation == generation
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
