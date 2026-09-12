import AppKit
import JRBarCore
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

    private var device: SettingsStore.DeviceEntry? { store.deviceEntries.first { $0.id == deviceID } }
    private var isScreenBar: Bool { deviceID == "virtual:status-bar" || device?.kind == "screen_bar" }
    private var deviceName: String { device?.name ?? (isScreenBar ? "Screen Bar" : deviceID) }

    /// A connected strip to match a Dot against -- the whole point of the
    /// companion preview is "the Dot tends to be brighter", so the option
    /// only exists where there is something to meet.
    private var stripPresent: Bool { store.core.devices.contains { $0.kind == "pro" && $0.isPresent } }
    private var canMatchStrip: Bool { device?.kind == "dot" && stripPresent && !isScreenBar }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Calibrate \(deviceName)").font(.title3.weight(.semibold))
                Text("The device is showing the patch below. Hold it beside the screen and match it by eye.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(patchColor)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .frame(height: 56)
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
                    Text("Matched").font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Does the light look white?")
                        HStack(spacing: 6) {
                            // fixedSize: these are the corrections, not
                            // decoration -- a truncated "Too mage…" is a
                            // button the user cannot read.
                            Button("Too warm") { nudge(.cooler) }.fixedSize()
                            Button("Too cool") { nudge(.warmer) }.fixedSize()
                            Button("Too green") { nudge(.lessGreen) }.fixedSize()
                            Button("Too magenta") { nudge(.greener) }.fixedSize()
                            Spacer()
                            Button("Looks white") { whiteMatched = true }
                                .buttonStyle(.borderedProminent)
                                .fixedSize()
                        }
                    }
                }
            }

            DisclosureGroup("Fine-tune by eye", isExpanded: $fineTuneExpanded) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    gainRow("Red", value: $model.red, tint: .red)
                    gainRow("Green", value: $model.green, tint: .green)
                    gainRow("Blue", value: $model.blue, tint: .blue)
                    GridRow {
                        Text("1.00 is the die as shipped; below dims the channel, above boosts a weak one.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .gridCellColumns(3)
                    }
                    GridRow {
                        Text("Resting glow")
                        Slider(value: $model.glow, in: CalibrationModel.glowRange)
                        ValueText(text: SettingsStore.percent(model.glow), width: 48)
                    }
                    GridRow {
                        Text("Brightness")
                        Slider(value: $model.brightness, in: 0...1)
                        ValueText(text: SettingsStore.percent(model.brightness), width: 48)
                    }
                }
                if canMatchStrip {
                    Toggle(isOn: $companion) {
                        SettingLabel(title: "Match the strip",
                                     subtitle: "Lights the strip with the same patch at its own settings so you can bring the Dot down to meet it.")
                    }
                }
            }

            HStack {
                Toggle("Compare with before", isOn: $comparing).toggleStyle(.button)
                Button("Reset to default") { model.reset() }
                Spacer()
                Button("Cancel") { endPreview(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    // Awaited so a `not_found` (the device went away
                    // mid-sheet) is reported instead of looking applied.
                    Task { [weak store] in
                        guard let store else { return }
                        do {
                            let reply = try await store.core.applyCalibrationNow(device: deviceID, profile: model.profileArguments())
                            if reply.ok {
                                endPreview()
                                dismiss()
                            } else {
                                store.report(error: reply.error?.message ?? reply.error?.code ?? "Apply refused")
                            }
                        } catch {
                            store.report(error: "Apply failed: \(error)")
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isDirty)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear(perform: load)
        .onDisappear { endPreview() }
        .onChange(of: model) { _, _ in schedulePreview() }
        .onChange(of: comparing) { _, _ in schedulePreview() }
        .onChange(of: companion) { _, _ in schedulePreview() }
    }

    /// The nominal patch -- what the device SHOULD look like, so it is never
    /// tinted by the working gains.
    private var patchColor: Color {
        let swatch = model.patch.swatch
        return Color(red: swatch.r, green: swatch.g, blue: swatch.b)
    }

    private func gainRow(_ title: String, value: Binding<Double>, tint: Color) -> some View {
        GridRow {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(title)
            }
            Slider(value: value, in: CalibrationModel.gainRange)
            ValueText(text: String(format: "%.2f", value.wrappedValue), width: 48)
        }
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
