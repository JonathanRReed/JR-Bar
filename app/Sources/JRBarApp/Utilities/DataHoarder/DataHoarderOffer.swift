import JRBarCore
import SwiftUI

/// History's offer of the Data Hoarder: which agent folders exist on this
/// Mac, what a backfill window would read from each, and the one click
/// that turns capture on. Only file names, sizes and dates are read until
/// that click; nothing is archived by opening the sheet.
@MainActor
@Observable
final class DataHoarderOffer: Identifiable {
    let id = UUID()
    /// The windows the sheet offers, in days.
    static let windows = [7, 30, 90]
    /// The window a first look proposes.
    static let defaultDays = 30

    var days = DataHoarderOffer.defaultDays
    private(set) var inventories: [ArchiveSourceInventory] = []
    var chosen: Set<String> = []
    private(set) var loading = false
    private(set) var loaded = false
    /// Data Hoarder's own "Store full prompts and responses" switch. Turn
    /// On leaves it as it is, so the sheet must say which copy it keeps.
    let fullContent: Bool
    /// When each listed source was last kept. The engine's window reads
    /// only sources new to it; one kept before picks up where it stopped,
    /// so its estimate counts what changed since instead.
    private(set) var resumesFrom: [String: Date] = [:]

    private let sources: [ArchiveSource]
    private let scanner: DataHoarderSourceScanner
    private let resumePoints: @MainActor ([String]) async -> [String: Date]
    private let onAccept: @MainActor (_ sourceIDs: [String], _ days: Int) -> Void
    @ObservationIgnored private let now: () -> Date

    init(sources: [ArchiveSource] = DataHoarderModel.agentSources(),
         scanner: DataHoarderSourceScanner = DataHoarderSourceScanner(),
         fullContent: Bool = false,
         resumePoints: @escaping @MainActor ([String]) async -> [String: Date] = { _ in [:] },
         now: @escaping () -> Date = Date.init,
         accept: @escaping @MainActor (_ sourceIDs: [String], _ days: Int) -> Void) {
        self.sources = sources
        self.fullContent = fullContent
        self.resumePoints = resumePoints
        self.scanner = scanner
        self.now = now
        onAccept = accept
    }

    /// Reads the folders' metadata once. A folder that is missing or not a
    /// folder is left out — the sheet lists what this Mac actually has.
    /// Every source with a file in the default window starts chosen, and
    /// so does every source kept before — it was chosen once already.
    func load() async {
        guard !loading, !loaded else { return }
        loading = true
        defer { loading = false }
        let found = (try? await scanner.scan(sources)) ?? []
        let listed = found.filter { !$0.files.isEmpty }
        resumesFrom = await resumePoints(listed.map(\.id))
        inventories = listed
        chosen = Set(inventories.filter {
            resumesFrom[$0.id] != nil || estimate(for: $0).fileCount > 0
        }.map(\.id))
        loaded = true
    }

    func estimate(for inventory: ArchiveSourceInventory) -> ArchiveBackfillEstimate {
        if let since = resumesFrom[inventory.id] {
            return ArchiveBackfillEstimate.of(inventory, changedAfter: since)
        }
        return ArchiveBackfillEstimate.of(inventory, days: days, now: now())
    }

    /// Whether the window picker changes anything: some listed source is
    /// new to the Data Hoarder.
    var windowApplies: Bool {
        !loaded || inventories.contains { resumesFrom[$0.id] == nil }
    }

    /// Every chosen source was kept before, so Turn On resumes rather
    /// than reading a window.
    var resumesEveryChosenSource: Bool {
        !chosen.isEmpty && chosen.allSatisfy { resumesFrom[$0] != nil }
    }

    /// What the chosen folders' window adds up to.
    var total: ArchiveBackfillEstimate {
        ArchiveBackfillEstimate.total(inventories.filter { chosen.contains($0.id) }.map(estimate(for:)))
    }

    var canAccept: Bool { !chosen.isEmpty && !loading }

    func toggle(_ sourceID: String) {
        if chosen.contains(sourceID) { chosen.remove(sourceID) } else { chosen.insert(sourceID) }
    }

    /// The consent click: the chosen sources, in the sheet's order.
    func accept() {
        guard canAccept else { return }
        onAccept(inventories.map(\.id).filter(chosen.contains), days)
    }

    /// "About 1.3 GB from 212 files" — the raw bytes the window reads; the
    /// kept copy is smaller while full content stays off.
    static func summary(_ estimate: ArchiveBackfillEstimate) -> String {
        guard estimate.fileCount > 0 else { return "No files in this window yet — new activity is kept from now on." }
        let files = estimate.fileCount == 1 ? "1 file" : "\(estimate.fileCount) files"
        return "Reads about \(DataHoarderModel.bytes(estimate.byteCount)) from \(files), then follows new activity live."
    }

    /// What the kept copy holds — the consent the click gives. Full
    /// content left on from an earlier visit means verbatim copies, and
    /// the sheet must not promise redaction then.
    static func contentNote(fullContent: Bool) -> String {
        fullContent
            ? "Full content is on in Data Hoarder: prompts and responses are kept verbatim."
            : "Prompts and responses are kept as “[redacted]”: the copy holds each session's projects, branches, tools, models and times. Full content is a separate switch in Data Hoarder."
    }

    /// A source row's trailing detail: "212 files · 1.3 GB", or for a
    /// source kept before, "since Sep 12 · 3 files · 20 MB".
    static func rowDetail(_ estimate: ArchiveBackfillEstimate, days: Int,
                          resumesFrom: Date? = nil, now: Date = Date()) -> String {
        if let resumesFrom {
            let day = Self.day(resumesFrom, now: now)
            guard estimate.fileCount > 0 else { return "nothing new since \(day)" }
            let files = estimate.fileCount == 1 ? "1 file" : "\(estimate.fileCount) files"
            return "since \(day) · \(files) · \(DataHoarderModel.bytes(estimate.byteCount))"
        }
        guard estimate.fileCount > 0 else { return "nothing in \(days) days" }
        let files = estimate.fileCount == 1 ? "1 file" : "\(estimate.fileCount) files"
        return "\(files) · \(DataHoarderModel.bytes(estimate.byteCount))"
    }

    /// "Sep 12", with the year once it is not this one.
    static func day(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let style = Date.FormatStyle(date: .omitted, time: .omitted).month(.abbreviated).day()
        return calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? date.formatted(style) : date.formatted(style.year())
    }

    /// The provider tile a source's row wears.
    nonisolated static func provider(of sourceID: String) -> String {
        switch sourceID {
        case "claude-projects": "claude"
        case "codex-sessions", "codex-archived-sessions": "codex"
        case "pi-sessions": "pi"
        case "gemini-chats": "gemini"
        case "grok-sessions": "grok"
        default: sourceID
        }
    }
}

/// The consent sheet: what would be read, from where, how big, and what
/// the kept copy holds — then Not Now or Turn On.
struct DataHoarderOfferSheet: View {
    @Bindable var offer: DataHoarderOffer
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            windowPicker
            sourceList
            VStack(alignment: .leading, spacing: 6) {
                if offer.loaded {
                    // Only once the folders are read: a "no files" line
                    // under the spinner would contradict it.
                    Text(DataHoarderOffer.summary(offer.total))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Label {
                    Text(DataHoarderOffer.contentNote(fullContent: offer.fullContent))
                } icon: {
                    Image(systemName: offer.fullContent ? "text.quote" : "text.redaction")
                }
                if !offer.resumesFrom.isEmpty {
                    Label {
                        Text("Folders kept before pick up where they stopped; the window reads only folders new to Data Hoarder.")
                    } icon: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                }
                Label {
                    Text("Nothing leaves this Mac. Turn it off any time under Utilities › Data Hoarder.")
                } icon: {
                    Image(systemName: "lock")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .labelStyle(OfferNoteLabelStyle())
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not Now", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Turn On Data Hoarder") {
                    offer.accept()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!offer.canAccept)
            }
        }
        .padding(22)
        .frame(width: 470)
        .task { await offer.load() }
        .animation(.easeOut(duration: 0.18), value: offer.days)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            DataHoarderMark(size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep a searchable copy of your sessions")
                    .font(.system(size: 15, weight: .semibold))
                Text("History searched only its own rows. Data Hoarder keeps a local copy of your agent transcripts, so a search can reach the sessions behind them.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var windowPicker: some View {
        HStack(spacing: 10) {
            Text("Start with the last")
                .font(.system(size: 12))
            Picker("Start with the last", selection: $offer.days) {
                ForEach(DataHoarderOffer.windows, id: \.self) { Text("\($0) days").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!offer.windowApplies)
        }
        .help(offer.windowApplies ? "" : "Every folder here was kept before, so it picks up where it stopped")
    }

    @ViewBuilder
    private var sourceList: some View {
        if offer.loading || !offer.loaded {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for agent folders…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        } else if offer.inventories.isEmpty {
            Text("No agent transcript folders on this Mac yet, so there is nothing to keep. History offers this again once an agent has written one.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(offer.inventories.enumerated()), id: \.element.id) { index, inventory in
                    if index > 0 { Divider().padding(.leading, 36) }
                    sourceRow(inventory)
                }
            }
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    private func sourceRow(_ inventory: ArchiveSourceInventory) -> some View {
        let estimate = offer.estimate(for: inventory)
        let style = ProviderStyle.style(for: DataHoarderOffer.provider(of: inventory.id))
        let chosen = Binding(get: { offer.chosen.contains(inventory.id) }, set: { _ in offer.toggle(inventory.id) })
        return Toggle(isOn: chosen) {
            HStack(spacing: 8) {
                ProviderTile(style: style, size: 18)
                Text(inventory.source.name).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Text(DataHoarderOffer.rowDetail(estimate, days: offer.days,
                                                resumesFrom: offer.resumesFrom[inventory.id]))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .help(inventory.source.root.path)
    }
}

/// The notes under the estimate: a small fixed-width icon column so the
/// wrapped lines align.
private struct OfferNoteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.frame(width: 14)
            configuration.title
        }
    }
}
