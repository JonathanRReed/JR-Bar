import AppKit
import ObjectiveC
import Testing

/// Pins the process accent before a proof constructs views or caches semantic colors.
@MainActor
public enum RenderProofAppearance {
    private static var pinned = false

    public static func pinDefaultAccent() throws {
        guard !pinned else { return }
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleAccentColor"] = 4
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let accent = try #require(class_getClassMethod(NSColor.self, #selector(getter: NSColor.controlAccentColor)))
        let blue = try #require(class_getClassMethod(NSColor.self, #selector(NSColor.jrbarProofBlueAccent)))
        method_exchangeImplementations(accent, blue)
        pinned = true
    }
}

public struct RenderProofAppearanceTrait: SuiteTrait, TestTrait, TestScoping {
    public var isRecursive: Bool { true }

    public func provideScope(for test: Test, testCase: Test.Case?,
                             performing function: @Sendable () async throws -> Void) async throws {
        if ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1" {
            try await RenderProofAppearance.pinDefaultAccent()
        }
        try await function()
    }
}

extension Trait where Self == RenderProofAppearanceTrait {
    public static var renderProofAppearance: Self { Self() }
}

private extension NSColor {
    @objc class func jrbarProofBlueAccent() -> NSColor { .systemBlue }
}
