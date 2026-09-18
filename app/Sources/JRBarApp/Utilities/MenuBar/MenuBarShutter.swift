import AppKit
import JRBarCore

/// How a shutter cover reads, resolved from `MenuBarSettings` — pure
/// value mapping so a test pins it without a panel. The defaults
/// reproduce the shipping look: `.menu` material, no tint, square ends,
/// no separator.
struct MenuBarCoverAppearance: Equatable, Sendable {
    var material: MenuBarSettings.CoverMaterial = .blend
    /// A "#RRGGBB" hex tint; empty = no tint layer.
    var tintHex: String = ""
    var tintOpacity: Double = MenuBarSettings.defaultCoverTintOpacity
    var roundness: Double = 0
    var separator: Bool = false
    /// The sampled bar color a `.blend` cover fills with — "#RRGGBB",
    /// empty until the hider probes the real bar next to the run.
    var blendHex: String = ""

    init(material: MenuBarSettings.CoverMaterial = .blend,
         tintHex: String = "",
         tintOpacity: Double = MenuBarSettings.defaultCoverTintOpacity,
         roundness: Double = 0, separator: Bool = false,
         blendHex: String = "") {
        self.material = material
        self.tintHex = tintHex
        self.tintOpacity = MenuBarSettings.clampedOpacity(tintOpacity)
        self.roundness = MenuBarSettings.clampedRoundness(roundness)
        self.separator = separator
        self.blendHex = blendHex
    }

    init(settings: MenuBarSettings) {
        self.init(material: settings.coverMaterial, tintHex: settings.coverTint,
                  tintOpacity: settings.coverTintOpacity,
                  roundness: settings.coverRoundness,
                  separator: settings.showCoverSeparator)
    }

    /// The tint the card enables first — a neutral menu-bar gray.
    nonisolated static let defaultTintHex = "#8E8E93"

    /// "#RRGGBB" or "#RRGGBBAA"-style hex → components; nil on garbage
    /// (an empty string included — that is the "no tint" state).
    nonisolated static func tintComponents(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255)
    }

    /// An `NSColor` back to "#RRGGBB" for the settings write; nil when
    /// the color won't convert to sRGB.
    nonisolated static func hex(from color: NSColor) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// The visual-effect material the cover's `NSVisualEffectView`
    /// draws.
    var effectMaterial: NSVisualEffectView.Material {
        switch material {
        case .blend: return .menu
        case .menu: return .menu
        case .hud: return .hudWindow
        case .popover: return .popover
        case .sheet: return .sheet
        }
    }

    /// The tint layer's color; nil when the hex is empty or unparseable.
    var tintColor: NSColor? {
        guard let c = Self.tintComponents(tintHex) else { return nil }
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: tintOpacity)
    }

    /// The opaque fill a `.blend` cover draws — the sampled bar color;
    /// nil while no probe has landed, when the material look stands in.
    var blendColor: NSColor? {
        guard material == .blend, let c = Self.tintComponents(blendHex) else { return nil }
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
}

/// A cover panel's content: the material view, a tint fill on top of
/// it, and the two hairlines marking where the covered run meets
/// visible menu bar. The container's layer carries the corner radius
/// so the run's ends round as a unit.
final class MenuBarCoverView: NSView {
    let effect = NSVisualEffectView()
    private let tintView = NSView()
    private let leadingHairline = NSView()
    private let trailingHairline = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        effect.blendingMode = .behindWindow
        effect.state = .active
        tintView.wantsLayer = true
        for hairline in [leadingHairline, trailingHairline] {
            hairline.wantsLayer = true
            hairline.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
        for sub in [effect, tintView, leadingHairline, trailingHairline] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),
            leadingHairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            leadingHairline.topAnchor.constraint(equalTo: topAnchor),
            leadingHairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            leadingHairline.widthAnchor.constraint(equalToConstant: 1),
            trailingHairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingHairline.topAnchor.constraint(equalTo: topAnchor),
            trailingHairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            trailingHairline.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Restyle in place — every reconcile reapplies, so a settings
    /// change lands on the next pass without churning panels.
    func apply(_ appearance: MenuBarCoverAppearance) {
        // `.blend` trades the material for a flat opaque fill of the
        // sampled bar color — the covered stretch reads as the bar's
        // own pixels, not a panel. A failed probe leaves the material.
        let blend = appearance.blendColor
        effect.isHidden = blend != nil
        layer?.backgroundColor = blend?.cgColor ?? NSColor.clear.cgColor
        effect.material = appearance.effectMaterial
        // A tint the user chose still reads over the blend — a
        // deliberate cover color outranks blending in.
        tintView.layer?.backgroundColor = appearance.tintColor?.cgColor
        tintView.isHidden = appearance.tintColor == nil
        leadingHairline.isHidden = !appearance.separator
        trailingHairline.isHidden = !appearance.separator
        // Resolved here, not once at init, so a dark/light flip follows.
        let separator = NSColor.separatorColor.cgColor
        leadingHairline.layer?.backgroundColor = separator
        trailingHairline.layer?.backgroundColor = separator
        // All four corners round together — at the menu bar's depth a
        // run's ends read as pill ends; a run that touches the screen
        // edge simply keeps its square corner off the bezel.
        layer?.cornerRadius = appearance.roundness
        layer?.masksToBounds = appearance.roundness > 0
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner,
                                .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
    }
}

/// The covers that hide menu bar items. macOS 26 gives no way to
/// evict or park a foreign item — verified live: oversized status
/// items, reinsertion, `isVisible`, and ⌘-drags all leave the item
/// drawn — so the utility covers it instead. A borderless panel at
/// `statusBar + 1` backed by a `.menu` visual effect is empirically
/// fully opaque to the items beneath (glass ghosts them through;
/// `.menu` does not) while reading as ordinary empty menu bar.
///
/// The shutter takes its clicks (`ignoresMouseEvents = false`): a
/// covered item must not still answer a click, and the press the
/// shutter swallows is exactly the reveal gesture — the global
/// monitor sees the `leftMouseDown` before delivery, hit-tests the
/// row, and fires `onReveal`.
///
/// One panel per covered run — a hidden item may sit between two
/// shown items, and the gap a shown item occupies is never covered.
/// The panel pool grows to the run count and idles extras out of
/// sight rather than churning windows.
@MainActor
final class MenuBarShutter {
    /// The covered x-ranges in Quartz coordinates, for diagnostics.
    private(set) var coveredRanges: [ClosedRange<CGFloat>] = []
    private var panels: [NSPanel] = []

    /// Cover `ranges` (Quartz x) on the menu bar row — one panel each,
    /// extras ordered out — styled by `appearance`. Re-applying the
    /// same set is a no-op; an appearance change reapplies in place.
    func cover(_ ranges: [ClosedRange<CGFloat>], rowHeight: CGFloat,
               appearance: MenuBarCoverAppearance = MenuBarCoverAppearance()) {
        let clean = ranges.filter { $0.upperBound - $0.lowerBound > 4 }
        if coveredRanges != clean {
            coveredRanges = clean
            MenuBarAssessmentBackend.log.notice("cover paint \(clean.map { "\(Int($0.lowerBound))–\(Int($0.upperBound))" }.joined(separator: " "), privacy: .public)")
        }
        while panels.count < clean.count { panels.append(makePanel()) }
        let displayHeight = CGDisplayBounds(CGMainDisplayID()).height
        for (index, panel) in panels.enumerated() {
            guard index < clean.count else {
                if panel.isVisible { panel.orderOut(nil) }
                continue
            }
            let range = clean[index]
            // Quartz top-left origin → AppKit bottom-left.
            let frame = NSRect(x: range.lowerBound,
                               y: displayHeight - rowHeight,
                               width: range.upperBound - range.lowerBound,
                               height: rowHeight)
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            (panel.contentView as? MenuBarCoverView)?.apply(appearance)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    func orderOut() {
        coveredRanges = []
        for panel in panels where panel.isVisible { panel.orderOut(nil) }
    }

    isolated deinit {
        for panel in panels { panel.orderOut(nil) }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // Above the menu bar's own level — the cover must draw over
        // the menubar window and the apps' extras-region windows.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]
        // Fold's warp captures the desktop — the cover must not be in
        // it, the same exclusion the Item Bar claims.
        if ProcessInfo.processInfo.environment["JRBAR_CAPTURE_CARD"] == nil {
            panel.sharingType = .none
        }
        // `.menu` over behind-window blending reads as the bar's own
        // material and — unlike glass — fully occludes the items it
        // covers; `apply` restyles it from settings every reconcile.
        panel.contentView = MenuBarCoverView()
        panel.title = "JR-Bar Menu Bar Cover"
        return panel
    }
}

/// The `.blend` probe's arithmetic: a captured strip of the real menu
/// bar, averaged down to the one "#RRGGBB" a flat-fill cover needs.
enum MenuBarBarSampler {
    /// The image's average color as "#RRGGBB"; nil when it has no
    /// pixels to read.
    nonisolated static func averageHex(of image: CGImage) -> String? {
        let source = CIImage(cgImage: image)
        guard !source.extent.isEmpty else { return nil }
        let averaged = source.applyingFilter(
            "CIAreaAverage",
            parameters: [kCIInputExtentKey: CIVector(cgRect: source.extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(averaged, toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2])
    }
}
