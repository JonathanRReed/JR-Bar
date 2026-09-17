import AppKit
import CoreWLAN
import Intents
import JRBarCore
import OSLog
import SwiftUI

/// The extra status items and bar surfaces `MenuBarSettings` drives
/// beyond the boundary: spacer/label items, the full-bar underlay, the
/// agent-state item, and the combined system item that stands in for
/// the Control Center extras it covers.
///
/// Every item follows the chevron's two rules — born visible so the
/// agent adopts it, never re-registered on an engine switch — and all
/// of them are protected owners ("JR-Bar"), so none can land in a
/// plan's hidden run.

/// A spacer or label item's click target. Bartender's spacer click
/// reveals the hidden run; ours does the same through the utility.
@MainActor
final class MenuBarSpacerActions: NSObject {
    var onClick: () -> Void = {}
    @objc func clicked(_ sender: Any?) { onClick() }
}

/// A tint sheet drawn under the whole menu bar row — Ice's "menu bar
/// appearance" — one panel per screen, below the items so the bar's
/// translucency shows it through. The bar backdrop is opaque on some
/// macOS builds; there the panels simply read as nothing, which is
/// the honest failure.
@MainActor
final class MenuBarUnderlay {
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var observers: [NSObjectProtocol] = []
    private var appearance = MenuBarCoverAppearance()

    /// Show or restyle the sheets. Called from `syncExtras` — a
    /// settings change lands on the next reconcile.
    func show(appearance: MenuBarCoverAppearance) {
        self.appearance = appearance
        var live: Set<CGDirectDisplayID> = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.uint32Value
            live.insert(id)
            let depth = max(NSStatusBar.system.thickness,
                            ScreenBarGeometry.notchDepth(of: screen))
            let frame = NSRect(x: screen.frame.minX,
                               y: screen.frame.maxY - depth,
                               width: screen.frame.width, height: depth)
            let panel = panels[id] ?? makePanel(id: id)
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            (panel.contentView as? MenuBarCoverView)?.apply(
                MenuBarCoverAppearance(material: appearance.material,
                                       tintHex: appearance.tintHex,
                                       tintOpacity: appearance.tintOpacity,
                                       roundness: 0, separator: false))
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        for (id, panel) in panels where !live.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
        if observers.isEmpty {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.show(appearance: self.appearance)
                }
            })
        }
    }

    func hide() {
        for (_, panel) in panels { panel.orderOut(nil) }
        panels = [:]
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    isolated deinit { hide() }

    private func makePanel(id: CGDirectDisplayID) -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // Below the items — the bar's own translucency carries the
        // tint through. One level under `statusBar` keeps it clear of
        // every status item window without touching the desktop.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]
        if ProcessInfo.processInfo.environment["JRBAR_CAPTURE_CARD"] == nil {
            panel.sharingType = .none
        }
        let view = MenuBarCoverView()
        panel.contentView = view
        panel.title = "JR-Bar Menu Bar Underlay \(id)"
        panels[id] = panel
        return panel
    }
}

/// One status item standing in for the Control Center extras it
/// covers — battery, Wi-Fi, sound and Focus in a single face, a
/// popover for the details, and the system's own items parked through
/// Control Center's `NSStatusItem Visible` defaults while it runs.
@MainActor
final class MenuBarCombinedItem {
    nonisolated static let log = Logger(subsystem: "devin.jrbar", category: "menubar")

    /// The Control Center extras this item replaces. Values are the
    /// `NSStatusItem Visible <id>` keys `com.apple.controlcenter`
    /// reads; restoring means writing the saved value back and letting
    /// ControlCenter relaunch.
    nonisolated static let coveredExtraKeys: [String] = [
        "Battery", "WiFi", "Bluetooth", "Sound", "NowPlaying", "FocusModes",
    ]
    /// Where the original visibility values are kept while hidden, so
    /// a disable restores exactly what the person had — including
    /// "was never set" (a missing key).
    nonisolated static let savedKey = "jrbar.menubar.ccOriginals"

    private(set) var item: NSStatusItem?
    private var popover: NSPopover?
    private var lastSignature = ""
    private var actions: MenuBarSpacerActions?

    /// Install (once) or refresh the item's face. The image rebuilds
    /// only when the signature changes — battery %, Wi-Fi state,
    /// Focus — so a 1 Hz reconcile costs a read, not a redraw.
    func sync() {
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "com.jonathanreed.jrbar.menubar-combined"
            let actions = MenuBarSpacerActions()
            actions.onClick = { [weak self] in self?.toggle() }
            item.button?.target = actions
            item.button?.action = #selector(MenuBarSpacerActions.clicked(_:))
            item.button?.toolTip = "Battery, Wi-Fi, sound and Focus — one item. Click for the panel."
            self.item = item
            self.actions = actions
        }
        let power = AlcovePowerMonitor.read()
        let ssid = MenuBarSystemTriggerSource.currentSSID()
        let focused = INFocusStatusCenter.default.authorizationStatus == .authorized
            && (INFocusStatusCenter.default.focusStatus.isFocused ?? false)
        let signature = "\(power.percent ?? -1)|\(power.charging)|\(ssid ?? "-")|\(focused)"
        guard signature != lastSignature else { return }
        lastSignature = signature
        item?.button?.image = Self.faceImage(power: power, wifi: ssid != nil, focused: focused)
        item?.button?.imagePosition = .imageOnly
        (popover?.contentViewController as? NSHostingController<MenuBarSystemPane>)?
            .rootView.model.refresh()
    }

    func remove() {
        popover?.close()
        popover = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        actions = nil
        Self.setCoveredExtrasHidden(false)
    }

    /// Hide or restore the Control Center extras this item covers.
    /// The write goes to Control Center's own defaults domain; the
    /// originals are saved first so a restore is exact, and the
    /// `killall` lands off the caller's thread — launchd relaunches it.
    nonisolated static func setCoveredExtrasHidden(_ hidden: Bool) {
        let suite = UserDefaults(suiteName: "com.apple.controlcenter")
        let ours = UserDefaults.standard
        if hidden {
            var saved = ours.dictionary(forKey: savedKey) as? [String: Bool] ?? [:]
            for key in coveredExtraKeys {
                let defaultsKey = "NSStatusItem Visible \(key)"
                if saved[key] == nil, let existing = suite?.object(forKey: defaultsKey) as? Bool {
                    saved[key] = existing
                }
                suite?.set(false, forKey: defaultsKey)
            }
            ours.set(saved, forKey: savedKey)
        } else {
            guard let saved = ours.dictionary(forKey: savedKey) as? [String: Bool] else { return }
            for key in coveredExtraKeys {
                let defaultsKey = "NSStatusItem Visible \(key)"
                if let original = saved[key] {
                    suite?.set(original, forKey: defaultsKey)
                } else {
                    suite?.removeObject(forKey: defaultsKey)
                }
            }
            ours.removeObject(forKey: savedKey)
        }
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = ["ControlCenter"]
            try? process.run()
        }
    }

    private func toggle() {
        guard let item, let button = item.button else { return }
        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentSize = NSSize(width: 260, height: 210)
            popover.contentViewController = NSHostingController(
                rootView: MenuBarSystemPane(model: MenuBarSystemModel()))
            self.popover = popover
        }
        guard let popover else { return }
        if popover.isShown {
            popover.close()
        } else {
            (popover.contentViewController as? NSHostingController<MenuBarSystemPane>)?
                .rootView.model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// The item's face: battery gauge + percent when the machine has a
    /// battery, Wi-Fi when a network is joined, a moon while Focus is
    /// on — one template image so the bar tints it like its own.
    nonisolated static func faceImage(power: AlcovePowerState, wifi: Bool,
                                      focused: Bool) -> NSImage? {
        var parts: [(symbol: String, text: String?)] = []
        if power.hasBattery {
            parts.append((power.charging ? "battery.100.bolt" : "battery.75percent",
                          power.percent.map { "\($0)" }))
        }
        if wifi { parts.append(("wifi", nil)) }
        if focused { parts.append(("moon.fill", nil)) }
        guard !parts.isEmpty else { return nil }
        let height: CGFloat = 18
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        var widths: [CGFloat] = []
        var images: [NSImage] = []
        for part in parts {
            guard let image = NSImage(systemSymbolName: part.symbol,
                                      accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            else { return nil }
            images.append(image)
            var width = image.size.width
            if let text = part.text {
                width += 2 + (text as NSString).size(withAttributes: [.font: font]).width
            }
            widths.append(width)
        }
        let gap: CGFloat = 5
        let width = widths.reduce(0, +) + gap * CGFloat(parts.count - 1)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (index, part) in parts.enumerated() {
                let symbol = images[index]
                symbol.draw(in: NSRect(x: x, y: (height - symbol.size.height) / 2,
                                       width: symbol.size.width, height: symbol.size.height))
                var next = x + symbol.size.width
                if let text = part.text {
                    (text as NSString).draw(
                        at: NSPoint(x: next + 2, y: (height - font.pointSize) / 2 - 1),
                        withAttributes: [.font: font])
                    next += 2 + (text as NSString).size(withAttributes: [.font: font]).width
                }
                x = next + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The combined item's popover model — a snapshot so the view reads
/// one consistent set of values.
@MainActor
@Observable
final class MenuBarSystemModel {
    var batteryText = "—"
    var batteryDetail = ""
    var wifiName = "No network"
    var focused = false
    var focusKnown = false
    var volume: Double = 0
    var volumeKnown = false
    var muted = false

    func refresh() {
        let power = AlcovePowerMonitor.read()
        if power.hasBattery {
            batteryText = power.percent.map { "\($0)%" } ?? "Battery"
            batteryDetail = power.charging ? "Charging"
                : power.onAC ? "On power adapter" : "On battery"
        } else {
            batteryText = "No battery"
            batteryDetail = ""
        }
        wifiName = MenuBarSystemTriggerSource.currentSSID() ?? "No network"
        focusKnown = INFocusStatusCenter.default.authorizationStatus == .authorized
        focused = focusKnown && (INFocusStatusCenter.default.focusStatus.isFocused ?? false)
        if let v = SystemLevelReader.outputVolume() {
            volume = Double(v)
            volumeKnown = true
        } else {
            volumeKnown = false
        }
        muted = SystemLevelReader.outputMuted() ?? false
    }

    func setVolume(_ value: Double) {
        SystemLevelReader.setOutputVolume(Float(value))
        muted = false
    }
}

/// The combined item's popover pane: readouts for what the face shows
/// plus the one control worth surfacing — the volume slider.
struct MenuBarSystemPane: View {
    let model: MenuBarSystemModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(symbol: model.batteryDetail == "Charging" ? "battery.100.bolt" : "battery.75percent",
                title: model.batteryText, detail: model.batteryDetail)
            row(symbol: "wifi", title: model.wifiName, detail: "Wi-Fi")
            if model.focusKnown {
                row(symbol: "moon.fill", title: model.focused ? "Focus on" : "Focus off",
                    detail: "")
            }
            HStack(spacing: 8) {
                Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18)
                if model.volumeKnown {
                    Slider(value: Binding(
                        get: { model.muted ? 0 : model.volume },
                        set: { model.setVolume($0) }))
                } else {
                    Text("This output has no volume control")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 236)
    }

    private func row(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 18)
            Text(title)
            Spacer()
            if !detail.isEmpty {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }
}
