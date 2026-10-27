import JRBarUI
import JRBarCore
import SwiftUI

/// Firmware status and actions inside the device card. Downloads require confirmation.
struct FirmwareRows: View {
    let firmware: FirmwareStore
    let device: SettingsStore.DeviceEntry
    /// The monitor is connected, so a command can be sent at all.
    let isLive: Bool
    /// The first firmware row asks for the status when the page opens
    /// and carries the search anchor.
    var isFirst = true
    /// The state frame's job, to follow while the page is open.
    var stateJob: FirmwareJob?

    private var state: FirmwareCardState {
        firmware.cardState(settingsID: device.id, kind: device.kind, fallbackName: device.name)
    }

    var body: some View {
        let card = state
        rows(card)
            .id(isFirst ? SettingsStore.groupAnchor("Firmware") : "firmware:\(device.id)")
    }

    // MARK: Rows

    @ViewBuilder
    private func rows(_ card: FirmwareCardState) -> some View {
        SettingRow("Firmware", subtitle: summary(card)) {
            HStack(spacing: SettingsMetrics.s) {
                primaryButton(card)
                if firmware.isRefreshing {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Checking the firmware")
                }
                Button("Check firmware") {
                    _ = Task { await firmware.refresh() }
                }
                .disabled(firmware.isRefreshing || card.isRunning || !isLive)
                .help("Reads the device's firmware version. Nothing is downloaded.")
                .accessibilityLabel("Check the firmware for \(card.name)")
                .accessibilityHint("Reads the device only. Makes no network request.")
            }
            .controlSize(.small)
        }
        .task(id: isFirst && isLive) {
            guard isFirst && isLive else { return }
            await firmware.pageAppeared(stateJob: stateJob)
        }
        .onChange(of: stateJob) { _, job in
            guard isFirst && isLive else { return }
            _ = Task { await firmware.observe(stateJob: job) }
        }
        if let detail = card.detail {
            CardNote(detail, symbol: noteSymbol(card), tint: noteTint(card))
        }
        if let blocked = card.blockedNote {
            CardNote(blocked, symbol: "hourglass")
        }
        if !card.notes.isEmpty {
            DisclosureRow("What's new", subtitle: whatsNewSubtitle(card), fold: "firmware:notes:\(device.id)") {
                FirmwareNotesList(notes: card.notes)
            }
        }
        if let note = groupNote(card) {
            CardNote(note, symbol: "info.circle")
        }
    }

    @ViewBuilder
    private func primaryButton(_ card: FirmwareCardState) -> some View {
        let row = firmware.status?.device(matching: device.id, kind: device.kind)
        if card.isRunning {
            Button("Show progress") {
                firmware.openSheet(deviceID: card.job?.device ?? row?.id ?? device.id, settingsID: device.id)
            }
            .accessibilityLabel("Show the progress of the \(card.name) update")
        } else if card.result != nil {
            Button("Show result") {
                firmware.openSheet(deviceID: card.job?.device ?? row?.id ?? device.id, settingsID: device.id)
            }
            .accessibilityLabel("Show how the \(card.name) update ended")
        } else if card.canStart && isLive {
            Button("Review update…") {
                if let row { firmware.openSheet(deviceID: row.id, settingsID: device.id) }
            }
            .disabled(!card.canStart || !isLive || firmware.anyJobRunning || row == nil)
            .accessibilityLabel("Review the \(card.name) firmware update")
            .accessibilityHint(startHint(card))
        }
    }

    private func startHint(_ card: FirmwareCardState) -> String {
        if card.canStart { return "Opens a confirmation first. Nothing is downloaded until you confirm." }
        if let reason = card.blockedNote ?? card.detail { return "Unavailable. " + reason }
        return "Unavailable."
    }

    private func summary(_ card: FirmwareCardState) -> String {
        guard isLive else {
            return firmware.status == nil ? MonitorWords.label : "Last reported: " + card.headline
        }
        switch card.display {
        case .upToDate(let version): return "\(version) · Up to date"
        case .updateAvailable(let from, let latest): return "\(from) · \(latest) available"
        case .loading: return firmware.isRefreshing ? "Reading firmware…" : "Not checked"
        default: return card.headline
        }
    }

    private func groupNote(_ card: FirmwareCardState) -> String? {
        switch card.display {
        case .updateAvailable, .cannotUpdate:
            return "An update changes only the device's firmware file. JR-Bar asks you first and shows what will be downloaded."
        default:
            return nil
        }
    }

    private func whatsNewSubtitle(_ card: FirmwareCardState) -> String? {
        switch card.display {
        case .updateAvailable(_, let latest), .cannotUpdate(_, let latest?, _): return "In firmware \(latest)"
        default: return nil
        }
    }

    private func noteSymbol(_ card: FirmwareCardState) -> String {
        switch card.display {
        case .failed: return "xmark.octagon.fill"
        case .unconfirmed, .cannotUpdate, .unavailable, .offline: return "exclamationmark.triangle.fill"
        case .succeeded: return "checkmark.circle.fill"
        default: return "info.circle"
        }
    }

    private func noteTint(_ card: FirmwareCardState) -> Color {
        switch card.display {
        case .failed: return Tone.failure.color
        case .unconfirmed, .cannotUpdate, .unavailable, .offline: return Tone.neutral.color
        case .succeeded: return Tone.done.color
        default: return .secondary
        }
    }
}

/// The release notes as a short list of plain sentences.
struct FirmwareNotesList: View {
    let notes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.s) {
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.s) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 4))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(note)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Release notes: " + notes.joined(separator: " "))
    }
}
