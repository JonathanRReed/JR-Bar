import SwiftUI

private struct ReduceMotionOverride: EnvironmentKey {
    static let defaultValue: Bool? = nil
}
private struct ReduceTransparencyOverride: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct ContrastInk: EnvironmentKey {
    static let defaultValue = JRBarTokens.Ink.Palette()
}

extension EnvironmentValues {
    var jrbarInk: JRBarTokens.Ink.Palette {
        get { self[ContrastInk.self] }
        set { self[ContrastInk.self] = newValue }
    }
    var jrbarReduceMotion: Bool? {
        get { self[ReduceMotionOverride.self] }
        set { self[ReduceMotionOverride.self] = newValue }
    }
    var jrbarReduceTransparency: Bool? {
        get { self[ReduceTransparencyOverride.self] }
        set { self[ReduceTransparencyOverride.self] = newValue }
    }
}

public extension View {
    /// Explicit preferences for previews or an app setting. Nil follows macOS.
    func jrbarAccessibility(reduceMotion: Bool? = nil, reduceTransparency: Bool? = nil, increaseContrast: Bool = false) -> some View {
        environment(\.jrbarReduceMotion, reduceMotion)
            .environment(\.jrbarReduceTransparency, reduceTransparency)
            .environment(\.jrbarInk, JRBarTokens.Ink.Palette(increased: increaseContrast))
    }
}
