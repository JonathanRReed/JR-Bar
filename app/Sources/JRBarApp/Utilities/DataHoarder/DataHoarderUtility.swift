import AppKit
import JRBarCore
import SwiftUI

@MainActor
@Observable
final class DataHoarderUtility: Toy {
    let model = DataHoarderModel()
    var onEnabledChange: ((Bool) -> Void)?
    @ObservationIgnored private var window: NSWindow?

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

    func openArchive() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Data Hoarder"
            window.identifier = NSUserInterfaceItemIdentifier("data-hoarder")
            window.contentView = NSHostingView(rootView: DataHoarderView(model: model))
            window.minSize = NSSize(width: 740, height: 480)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
            if !enabled { stopImport() }
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
    var selectedID: String?
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
        records.first { $0.id == selectedID }
            ?? searchResults.first { $0.record.id == selectedID }?.record
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
        guard !busy else { return }
        preview = ""
        previewError = nil
        guard let requested = selectedID else { return }
        let requestedTrash = showTrash
        do {
            let text = try await archive.preview(id: requested, inTrash: requestedTrash)
            guard !Task.isCancelled, requested == selectedID, requestedTrash == showTrash else { return }
            preview = text.isEmpty ? "Empty file" : text
        } catch {
            guard !Task.isCancelled, requested == selectedID, requestedTrash == showTrash else { return }
            previewError = error.localizedDescription
            preview = "Preview unavailable. The saved file could not be read safely."
        }
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

    /// Loads everything the detail pane beyond the raw preview needs:
    /// segment notes, related records, and — depending on the sniffed kind —
    /// the reconstructed timeline or the parsed CLIProxyAPI request. Segment
    /// reads are hash-verified by the archive; reconstruction and parsing run
    /// off-main. Cancellable and stale-guarded like `loadPreview`.
    func loadDetail() async {
        detailRevision &+= 1
        let revision = detailRevision
        detailKind = .plain
        detailLoading = false
        detailError = nil
        reconstruction = nil
        cliProxyRequest = nil
        relatedRecords = []
        segmentNotes = []
        guard !busy, let record = selected else { return }
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
                let provider = (provider == "claude" || provider == "codex") ? provider! : "other"
                let epochFallback = record.startedAt
                let rebuilt = await Task.detached(priority: .userInitiated) {
                    SessionReconstructor.reconstruct(segments: payloads, provider: provider,
                                                     epochFallback: epochFallback)
                }.value
                guard !Task.isCancelled, revision == detailRevision,
                      selectedID == id, requestedTrash == showTrash else { return }
                reconstruction = rebuilt
            } catch {
                guard !Task.isCancelled, revision == detailRevision else { return }
                detailError = "Timeline unavailable: \(error.localizedDescription)"
            }
        case .cliProxy:
            detailLoading = true
            defer { if revision == detailRevision { detailLoading = false } }
            do {
                let payloads = try await archive.segmentData(id: id, inTrash: requestedTrash)
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
        let needed = selection.reduce(Int64(0)) { $0 + max(0, $1.size) }
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

    func setCapture(_ on: Bool, sourceID: String) {
        if on { backfillOffer = sourceID }
        // Nested mutation still fires `captureSettings`' didSet, which
        // persists through the store and re-applies capture.
        captureSettings.captureSources[sourceID] = on
    }

    /// Mirrors a persisted settings struct in without echoing it back —
    /// the store is the owner, this only keeps the card's bindings fresh.
    func applyCaptureSettings(_ settings: DataHoarderSettings) {
        guard captureSettings != settings else { return }
        var copy = captureSettings
        copy.captureSources = settings.captureSources
        copy.fullContent = settings.fullContent
        copy.paused = settings.paused
        suppressCaptureNotify = true
        captureSettings = copy
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

    /// Re-derives what should be running. Utility off or paused ⇒ nothing
    /// watches — the disabled-module rule is enforced here, not by trusting
    /// the watcher list to be empty.
    func applyCapture() {
        let (sources, signature) = capturePlan()
        guard signature != appliedCaptureSignature || captureRunning != !sources.isEmpty else {
            return
        }
        appliedCaptureSignature = signature
        let full = captureSettings.fullContent
        Task {
            if sources.isEmpty {
                await capture.stop()
                captureRunning = false
            } else {
                await capture.start(sources: sources, fullContent: full)
                captureRunning = !(await capture.activeSourceIDs).isEmpty
            }
            await refreshCaptureStatus()
            pumpSearchIndex()
        }
    }

    /// Awaitable twin of `applyCapture` for tests and any caller that must
    /// not race a pending fire-and-forget capture task.
    func applyCaptureNow() async {
        let (sources, signature) = capturePlan()
        guard signature != appliedCaptureSignature || captureRunning != !sources.isEmpty else {
            await refreshCaptureStatus()
            return
        }
        appliedCaptureSignature = signature
        if sources.isEmpty {
            await capture.stop()
            captureRunning = false
        } else {
            await capture.start(sources: sources, fullContent: captureSettings.fullContent)
            captureRunning = !(await capture.activeSourceIDs).isEmpty
        }
        await refreshCaptureStatus()
        pumpSearchIndex()
    }

    private func captureSource(id: String) -> ArchiveSource? {
        captureSourceOptions.first { $0.id == id }
    }

    /// Termination path — `applyCapture` is Task-bound and may lose the
    /// race against process exit; the streams die with it anyway.
    func stopCapture() {
        Task { await capture.stop() }
        captureRunning = false
    }

    func refreshCaptureStatus() async {
        captureFailureCount = (try? await archive.captureFailureCount()) ?? 0
        captureFailures = (try? await archive.captureFailures(limit: 20)) ?? []
        availableProjects = (try? await archive.searchableProjects()) ?? []
        indexProgress = try? await archive.indexProgress()
    }

    /// Pumps the FTS backfill until the pending queue drains (or a newer pass
    /// supersedes this one). Called after imports, capture ticks and refresh.
    func pumpSearchIndex() {
        indexTask?.cancel()
        indexTask = Task {
            while !Task.isCancelled {
                let indexed = (try? await archive.indexPendingSegments(limit: 200)) ?? 0
                guard !Task.isCancelled else { return }
                if indexed == 0 { break }
                indexProgress = try? await archive.indexProgress()
            }
            indexProgress = try? await archive.indexProgress()
        }
    }

    // MARK: Search

    var searchActive: Bool {
        !query.isEmpty || searchFilter.provider != nil || searchFilter.project != nil
            || searchFilter.state != nil || searchFilter.from != nil || searchFilter.to != nil
    }

    /// Cancels the in-flight page and runs the first page. The caller debounces.
    func runSearch() async {
        guard enabled else { return }
        searchRevision &+= 1
        let rev = searchRevision
        searching = true
        let q = query
        let filter = searchFilter
        do {
            if showTrash {
                // FTS rows key off live records, so trash searches run the
                // catalog scan — bounded fine for trash-sized sets.
                let found = try await archive.records(query: q, inTrash: true)
                let filtered = found.filter { Self.matchesSearchFilter($0, filter: filter) }
                guard rev == searchRevision, !Task.isCancelled else { return }
                searchResults = filtered.map { ArchiveSearchResult(record: $0, snippets: [], rank: nil) }
                searchOffset = searchResults.count
                searchHasMore = false
            } else {
                async let page = archive.search(query: q, filter: filter, offset: 0, limit: Self.pageSize)
                async let more = archive.searchHasMore(query: q, filter: filter, offset: 0, limit: Self.pageSize)
                let (results, hasMore) = try await (page, more)
                guard rev == searchRevision, !Task.isCancelled else { return }
                searchResults = results
                searchOffset = results.count
                searchHasMore = hasMore
            }
            searching = false
            searchError = nil
        } catch {
            guard rev == searchRevision else { return }
            searching = false
            searchError = error.localizedDescription
        }
    }

    func loadMoreSearch() async {
        guard searchHasMore, !searching, !showTrash else { return }
        let rev = searchRevision
        searching = true
        let q = query
        let filter = searchFilter
        let offset = searchOffset
        do {
            async let page = archive.search(query: q, filter: filter, offset: offset, limit: Self.pageSize)
            async let more = archive.searchHasMore(query: q, filter: filter, offset: offset, limit: Self.pageSize)
            let (results, hasMore) = try await (page, more)
            guard rev == searchRevision, !Task.isCancelled else { return }
            searchResults.append(contentsOf: results)
            searchOffset += results.count
            searchHasMore = hasMore
            searching = false
        } catch {
            guard rev == searchRevision else { return }
            searching = false
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
}
