import AppKit
import JRBarCore
import Observation
import SwiftUI

// MARK: - Calibration

/// The guided calibration sheet: a truthful nominal patch on screen, the
/// same patch on the device through the WORKING values (the daemon applies
/// them through the live write boundary -- the old sheet baked gains into a
/// hex and then had the stored gains applied on top, so it previewed
/// neither profile), and a white-balance question that resolves most
/// devices without a slider ever moving. Nothing persists until Apply;
/// the preview is held daemon-side for as long as the sheet is open.
struct CalibrationSheet: View {
    @Bindable var store: SettingsStore
    let deviceID: String
    let dismiss: () -> Void

    @ViewState private var model = CalibrationModel()
    @ViewState private var loaded = false
    @ViewState private var comparing = false
    @ViewState private var whiteMatched = false
    @ViewState private var companion = false
    @ViewState private var fineTuneExpanded = false
    @ViewState private var previewWork: DispatchWorkItem?
    @ViewState private var submission = CalibrationSubmission()

    init(store: SettingsStore, deviceID: String, dismiss: @escaping () -> Void,
         submission: CalibrationSubmission = CalibrationSubmission(),
         fineTuneExpanded: Bool = false) {
        self.store = store
        self.deviceID = deviceID
        self.dismiss = dismiss
        _submission = ViewState(wrappedValue: submission)
        _fineTuneExpanded = ViewState(wrappedValue: fineTuneExpanded)
    }

    private var device: SettingsStore.DeviceEntry? { store.deviceEntries.first { $0.id == deviceID } }
    private var isScreenBar: Bool { deviceID == "virtual:status-bar" || device?.kind == "screen_bar" }
    private var deviceName: String { device?.name ?? (isScreenBar ? "Screen Bar" : deviceID) }
    /// The header tile's glyph: the band, the Dot or the strip.
    private var deviceSymbol: String {
        if isScreenBar { return "rectangle.topthird.inset.filled" }
        return device?.kind == "dot" ? "circle.grid.2x1.fill" : "light.beacon.max.fill"
    }

    /// A connected strip to match a Dot against -- the whole point of the
    /// companion preview is "the Dot tends to be brighter", so the option
    /// only exists where there is something to meet.
    private var stripPresent: Bool { store.core.devices.contains { $0.kind == "pro" && $0.isPresent } }
    private var canMatchStrip: Bool { device?.kind == "dot" && stripPresent && !isScreenBar }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                calibrationControls
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            calibrationFooter
                .padding(20)
        }
        .frame(minWidth: 320, idealWidth: 540, maxWidth: 540,
               minHeight: 320, idealHeight: 640, maxHeight: 640)
        .disabled(submission.isApplying)
        .interactiveDismissDisabled(submission.isApplying)
        .onAppear(perform: load)
        .onDisappear { endPreview() }
        .onChange(of: model) { _, _ in schedulePreview() }
        .onChange(of: comparing) { _, _ in schedulePreview() }
        .onChange(of: companion) { _, _ in schedulePreview() }
    }

    private var calibrationControls: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.l) {
            HStack(alignment: .center, spacing: SettingsMetrics.m) {
                SettingsIconTile(symbol: deviceSymbol, tint: SettingsStore.Chapter.devices.tint, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calibrate \(deviceName)").font(.title3.weight(.semibold))
                    Text("The device is showing the patch below. Hold it beside the screen and match it by eye.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: SettingsMetrics.s + 2) {
                RoundedRectangle(cornerRadius: SettingsMetrics.panelRadius, style: .continuous)
                    .fill(patchColor)
                    .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.panelRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                    .frame(height: 72)
                    .accessibilityLabel("The \(model.patch.label) patch")
                Picker("Patch", selection: $model.patch) {
                    ForEach(CalibrationModel.Patch.allCases, id: \.self) { patch in
                        Text(patch.label).tag(patch)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if model.patch == .white {
                if whiteMatched {
                    Label("Matched", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: SettingsMetrics.s) {
                        Text("Does the light look white?")
                            .fontWeight(.medium)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 6)], spacing: 6) {
                            Button("Too warm") { nudge(.cooler) }
                            Button("Too cool") { nudge(.warmer) }
                            Button("Too green") { nudge(.lessGreen) }
                            Button("Too magenta") { nudge(.greener) }
                            Button("Looks white") { whiteMatched = true }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(SettingsMetrics.m)
                    .background(InsetPanel())
                }
            }

            DisclosureGroup(isExpanded: $fineTuneExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    gainRow("Red", value: $model.red, tint: .red)
                    gainRow("Green", value: $model.green, tint: .green)
                    gainRow("Blue", value: $model.blue, tint: .blue)
                    Text("1.00 is the die as shipped; below dims the channel, above boosts a weak one.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Text("Resting glow").frame(width: 90, alignment: .leading)
                        Slider(value: $model.glow, in: CalibrationModel.glowRange)
                            .frame(minWidth: 0, maxWidth: .infinity)
                        ValueText(text: SettingsStore.percent(model.glow), width: 48)
                    }
                    HStack(spacing: 12) {
                        Text("Brightness").frame(width: 90, alignment: .leading)
                        Slider(value: $model.brightness, in: 0...1)
                            .frame(minWidth: 0, maxWidth: .infinity)
                        ValueText(text: SettingsStore.percent(model.brightness), width: 48)
                    }
                }
                if canMatchStrip {
                    Toggle(isOn: $companion) {
                        SettingLabel(title: "Match the strip",
                                     subtitle: "Lights the strip with the same patch at its own settings so you can bring the Dot down to meet it.")
                    }
                }
            } label: {
                SettingLabel(title: "Fine-tune by eye",
                             subtitle: "Each channel's gain, the resting glow and the brightness.")
            }
            .disclosureGroupStyle(SettingsDisclosureStyle())
        }
    }

    private var calibrationFooter: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.s) {
            if let error = submission.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: SettingsMetrics.s) { secondaryActions }
                VStack(alignment: .leading, spacing: SettingsMetrics.s) { secondaryActions }
            }
            HStack {
                Spacer()
                Button("Cancel") { endPreview(); dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    // Awaited so a `not_found` (the device went away
                    // mid-sheet) is reported instead of looking applied.
                    let profile = model.profileArguments()
                    previewWork?.cancel()
                    previewWork = nil
                    Task { [store] in
                        let saved = await submission.apply {
                            try await store.core.applyCalibrationNow(device: deviceID, profile: profile)
                        }
                        if saved {
                            endPreview()
                            dismiss()
                        }
                    }
                } label: {
                    if submission.isApplying {
                        DelayedWait { Text("Apply") }
                    } else {
                        Text("Apply")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isDirty || !store.core.isLive)
            }
        }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        Toggle("Compare with before", isOn: $comparing).toggleStyle(.button)
        Button("Reset to default") { model.reset() }
        if !startingPoints.isEmpty {
            Menu("Start from") {
                ForEach(startingPoints) { point in
                    Button(point.title) { start(from: point) }
                }
            }
            .fixedSize()
            .help("Begin from a look you already have instead of from scratch")
        }
    }

    /// The nominal patch -- what the device SHOULD look like, so it is never
    /// tinted by the working gains.
    private var patchColor: Color {
        let swatch = model.patch.swatch
        return Color(red: swatch.r, green: swatch.g, blue: swatch.b)
    }

    private func gainRow(_ title: String, value: Binding<Double>, tint: Color) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(tint.gradient).frame(width: 9, height: 9)
                Text(title)
            }
            .frame(width: 90, alignment: .leading)
            Slider(value: value, in: CalibrationModel.gainRange)
                .tint(tint)
                .frame(minWidth: 0, maxWidth: .infinity)
            ValueText(text: String(format: "%.2f", value.wrappedValue), width: 48)
        }
    }

    /// Looks this device can start from: another strip or Dot's white
    /// balance (the same LEDs behind the same diffuser), and this device's
    /// own saved Day, Night or Travel profile.
    private var startingPoints: [CalibrationStartingPoint] {
        guard !isScreenBar else { return [] }
        let entries = store.deviceEntries.map { entry in
            (id: entry.id, name: entry.name, kind: entry.kind,
             fields: store.document.deviceEntries.first { $0.id == entry.id }?.entry ?? [:])
        }
        return CalibrationStartingPoint.options(for: deviceID, devices: entries, document: store.document)
    }

    private func start(from point: CalibrationStartingPoint) {
        whiteMatched = false
        model.red = CalibrationStartingPoint.clampGain(point.red)
        model.green = CalibrationStartingPoint.clampGain(point.green)
        model.blue = CalibrationStartingPoint.clampGain(point.blue)
        if let brightness = point.brightness { model.brightness = min(1, max(0, brightness)) }
        if let glow = point.glow { model.glow = min(CalibrationModel.glowRange.upperBound, max(CalibrationModel.glowRange.lowerBound, glow)) }
    }

    private func nudge(_ nudge: CalibrationModel.Nudge) {
        // A correction after "Looks white" means it did not: the caption
        // would be claiming a match the user just unmade.
        whiteMatched = false
        model.nudge(nudge)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let doc = store.document
        if let prefix = device?.prefix {
            model = CalibrationModel(
                red: doc.double(SettingsPath("\(prefix).red_gain")) ?? 1,
                green: doc.double(SettingsPath("\(prefix).green_gain")) ?? 1,
                blue: doc.double(SettingsPath("\(prefix).blue_gain")) ?? 1,
                glow: doc.double(SettingsPath("\(prefix).resting_glow")) ?? 0,
                brightness: (doc.double(SettingsPath("\(prefix).brightness")) ?? 255) / 255.0
            )
        }
        // A Dot beside its strip starts in match mode: brightness is the
        // correction it most often needs.
        companion = canMatchStrip
        // Screenshot affordance alongside the JRBAR_OPEN_* switches: opens
        // the disclosure without a click.
        if ProcessInfo.processInfo.environment["JRBAR_CALIBRATE_FINE_TUNE"] == "1" {
            fineTuneExpanded = true
        }
        sendPreview()
    }

    /// The values the preview must show: the working model normally, the
    /// original profile while comparing -- same patch either way.
    private var previewed: CalibrationModel {
        guard comparing else { return model }
        var shown = model
        shown.red = model.original.red
        shown.green = model.original.green
        shown.blue = model.original.blue
        shown.glow = model.original.glow
        shown.brightness = model.original.brightness
        return shown
    }

    private func sendPreview() {
        // Awaited so a refusal (the device vanished, the daemon is busy)
        // is said out loud instead of the header claiming a lit patch.
        Task { [weak store] in
            guard let store else { return }
            do {
                let reply = try await store.core.previewCalibrationNow(
                    args: previewed.previewArguments(device: deviceID, companion: canMatchStrip && companion)
                )
                if !reply.ok {
                    store.report(error: reply.error?.message ?? reply.error?.code ?? "Preview refused")
                }
            } catch {
                store.report(error: "Preview failed: \(error)")
            }
        }
    }

    /// Every edit re-previews, debounced: the hold is daemon-side, so this
    /// only re-sends when the numbers actually changed.
    private func schedulePreview() {
        guard loaded else { return }
        previewWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { sendPreview() }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func endPreview() {
        // A debounced preview still queued would fire after the end and
        // re-hold the patch for ten minutes with the sheet gone.
        previewWork?.cancel()
        previewWork = nil
        store.core.endCalibrationPreview(device: deviceID)
    }
}

/// One save at a time, with a refusal kept inside the calibration sheet.
@MainActor
@Observable
final class CalibrationSubmission {
    private(set) var isApplying = false
    private(set) var error: String?

    func apply(_ operation: @MainActor () async throws -> CoreReply) async -> Bool {
        guard !isApplying else { return false }
        isApplying = true
        error = nil
        defer { isApplying = false }
        do {
            let reply = try await operation()
            guard reply.ok else {
                error = reply.error?.message ?? reply.error?.code ?? "Apply refused"
                return false
            }
            return true
        } catch {
            self.error = "Apply failed: \(error)"
            return false
        }
    }
}

/// Where a calibration can begin besides the die as shipped — Ambilight
/// offers presets for the wall behind the set; the honest version here is
/// looks this Mac already has. Another strip's or Dot's white balance is
/// the same LEDs behind the same diffuser, so its gains are a fair first
/// guess (not its brightness or glow, which are that device's own). A
/// saved profile's entry for this very device brings back all of it.
/// The Screen Bar is a display, not a die: nothing carries across.
struct CalibrationStartingPoint: Identifiable, Equatable {
    let id: String
    let title: String
    let red: Double
    let green: Double
    let blue: Double
    /// 0…1, when the starting point carries a level.
    let brightness: Double?
    let glow: Double?

    static func options(for deviceID: String,
                        devices: [(id: String, name: String, kind: String, fields: [String: JSONValue])],
                        document: SettingsDocument) -> [CalibrationStartingPoint] {
        var options: [CalibrationStartingPoint] = []
        for device in devices where device.id != deviceID && (device.kind == "pro" || device.kind == "dot") {
            let red = device.fields["red_gain"]?.doubleValue ?? 1
            let green = device.fields["green_gain"]?.doubleValue ?? 1
            let blue = device.fields["blue_gain"]?.doubleValue ?? 1
            guard red != 1 || green != 1 || blue != 1 else { continue }
            options.append(CalibrationStartingPoint(
                id: "device:\(device.id)",
                title: "\(device.name)'s white balance",
                red: red, green: green, blue: blue, brightness: nil, glow: nil))
        }
        let profiles = document.object("calibration_profiles") ?? [:]
        for slot in LightProfiles.savedSlots(in: document) {
            guard let saved = profiles[slot]?[deviceID]?.objectValue else { continue }
            options.append(CalibrationStartingPoint(
                id: "profile:\(slot)",
                title: "The \(slot) profile",
                red: saved["red_gain"]?.doubleValue ?? 1,
                green: saved["green_gain"]?.doubleValue ?? 1,
                blue: saved["blue_gain"]?.doubleValue ?? 1,
                brightness: saved["brightness"]?.doubleValue.map { $0 / 255 },
                glow: saved["resting_glow"]?.doubleValue))
        }
        return options
    }

    static func clampGain(_ value: Double) -> Double {
        min(CalibrationModel.gainRange.upperBound, max(CalibrationModel.gainRange.lowerBound, value))
    }
}
