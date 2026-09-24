import AppKit
import SwiftUI
import JRBarCore

struct DataHoarderView: View {
    @Bindable var model: DataHoarderModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "archivebox.fill").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Data Hoarder").font(.title2.bold())
                    Text("Your traces, kept on this Mac.").foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Find History…", systemImage: "magnifyingglass") {
                    Task { await model.discoverHistory() }
                }
                .disabled(!model.enabled || model.busy)
                Button("Choose Files…", systemImage: "plus") { model.chooseFiles() }
                    .disabled(!model.enabled || model.busy)
                Menu("Export", systemImage: "square.and.arrow.up") {
                    Button("Selected File…") { model.exportSelected() }
                        .disabled(model.selected == nil)
                    Button("Selected Session as Markdown…") { model.exportMarkdown() }
                        .disabled(!model.canExportMarkdown)
                        .help("A readable copy of the rebuilt timeline, for a PR or a postmortem")
                    Button("Entire Archive…") { model.chooseArchiveExport() }
                }
                .disabled(model.busy)
            }
            .padding(20)

            HStack {
                Picker("Archive view", selection: $model.showTrash) {
                    Text("Saved").tag(false)
                    Text("Archive Trash").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                Spacer()
                if model.showTrash {
                    Picker("Empty trash after", selection: trashRetentionBinding) {
                        Text("Keep forever").tag(0)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .labelsHidden().frame(width: 120)
                    .help("Automatically and permanently delete records that have been in the trash longer than this.")
                    Button("Restore Selected") { Task { await model.restoreSelected() } }
                        .disabled(model.selected == nil)
                    Button("Empty Archive Trash…") { model.confirmEmptyTrash() }
                        .disabled(model.storageUsage?.trashedRecordCount == 0)
                } else {
                    Button("Move to Archive Trash", systemImage: "trash") {
                        Task { await model.moveSelectedToTrash() }
                    }.disabled(model.selected == nil)
                }
            }
            .disabled(model.busy)
            .padding(.horizontal, 20).padding(.bottom, 12)

            if model.exportingArchive {
                HStack {
                    Text("Exporting and verifying all archived files…").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop Export") { model.stopExport() }
                }
                .padding(.horizontal, 20).padding(.bottom, 10)
            }

            if let progress = model.importProgress {
                HStack {
                    Text(progress).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop Import") { model.stopImport() }
                }
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }

            if !model.enabled {
                Text("Imports and capture are off. Enable Data Hoarder in Utilities to add files. Your saved archive remains readable.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }
            if let error = model.displayedError {
                ScrollView {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                .padding(.horizontal, 20).padding(.bottom, 10)
            } else if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 10)
            }

            if !model.candidates.isEmpty { importReview }
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        TextField("Search names, sources, or contents", text: $model.query)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Search archive")
                        if model.searching {
                            ProgressView().controlSize(.small).accessibilityLabel("Searching archive")
                        }
                        if !model.query.isEmpty {
                            Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .accessibilityLabel("Clear archive search")
                        }
                    }.padding(.horizontal, 12).padding(.top, 12)
                    filterBar
                    listContent
                    footerCounts
                }
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380,
                       maxHeight: .infinity, alignment: .top)
                detail.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                if let usage = model.storageUsage {
                    Text("Saved: \(usage.recordCount) \(usage.recordCount == 1 ? "file" : "files"), \(DataHoarderModel.bytes(usage.contentBytes)) · Trash: \(usage.trashedRecordCount), \(DataHoarderModel.bytes(usage.trashedContentBytes)) · \(DataHoarderModel.bytes(usage.allocatedBytes)) allocated on disk")
                        .help("Includes archive files, the catalog, and temporary files. Filesystem compression and shared blocks can affect allocated space.")
                } else if let error = model.storageError {
                    Text("Storage unavailable").help(error)
                } else {
                    Text("Measuring archive storage…")
                }
                if let progress = model.indexProgress, progress.indexed < progress.total {
                    Text("· indexing \(progress.indexed) of \(progress.total)")
                        .help("Segments already searchable out of all archived segments.")
                }
                if model.captureFailureCount > 0 {
                    Button("\(model.captureFailureCount) capture \(model.captureFailureCount == 1 ? "failure" : "failures") — details") {
                        model.showCaptureFailures.toggle()
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(.orange)
                    .popover(isPresented: $model.showCaptureFailures, arrowEdge: .bottom) {
                        captureFailureDetails
                    }
                }
                Spacer(minLength: 8)
                if model.measuringStorage { ProgressView().controlSize(.mini) }
                Button { Task { await model.refreshStorage() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh archive storage")
                .disabled(model.busy || model.measuringStorage)
            }
            .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(minWidth: 720, minHeight: 440)
        .task(id: model.enabled) {
            guard model.enabled else { return }
            await model.refreshStorage()
            await model.refreshCaptureStatus()
            model.pumpSearchIndex()
        }
        .task(id: "\(model.busy):\(model.showTrash):\(model.query)") {
            // Debounced content search — each keystroke retires the last pass.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            if model.searchActive {
                await model.runSearch()
            } else {
                await model.reload()
            }
        }
        .task(id: model.searchFilter) {
            // Filter picks skip the typing debounce.
            guard model.searchActive else { return }
            await model.runSearch()
        }
        .task(id: model.backfillOffer) {
            guard let source = model.backfillOffer else { return }
            await model.offerBackfill(for: source)
        }
        .task(id: "\(model.busy):\(model.showTrash):\(model.selectedID ?? "")") {
            await model.loadPreview()
            await model.loadDetail()
        }
        .sheet(isPresented: $model.reviewingSources) { DataHoarderSourcesView(model: model) }
    }

    // MARK: Search filters

    private var filterBar: some View {
        HStack(spacing: 8) {
            Picker("Provider", selection: $model.searchFilter.provider) {
                Text("All providers").tag(String?.none)
                Text("Claude").tag(String?.some("claude"))
                Text("Codex").tag(String?.some("codex"))
                Text("Other").tag(String?.some("other"))
            }
            .pickerStyle(.menu).fixedSize().labelsHidden()
            .accessibilityLabel("Filter by provider")
            Picker("Project", selection: $model.searchFilter.project) {
                Text("All projects").tag(String?.none)
                ForEach(model.availableProjects, id: \.self) { project in
                    Text(project).tag(String?.some(project))
                }
            }
            .pickerStyle(.menu).fixedSize().labelsHidden()
            .accessibilityLabel("Filter by project")
            Picker("State", selection: $model.searchFilter.state) {
                Text("Any state").tag(CaptureState?.none)
                Text("Live").tag(CaptureState?.some(.live))
                Text("Closed").tag(CaptureState?.some(.closed))
                Text("Gap").tag(CaptureState?.some(.gap))
                Text("Snapshot").tag(CaptureState?.some(.snapshot))
            }
            .pickerStyle(.menu).fixedSize().labelsHidden()
            .accessibilityLabel("Filter by capture state")
            DatePicker("From", selection: fromBinding, displayedComponents: .date)
                .labelsHidden().fixedSize()
                .accessibilityLabel("Filter from date")
            if model.searchFilter.from != nil {
                clearFilterButton { model.searchFilter.from = nil }
            }
            Text("–").foregroundStyle(.tertiary)
            DatePicker("To", selection: toBinding, displayedComponents: .date)
                .labelsHidden().fixedSize()
                .accessibilityLabel("Filter to date")
            if model.searchFilter.to != nil {
                clearFilterButton { model.searchFilter.to = nil }
            }
        }
        .padding(.horizontal, 12)
        .font(.caption)
    }

    private var fromBinding: Binding<Date> {
        Binding(get: { model.searchFilter.from ?? Date() },
                set: { model.searchFilter.from = $0 })
    }

    /// 0 means "keep forever" — the picker needs a concrete tag for nil.
    private var trashRetentionBinding: Binding<Int> {
        Binding(get: { model.captureSettings.trashRetentionDays ?? 0 },
                set: { model.captureSettings.trashRetentionDays = $0 > 0 ? $0 : nil })
    }

    private var toBinding: Binding<Date> {
        Binding(
            get: { model.searchFilter.to ?? Date() },
            // The picker yields the day at 00:00 — an inclusive "to" means
            // the end of that day, or nothing picked today would match.
            set: { picked in
                model.searchFilter.to = Calendar.current
                    .date(byAdding: .day, value: 1, to: picked)?
                    .addingTimeInterval(-1)
            })
    }

    private func clearFilterButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("Clear date filter")
    }

    // MARK: List

    @ViewBuilder private var listContent: some View {
        if model.searchActive {
            if model.searchResults.isEmpty && !model.searching {
                ContentUnavailableView("No matching segments", systemImage: "magnifyingglass",
                                       description: Text("Adjust the query or filters. New segments index in the background."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedID) {
                    ForEach(Array(model.searchResults.enumerated()), id: \.offset) { _, result in
                        searchRow(result)
                            .tag(result.record.id)
                    }
                    if model.searchHasMore {
                        Button("Load more") { Task { await model.loadMoreSearch() } }
                            .disabled(model.searching)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        } else if model.records.isEmpty {
            ContentUnavailableView(model.query.isEmpty
                                   ? (model.showTrash ? "Archive Trash is empty" : "Your archive is empty") : "No matching files",
                                   systemImage: "archivebox",
                                   description: Text(model.query.isEmpty
                                       ? (model.showTrash ? "Removed copies stay here until you restore them or empty the trash."
                                          : "Choose trace or session files, review them, and save a local copy.")
                                       : "Try a filename, source path, or text from a trace."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $model.selectedID) {
                ForEach(model.records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.name).font(.body.weight(.medium)).lineLimit(1)
                        Text("\(DataHoarderModel.bytes(record.byteCount)) · \(record.importedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(record.id)
                }
            }
        }
    }

    private func searchRow(_ result: ArchiveSearchResult) -> some View {
        let record = result.record
        return VStack(alignment: .leading, spacing: 3) {
            Text(record.title ?? record.name).font(.body.weight(.medium)).lineLimit(1)
            HStack(spacing: 6) {
                if let provider = record.provider {
                    Text(provider).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if let project = record.project { Text(project).lineLimit(1) }
                Text((record.lastActivityAt ?? record.importedAt).formatted(date: .abbreviated, time: .omitted))
                Text(DataHoarderModel.bytes(record.byteCount))
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(result.snippets, id: \.self) { snippet in
                Text(markedSnippet(snippet))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var footerCounts: some View {
        let count = model.searchActive ? model.searchResults.count : model.records.count
        let bytes = model.searchActive
            ? model.searchResults.reduce(0) { $0 + $1.record.byteCount }
            : DataHoarderModel.totalBytes(model.records.map(\.byteCount))
        let label = model.searchActive
            ? "\(count) \(count == 1 ? "result" : "results")\(model.searchHasMore ? "+" : "") · \(DataHoarderModel.bytes(bytes))"
            : "\(count) \(count == 1 ? "file" : "files") shown · \(DataHoarderModel.bytes(bytes))"
        return Text(label)
            .font(.caption).foregroundStyle(.secondary).padding(12)
    }

    private var captureFailureDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Capture failures").font(.headline)
            Text("The archive kept the last good offset; these files retry on the next change or rescan.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.captureFailures, id: \.at) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.path).font(.caption).lineLimit(1).truncationMode(.middle)
                            Text("\(failure.at.formatted(date: .abbreviated, time: .shortened)) — \(failure.error)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }.frame(maxHeight: 220)
        }
        .padding(14).frame(width: 380)
    }

    private var importReview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review import").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach($model.candidates) { $candidate in
                        Toggle(isOn: $candidate.selected) {
                            HStack {
                                Text(candidate.url.lastPathComponent).lineLimit(1)
                                    .help(candidate.url.path)
                                Spacer()
                                Text(DataHoarderModel.bytes(candidate.size))
                                if let modified = candidate.modified {
                                    Text(modified.formatted(date: .abbreviated, time: .shortened))
                                }
                            }.font(.callout)
                        }.toggleStyle(.checkbox)
                    }
                }
            }.frame(maxHeight: 120)
            Toggle("Copy full contents of the selected files into this Mac's archive", isOn: $model.copyContents)
                .toggleStyle(.checkbox)
            Text("These files may contain prompts, responses, or other private data. Originals are preserved. Nothing is uploaded.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { model.cancelReview() }
                Spacer()
                Button("Import \(model.selectedCount) \(model.selectedCount == 1 ? "File" : "Files")") { Task { await model.importSelected() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.enabled || !model.copyContents || model.selectedCount == 0)
            }
        }
        .disabled(model.busy)
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20).padding(.bottom, 16)
    }

    @ViewBuilder private var detail: some View {
        if let record = model.selected {
            VStack(alignment: .leading, spacing: 12) {
                Text(record.title ?? record.name).font(.title3.bold()).textSelection(.enabled)
                if record.title != nil {
                    Text(record.name).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("Original: \(record.sourcePath)").font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                provenanceBlock(record)
                HStack(spacing: 10) {
                    Button("Reveal Original in Finder") { model.revealInFinder(record) }
                        .disabled(!FileManager.default.fileExists(atPath: record.sourcePath))
                    Button("Copy Path") { model.copyPath(record) }
                    if let session = model.sessionID(for: record) {
                        Button("Open in Terminal") { model.openInTerminal(record) }
                            .help("Raise the live session \(session)")
                    } else {
                        Button("Open in Terminal") {}
                            .disabled(true)
                            .help("Only sessions the daemon still knows can be raised.")
                    }
                }
                .font(.callout)
                if model.detailKind == .cliProxy {
                    cliProxyCard
                }
                relatedSection
                captureGapSection(record)
                Divider()
                detailContent
            }.padding(20)
        } else {
            ContentUnavailableView("Select a saved file", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Read its saved contents or export a copy."))
        }
    }

    /// Where this record came from and how much of it the archive holds:
    /// provider and capture-state chips, segment count, the captured time
    /// range, and the declared project/model/session facts.
    private func provenanceBlock(_ record: ArchiveRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let provider = record.provider {
                    Text(provider)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                captureStateChip(record.captureState)
                Text("\(record.segmentCount) \(record.segmentCount == 1 ? "segment" : "segments")")
                Text("·").foregroundStyle(.tertiary)
                Text(DataHoarderModel.bytes(record.byteCount))
                Text("·").foregroundStyle(.tertiary)
                Text(capturedRange(record)).lineLimit(1)
            }
            .font(.caption).foregroundStyle(.secondary)
            if record.project != nil || record.model != nil || record.sessionID != nil {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    if let project = record.project {
                        provenanceRow("Project", value: project)
                    }
                    if let model = record.model {
                        provenanceRow("Model", value: model)
                    }
                    if let sessionID = record.sessionID {
                        GridRow {
                            Text("Session").foregroundStyle(.tertiary)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(sessionID, forType: .string)
                            } label: {
                                Text(String(sessionID.prefix(8)) + "…")
                                    .font(.system(.caption, design: .monospaced))
                            }
                            .buttonStyle(.plain)
                            .help("Copy full session id: \(sessionID)")
                            .accessibilityLabel("Session \(sessionID) — click to copy")
                        }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func provenanceRow(_ label: String, value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.tertiary)
            Text(value).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func capturedRange(_ record: ArchiveRecord) -> String {
        if let start = record.startedAt, let last = record.lastActivityAt, start != last {
            return "\(start.formatted(date: .abbreviated, time: .shortened)) → \(last.formatted(date: .abbreviated, time: .shortened))"
        }
        if let stamp = record.startedAt ?? record.lastActivityAt {
            return "captured \(stamp.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Saved \(record.importedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    /// The capture state as a chip: a gap is a warning, live carries a
    /// capturing tint, closed/snapshot stay muted.
    @ViewBuilder
    private func captureStateChip(_ state: CaptureState) -> some View {
        switch state {
        case .gap:
            Label("gap", systemImage: "exclamationmark.triangle")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.orange.opacity(0.18), in: Capsule())
                .foregroundStyle(.orange)
                .help("Source changed underneath — the archive kept what it captured")
        case .live:
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 5, height: 5)
                Text("capturing")
            }
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.green.opacity(0.15), in: Capsule())
            .foregroundStyle(.green)
            .help("Live capture — new lines land as segments")
        case .closed:
            Text("closed")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .foregroundStyle(.secondary)
                .help("The source stopped changing — this record is complete")
        case .snapshot:
            Text("snapshot")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .foregroundStyle(.secondary)
                .help("A one-shot import — not a live capture")
        }
    }

    /// The CLIProxyAPI request summary: the request line, the facts the
    /// stored log kept (client, upstream, attempts, model, session), and
    /// the error text when the upstream answered ≥400.
    @ViewBuilder private var cliProxyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let request = model.cliProxyRequest {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(request.method ?? "?") \(request.path ?? "?")")
                        .font(.system(.callout, weight: .semibold))
                        .textSelection(.enabled)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(request.status.map(String.init) ?? "—")
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle((request.status ?? 0) >= 400 ? Color.red : Color.green)
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    if let client = request.client {
                        provenanceRow("Client", value: client)
                    }
                    if let upstream = request.upstreamURL {
                        provenanceRow("Upstream", value: upstream)
                    }
                    if request.attemptCount > 0 {
                        provenanceRow("Attempts", value: "\(request.attemptCount)")
                    }
                    if let model = request.model {
                        provenanceRow("Model", value: model)
                    }
                    if let sessionID = request.sessionID {
                        provenanceRow("Session", value: sessionID)
                    }
                    if let timestamp = request.timestamp {
                        provenanceRow("At", value: timestamp.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let errorSummary = request.errorSummary {
                    Label(errorSummary, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
            } else {
                Label(model.detailError ?? "Reading request log…",
                      systemImage: model.detailError == nil ? "doc.text" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Saved records that share this record's session id: transcripts get
    /// one row each; the CLIProxyAPI requests collapse into a count row
    /// that selects the newest one.
    @ViewBuilder private var relatedSection: some View {
        let transcripts = model.relatedRecords.filter { $0.provider != "cliproxy" }
        let proxied = model.relatedRecords.filter { $0.provider == "cliproxy" }
        if !transcripts.isEmpty || !proxied.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Related")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(transcripts) { related in
                    relatedButton(related, label: "Session transcript — \(related.title ?? related.name)")
                }
                if !proxied.isEmpty,
                   let newest = proxied.max(by: {
                       ($0.lastActivityAt ?? $0.importedAt) < ($1.lastActivityAt ?? $1.importedAt)
                   }) {
                    relatedButton(newest, label: "\(proxied.count) proxied \(proxied.count == 1 ? "request" : "requests")")
                }
            }
        }
    }

    private func relatedButton(_ record: ArchiveRecord, label: String) -> some View {
        Button { model.openRelated(record) } label: {
            Label(label, systemImage: "arrow.right.circle")
                .font(.caption).lineLimit(1)
        }
        .buttonStyle(.link)
        .help("Open \(record.name) in the archive")
    }

    /// `.gap` records and any segment carrying a capture note say so here —
    /// the note strings are the archive's own, listed verbatim.
    @ViewBuilder
    private func captureGapSection(_ record: ArchiveRecord) -> some View {
        if record.captureState == .gap || !model.segmentNotes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Capture gaps")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if record.captureState == .gap {
                    Text("Source changed underneath — the archive kept what it captured.")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(model.segmentNotes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Contents is the highlighted preview; transcript-like records also get
    /// a Timeline pane rebuilt from the stored segments.
    @ViewBuilder private var detailContent: some View {
        if model.detailKind == .transcript {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Detail view", selection: $model.detailMode) {
                    Text("Contents").tag(DataHoarderModel.DetailMode.contents)
                    Text("Timeline").tag(DataHoarderModel.DetailMode.timeline)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                if model.detailMode == .timeline {
                    timelinePane
                } else {
                    previewScroll
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            previewScroll
        }
    }

    @ViewBuilder private var timelinePane: some View {
        if model.detailLoading && model.reconstruction == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Rebuilding the session timeline…")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let reconstruction = model.reconstruction {
            ReconstructedTimelineView(reconstruction: reconstruction,
                                      viewState: model.timelineViewState, landOnFailure: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(model.detailError ?? "Nothing to rebuild — the stored segments produced no rows.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var previewScroll: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(highlightedPreview)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .defaultScrollAnchor(.topLeading)
        .defaultScrollAnchor(.topLeading, for: .alignment)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The preview with the query's terms tinted — best-effort, capped so a
    /// huge transcript doesn't spend the frame in the scan.
    private var highlightedPreview: AttributedString {
        let text = model.preview.isEmpty ? "Loading preview…" : model.preview
        var attributed = AttributedString(text)
        let terms = model.previewHighlightTerms
        guard !terms.isEmpty else { return attributed }
        var marked = 0
        for term in terms where marked < 500 {
            var start = attributed.startIndex
            while start < attributed.endIndex, marked < 500 {
                let slice = attributed[start...]
                guard let range = slice.range(of: term, options: .caseInsensitive) else { break }
                attributed[range].backgroundColor = .orange.withAlphaComponent(0.35)
                marked += 1
                start = range.upperBound
            }
        }
        return attributed
    }
}

/// Parses the FTS `snippet()` `«hit»` markers into a tinted
/// AttributedString; anything unmarked stays plain.
func markedSnippet(_ snippet: String) -> AttributedString {
    var out = AttributedString()
    var rest = snippet[...]
    while let open = rest.range(of: "«") {
        out.append(AttributedString(rest[..<open.lowerBound]))
        rest = rest[open.upperBound...]
        if let close = rest.range(of: "»") {
            var hit = AttributedString(rest[..<close.lowerBound])
            hit.foregroundColor = .orange
            hit.font = .caption.bold()
            out.append(hit)
            rest = rest[close.upperBound...]
        } else {
            out.append(AttributedString(rest))
            rest = rest[rest.endIndex...]
        }
    }
    out.append(AttributedString(rest))
    return out
}

/// The Data Hoarder card's capture controls — per-source "Capture new
/// activity" toggles, the explicit full-content consent, and the pause
/// switch. Lives beside the archive window's view code; the Utilities
/// card embeds it.
struct DataHoarderCaptureControls: View {
    @Bindable var model: DataHoarderModel
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.captureSourceOptions) { source in
                HStack(spacing: 8) {
                    Toggle("Capture new activity — \(source.name)",
                           isOn: captureBinding(source.id))
                        .toggleStyle(.checkbox)
                        .help(captureHelp(for: source))
                    if model.captureSettings.captureSources[source.id] == true {
                        Button("Also import existing files…") {
                            open()
                            Task { await model.offerBackfill(for: source.id) }
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
            }
            Toggle("Store full prompts and responses", isOn: $model.captureSettings.fullContent)
                .toggleStyle(.checkbox)
            Text("Off keeps each line's structure — types, timestamps, tool names, token counts — but stores prompt and response text as “[redacted]”. On stores transcripts verbatim; already-archived copies are unchanged either way.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("When a source starts", selection: backfillBinding) {
                Text("Follow new activity only").tag(0)
                Text("Also read the last 7 days").tag(7)
                Text("Also read the last 30 days").tag(30)
                Text("Also read the last 90 days").tag(90)
            }
            .pickerStyle(.menu).fixedSize()
            .help("Read once, on a source's first scan: files modified in the window are archived from their start; older files wait for Also import existing files.")
            Toggle("Pause capture", isOn: $model.captureSettings.paused)
                .toggleStyle(.checkbox)
            if model.captureRunning {
                Text("Capture is running — new lines land as segments within a few seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func captureHelp(for source: ArchiveSource) -> String {
        source.id == ArchiveSource.cliProxyAPILogs
            ? "Per-request logs written by CLIProxyAPI — captured only while enabled."
            : "New lines under \(source.root.path) are archived as segments."
    }

    private func captureBinding(_ sourceID: String) -> Binding<Bool> {
        Binding(get: { model.captureSettings.captureSources[sourceID] ?? false },
                set: { on in
                    let review = on && model.offersImportReviewOnCapture
                    model.setCapture(on, sourceID: sourceID)
                    if review {
                        open()
                        Task { await model.offerBackfill(for: sourceID) }
                    }
                })
    }

    /// 0 stands for "no window" — the picker needs a concrete tag for nil.
    private var backfillBinding: Binding<Int> {
        Binding(get: { model.captureSettings.backfillDays ?? 0 },
                set: { model.captureSettings.backfillDays = $0 > 0 ? $0 : nil })
    }
}
