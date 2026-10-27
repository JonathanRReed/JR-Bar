import Foundation
import JRBarCore
import JRBarLEDS
import Observation

struct StudioMix: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let parameters: [Parameter]

    struct Parameter: Decodable, Hashable {
        let key: String
        let type: String
        let minimum: Double
        let maximum: Double
        let `default`: Double

        var control: EffectParameter {
            EffectParameter(name: key, type: type == "integer" ? .integer : .number,
                            defaultValue: .number(`default`), minimum: minimum, maximum: maximum,
                            unit: key == "duration_seconds" ? "seconds" : nil)
        }
    }
}

struct StudioLightPlan: Decodable, Hashable {
    let mixes: [StudioMix]
    let devices: [Device]

    struct Device: Decodable, Hashable, Identifiable {
        var id: String { device }
        let device: String
        let ledCount: Int
        let requestedMix: String
        let played: String
        let reason: String
        let warnings: [String]
        let program: String
        let cueReason: String?

        @MainActor var playbackWarnings: [String] {
            StudioFleetPreview.playbackWarnings(warnings, program: program, ledCount: ledCount) + [StudioFleetPreview.motionNotice(played: played, program: program, ledCount: ledCount)].compactMap { $0 }
        }

        enum CodingKeys: String, CodingKey {
            case device, played, reason, warnings, program
            case ledCount = "led_count", requestedMix = "requested_mix", cueReason = "cue_reason"
        }
    }
}

struct StudioFleetPreview: Decodable, Hashable {
    let program: String
    let label: String
    let played: String
    let reason: String
    let warnings: [String]
    let ledCount: Int
    enum CodingKeys: String, CodingKey {
        case program, label, played, reason, warnings
        case ledCount = "led_count"
    }

    static func playbackCycle(program: String, ledCount: Int) -> String? {
        guard let parsed = try? LEDSProgram.parse(program, ledCount: ledCount),
              let duration = LEDSSampler(program: parsed, ledCount: ledCount).cycleDuration else { return nil }
        return String(format: "%.3f s / loop", duration)
    }

    static func playbackWarnings(_ warnings: [String], program: String, ledCount: Int) -> [String] {
        var result = warnings.map(StudioWarning.plain)
        if warnings.contains(where: { $0.contains("cadence_clamped") }),
           let parsed = try? LEDSProgram.parse(program, ledCount: ledCount),
           let duration = LEDSSampler(program: parsed, ledCount: ledCount).cycleDuration {
            result.append(String(format: "Playing a %.2f s cycle.", duration))
        }
        return result
    }

    @MainActor var motionNotice: String? { Self.motionNotice(played: played, program: program, ledCount: ledCount) }

    @MainActor static func motionNotice(played: String, program: String, ledCount: Int) -> String? {
        let names = ["classic": "Status only", "color_blend": "Smooth"]
        guard let name = names[played],
              let sampler = LEDPreviewSamplers.sampler(for: program, ledCount: ledCount), !sampler.isStatic else { return nil }
        return "\(name) still moves the state light."
    }

    @MainActor var playbackWarnings: [String] {
        Self.playbackWarnings(warnings, program: program, ledCount: ledCount) + [motionNotice].compactMap { $0 }
    }
}

/// Caches daemon programs across window sessions. Opening Studio never plays hardware.
@MainActor
@Observable
final class EffectStudioLights {
    enum Scenario: String, CaseIterable, Identifiable {
        case live, one = "one_working", two = "pair", three = "fleet", ask = "one_needs_you"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .live: "Live"
            case .one: "1 provider"
            case .two: "2"
            case .three: "3"
            case .ask: "An ask"
            }
        }
    }

    let core: CoreModel
    let settings: SettingsStore
    private let ownsSettings: Bool
    var scenario: Scenario = .three
    var playOnDevices = true
    var inspector = false
    private(set) var playing = false
    private(set) var playFailure: String?
    private(set) var auditions: [String: StudioFleetPreview] = [:]
    @ObservationIgnored private var playTask: Task<Void, Never>?
    @ObservationIgnored private var playRevision = 0
    private(set) var providerPrograms: [String: String] = [:]
    private(set) var cues: [String: LightCueState]?
    private(set) var supportingFailure: String?
    private(set) var plan: StudioLightPlan?
    private(set) var previews: [String: StudioFleetPreview] = [:]
    private(set) var failure: String?
    private(set) var planFailure: String?
    private(set) var refreshing = false
    @ObservationIgnored private var completedPreviewKey: String?
    @ObservationIgnored private var completedSupportingKey: String?
    @ObservationIgnored private var previewRevision = 0
    @ObservationIgnored private var supportingRevision = 0
    @ObservationIgnored var requestProvider: ((String) async throws -> String)?
    @ObservationIgnored var requestCues: (() async throws -> LightCueList)?
    @ObservationIgnored private var planRevision = 0
    @ObservationIgnored var requestPlan: (() async throws -> StudioLightPlan)?
    @ObservationIgnored var requestPreview: ((String, String) async throws -> StudioFleetPreview)?

    init(core: CoreModel, settings: SettingsStore? = nil) {
        self.core = core
        ownsSettings = settings == nil
        self.settings = settings ?? SettingsStore(core: core)
    }

    func windowDidClose() {
        playRevision += 1
        playTask?.cancel()
        playTask = nil
        playing = false
        cancelReads()
        if ownsSettings { settings.settingsWindowDidClose() }
    }

    var mix: String { settings.values.string("colors.blend_mode") ?? "color_blend" }
    var previewKey: String {
        let catalog = plan?.mixes.map(\.id).joined(separator: ",") ?? ""
        return "\(core.isLive)-\(settings.settingsRevision)-\(scenario.rawValue)-\(catalog)"
    }
    private func cacheKey(_ mode: String) -> String { "\(scenario.rawValue)|\(mode)" }
    func preview(_ mode: String) -> StudioFleetPreview? { previews[cacheKey(mode)] }
    var selectedPreview: StudioFleetPreview? { preview(mix) }
    var liveStrip: StudioLightPlan.Device? {
        plan?.devices.first { $0.ledCount == 8 && $0.device != "virtual:status-bar" }
            ?? plan?.devices.first { $0.ledCount == 8 }
    }
    var screenProgram: String? {
        scenario == .live ? plan?.devices.first { $0.device == "virtual:status-bar" }?.program : selectedPreview?.program
    }
    var program: String? { scenario == .live ? liveStrip?.program : selectedPreview?.program }
    var playbackCycle: String? {
        guard let program else { return nil }
        let count = scenario == .live ? liveStrip?.ledCount : selectedPreview?.ledCount
        return StudioFleetPreview.playbackCycle(program: program, ledCount: count ?? 8)
    }


    func deviceName(_ id: String) -> String {
        if id == "virtual:status-bar" { return "Screen Bar" }
        if let device = settings.deviceEntries.first(where: { $0.id == id }) { return device.name }
        if let device = core.devices.first(where: { $0.id == id }) {
            return device.name ?? (device.kind == "dot" ? "PulseDot" : "SidePulse Pro")
        }
        return id
    }

    func refreshPlan() async {
        guard core.isLive, !Task.isCancelled else { return }
        planRevision += 1
        let revision = planRevision
        do {
            let result: StudioLightPlan
            if let requestPlan { result = try await requestPlan() }
            else { result = try await core.request("what_plays", as: StudioLightPlan.self) }
            guard revision == planRevision, !Task.isCancelled else { return }
            plan = result
            planFailure = nil
        } catch {
            guard revision == planRevision, !Task.isCancelled else { return }
            planFailure = "Light plan unavailable: \(EffectStudioStore.describe(error))"
        }
    }

    func refreshPreviews() async {
        let key = previewKey
        guard core.isLive, !Task.isCancelled, key != completedPreviewKey else { return }
        auditions = [:]
        previewRevision += 1
        let revision = previewRevision
        let scenario = self.scenario == .live ? Scenario.three.rawValue : self.scenario.rawValue
        let prefix = self.scenario.rawValue
        refreshing = true
        defer { if revision == previewRevision { refreshing = false } }
        do {
            // The selected program arrives first; cards follow without holding up the stage.
            let modes = [mix] + (plan?.mixes.map(\.id) ?? []).filter { $0 != mix }
            for mode in modes {
                let result: StudioFleetPreview
                if let requestPreview { result = try await requestPreview(scenario, mode) }
                else {
                    result = try await core.request("preview_fleet", args: [
                        "scenario": .string(scenario), "blend_mode": .string(mode), "led_count": .number(8),
                    ], as: StudioFleetPreview.self)
                }
                guard revision == previewRevision, !Task.isCancelled else { return }
                previews["\(prefix)|\(mode)"] = result
            }
            failure = nil
            completedPreviewKey = key
        } catch {
            guard revision == previewRevision, !Task.isCancelled else { return }
            failure = "Preview unavailable: \(EffectStudioStore.describe(error))"
        }
    }

    func refreshSupportingPreviews() async {
        let key = "\(core.isLive)-\(settings.settingsRevision)"
        guard core.isLive, !Task.isCancelled, key != completedSupportingKey else { return }
        supportingRevision += 1
        let revision = supportingRevision
        do {
            let list: LightCueList
            if let requestCues { list = try await requestCues() }
            else { list = try await core.request("list_cues", as: LightCueList.self) }
            guard revision == supportingRevision, !Task.isCancelled else { return }
            cues = Dictionary(list.cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for provider in SettingsKey.providers where provider != "t3code" {
                let program: String
                if let requestProvider { program = try await requestProvider(provider) }
                else {
                    let result = try await core.request("preview_provider_motion", args: ["provider": .string(provider), "led_count": .number(8)],
                                                        as: EffectPreview.self)
                    program = result.program
                }
                guard revision == supportingRevision, !Task.isCancelled else { return }
                providerPrograms[provider] = program
            }
            supportingFailure = nil
            completedSupportingKey = key
        } catch {
            guard revision == supportingRevision, !Task.isCancelled else { return }
            supportingFailure = "Provider previews or cues unavailable: \(EffectStudioStore.describe(error))"
        }
    }

    @discardableResult
    func playPreview() -> Task<Void, Never>? {
        guard core.isLive, scenario != .live, failure == nil, !refreshing, !playing, program != nil else { return nil }
        let devices = playOnDevices ? core.devices.filter { $0.isPresent && ($0.kind == "pro" || $0.kind == "dot") } : []
        let scenario = self.scenario
        let sourceKey = previewKey
        playing = true
        playFailure = nil
        auditions = [:]
        playRevision += 1
        let revision = playRevision
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if revision == self.playRevision { self.playing = false; self.playTask = nil } }
            do {
                let screen = try await self.core.request("preview_fleet", args: [
                    "scenario": .string(scenario.rawValue), "device": .string("virtual:status-bar"),
                    "led_count": .number(8),
                ], as: StudioFleetPreview.self)
                guard revision == self.playRevision, sourceKey == self.previewKey, !Task.isCancelled else { return }
                self.auditions["Screen Bar"] = screen
                var programs = [("screen_bar", screen.program)]
                for device in devices {
                    let preview = try await self.core.request("preview_fleet", args: [
                        "scenario": .string(scenario.rawValue), "device": .string(device.id),
                        "led_count": .number(Double(device.kind == "dot" ? 2 : 8)),
                    ], as: StudioFleetPreview.self)
                    guard revision == self.playRevision, sourceKey == self.previewKey, !Task.isCancelled else { return }
                    self.auditions[device.name ?? device.id] = preview
                    programs.append((device.id, preview.program))
                }
                for (surface, source) in programs {
                    guard revision == self.playRevision, sourceKey == self.previewKey, !Task.isCancelled else { return }
                    let reply = try await self.core.previewProgramNow(surface: surface, program: source, seconds: 5)
                    guard reply.ok else { throw reply.error ?? CoreReplyError(code: "refused") }
                }
            } catch {
                guard revision == self.playRevision, sourceKey == self.previewKey, !Task.isCancelled else { return }
                self.playFailure = "Preview failed: \(EffectStudioStore.describe(error))"
            }
        }
        playTask = task
        return task
    }

    func cancelReads() {
        planRevision += 1
        previewRevision += 1
        supportingRevision += 1
        refreshing = false
    }
}
