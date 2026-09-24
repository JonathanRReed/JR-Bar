import AppKit
import CoreBluetooth
import CoreWLAN
import Intents
import IOBluetooth
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

    /// Whether Control Center's items stand hidden through us now — the
    /// saved originals are written with the hide and removed with the
    /// restore, so they outlive a crash that skipped the restore.
    nonisolated static func coveredExtrasSaved() -> Bool {
        UserDefaults.standard.dictionary(forKey: savedKey) != nil
    }

    private(set) var item: NSStatusItem?
    private var popover: NSPopover?
    private var lastSignature = ""
    private var actions: MenuBarSpacerActions?
    /// The agents' line for the popover — what no Control Center has: the
    /// combined state's word, its detail and its tint. The utility wires
    /// it from the daemon feed.
    var agentLine: @MainActor () -> MenuBarSystemModel.AgentLine? = { nil }

    typealias Readout = (image: NSImage?, signature: String, label: String)

    /// The last read, shared for a beat: the item's own sync, the
    /// mirror's segment and every face redraw in between ask within the
    /// same pass, and each read is IOKit, CoreWLAN and Focus.
    private var cachedReadout: (at: Date, read: Readout)?
    nonisolated static let readoutShelfLife: TimeInterval = 1

    /// What the face shows right now: the composed image, a signature
    /// that changes only when a value does, and a spoken summary for the
    /// mirror's segment. At most one read per `readoutShelfLife`.
    func readout(now: Date = Date()) -> Readout {
        if let cached = cachedReadout, now.timeIntervalSince(cached.at) < Self.readoutShelfLife {
            return cached.read
        }
        let read = freshReadout()
        cachedReadout = (now, read)
        return read
    }

    private func freshReadout() -> Readout {
        let power = AlcovePowerMonitor.read()
        let ssid = MenuBarSystemTriggerSource.currentSSID()
        let focused = INFocusStatusCenter.default.authorizationStatus == .authorized
            && (INFocusStatusCenter.default.focusStatus.isFocused ?? false)
        let signature = "\(power.percent ?? -1)|\(power.charging)|\(ssid ?? "-")|\(focused)"
        var parts: [String] = []
        if power.hasBattery {
            parts.append("Battery " + (power.percent.map { "\($0)%" } ?? "unknown")
                         + (power.charging ? ", charging" : ""))
        }
        parts.append(ssid.map { "Wi-Fi \($0)" } ?? "Wi-Fi off or unnamed")
        if focused { parts.append("Focus on") }
        return (Self.faceImage(power: power, wifi: ssid != nil, focused: focused), signature,
                parts.joined(separator: ", "))
    }

    /// Install (once) or refresh the item's face. The image rebuilds
    /// only when the signature changes — battery %, Wi-Fi state,
    /// Focus — so a refresh costs a read, not a redraw. `blank` hands
    /// the face to the mirror.
    func sync(blank: Bool = false) {
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
        let read = readout()
        let signature = read.signature + (blank ? "|blank" : "")
        guard signature != lastSignature else { return }
        lastSignature = signature
        item?.button?.image = blank ? nil : read.image
        item?.button?.imagePosition = .imageOnly
        (popover?.contentViewController as? NSHostingController<MenuBarSystemPane>)?
            .rootView.model.refresh()
    }

    func remove() {
        // The pane's live feeds stop with the item, not only with a
        // SwiftUI disappear the closing popover may never deliver.
        (popover?.contentViewController as? NSHostingController<MenuBarSystemPane>)?
            .rootView.model.stopLive()
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

    /// The popover, anchored on `view` — the mirror's segment while it
    /// carries the readout, the item's own button otherwise.
    func toggle(relativeTo view: NSView) {
        showPopover(relativeTo: view)
    }

    private func toggle() {
        guard let item, let button = item.button else { return }
        showPopover(relativeTo: button)
    }

    private func showPopover(relativeTo button: NSView) {
        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            let model = MenuBarSystemModel()
            model.agentLine = { [weak self] in self?.agentLine() }
            let hosting = NSHostingController(rootView: MenuBarSystemPane(model: model))
            // The pane grows with what is connected and playing.
            hosting.sizingOptions = [.preferredContentSize]
            popover.contentViewController = hosting
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
            parts.append((power.charging ? "battery.100.bolt"
                                        : batterySymbol(percent: power.percent),
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

    /// The battery gauge symbol for a charge level — the face used to
    /// claim 75% at any charge.
    nonisolated static func batterySymbol(percent: Int?) -> String {
        switch percent ?? 50 {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// The safety gate on the combined item's one risky write: Control
/// Center's battery, Wi-Fi, Bluetooth, sound, Now Playing and Focus items
/// are hidden only while the replacement face is verifiably drawn —
/// otherwise both could vanish at once. The face has to stand for a
/// settle window before the items hide, and a flip back to hidden waits
/// out a minimum interval, so a flapping face never thrashes
/// `killall ControlCenter`. Restoring waits only the settle window:
/// your battery and Wi-Fi coming back is never throttled. Pure, so a
/// test pins the timing.
struct MenuBarDrawnGate: Equatable, Sendable {
    /// Whether Control Center's items are hidden through the gate now.
    private(set) var hidden = false

    /// A gate that starts from what stands: `hidden` when a run that
    /// never restored (a crash) left Control Center's items hidden, so a
    /// face that never draws still gives them back.
    init(hidden: Bool = false) {
        self.hidden = hidden
    }
    private var drawnSince: Date?
    private var undrawnSince: Date?
    private var lastHide: Date = .distantPast

    /// How long the face must stand (or be gone) before the gate acts.
    nonisolated static let settle: TimeInterval = 3
    /// The least time between two hides.
    nonisolated static let minHideInterval: TimeInterval = 10

    /// One look at the face. Returns the new state when Control Center's
    /// items should flip, nil when nothing changes. `wanted` off restores
    /// at once — the person turned the item off.
    mutating func step(wanted: Bool, drawn: Bool, now: Date) -> Bool? {
        guard wanted else {
            drawnSince = nil
            undrawnSince = nil
            guard hidden else { return nil }
            hidden = false
            return false
        }
        if drawn {
            undrawnSince = nil
            let since = drawnSince ?? now
            drawnSince = since
            guard !hidden, now.timeIntervalSince(since) >= Self.settle,
                  now.timeIntervalSince(lastHide) >= Self.minHideInterval else { return nil }
            hidden = true
            lastHide = now
            return true
        }
        drawnSince = nil
        let since = undrawnSince ?? now
        undrawnSince = since
        guard hidden, now.timeIntervalSince(since) >= Self.settle else { return nil }
        hidden = false
        return false
    }

    /// The disable path: restore now, whatever the clocks say.
    mutating func release() -> Bool {
        defer { self = MenuBarDrawnGate() }
        return hidden
    }
}

/// A connected Bluetooth device as the popover lists it.
struct MenuBarBluetoothDevice: Equatable, Sendable {
    var name: String
    var battery: Int?
}

/// The popover's reads that reach outside the process, and the pure
/// shaping of what they return.
enum MenuBarSystemReadings {
    /// The connected Bluetooth devices, by name — nil unless Bluetooth is
    /// already granted (`CBCentralManager.authorization` reads TCC
    /// without asking), so opening the popover is never the prompt. Read
    /// off the main actor: IOBluetooth's first contact can wait on the
    /// TCC handshake, and that wait once froze the app on main.
    nonisolated static func connectedBluetooth() async -> [MenuBarBluetoothDevice]? {
        guard CBCentralManager.authorization == .allowedAlways else { return nil }
        return await Task.detached(priority: .utility) { () -> [MenuBarBluetoothDevice] in
            let paired = (IOBluetoothDevice.pairedDevices() ?? []).compactMap { $0 as? IOBluetoothDevice }
            return sorted(paired.filter { $0.isConnected() }.map { device in
                MenuBarBluetoothDevice(name: device.name ?? device.addressString ?? "Bluetooth device",
                                       battery: battery(of: device))
            })
        }.value
    }

    /// A device's battery, when it reports one. `batteryPercent` is read
    /// only where a real method returns an object: on 27 a device can
    /// forward the selector with no key behind it, and KVO's exception
    /// cannot be caught in Swift — the notch's announcer learned this.
    nonisolated static func battery(of device: IOBluetoothDevice) -> Int? {
        let selector = NSSelectorFromString("batteryPercent")
        guard let method = class_getInstanceMethod(type(of: device), selector) else { return nil }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard String(cString: returnType).hasPrefix("@") else { return nil }
        return (device.perform(selector)?.takeUnretainedValue() as? NSNumber)
            .map(\.intValue)
            .flatMap { (0...100).contains($0) ? $0 : nil }
    }

    /// The devices in name order — the popover never reshuffles as
    /// connections land.
    nonisolated static func sorted(_ devices: [MenuBarBluetoothDevice]) -> [MenuBarBluetoothDevice] {
        devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The Now Playing row: the track, and who it is by (or the album).
    /// Nil with nothing playing or paused.
    nonisolated static func nowPlaying(_ media: AlcoveMedia?) -> (title: String, detail: String)? {
        guard let media, !media.title.isEmpty else { return nil }
        let detail = [media.artist, media.album].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return (media.title, detail)
    }

    /// Wi-Fi's own settings pane — the popover's Wi-Fi row opens it.
    nonisolated static let wifiSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!
}

/// The combined item's popover model — a snapshot so the view reads
/// one consistent set of values.
@MainActor
@Observable
final class MenuBarSystemModel {
    /// The agents' row: the combined state's word, the detail line, and
    /// the tint the dot wears (nil keeps the label colour).
    struct AgentLine: Equatable {
        var label: String
        var detail: String
        var tintHex: String?
    }

    var batteryText = "—"
    var batteryDetail = ""
    var batteryPercent: Int?
    /// Connected Bluetooth devices; nil until read, or while Bluetooth
    /// is not granted — the popover never asks.
    var bluetooth: [MenuBarBluetoothDevice]?
    /// What is playing, from the notch's one media feed.
    var media: AlcoveMedia?
    var agents: AgentLine?
    @ObservationIgnored var agentLine: @MainActor () -> AgentLine? = { nil }
    @ObservationIgnored private var mediaToken: UUID?
    @ObservationIgnored private var bluetoothRead: Task<Void, Never>?
    var wifiName = "No network"
    var focused = false
    var focusKnown = false
    var volume: Double = 0
    var volumeKnown = false
    var muted = false

    func refresh() {
        let power = AlcovePowerMonitor.read()
        batteryPercent = power.hasBattery ? power.percent : nil
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
        agents = agentLine()
    }

    /// The pane is up: follow what is playing and read the connected
    /// devices. Both stop with the pane.
    func startLive() {
        if mediaToken == nil {
            mediaToken = MediaFeed.shared.subscribe { [weak self] media in self?.media = media }
        }
        bluetoothRead?.cancel()
        bluetoothRead = Task { [weak self] in
            let devices = await MenuBarSystemReadings.connectedBluetooth()
            guard !Task.isCancelled else { return }
            self?.bluetooth = devices
        }
    }

    func stopLive() {
        if let mediaToken { MediaFeed.shared.unsubscribe(mediaToken) }
        mediaToken = nil
        bluetoothRead?.cancel()
        bluetoothRead = nil
    }

    func togglePlayPause() {
        MediaFeed.shared.send(.togglePlayPause)
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
            if let agents = model.agents {
                HStack(spacing: 8) {
                    Circle()
                        .fill(agents.tintHex.flatMap(MenuBarCoverAppearance.tintComponents)
                            .map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? Color.primary)
                        .frame(width: 8, height: 8)
                        .frame(width: 18)
                    Text(agents.label)
                    Spacer()
                    Text(agents.detail)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .accessibilityElement(children: .combine)
                Divider()
            }
            row(symbol: model.batteryDetail == "Charging"
                    ? "battery.100.bolt"
                    : MenuBarCombinedItem.batterySymbol(percent: model.batteryPercent),
                title: model.batteryText, detail: model.batteryDetail)
            Button {
                NSWorkspace.shared.open(MenuBarSystemReadings.wifiSettingsURL)
            } label: {
                row(symbol: "wifi", title: model.wifiName, detail: "Wi-Fi")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Wi-Fi settings")
            if let devices = model.bluetooth, !devices.isEmpty {
                ForEach(devices, id: \.name) { device in
                    row(symbol: "dot.radiowaves.left.and.right", title: device.name,
                        detail: device.battery.map { "\($0)%" } ?? "Connected")
                }
            }
            if model.focusKnown {
                row(symbol: "moon.fill", title: model.focused ? "Focus on" : "Focus off",
                    detail: "")
            }
            if let playing = MenuBarSystemReadings.nowPlaying(model.media) {
                HStack(spacing: 8) {
                    Button { model.togglePlayPause() } label: {
                        Image(systemName: model.media?.playing == true ? "pause.fill" : "play.fill")
                            .frame(width: 18)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.media?.playing == true ? "Pause" : "Play")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(playing.title)
                            .lineLimit(1)
                        if !playing.detail.isEmpty {
                            Text(playing.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
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
        .onAppear { model.startLive() }
        .onDisappear { model.stopLive() }
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
