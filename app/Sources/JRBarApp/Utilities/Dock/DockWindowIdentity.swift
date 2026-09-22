import ApplicationServices
import Darwin

/// Resolves the native window number carried by an Accessibility window.
/// HIServices does not publish this function in its Swift module, so the
/// bridge resolves the verified C ABI at runtime and becomes unavailable if
/// the symbol is absent on a future macOS release.
@MainActor
enum DockWindowIdentity {
    typealias WindowIDFunction = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private static let frameworkPath =
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"

    private final class Resolver {
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
