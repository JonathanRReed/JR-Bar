import JRBarCore

/// Explicit reads of retained evidence do not confer capture/import consent.
/// Keep these bindings shared by the app and its regression tests; no timers,
/// source discovery, backfill, indexing, or capture start is installed here.
@MainActor
enum ArchiveReadBindings {
    static func install(history: HistoryStore, model: DataHoarderModel) {
        history.archiveSearch = { [weak model] query in
            guard let model else { return [:] }
            return await DataHoarderModel.transcriptHits(in: model.archive, query: query)
        }
        history.archiveSearchAvailable = { [weak model] in model != nil }
    }

    static func install(overview: OverviewStore, model: DataHoarderModel) {
        overview.archiveTimeline = { [weak model] sessionID in
            guard let model else { return nil }
            return await DataHoarderModel.archivedTimeline(in: model.archive, sessionID: sessionID)
        }
        overview.archiveProxyEvidence = { [weak model] sessionID in
            guard let model else { return [] }
            return await DataHoarderModel.proxyRequests(in: model.archive, sessionID: sessionID)
        }
    }
}
