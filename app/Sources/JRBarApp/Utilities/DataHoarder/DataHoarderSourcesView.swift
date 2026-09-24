import SwiftUI
import JRBarCore

/// Find History's sheet: the agent folders discovery found, each with
/// its provider, where it lives, how many files the date window keeps
/// and how big they are — pick the ones to review, then review them.
struct DataHoarderSourcesView: View {
    @Bindable var model: DataHoarderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                DataHoarderMark(size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Find agent history")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Choose sources to review. Discovery reads file metadata only; it does not import conversations. Live capture is a separate per-source toggle on the Data Hoarder card.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Text("Modified in")
                    .font(.system(size: 12))
                Picker("File modification dates", selection: $model.historyWindowDays) {
                    Text("Last 7 days").tag(7)
                    Text("Last 30 days").tag(30)
                    Text("All dates").tag(0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.sourceInventories.enumerated()), id: \.element.id) { index, inventory in
                        // Inset to the names, the way a grouped list rules.
                        if index > 0 { Divider().padding(.leading, 60) }
                        sourceRow(inventory)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            }
            Text("\(model.selectedHistoryFiles.count) \(model.selectedHistoryFiles.count == 1 ? "file" : "files") selected. You can exclude individual files in the next review.")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { model.reviewingSources = false }
                    .keyboardShortcut(.cancelAction)
                Button("Choose Folder…") { model.chooseHistoryFolder() }
                Spacer()
                Button("Review Selected Files") { model.reviewHistorySelection() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedHistoryFiles.isEmpty || !model.enabled || model.busy)
            }
        }
        .padding(22)
        .frame(width: 630, height: 480)
        .disabled(model.busy)
    }

    private func sourceRow(_ inventory: ArchiveSourceInventory) -> some View {
        let files = model.historyFiles(in: inventory)
        let style = ProviderStyle.style(for: DataHoarderOffer.provider(of: inventory.id))
        let selected = Binding(get: { model.selectedSources.contains(inventory.id) }, set: {
            if $0 { model.selectedSources.insert(inventory.id) }
            else { model.selectedSources.remove(inventory.id) }
        })
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: selected) {
                HStack(spacing: 8) {
                    ProviderTile(style: style, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(inventory.source.name)
                            .font(.system(size: 12.5, weight: .medium))
                        Text((inventory.source.root.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Text("\(files.count) \(files.count == 1 ? "file" : "files") · \(DataHoarderModel.bytes(DataHoarderModel.totalBytes(files.map(\.byteCount))))")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(files.isEmpty)
            Group {
                if let first = inventory.earliestModifiedAt, let last = inventory.latestModifiedAt {
                    Text("All discovered file dates: \(first.formatted(date: .abbreviated, time: .omitted)) to \(last.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                ForEach(inventory.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.leading, 50)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .help(inventory.source.root.path)
    }
}
