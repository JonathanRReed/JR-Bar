import AppKit
import JRBarCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class DataHoarderUtility: Toy {
    let model = DataHoarderModel()
    var onEnabledChange: ((Bool) -> Void)?
    @ObservationIgnored private var windowController: DataHoarderWindowController?

    let id = "data-hoarder"
    let name = "Data Hoarder"
    let blurb = "Keep a local, searchable copy of your traces and session files."
    let symbol = "archivebox"
    var isOn: Bool {
        get { model.enabled }
        set {
            model.enabled = newValue
            onEnabledChange?(newValue)
        }
    }
    var status: ToyStatus { isOn ? .on : .off }
    var controls: AnyView {
        AnyView(VStack(alignment: .leading, spacing: 10) {
            Text("Import files you select, or capture new activity from sources you enable below. Originals stay untouched; nothing leaves this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            DataHoarderCaptureControls(model: model, open: { self.openArchive() })
            Button("Open Archive…") { self.openArchive() }
            Text("Switching this utility off stops capture and new imports; your saved archive stays.")
                .font(.caption).foregroundStyle(.secondary)
        })
    }

    /// History's offer, accepted: the chosen agent sources capture from
    /// now on, the backfill window reads their last `backfillDays`, and the
    /// utility switches on. Full content stays whatever the card says —
    /// off unless chosen there.
    func keepTranscripts(sourceIDs: [String], backfillDays: Int) {
        model.keepAgentTranscripts(sourceIDs: sourceIDs, backfillDays: backfillDays)
        isOn = true
    }

    func openArchive() {
        let controller = windowController ?? DataHoarderWindowController(model: model)
        windowController = controller
        controller.show()
    }
}

struct ArchiveImportCandidate: Identifiable {
    var id: URL { url }
    let url: URL
    let size: Int64
    let modified: Date?
    var selected = true
}

@MainActor
@Observable
final class DataHoarderModel {
    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if !enabled {
                stopImport()
                stopIndexing()
                // Capture consent and read-only browsing are independent.
                // A visible archive stays usable when capture is disabled.
                if !archiveWindowIsOpen { releaseArchivePresentation() }
            }
            applyCapture()
        }
    }
    var query = ""
    var showTrash = false {
        didSet {
            records = []
            selectedID = nil
            preview = ""
            previewError = nil
            error = nil
            message = nil
        }
    }
    var records: [ArchiveRecord] = []
    var selectedID: String? {
        didSet {
            guard selectedID != oldValue else { return }
            preview = ""
            previewError = nil
            clearRecordDetail()
        }
    }
    var preview = ""
    var candidates: [ArchiveImportCandidate] = []
    var copyContents = false
    var busy = false
    var reviewingSources = false
    var sourceInventories: [ArchiveSourceInventory] = []
    var selectedSources: Set<String> = []
    var historyWindowDays = 30
    var importProgress: String?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    var exportingArchive = false
    var storageUsage: ArchiveStorageUsage?
    var storageError: String?
    var measuringStorage = false
    @ObservationIgnored private var storageRevision = 0
    var message: String?
    var error: String?
    var searchError: String?
    var searching = false
    @ObservationIgnored private var searchRevision = 0
    var previewError: String?
    var displayedError: String? { searchError ?? previewError ?? error }

    // MARK: Capture

    /// The persisted capture dials, mirrored from `UtilitiesState.dataHoarder`.
    /// Writes round-trip through `onCaptureSettingsChange` so the store stays
    /// the single owner — the equality guards break the sync loop.
    var captureSettings = DataHoarderSettings() {
        didSet {
            guard captureSettings != oldValue else { return }
            if !suppressCaptureNotify { onCaptureSettingsChange?(captureSettings) }
            applyCapture()
        }
    }
    @ObservationIgnored private var suppressCaptureNotify = false
    var onCaptureSettingsChange: ((DataHoarderSettings) -> Void)?
    let capture: DataHoarderCapture
    var captureRunning = false
    var captureFailureCount = 0
    var captureFailures: [CaptureFailure] = []
    var showCaptureFailures = false

    // MARK: Search

    static let pageSize = 50
    var searchResults: [ArchiveSearchResult] = []
    var searchHasMore = false
    var searchOffset = 0
    var searchFilter = ArchiveSearchFilter()
    var availableProjects: [String] = []
    var indexProgress: (indexed: Int, total: Int)?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var indexGeneration: UInt64 = 0
    @ObservationIgnored private var indexRequested = false

    /// The live roster lookup the Overview uses — set by UtilitiesStore, so a
    /// captured record whose session is still known can open its terminal.
    var sessionResolver: ((ArchiveRecord) -> String?)?
    var sessionOpener: ((String) -> Void)?
    /// A source whose capture toggle just switched on — the card offers to
    /// import its existing files through the normal review.
    var backfillOffer: String?

    let archive: DataHoarderArchive
    let sourceScanner: DataHoarderSourceScanner

    init(archive: DataHoarderArchive = DataHoarderArchive(
        root: AppStateFile.defaultURL().deletingLastPathComponent().appending(path: "archive")),
         sourceScanner: DataHoarderSourceScanner = DataHoarderSourceScanner(),
         capture: DataHoarderCapture? = nil) {
        self.archive = archive
        self.sourceScanner = sourceScanner
        self.capture = capture ?? DataHoarderCapture(archive: archive)
    }

    var selected: ArchiveRecord? {
        if searchActive {
            guard displayedSearchRequest == currentSearchRequest else { return nil }
            return searchResults.first { $0.record.id == selectedID }?.record
        }
        return records.first { $0.id == selectedID }
    }
    var selectedCount: Int { candidates.filter(\.selected).count }
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func totalBytes(_ sizes: [Int64]) -> Int64 {
        sizes.reduce(0) { total, size in
            let (sum, overflow) = total.addingReportingOverflow(max(0, size))
            return overflow ? .max : sum
        }
    }

    func historyFiles(in inventory: ArchiveSourceInventory, now: Date = Date()) -> [ArchiveSourceFile] {
        guard historyWindowDays > 0 else { return inventory.files }
        let start = now.addingTimeInterval(-Double(historyWindowDays) * 86_400)
        return inventory.files.filter { ($0.modifiedAt ?? .distantPast) >= start }
    }

    var selectedHistoryFiles: [ArchiveSourceFile] {
        var seen = Set<URL>()
        return sourceInventories.filter { selectedSources.contains($0.id) }
            .flatMap { historyFiles(in: $0) }.filter { seen.insert($0.url.standardizedFileURL).inserted }
    }

    func discoverHistory(sources: [ArchiveSource] = ArchiveSource.defaults()) async {
        guard enabled, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let results = try await sourceScanner.scan(sources)
            guard !Task.isCancelled, enabled else { return }
            sourceInventories = results
            selectedSources = []
            reviewingSources = true
        } catch { self.error = error.localizedDescription }
    }

    func chooseHistoryFolder() {
        guard enabled, !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a history folder"
        panel.message = "Only file names, sizes, and dates are scanned. You review files before importing their contents."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await discoverHistory(sources: [ArchiveSource(
                id: url.standardizedFileURL.path, name: url.lastPathComponent, root: url,
                extensions: ["jsonl", "json", "log", "txt"])])
        }
    }

    func reviewHistorySelection() {
        guard enabled, !busy else { return }
        candidates = selectedHistoryFiles.map {
            ArchiveImportCandidate(url: $0.url, size: $0.byteCount, modified: $0.modifiedAt)
        }
        copyContents = false
        reviewingSources = false
        message = nil
        error = nil
    }

    /// Permanently removes trash entries past the configured retention age.
    /// Runs inside `reload` — retention only ever deletes what the user
    /// already deleted, and a no-op sweep is a cheap catalog read.
    private func sweepTrashRetention() async {
        guard let days = captureSettings.trashRetentionDays else { return }
        do {
            if try await archive.purgeExpiredTrash(olderThanDays: days) > 0 {
                await refreshStorage()
            }
        } catch {
            storageError = error.localizedDescription
        }
    }

    func reload() async {
        guard !busy else { return }
        searchRevision &+= 1
        let revision = searchRevision
        searching = true
        defer { if revision == searchRevision { searching = false } }
        let requested = query
        let requestedTrash = showTrash
        await sweepTrashRetention()
        guard !Task.isCancelled, requested == query, requestedTrash == showTrash,
              revision == searchRevision else { return }
        do {
            let found = try await archive.records(query: requested, inTrash: requestedTrash)
            guard !Task.isCancelled, requested == query, requestedTrash == showTrash,
                  revision == searchRevision else { return }
            records = found
            if !found.contains(where: { $0.id == selectedID }) { selectedID = found.first?.id }
            searchError = nil
        } catch {
            guard !Task.isCancelled, requested == query, requestedTrash == showTrash,
                  revision == searchRevision else { return }
            searchError = error.localizedDescription
        }
    }

    func refreshStorage() async {
        guard !busy else { return }
        storageRevision &+= 1
        let revision = storageRevision
        measuringStorage = true
        defer { if revision == storageRevision { measuringStorage = false } }
        do {
            let usage = try await archive.storageUsage()
            guard !Task.isCancelled, revision == storageRevision else { return }
            storageUsage = usage
            storageError = nil
        } catch {
            guard !Task.isCancelled, revision == storageRevision else { return }
            storageUsage = nil
            storageError = error.localizedDescription
        }
    }

    func loadPreview() async {
        guard !busy, !Task.isCancelled else { return }
        let generation = presentationGeneration
        preview = ""
        previewError = nil
        guard let requested = selected?.id else { return }
        let request = currentSearchRequest
        let requestedTrash = showTrash
        do {
            let text = try await archive.preview(id: requested, inTrash: requestedTrash)
            guard !Task.isCancelled, generation == presentationGeneration,
                  request == currentSearchRequest,
                  requested == selectedID, requestedTrash == showTrash else { return }
            preview = text.isEmpty ? "Empty file" : text
        } catch {
            guard !Task.isCancelled, generation == presentationGeneration,
                  request == currentSearchRequest,
                  requested == selectedID, requestedTrash == showTrash else { return }
            previewError = error.localizedDescription
            preview = "Preview unavailable. The saved file could not be read safely."
        }
    }

    @ObservationIgnored private(set) var archiveWindowIsOpen = false
    @ObservationIgnored private var presentationGeneration: UInt64 = 0

    func archiveWindowDidOpen() { archiveWindowIsOpen = true }

    func archiveWindowDidClose() {
        archiveWindowIsOpen = false
        releaseArchivePresentation()
    }

    /// Release rendered data; keep navigation and pending import choices.
    /// Export/import jobs own their captured inputs and are not canceled here.
    private func releaseArchivePresentation() {
        presentationGeneration &+= 1
        searchRevision &+= 1
        clearRecordDetail()
        storageRevision &+= 1
        searching = false
        measuringStorage = false
        records = []
        searchResults = []
        searchHasMore = false
        searchOffset = 0
        preview = ""
        previewError = nil
        displayedSearchRequest = nil
    }

    // MARK: Record detail

    /// What the detail pane can offer for the selected record — decided once
    /// per selection from provider metadata and a cheap first-segment sniff.
    enum DetailKind: String, Equatable {
        /// Raw contents only — no transcript or request structure recognised.
        case plain
        /// Session transcript: a Contents | Timeline picker backed by
        /// `SessionReconstructor`.
        case transcript
        /// A CLIProxyAPI per-request log: the request card plus contents.
        case cliProxy
    }

    enum DetailMode: String {
        case contents, timeline
    }

    var detailKind = DetailKind.plain
    var detailMode = DetailMode.contents
    var detailLoading = false
    var detailError: String?
    var reconstruction: SessionReconstruction?
    var cliProxyRequest: CLIProxyRequest?
    /// Saved records sharing the selection's session id — transcripts and
    /// the CLIProxyAPI requests that carried the same link.
    var relatedRecords: [ArchiveRecord] = []
    /// Per-segment capture notes ("gap: source rewritten") — surfaced
    /// verbatim, never synthesised.
    var segmentNotes: [String] = []
    /// The timeline pane's display state (kind filter, gap disclosure) —
    /// kept here so it survives pane switches.
    let timelineViewState = ReconstructedTimelineViewState()
    @ObservationIgnored private var detailRevision = 0

    private func clearRecordDetail() {
        detailRevision &+= 1
        detailKind = .plain
        detailLoading = false
        detailError = nil
        reconstruction = nil
        cliProxyRequest = nil
        relatedRecords = []
        segmentNotes = []
    }

    /// Loads everything the detail pane beyond the raw preview needs:
    /// segment notes, related records, and — depending on the sniffed kind —
    /// the reconstructed timeline or the parsed CLIProxyAPI request. Segment
    /// reads are hash-verified by the archive; reconstruction and parsing run
    /// off-main. Cancellable and stale-guarded like `loadPreview`.
    func loadDetail() async {
        clearRecordDetail()
        let revision = detailRevision
        guard !Task.isCancelled, !busy, let record = selected else { return }
        let id = record.id
        let requestedTrash = showTrash

        var provider = record.provider
        if provider != "cliproxy", provider != "claude", provider != "codex" {
            provider = await sniffedKind(id: id, inTrash: requestedTrash)
            guard !Task.isCancelled, revision == detailRevision,
                  selectedID == id, requestedTrash == showTrash else { return }
        }
        switch provider {
        case "cliproxy": detailKind = .cliProxy
        case "claude", "codex", "jsonl": detailKind = .transcript
        default: detailKind = .plain
        }

        let segments = (try? await archive.segments(id: id)) ?? []
        guard !Task.isCancelled, revision == detailRevision,
              selectedID == id, requestedTrash == showTrash else { return }
        let related: [ArchiveRecord]
        if let sessionID = record.sessionID, !sessionID.isEmpty {
            related = (try? await archive.relatedRecords(sessionID: sessionID, excluding: id)) ?? []
        } else {
            related = []
        }
        guard !Task.isCancelled, revision == detailRevision,
              selectedID == id, requestedTrash == showTrash else { return }
        segmentNotes = segments.compactMap(\.note)
        relatedRecords = related

        switch detailKind {
        case .plain:
            return
        case .transcript:
            detailLoading = true
            defer { if revision == detailRevision { detailLoading = false } }
            do {
                let payloads = try await archive.segmentData(id: id, inTrash: requestedTrash)
                guard !Task.isCancelled, revision == detailRevision,
                      selectedID == id, requestedTrash == showTrash else { return }
                let provider = (provider == "claude" || provider == "codex") ? provider! : "other"
                let epochFallback = record.startedAt
                let rebuilt = await Task.detached(priority: .userInitiated) {
                    SessionReconstructor.reconstruct(segments: payloads, provider: provider,
                                                     epochFallback: epochFallback)
                }.value
                // The proxy's requests for the same session sit between
                // the turns: retries and refusals the transcript never
                // records.
                let requests = await Self.proxyRequests(in: archive, records: related)
                guard !Task.isCancelled, revision == detailRevision,
                      selectedID == id, requestedTrash == showTrash else { return }
                reconstruction = rebuilt.withProxyRequests(requests)
            } catch {
                guard !Task.isCancelled, revision == detailRevision else { return }
                detailError = "Timeline unavailable: \(error.localizedDescription)"
            }
        case .cliProxy:
            detailLoading = true
            defer { if revision == detailRevision { detailLoading = false } }
            do {
                let payloads = try await archive.segmentData(id: id, inTrash: requestedTrash)
                guard !Task.isCancelled, revision == detailRevision,
                      selectedID == id, requestedTrash == showTrash else { return }
                var data = Data()
                for payload in payloads { data.append(payload) }
                let request = await Task.detached(priority: .userInitiated) {
                    CLIProxyLogParser.parse(data)
                }.value
                guard !Task.isCancelled, revision == detailRevision,
                      selectedID == id, requestedTrash == showTrash else { return }
                cliProxyRequest = request
                if request == nil {
                    detailError = "The stored log does not parse as a CLIProxyAPI request — the raw contents are below."
                }
            } catch {
                guard !Task.isCancelled, revision == detailRevision else { return }
                detailError = "Request summary unavailable: \(error.localizedDescription)"
            }
        }
    }

    /// The detail-kind probe for records whose provider metadata is missing
    /// or noncommittal: "cliproxy"/"claude"/"codex" when the transcript probe
    /// classifies the stored head, "jsonl" when the first line is any JSON
    /// object (reconstruction then reports an honest `unsupported_provider`
    /// gap rather than hiding the Timeline pane), nil otherwise.
    private func sniffedKind(id: String, inTrash: Bool) async -> String? {
        guard let text = try? await archive.preview(id: id, inTrash: inTrash),
              !text.isEmpty else { return nil }
        let head = String(text.prefix(64 * 1024))
        if CLIProxyLogParser.looksLikeCLIProxyLog(Data(head.utf8)) { return "cliproxy" }
        var metadata = TranscriptMetadata()
        TranscriptProbe.ingest(
            lines: Array(head.components(separatedBy: .newlines).prefix(60)),
            into: &metadata, includeTitle: false)
        if let provider = metadata.provider, provider != "other" { return provider }
        for line in head.split(separator: "\n").prefix(10) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)))
                is [String: Any] ? "jsonl" : nil
        }
        return nil
    }

    /// Jump the archive list to a related record. Related records only exist
    /// among saved (non-trashed) records, so an active search or trash view
    /// is cleared first — the selection is set only once the list can show it.
    func openRelated(_ record: ArchiveRecord) {
        if searchActive {
            query = ""
            searchFilter = ArchiveSearchFilter()
        }
        let needsReload = showTrash || !records.contains(where: { $0.id == record.id })
        if showTrash { showTrash = false }
        if needsReload {
            Task {
                await reload()
                selectedID = record.id
            }
        } else {
            selectedID = record.id
        }
    }

    func chooseFiles() {
        guard enabled, !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose traces and session files"
        panel.message = "Review the selected files before copying their full contents into your local archive."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            candidates = try panel.urls.map { url in
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return ArchiveImportCandidate(url: url, size: Int64(values.fileSize ?? 0),
                                              modified: values.contentModificationDate)
            }
            copyContents = false
            error = nil
            message = nil
        } catch { self.error = error.localizedDescription }
    }

    func importSelected() async {
        guard enabled, !busy, copyContents, selectedCount > 0 else { return }
        busy = true
        error = nil
        let selection = candidates.filter(\.selected)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performImport(selection)
        }
        importTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        importTask = nil
        importProgress = nil
        busy = false
        // Content searches are owned by the view's cancellable task. Only
        // refresh inexpensive metadata here, so Stop Import really finishes.
        // The reload is part of the finished import, not idle work: records
        // and the selection it just set stay truthful with no window open.
        if query.isEmpty { await reload() }
        pumpSearchIndex()
        await refreshCaptureStatus()
    }

    func stopImport() {
        guard let importTask else { return }
        importTask.cancel()
        importProgress = "Stopping import. Completed files will stay saved."
    }

    func cancelReview() {
        candidates = []
        copyContents = false
        error = nil
    }

    private func performImport(_ selection: [ArchiveImportCandidate]) async {
        let needed = Self.totalBytes(selection.map(\.size))
        if needed > 0, let available = await archive.availableCapacity(), available < needed {
            error = "Not enough free space to archive \(DataHoarderModel.bytes(needed)); the archive volume has \(DataHoarderModel.bytes(available)) available."
            return
        }
        var imported = 0
        var failures: [String] = []
        var stopped = false
        for candidate in selection {
            guard enabled, !Task.isCancelled else { stopped = true; break }
            importProgress = "Archiving \(imported + failures.count + 1) of \(selection.count) \(selection.count == 1 ? "file" : "files")…"
            do {
                let record = try await archive.importFile(candidate.url)
                // A pi, Gemini or Grok file lands under its agent's name.
                await stampSourceProvider(record)
                candidates.removeAll { $0.id == candidate.id }
                selectedID = record.id
                imported += 1
            } catch is CancellationError {
                stopped = true
                break
            } catch {
                if Task.isCancelled { stopped = true; break }
                failures.append("\(candidate.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        message = "\(stopped ? "Import stopped. " : "")Archived \(imported) of \(selection.count) selected \(selection.count == 1 ? "file" : "files"). Identical contents share one saved copy."
        if !failures.isEmpty {
            error = "\(failures.count) \(failures.count == 1 ? "file could" : "files could") not be archived.\n"
                + failures.prefix(3).joined(separator: "\n")
                + (failures.count > 3 ? "\nThe other failed files remain in review for retry." : "")
        }
        if candidates.isEmpty { copyContents = false }
    }

    func exportSelected() {
        guard let record = selected, !busy else { return }
        let fromTrash = showTrash
        let panel = NSSavePanel()
        panel.title = "Export saved file"
        panel.nameFieldStringValue = record.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                // The panel's own "Replace?" is the overwrite consent.
                try await archive.export(id: record.id, to: url,
                                         inTrash: fromTrash, overwriting: true)
                message = "Exported \(record.name)."
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    /// The selected transcript as a readable Markdown file — its
    /// facts, what happened, the gaps and every rebuilt row, the proxy's
    /// requests included — for a PR description or a postmortem. Written
    /// from the timeline already rebuilt for the detail pane, so the file
    /// says what the pane showed.
    var canExportMarkdown: Bool {
        detailKind == .transcript && reconstruction != nil && selected != nil && !busy
    }

    func exportMarkdown() {
        guard canExportMarkdown, let record = selected, let reconstruction else { return }
        let panel = NSSavePanel()
        panel.title = "Export as Markdown"
        panel.message = "A readable copy of the rebuilt timeline. The archived file itself is unchanged."
        panel.nameFieldStringValue = ((record.name as NSString).deletingPathExtension) + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(Self.markdown(for: record, reconstruction: reconstruction).utf8).write(to: url, options: .atomic)
            message = "Exported \(url.lastPathComponent)."
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The Markdown for one archived record: the catalog's facts over the
    /// shared renderer.
    nonisolated static func markdown(for record: ArchiveRecord, reconstruction: SessionReconstruction,
                                     generatedAt: Date = Date()) -> String {
        let when = DateFormatter()
        when.dateFormat = "yyyy-MM-dd HH:mm"
        var facts: [SessionMarkdown.Fact] = []
        if let provider = record.provider { facts.append(.init("Provider", SessionLabel.providerName(provider))) }
        if let session = record.sessionID { facts.append(.init("Session", session)) }
        if let project = record.project { facts.append(.init("Project", project)) }
        if let model = record.model { facts.append(.init("Model", ModelName.display(model) ?? model)) }
        if let started = record.startedAt { facts.append(.init("Started", when.string(from: started))) }
        if let last = record.lastActivityAt { facts.append(.init("Last activity", when.string(from: last))) }
        facts.append(.init("Archived file", record.name))
        facts.append(.init("Capture", record.captureState.rawValue))
        return SessionMarkdown.render(
            title: record.title ?? record.name, facts: facts, reconstruction: reconstruction,
            notes: ["From the Data Hoarder archive's hash-verified copy."], generatedAt: generatedAt)
    }

    func chooseArchiveExport() {
        guard !busy else { return }
        let panel = NSSavePanel()
        panel.title = "Export entire archive"
        panel.message = "Save every archived file and its metadata, including Archive Trash and records hidden by search."
        panel.nameFieldStringValue = "JR-Bar Archive"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportTask = Task { await exportArchive(to: url) }
    }

    func exportArchive(to url: URL) async {
        guard !busy else { return }
        busy = true
        exportingArchive = true
        error = nil
        message = nil
        defer {
            busy = false
            exportingArchive = false
            exportTask = nil
        }
        do {
            let count = try await archive.exportArchive(to: url, overwriting: true)
            message = "Exported \(count) \(count == 1 ? "file" : "files") with archive metadata."
        } catch is CancellationError {
            message = "Export stopped. No partial archive was saved."
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stopExport() { exportTask?.cancel() }

    func moveSelectedToTrash() async {
        guard let record = selected, !showTrash, !busy else { return }
        busy = true
        error = nil
        message = nil
        defer { busy = false }
        do {
            try await archive.moveToTrash(id: record.id)
            message = "Moved \(record.name) to Archive Trash. You can restore it there."
        } catch { self.error = error.localizedDescription }
    }

    func restoreSelected() async {
        guard let record = selected, showTrash, !busy else { return }
        busy = true
        error = nil
        message = nil
        defer { busy = false }
        do {
            try await archive.restoreFromTrash(id: record.id)
            message = "Restored \(record.name)."
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func confirmEmptyTrash(confirm: (([ArchiveRecord]) -> Bool)? = nil) -> Task<Void, Never>? {
        guard !busy else { return nil }
        busy = true
        return Task {
            defer { busy = false }
            error = nil
            message = nil
            do {
                let records = try await archive.trashedRecords()
                guard !records.isEmpty else { return }
                let approved: Bool
                if let confirm {
                    approved = confirm(records)
                } else {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Permanently delete \(records.count) \(records.count == 1 ? "archived file" : "archived files")?"
                    alert.informativeText = "This empties Archive Trash, including files hidden by search. The archived copies cannot be recovered afterward. Original source files stay untouched."
                    alert.addButton(withTitle: "Cancel")
                    alert.addButton(withTitle: "Delete Permanently")
                    approved = alert.runModal() == .alertSecondButtonReturn
                }
                guard approved else { return }
                do {
                    let count = try await archive.emptyTrash(ids: records.map(\.id))
                    message = "Deleted \(count) \(count == 1 ? "archived copy" : "archived copies")."
                } catch {
                    self.error = "Cleanup stopped: \(error.localizedDescription) Some copies may already have been deleted. Remaining entries stay in Archive Trash for retry."
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: Capture

    /// Every root the settings card can offer: the known transcript sources
    /// plus any custom folders the user enabled previously (so a path that
    /// no longer exists still shows its toggle instead of vanishing).
    var captureSourceOptions: [ArchiveSource] {
        var seen = Set(ArchiveSource.defaults().map(\.id))
        var list = ArchiveSource.defaults()
        for id in captureSettings.enabledSources where id.hasPrefix("/") && !seen.contains(id) {
            seen.insert(id)
            list.append(ArchiveSource(id: id, name: URL(fileURLWithPath: id).lastPathComponent,
                                    root: URL(fileURLWithPath: id),
                                    extensions: ["jsonl", "json", "log", "txt"]))
        }
        return list
    }

    /// The known agent transcript sources — every default but the proxy's
    /// request logs, which are not sessions.
    static func agentSources(_ all: [ArchiveSource] = ArchiveSource.defaults()) -> [ArchiveSource] {
        all.filter { $0.id != ArchiveSource.cliProxyAPILogs }
    }

    /// The utility is on and at least one agent source captures — History
    /// stops offering the Data Hoarder once this holds. A paused capture
    /// still counts: pausing was a choice, not a gap to sell into.
    var keepsAgentTranscripts: Bool {
        let agents = Set(Self.agentSources().map(\.id))
        return enabled && captureSettings.enabledSources.contains(where: agents.contains)
    }

    /// The settings half of `DataHoarderUtility.keepTranscripts`: sources on
    /// and the backfill window set, persisted through the store callback,
    /// without raising the card's import review — the window already reads
    /// the recent files, and a review would import them a second time.
    func keepAgentTranscripts(sourceIDs: [String], backfillDays: Int) {
        var settings = captureSettings
        for id in sourceIDs { settings.captureSources[id] = true }
        settings.backfillDays = backfillDays > 0 ? backfillDays : nil
        captureSettings = settings
    }

    /// Whether switching a source on should open the import review: only
    /// when no backfill window reads the recent files by itself.
    var offersImportReviewOnCapture: Bool { captureSettings.backfillDays == nil }

    /// The backfill window's start for a capture run starting `now`.
    func backfillSince(now: Date = Date()) -> Date? {
        captureSettings.backfillDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
    }

    func setCapture(_ on: Bool, sourceID: String) {
        if on, offersImportReviewOnCapture { backfillOffer = sourceID }
        // Nested mutation still fires `captureSettings`' didSet, which
        // persists through the store and re-applies capture.
        captureSettings.captureSources[sourceID] = on
    }

    /// Mirrors a persisted settings struct in without echoing it back —
    /// the store is the owner, this only keeps the card's bindings fresh.
    /// The whole struct comes across: a field left behind here (trash
    /// retention once was) reads as unset after a relaunch, and the next
    /// card edit would write that blank back over the saved choice.
    func applyCaptureSettings(_ settings: DataHoarderSettings) {
        guard captureSettings != settings else { return }
        suppressCaptureNotify = true
        captureSettings = settings
        suppressCaptureNotify = false
    }

    /// What the last apply actually told the engine — source set, roots and
    /// the consent flag. A settings mirror that changes nothing effective
    /// must not tear down FSEvent streams and rescan whole trees.
    private var appliedCaptureSignature: String?

    private func capturePlan() -> (sources: [ArchiveSource], signature: String) {
        let sources = (enabled && !captureSettings.paused)
            ? captureSettings.enabledSources.compactMap { captureSource(id: $0) }
            : []
        let signature = sources.map { "\($0.id)|\($0.root.path)" }.sorted()
            .joined(separator: ";") + " fc=\(captureSettings.fullContent)"
        return (sources, signature)
    }

    /// The apply on its way, if any. Applies run one after another, so a
    /// stop and a start — or two starts — never interleave on the engine,
    /// where a second start's `stop` could land mid-rescan and the first
    /// would then open a stream nothing stops. A newer plan cancels the one
    /// before it rather than waiting it out: a first start can be reading a
    /// 30-day backfill, and a pause or switch-off must not queue behind
    /// gigabytes of transcripts. The engine's rescan stops at its next
    /// file without stamping the scan, so the backfill resumes next start.
    @ObservationIgnored private var applyTask: Task<Void, Never>?
    @ObservationIgnored private var captureApplyGeneration: UInt64 = 0
    @ObservationIgnored private var appliesInFlight = 0
    /// Engine applies launched; tests read it to see a repeat dropped.
    @ObservationIgnored private(set) var captureApplies = 0

    /// A new plan always applies. The same plan re-applies only when no
    /// apply is on its way and the engine disagrees with it — switching on
    /// sets `enabled` twice (the utility, then the store's echo), and the
    /// echo must not start a second engine behind the first.
    private func needsApply(_ sources: [ArchiveSource], _ signature: String) -> Bool {
        if signature != appliedCaptureSignature { return true }
        return appliesInFlight == 0 && captureRunning != !sources.isEmpty
    }

    /// Re-derives what should be running. Utility off or paused ⇒ nothing
    /// watches — the disabled-module rule is enforced here, not by trusting
    /// the watcher list to be empty.
    func applyCapture() {
        let (sources, signature) = capturePlan()
        guard needsApply(sources, signature) else { return }
        appliedCaptureSignature = signature
        captureApplyGeneration &+= 1
        let generation = captureApplyGeneration
        let full = captureSettings.fullContent
        let since = backfillSince()
        let previous = applyTask
        previous?.cancel()
        if !enabled { stopIndexing() }
        // A disabled, never-started archive must not open SQLite merely
        // to confirm that it has no work. An existing apply still drains.
        if sources.isEmpty, previous == nil, !captureRunning { return }
        appliesInFlight += 1
        captureApplies += 1
        applyTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                self.appliesInFlight -= 1
                if self.captureApplyGeneration == generation { self.applyTask = nil }
            }
            guard !Task.isCancelled, self.captureApplyGeneration == generation else { return }
            await self.runApply(sources: sources, fullContent: full,
                               backfillSince: since, generation: generation)
        }
    }

    /// Awaitable twin of `applyCapture` for tests and any caller that must
    /// not race a pending fire-and-forget capture task.
    func applyCaptureNow() async {
        applyCapture()
        while let pending = applyTask {
            let generation = captureApplyGeneration
            await pending.value
            if generation == captureApplyGeneration { break }
        }
        if enabled { await refreshCaptureStatus() }
    }

    private func runApply(sources: [ArchiveSource], fullContent: Bool,
                          backfillSince: Date?, generation: UInt64) async {
        guard !Task.isCancelled, generation == captureApplyGeneration else { return }
        if sources.isEmpty {
            await capture.stop()
            guard !Task.isCancelled, generation == captureApplyGeneration else { return }
            captureRunning = false
            return
        }
        await capture.start(sources: sources, fullContent: fullContent, backfillSince: backfillSince)
        guard !Task.isCancelled, generation == captureApplyGeneration, enabled else { return }
        let running = !(await capture.activeSourceIDs).isEmpty
        guard !Task.isCancelled, generation == captureApplyGeneration, enabled else { return }
        captureRunning = running
        await refreshCaptureStatus()
        guard !Task.isCancelled, generation == captureApplyGeneration, enabled else { return }
        pumpSearchIndex()
    }

    private func captureSource(id: String) -> ArchiveSource? {
        captureSourceOptions.first { $0.id == id }
    }

    /// Termination path — `applyCapture` is Task-bound and may lose the
    /// race against process exit; the streams die with it anyway.
    func stopCapture() {
        captureApplyGeneration &+= 1
        let generation = captureApplyGeneration
        applyTask?.cancel()
        appliedCaptureSignature = nil
        stopIndexing()
        Task { [weak self] in
            guard let self, self.captureApplyGeneration == generation else { return }
            await self.capture.stop()
        }
        captureRunning = false
    }

    func refreshCaptureStatus() async {
        let captureGeneration = captureApplyGeneration
        let presentation = presentationGeneration
        func stillCurrent() -> Bool {
            !Task.isCancelled && (enabled || archiveWindowIsOpen)
                && captureGeneration == captureApplyGeneration
                && presentation == presentationGeneration
        }
        guard stillCurrent() else { return }
        let count = (try? await archive.captureFailureCount()) ?? 0
        guard stillCurrent() else { return }
        let failures = (try? await archive.captureFailures(limit: 20)) ?? []
        guard stillCurrent() else { return }
        let projects = (try? await archive.searchableProjects()) ?? []
        guard stillCurrent() else { return }
        let progress = try? await archive.indexProgress()
        guard stillCurrent() else { return }
        captureFailureCount = count
        captureFailures = failures
        availableProjects = projects
        indexProgress = progress
    }

    private func stopIndexing() {
        indexGeneration &+= 1
        indexRequested = false
        indexTask?.cancel()
        indexTask = nil
    }

    /// One worker drains pending segments; refreshes request another pass.
    func pumpSearchIndex() {
        guard enabled else { return }
        if indexTask != nil {
            indexRequested = true
            return
        }
        indexGeneration &+= 1
        let generation = indexGeneration
        indexTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.indexGeneration == generation { self.indexTask = nil }
            }
            while !Task.isCancelled, self.enabled, generation == self.indexGeneration {
                self.indexRequested = false
                let indexed = (try? await self.archive.indexPendingSegments(limit: 200)) ?? 0
                guard !Task.isCancelled, self.enabled, generation == self.indexGeneration else { return }
                let progress = try? await self.archive.indexProgress()
                guard !Task.isCancelled, self.enabled, generation == self.indexGeneration else { return }
                self.indexProgress = progress
                if indexed == 0 && !self.indexRequested { return }
                await Task.yield()
            }
        }
    }

    // MARK: Search

    var searchActive: Bool { !query.isEmpty || !searchFilter.isEmpty }

    private struct SearchRequest: Equatable {
        let query: String
        let filter: ArchiveSearchFilter
        let trash: Bool
    }

    private var currentSearchRequest: SearchRequest {
        SearchRequest(query: query, filter: searchFilter, trash: showTrash)
    }

    @ObservationIgnored private var displayedSearchRequest: SearchRequest?

    /// Replaces the current search. The view owns cancellation and debounce.
    func runSearch() async {
        guard !Task.isCancelled else { return }
        searchRevision &+= 1
        let rev = searchRevision
        let request = currentSearchRequest
        displayedSearchRequest = nil
        searchHasMore = false
        searching = true
        defer { if rev == searchRevision { searching = false } }
        do {
            if request.trash {
                let found = try await archive.records(query: request.query, inTrash: true)
                guard rev == searchRevision, request == currentSearchRequest,
                      !Task.isCancelled else { return }
                let filtered = found.filter { Self.matchesSearchFilter($0, filter: request.filter) }
                searchResults = filtered.map { ArchiveSearchResult(record: $0, snippets: [], rank: nil) }
                searchOffset = searchResults.count
            } else {
                // One look-ahead row answers pagination without a second search.
                let page = try await archive.search(query: request.query, filter: request.filter,
                                                    offset: 0, limit: Self.pageSize + 1)
                guard rev == searchRevision, request == currentSearchRequest,
                      !Task.isCancelled else { return }
                searchResults = Array(page.prefix(Self.pageSize))
                searchOffset = searchResults.count
                searchHasMore = page.count > Self.pageSize
            }
            displayedSearchRequest = request
            if !searchResults.contains(where: { $0.record.id == selectedID }) {
                selectedID = searchResults.first?.record.id
            }
            searchError = nil
        } catch {
            guard rev == searchRevision, request == currentSearchRequest,
                  !Task.isCancelled else { return }
            searchError = error.localizedDescription
        }
    }

    func loadMoreSearch() async {
        let request = currentSearchRequest
        guard !Task.isCancelled, searchHasMore, !searching, !request.trash,
              displayedSearchRequest == request else { return }
        let rev = searchRevision
        let offset = searchOffset
        searching = true
        defer { if rev == searchRevision { searching = false } }
        do {
            let page = try await archive.search(query: request.query, filter: request.filter,
                                                offset: offset, limit: Self.pageSize + 1)
            guard rev == searchRevision, request == currentSearchRequest,
                  !Task.isCancelled else { return }
            let visible = page.prefix(Self.pageSize)
            searchResults.append(contentsOf: visible)
            searchOffset += visible.count
            searchHasMore = page.count > Self.pageSize
            searchError = nil
        } catch {
            guard rev == searchRevision, request == currentSearchRequest,
                  !Task.isCancelled else { return }
            searchError = error.localizedDescription
        }
    }

    /// The archive's private `matches` mirrored for the trash path, where
    /// FTS rows don't reach — same predicate fields, same semantics.
    private static func matchesSearchFilter(_ record: ArchiveRecord, filter: ArchiveSearchFilter) -> Bool {
        if !filter.providers.isEmpty {
            guard let provider = record.provider, filter.providers.contains(provider) else { return false }
        }
        if let project = filter.project, record.project != project { return false }
        if !filter.states.isEmpty, !filter.states.contains(record.captureState) { return false }
        let activity = record.lastActivityAt ?? record.importedAt
        if let from = filter.from, activity < from { return false }
        if let to = filter.to, activity > to { return false }
        return true
    }

    /// Terms the preview view highlights — the query's words, capped so a
    /// long sentence doesn't paint the whole preview.
    var previewHighlightTerms: [String] {
        Array(query.split(whereSeparator: \.isWhitespace).map(String.init).prefix(8))
    }

    // MARK: Record actions

    func revealInFinder(_ record: ArchiveRecord) {
        let url = URL(fileURLWithPath: record.sourcePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyPath(_ record: ArchiveRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.sourcePath, forType: .string)
    }

    func sessionID(for record: ArchiveRecord) -> String? {
        sessionResolver?(record)
    }

    func openInTerminal(_ record: ArchiveRecord) {
        guard let id = sessionResolver?(record) else { return }
        sessionOpener?(id)
    }

    /// Switching a source's capture on opens the sources review with that
    /// source preselected, so "also import existing files" is one checkbox.
    func offerBackfill(for sourceID: String) async {
        backfillOffer = nil
        await discoverHistory()
        if sourceInventories.contains(where: { $0.id == sourceID }) {
            selectedSources = [sourceID]
        }
    }

    // MARK: Archived timelines for other windows

    /// The archived copy of a session's transcript, rebuilt — what the
    /// Overview inspector shows when the live transcript was cleaned up or
    /// moved. The newest Claude/Codex record filed under the session's id
    /// wins; segment reads are hash-verified like every other archive read,
    /// and the rebuild runs off-main. Nil when the archive never kept it.
    nonisolated static func archivedTimeline(in archive: DataHoarderArchive,
                                             sessionID: String) async -> (SessionReconstruction, ArchiveRecord)? {
        guard !sessionID.isEmpty,
              let records = try? await archive.relatedRecords(sessionID: sessionID),
              let record = newestTranscript(in: records),
              let provider = record.provider,
              let payloads = try? await archive.segmentData(id: record.id) else { return nil }
        let startedAt = record.startedAt
        let rebuilt = await Task.detached(priority: .userInitiated) {
            SessionReconstructor.reconstruct(segments: payloads, provider: provider, epochFallback: startedAt)
        }.value
        return (rebuilt.withProxyRequests(await proxyRequests(in: archive, records: records)), record)
    }

    /// The CLIProxyAPI requests a session's saved records include, parsed
    /// off-main from hash-verified segments — the newest
    /// `SessionProxyEvidence.requestLimit`, since a long session behind a
    /// proxy logs one file per request. A record that no longer parses
    /// is left out, never guessed at.
    nonisolated static func proxyRequests(in archive: DataHoarderArchive,
                                          records: [ArchiveRecord]) async -> [CLIProxyRequest] {
        let proxied = records
            .filter { $0.provider == "cliproxy" }
            .sorted { ($0.lastActivityAt ?? $0.importedAt) > ($1.lastActivityAt ?? $1.importedAt) }
            .prefix(SessionProxyEvidence.requestLimit)
        guard !proxied.isEmpty else { return [] }
        var logs: [Data] = []
        for record in proxied {
            guard !Task.isCancelled, let payloads = try? await archive.segmentData(id: record.id) else { continue }
            var data = Data()
            for payload in payloads { data.append(payload) }
            logs.append(data)
        }
        let captured = logs
        return await Task.detached(priority: .userInitiated) {
            captured.compactMap(CLIProxyLogParser.parse)
        }.value
    }

    /// History's transcript search: session uuid → the best readable
    /// snippet, from full-text hits in Claude and Codex transcripts only
    /// (a metadata hit on a folder name says nothing about what was said).
    nonisolated static func transcriptHits(in archive: DataHoarderArchive, query: String,
                                           limit: Int = 100) async -> [String: String] {
        let filter = ArchiveSearchFilter(providers: ["claude", "codex"])
        guard let results = try? await archive.search(query: query, filter: filter, limit: limit) else { return [:] }
        var hits: [String: String] = [:]
        for result in results where result.rank != nil {
            guard let session = result.record.sessionID, !session.isEmpty, hits[session] == nil else { continue }
            hits[session] = result.snippets.first.map(TranscriptSnippet.readable) ?? ""
        }
        return hits
    }

    /// The proxy's requests for one session id, for a timeline built
    /// elsewhere (the Overview's live transcript).
    nonisolated static func proxyRequests(in archive: DataHoarderArchive,
                                          sessionID: String) async -> [CLIProxyRequest] {
        guard !sessionID.isEmpty,
              let records = try? await archive.relatedRecords(sessionID: sessionID) else { return [] }
        return await proxyRequests(in: archive, records: records)
    }

    /// The transcript record a session's timeline should come from: a
    /// Claude or Codex record (never a CLIProxyAPI request log), newest
    /// activity first.
    nonisolated static func newestTranscript(in records: [ArchiveRecord]) -> ArchiveRecord? {
        records
            .filter { $0.provider == "claude" || $0.provider == "codex" }
            .max { ($0.lastActivityAt ?? $0.importedAt) < ($1.lastActivityAt ?? $1.importedAt) }
    }
}
