import SwiftUI
import JRBarCore

struct DataHoarderSourcesView: View {
    @Bindable var model: DataHoarderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Find agent history").font(.title2.bold())
            Text("Choose sources to review. Discovery reads file metadata only; it does not import conversations. Live capture is a separate per-source toggle on the Data Hoarder card.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("File modification dates", selection: $model.historyWindowDays) {
                Text("Last 7 days").tag(7)
                Text("Last 30 days").tag(30)
                Text("All dates").tag(0)
            }.pickerStyle(.segmented)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.sourceInventories) { inventory in
                        sourceRow(inventory)
                    }
                }
            }
            Text("\(model.selectedHistoryFiles.count) \(model.selectedHistoryFiles.count == 1 ? "file" : "files") selected. You can exclude individual files in the next review.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { model.reviewingSources = false }
                Button("Choose Folder…") { model.chooseHistoryFolder() }
                Spacer()
                Button("Review Selected Files") { model.reviewHistorySelection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedHistoryFiles.isEmpty || !model.enabled || model.busy)
            }
        }
        .padding(24)
        .frame(width: 630, height: 470)
        .disabled(model.busy)
    }

    private func sourceRow(_ inventory: ArchiveSourceInventory) -> some View {
        let files = model.historyFiles(in: inventory)
        let selected = Binding(get: { model.selectedSources.contains(inventory.id) }, set: {
            if $0 { model.selectedSources.insert(inventory.id) }
            else { model.selectedSources.remove(inventory.id) }
        })
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: selected) {
                HStack {
                    Text(inventory.source.name).font(.headline)
                    Spacer()
                    Text("\(files.count) \(files.count == 1 ? "file" : "files") · \(DataHoarderModel.bytes(DataHoarderModel.totalBytes(files.map(\.byteCount))))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(files.isEmpty)
            Text(inventory.source.root.path).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let first = inventory.earliestModifiedAt, let last = inventory.latestModifiedAt {
                Text("All discovered file dates: \(first.formatted(date: .abbreviated, time: .omitted)) to \(last.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(inventory.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}
