import Foundation

/// The Dock utility's persisted state (docs/TOY-PARITY.md, "Dock").
/// One mode: **Enhance** keeps Apple's Dock and floats window
/// previews over it. The Replace bar was cut on 2026-09-15 — one dock
/// done well beats two done halfway — and its keys (`mode`, `edge`,
/// `pinned`, `magnification`, …) are ignored on decode.
///
/// Lives inside `UtilitiesState.dock` — `app-state.json`, never
/// `UserDefaults` — and decodes tolerantly at every level the way
/// `MenuBarSettings` does: a missing or mistyped key falls back to its
/// default and unknown keys are ignored, so an older or newer build
/// can share the file.
public struct DockSettings: Codable, Equatable, Sendable {
    /// The card toggle.
    public var enabled: Bool
    /// The hover-preview knobs.
    public var enhance: DockEnhanceSettings

    public init(enabled: Bool = false, enhance: DockEnhanceSettings = DockEnhanceSettings()) {
        self.enabled = enabled
        self.enhance = enhance
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, enhance
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        enhance = (try? c.decodeIfPresent(DockEnhanceSettings.self, forKey: .enhance)) ?? DockEnhanceSettings()
    }
}

/// The hover-preview knobs (docs/TOY-PARITY.md, "Dock — Enhance"):
/// how long the pointer must rest on an Apple-Dock icon before the
/// preview panel opens, whether the panel's cards carry live
/// `SCScreenshotManager` thumbnails or plain icon + title cards, and
/// the card size.
public struct DockEnhanceSettings: Codable, Equatable, Sendable {
    /// Seconds of rest before the preview opens — Apple's own ~250 ms.
    public var previewDelay: Double {
        didSet { previewDelay = Self.clampedDelay(previewDelay) }
    }
    /// Thumbnails (one capture per window when the preview opens) need
    /// Screen Recording; off is icon + title cards.
    public var showThumbnails: Bool
    /// Bigger cards — 208×130 instead of 144×90 — for people who read
    /// the thumbnail rather than the title.
    public var largePreviews: Bool
    /// Thumbnails for windows on other Spaces and minimized windows
    /// too; the cards list every window either way.
    public var includeOffscreenWindows: Bool

    public static let delayRange: ClosedRange<Double> = 0.05...1.0
    public static let defaultDelay: Double = 0.25

    public init(previewDelay: Double = DockEnhanceSettings.defaultDelay,
                showThumbnails: Bool = true,
                largePreviews: Bool = false,
                includeOffscreenWindows: Bool = true) {
        self.previewDelay = Self.clampedDelay(previewDelay)
        self.showThumbnails = showThumbnails
        self.largePreviews = largePreviews
        self.includeOffscreenWindows = includeOffscreenWindows
    }

    static func clampedDelay(_ value: Double) -> Double {
        guard value.isFinite else { return defaultDelay }
        return min(delayRange.upperBound, max(delayRange.lowerBound, value))
    }

    private enum CodingKeys: String, CodingKey {
        case previewDelay, showThumbnails, largePreviews, includeOffscreenWindows
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        previewDelay = Self.clampedDelay(
            (try? c.decodeIfPresent(Double.self, forKey: .previewDelay)) ?? Self.defaultDelay)
        showThumbnails = (try? c.decodeIfPresent(Bool.self, forKey: .showThumbnails)) ?? true
        largePreviews = (try? c.decodeIfPresent(Bool.self, forKey: .largePreviews)) ?? false
        includeOffscreenWindows = (try? c.decodeIfPresent(Bool.self, forKey: .includeOffscreenWindows)) ?? true
    }
}

/// The edge Apple's Dock hugs — read off its AX frame, never set.
/// `top` is deliberately absent — the menu bar owns that edge.
public enum DockEdge: String, Codable, CaseIterable, Sendable {
    case bottom
    case left
    case right

    /// True for `bottom`: the row runs horizontally.
    public var isHorizontal: Bool { self == .bottom }
}
