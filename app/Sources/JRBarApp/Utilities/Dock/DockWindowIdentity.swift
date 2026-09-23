import ApplicationServices
import Darwin
import QuartzCore

/// Resolves the native window number carried by an Accessibility window.
/// HIServices does not publish this function in its Swift module, so the
/// bridge resolves the verified C ABI at runtime and becomes unavailable if
/// the symbol is absent on a future macOS release. Callable from any
/// thread, like the AX calls it rides with: a window list read on
/// `DockAXWorker` asks it too.
enum DockWindowIdentity {
    typealias WindowIDFunction = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private static let frameworkPath =
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"

    /// Immutable once resolved — the image handle and a C function
    /// pointer — so any thread may read it.
    private final class Resolver: @unchecked Sendable {
        let handle: UnsafeMutableRawPointer
        let function: WindowIDFunction

        init?(path: String) {
            guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
            guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
                dlclose(handle)
                return nil
            }
            self.handle = handle
            function = unsafeBitCast(symbol, to: WindowIDFunction.self)
        }

        deinit {
            dlclose(handle)
        }
    }

    /// Kept for the process lifetime so the resolved function never outlives
    /// the image that owns it.
    private static let resolver = Resolver(path: frameworkPath)

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        windowID(of: element, using: resolver?.function)
    }

    /// Injection seam for the ABI result handling. A nil function models a
    /// macOS release where HIServices or the private symbol is unavailable.
    static func windowID(
        of element: AXUIElement,
        using function: WindowIDFunction?
    ) -> CGWindowID? {
        guard let function else { return nil }
        var windowID: CGWindowID = 0
        guard function(element, &windowID) == .success, windowID != 0 else { return nil }
        return windowID
    }
}

/// Windows on other Spaces have no entry in an app's `AXWindows` — that
/// list covers the current Space — so a switcher row for one carried no
/// element and committing it could only activate the app. HIServices'
/// `_AXUIElementCreateWithRemoteToken` (the family `_AXUIElementGetWindow`
/// comes from) builds an element straight from (pid, element id); walking
/// a bounded run of ids and keeping the one whose native window id is the
/// CG row's reaches that exact window — AltTab's approach, re-derived.
/// Read-only: it creates references and writes nothing, no SkyLight call
/// is involved, and like the identity bridge it resolves at runtime and
/// answers nil if the symbol is ever gone. Run lazily, per commit, never
/// per open — and on `DockAXWorker`, since a hung app spends the whole
/// time budget on it.
enum DockRemoteWindows {
    typealias CreateFunction = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    /// Element ids tried per lookup, and the wall-clock cap on the walk —
    /// a hung app answers every probe with a timeout, not a window.
    static let idBudget: UInt64 = 1000
    static let timeBudget: TimeInterval = 0.2
    /// Per-probe AX timeout: a live app answers in microseconds.
    static let probeTimeout: Float = 0.02

    /// Immutable once resolved, like the identity bridge's.
    private final class Resolver: @unchecked Sendable {
        let handle: UnsafeMutableRawPointer
        let create: CreateFunction

        init?(path: String) {
            guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
            guard let symbol = dlsym(handle, "_AXUIElementCreateWithRemoteToken") else {
                dlclose(handle)
                return nil
            }
            self.handle = handle
            create = unsafeBitCast(symbol, to: CreateFunction.self)
        }

        deinit { dlclose(handle) }
    }

    private static let resolver = Resolver(
        path: "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices")

    /// The 20-byte remote token: the pid, four zero bytes, the "coco"
    /// magic, then the 64-bit element id — little-endian throughout.
    static func token(pid: pid_t, elementID: UInt64) -> Data {
        var data = Data()
        withUnsafeBytes(of: pid.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(0)) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(0x636f_636f).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: elementID.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// The AX window of `pid` whose native id is `windowID`, wherever it
    /// lives, or nil.
    static func element(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        element(pid: pid, windowID: windowID, create: resolver?.create,
                windowIDOf: { DockWindowIdentity.windowID(of: $0) })
    }

    /// The seam: `create` nil models a macOS without the symbol.
    static func element(pid: pid_t, windowID: CGWindowID, create: CreateFunction?,
                        windowIDOf: (AXUIElement) -> CGWindowID?,
                        budget: UInt64 = idBudget) -> AXUIElement? {
        guard let create else { return nil }
        let start = CACurrentMediaTime()
        for id in 0..<budget {
            if CACurrentMediaTime() - start > timeBudget { break }
            guard let element = create(token(pid: pid, elementID: id) as CFData)?
                .takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, probeTimeout)
            if windowIDOf(element) == windowID { return element }
        }
        return nil
    }
}
