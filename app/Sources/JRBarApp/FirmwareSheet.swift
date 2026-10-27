import JRBarUI
import JRBarCore
import SwiftUI

/// The sheet Settings raises for a firmware update: what will happen, then
/// the update as it runs, then how it ended. It is the only place an update
/// can be started, and it cannot be closed by accident while one runs.
struct FirmwareSheet: View {
    @Bindable var store: SettingsStore

    var body: some View {
        FirmwareSheetContent(
            firmware: store.firmware,
            fallbackName: fallbackName,
            isLive: store.isLive,
            stateJob: store.core.firmware,
            onCalibrate: calibrate
        )
    }

    private var fallbackName: String {
        let id = store.firmware.sheetSettingsID
        return store.deviceEntries.first { $0.id == id }?.name ?? "SidePulse"
    }

    /// Closes the sheet, then opens the existing calibration sheet for the
    /// same device. Two sheets cannot share the window, so the second waits
    /// a beat for the first to leave.
    private func calibrate() {
        guard let id = store.firmware.sheetSettingsID else { return }
        guard store.firmware.closeSheet() else { return }
        _ = Task { @MainActor [store] in
            try? await Task.sleep(for: .milliseconds(350))
            store.calibrating = id
        }
    }
}

/// The sheet's body, apart from the Settings store so it can be drawn
/// with any firmware state.
struct FirmwareSheetContent: View {
    let firmware: FirmwareStore
    let fallbackName: String
    let isLive: Bool
    var stateJob: FirmwareJob?
    var onCalibrate: () -> Void = {}

    var body: some View {
        let stage = firmware.sheetStage
        VStack(alignment: .leading, spacing: SettingsMetrics.l) {
            switch stage {
            case .confirm: confirmStage
            case .starting: startingStage
            case .running(let job): runningStage(job)
            case .finished(let job): finishedStage(job)
            }
        }
        .padding(20)
        .frame(width: 540)
        .interactiveDismissDisabled(!firmware.canCloseSheet)
        .onAppear {
            _ = Task { await firmware.observe(stateJob: stateJob) }
        }
        .onChange(of: stateJob) { _, job in
            _ = Task { await firmware.observe(stateJob: job) }
        }
    }

    // MARK: Before anything is sent

    @ViewBuilder
    private var confirmStage: some View {
        if let confirmation = firmware.confirmation(fallbackName: fallbackName) {
            header(symbol: "memorychip", tint: SettingsStore.Chapter.devices.tint,
                   title: confirmation.title, subtitle: confirmation.summary)
            VStack(alignment: .leading, spacing: SettingsMetrics.m) {
                ForEach(Array(confirmation.bullets.enumerated()), id: \.offset) { _, bullet in
                    bulletRow(bullet)
                }
            }
            .padding(SettingsMetrics.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(InsetPanel())
            if let failure = firmware.startFailure {
                SettingsBanner(symbol: "exclamationmark.triangle.fill", tint: Tone.neutral.color,
                               title: "The update did not start", detail: failure)
            }
            if !isLive {
                SettingsBanner(symbol: "bolt.slash.fill", tint: Tone.neutral.color, title: "The monitor is not running",
                               detail: "Start it again, then open this sheet again.")
            }
            HStack {
                Spacer()
                Button("Cancel") { firmware.closeSheet() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Closes this sheet. Nothing is downloaded or written.")
                Button(confirmation.confirmLabel) {
                    guard let id = firmware.sheetDeviceID else { return }
                    _ = Task { await firmware.startUpdate(deviceID: id) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isLive || firmware.anyJobRunning)
                .accessibilityLabel(confirmation.confirmLabel)
                .accessibilityHint(confirmation.cached
                    ? "Starts the update now. The LEDs go still for about a minute."
                    : "Downloads the firmware, then starts the update. The LEDs go still for about a minute.")
            }
        } else {
            header(symbol: "memorychip", tint: SettingsStore.Chapter.devices.tint,
                   title: "Firmware details are not available",
                   subtitle: "Close this sheet and press Check firmware.")
            HStack {
                Spacer()
                Button("Close") { firmware.closeSheet() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func bulletRow(_ bullet: FirmwareBullet) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.m) {
            Image(systemName: bullet.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(bullet.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: While it runs

    private var startingStage: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.l) {
            header(symbol: "memorychip", tint: SettingsStore.Chapter.devices.tint,
                   title: "Starting the update", subtitle: "Waiting for the monitor to accept it.")
            waitRow(label: "Starting", detail: "Please leave the device connected.")
        }
    }

    private func runningStage(_ job: FirmwareJob) -> some View {
        let progress = FirmwarePresenter.progress(for: job)
        let name = job.name ?? fallbackName
        let target = job.toVersion.map { "to firmware \($0)" } ?? "to the new firmware"
        return VStack(alignment: .leading, spacing: SettingsMetrics.l) {
            header(symbol: "memorychip", tint: SettingsStore.Chapter.devices.tint,
                   title: "Updating the \(name)", subtitle: "From firmware \(job.fromVersion ?? "its current version") \(target).")
            waitRow(label: progress.label, detail: progress.step, figure: progress.download)
            .padding(SettingsMetrics.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(InsetPanel())
            SettingsBanner(symbol: "exclamationmark.triangle.fill", tint: Tone.neutral.color, title: progress.reminder,
                           detail: "Keep the Mac awake and plugged in. The LEDs stay still for about a minute, and the device restarts once.")
        }
    }

    private func waitRow(label: String, detail: String?, figure: String? = nil) -> some View {
        HStack(spacing: SettingsMetrics.m) {
            ProgressView().controlSize(.small)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).fontWeight(.medium)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                if let figure {
                    Text(figure)
                        .font(.title3.monospacedDigit())
                        .padding(.top, 2)
                        .accessibilityLabel("Downloaded \(figure)")
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: How it ended

    @ViewBuilder
    private func finishedStage(_ job: FirmwareJob) -> some View {
        let name = job.name ?? fallbackName
        if let result = FirmwarePresenter.result(for: job, name: name) {
            header(symbol: symbol(result), tint: tint(result), title: result.headline, subtitle: nil)
            VStack(alignment: .leading, spacing: SettingsMetrics.s) {
                ForEach(Array(result.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
                if let took = result.tookLine {
                    Text(took).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let colour = result.colourNote {
                CardNote(colour, symbol: "paintpalette")
            }
            HStack {
                Spacer()
                if result.colourNote != nil {
                    Button("Check colour calibration…", action: onCalibrate)
                        .accessibilityHint("Closes this sheet and opens the colour calibration sheet for the \(name).")
                }
                Button("Close") { firmware.closeSheet() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Closes this sheet.")
            }
        }
    }

    private func symbol(_ result: FirmwareResult) -> String {
        switch result.kind {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .unconfirmed: return "questionmark.circle.fill"
        }
    }

    private func tint(_ result: FirmwareResult) -> Color {
        switch result.kind {
        case .succeeded: return Tone.done.color
        case .failed: return Tone.failure.color
        case .unconfirmed: return Tone.neutral.color
        }
    }

    // MARK: Header

    private func header(symbol: String, tint: Color, title: String, subtitle: String?) -> some View {
        HStack(alignment: .center, spacing: SettingsMetrics.m) {
            SettingsIconTile(symbol: symbol, tint: tint, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
