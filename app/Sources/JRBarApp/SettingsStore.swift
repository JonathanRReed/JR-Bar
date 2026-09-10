import AppKit
import JRBarCore
import Observation
import ServiceManagement
import SwiftUI

/// The Settings window's state. The daemon's document is the only source of
/// truth; this store overlays the edits it has sent and not yet seen echoed,
/// so a slider does not snap back between the write and the next `settings`
/// message, and turns paths into SwiftUI bindings.
@MainActor
@Observable
final class SettingsStore {
    enum Page: String, CaseIterable, Identifiable, Hashable {
        case general, agents, usage, devices, lighting, notifications, remote, advanced

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .agents: return "Agents"
            case .usage: return "Usage"
            case .devices: return "Devices & Screen Bar"
            case .lighting: return "Lighting"
            case .notifications: return "Notifications & Focus"
            case .remote: return "Remote"
            case .advanced: return "Advanced"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .agents: return "person.2.fill"
            case .usage: return "chart.bar.fill"
            case .devices: return "light.beacon.max.fill"
            case .lighting: return "paintpalette.fill"
            case .notifications: return "bell.badge.fill"
            case .remote: return "antenna.radiowaves.left.and.right"
            case .advanced: return "wrench.and.screwdriver.fill"
            }
        }

        /// System Settings tints every sidebar icon; these follow its palette.
        var tint: Color {
            switch self {
            case .general: return Color(nsColor: .systemGray)
            case .agents: return Color(nsColor: .systemBlue)
            case .usage: return Color(nsColor: .systemGreen)
            case .devices: return Color(nsColor: .systemOrange)
            case .lighting: return Color(nsColor: .systemPink)
            case .notifications: return Color(nsColor: .systemRed)
            case .remote: return Color(nsColor: .systemTeal)
            case .advanced: return Color(nsColor: .systemGray)
            }
        }

        var catalogue: SettingsKey.Page { SettingsKey.Page(rawValue: rawValue)! }
    }

    let core: CoreModel
    var page: Page = .general
    /// Lighting › Effects… opens the Effect Studio window.
    var onOpenEffects: (@MainActor () -> Void)?
    var calibrating: String?
    var doctorReport: JSONValue?
    var doctorRunning = false
    var lastError: String?
    var resetTarget: Page?
    var pendingWrites = 0
    /// Software-update channel: an app concern (there is no updater yet), kept in user defaults.
    var updateChannel: String = UserDefaults.standard.string(forKey: "updateChannel") ?? "stable" {
        didSet { UserDefaults.standard.set(updateChannel, forKey: "updateChannel") }
    }
    var launchAtLogin: Bool = false
    var launchAtLoginError: String?

    @ObservationIgnored private var pending: [String: JSONValue] = [:]
    @ObservationIgnored private var throttles: [String: DispatchWorkItem] = [:]
    @ObservationIgnored private var errorClear: DispatchWorkItem?
    /// Bumped whenever the overlay changes so observers re-read.
    private var overlayVersion = 0

    init(core: CoreModel) {
        self.core = core
        refreshLaunchAtLogin()
    }

    // MARK: Document

    /// The daemon's document with unsent-or-unechoed edits applied.
    var document: SettingsDocument {
        _ = overlayVersion
        var document = SettingsDocument(core.settings?.document ?? .object([:]))
        for (path, value) in pending {
            document = document.replacing(SettingsPath(path), with: value)
        }
        return document
    }

    var hasDocument: Bool { core.settings != nil }
    var generation: Int { core.settings?.generation ?? 0 }

    func isProvided(_ path: String) -> Bool {
        _ = overlayVersion
        return SettingsDocument(core.settings?.document ?? .object([:])).contains(SettingsPath(path))
    }

    func value(_ path: String) -> JSONValue? { document.value(at: SettingsPath(path)) }

    // MARK: Writes

    /// Sends `set_setting`. `throttled` coalesces a slider's stream into one
    /// write every 120 ms, the last value always winning.
    func set(_ path: String, _ value: JSONValue, throttled: Bool = false) {
        pending[path] = value
        overlayVersion += 1
        throttles[path]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush(path) }
        }
        throttles[path] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (throttled ? 0.12 : 0), execute: work)
    }

    private func flush(_ path: String) {
        throttles[path] = nil
        guard let value = pending[path] else { return }
        pendingWrites += 1
        Task { [weak self] in
            guard let self else { return }
            defer { self.pendingWrites -= 1 }
            do {
                let reply = try await self.core.setSetting(SettingsPath(path), value: value)
                if !reply.ok {
                    self.report(error: reply.error?.message ?? "\(path): refused (\(reply.error?.code ?? "error"))")
                    self.dropPending(path)
                } else {
                    self.settlePending(path, value: value)
                }
            } catch {
                self.report(error: "\(path): \(error)")
                self.dropPending(path)
            }
        }
    }

    /// Once the daemon's document carries the value, the overlay is not
    /// needed; if the echo is late, give it a moment rather than snapping.
    private func settlePending(_ path: String, value: JSONValue) {
        let echoed = SettingsDocument(core.settings?.document ?? .object([:])).value(at: SettingsPath(path)) == value
        if echoed || throttles[path] != nil {
            if echoed { dropPending(path, ifStill: value) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            MainActor.assumeIsolated { self?.dropPending(path, ifStill: value) }
        }
    }

    private func dropPending(_ path: String, ifStill value: JSONValue? = nil) {
        if let value, pending[path] != value { return }
        pending[path] = nil
        overlayVersion += 1
    }

    func report(error: String) {
        lastError = error
        errorClear?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.lastError = nil } }
        errorClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    // MARK: Bindings

    func bool(_ path: String, default fallback: Bool = false) -> Binding<Bool> {
        Binding(
            get: { self.document.bool(SettingsPath(path)) ?? fallback },
            set: { self.set(path, .bool($0)) }
        )
    }

    func double(_ path: String, default fallback: Double = 0, throttled: Bool = true) -> Binding<Double> {
        Binding(
            get: { self.document.double(SettingsPath(path)) ?? fallback },
            set: { self.set(path, .number($0), throttled: throttled) }
        )
    }

    func int(_ path: String, default fallback: Int = 0) -> Binding<Int> {
        Binding(
            get: { self.document.int(SettingsPath(path)) ?? fallback },
            set: { self.set(path, .number(Double($0))) }
        )
    }

    func string(_ path: String, default fallback: String = "") -> Binding<String> {
        Binding(
            get: { self.document.string(SettingsPath(path)) ?? fallback },
            set: { self.set(path, .string($0)) }
        )
    }

    /// A string that may be JSON null (`provider_pin`, `signal_policy`);
    /// `nilToken` stands for null in a picker.
    func optionalString(_ path: String, nilToken: String = "") -> Binding<String> {
        Binding(
            get: { self.document.string(SettingsPath(path)) ?? nilToken },
            set: { self.set(path, $0 == nilToken ? .null : .string($0)) }
        )
    }

    func stringList(_ path: String) -> Binding<[String]> {
        Binding(
            get: { self.document.strings(SettingsPath(path)) ?? [] },
            set: { self.set(path, .array($0.map(JSONValue.string))) }
        )
    }

    /// Membership of `item` in a string list as a toggle.
    func listMember(_ path: String, _ item: String) -> Binding<Bool> {
        Binding(
            get: { (self.document.strings(SettingsPath(path)) ?? []).contains(item) },
            set: { on in
                var items = self.document.strings(SettingsPath(path)) ?? []
                if on, !items.contains(item) { items.append(item) }
                if !on { items.removeAll { $0 == item } }
                self.set(path, .array(items.map(JSONValue.string)))
            }
        )
    }

    /// A nullable number as (automatic, value) for the geometry rows.
    func isNull(_ path: String) -> Bool {
        guard let value = document.value(at: SettingsPath(path)) else { return true }
        return value.isNull
    }

    /// A hex colour string as a SwiftUI `Color`.
    func color(_ path: String, default fallback: String) -> Binding<Color> {
        Binding(
            get: {
                let hex = self.document.string(SettingsPath(path)) ?? fallback
                return Color(nsColor: NSColor(hex: hex) ?? .gray)
            },
            set: { color in
                guard let hex = NSColor(color).hexString else { return }
                self.set(path, .string(hex), throttled: true)
            }
        )
    }

    /// Minutes since midnight as a `Date` for `DatePicker`.
    func minutesOfDay(_ path: String, default fallback: Int) -> Binding<Date> {
        Binding(
            get: {
                let minutes = self.document.int(SettingsPath(path)) ?? fallback
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                self.set(path, .number(Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))))
            }
        )
    }

    // MARK: Devices

    struct DeviceEntry: Identifiable {
        let index: Int
        let id: String
        let name: String
        let kind: String
        var prefix: String { "devices.\(index)" }
    }

    /// Devices from the settings document, kind resolved through the
    /// state's device list when the document does not say.
    var deviceEntries: [DeviceEntry] {
        let known = Dictionary(core.devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return document.deviceEntries.map { index, id, entry in
            let state = known[id]
            let name = entry["name"]?.stringValue ?? state?.name ?? id
            let kind = state?.kind ?? Self.guessKind(id: id, name: name)
            return DeviceEntry(index: index, id: id, name: name, kind: kind)
        }
    }

    private static func guessKind(id: String, name: String) -> String {
        let text = (id + " " + name).lowercased()
        if text.contains("dot") { return "dot" }
        if text.contains("pro") || text.contains("sidepulse") { return "pro" }
        return "unknown"
    }

    func stateDevice(_ id: String) -> CoreDevice? { core.devices.first { $0.id == id } }

    // MARK: Hooks

    func hookStatus(_ provider: String) -> String? {
        core.state?.health?["hooks"]?[provider]?.stringValue
    }

    // MARK: Actions

    func runDoctor() {
        doctorRunning = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.doctorRunning = false }
            do {
                let reply = try await self.core.doctor()
                self.doctorReport = reply.ok ? (reply.result ?? .object([:])) : .object(["error": .string(reply.error?.message ?? "doctor failed")])
            } catch {
                self.doctorReport = .object(["error": .string("\(error)")])
            }
        }
    }

    func resetPage(_ page: Page) {
        let paths = SettingsKey.resetPaths(on: page.catalogue, in: SettingsDocument(core.settings?.document ?? .object([:])))
        guard !paths.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.core.resetSettings(paths: paths)
                if !reply.ok { self.report(error: reply.error?.message ?? "reset refused") }
            } catch {
                self.report(error: "reset: \(error)")
            }
        }
    }

    func revealStateFolder() {
        let directory = (core.socketPath as NSString).deletingLastPathComponent
        let url = URL(fileURLWithPath: directory)
        if FileManager.default.fileExists(atPath: directory) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    // MARK: Launch at login

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }
}

extension NSColor {
    /// `#RRGGBB` in sRGB, the form the settings document stores.
    var hexString: String? {
        guard let srgb = usingColorSpace(.sRGB) else { return nil }
        let r = Int((srgb.redComponent * 255).rounded()), g = Int((srgb.greenComponent * 255).rounded()), b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}
