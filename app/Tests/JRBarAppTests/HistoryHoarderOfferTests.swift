import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// History's empty search offers the Data Hoarder in one line; the offer's
/// sheet quotes what a backfill window would read, from metadata alone,
/// and turns capture on only on its own click.
@MainActor
@Suite struct HistoryHoarderOfferTests {
    private func store(keeps: Bool) -> (HistoryStore, Box) {
        let store = HistoryStore(core: CoreModel())
        let box = Box()
        store.rows = [CoreHistoryRow(at: 10, kind: "completed", provider: "claude", label: "Docs")]
        store.hoarderKeepsTranscripts = { keeps }
        store.keepTranscripts = { ids, days in box.accepted = (ids, days) }
        return (store, box)
    }

    final class Box { var accepted: ([String], Int)? }

    @Test("the offer shows for a real query with no transcript copy, and nowhere else")
    func offerVisibility() {
        let (off, _) = store(keeps: false)
        #expect(!off.offersHoarder, "no query, no offer")
        off.filter.text = "au"
        #expect(!off.offersHoarder, "a query too short to search transcripts")
        off.filter.text = "auth middleware"
        #expect(off.filtered.isEmpty)
        #expect(off.offersHoarder)

        let (on, _) = store(keeps: true)
        on.filter.text = "auth middleware"
        #expect(!on.offersHoarder, "the Data Hoarder already keeps transcripts")

        let unwired = HistoryStore(core: CoreModel())
        unwired.filter.text = "auth middleware"
        #expect(!unwired.offersHoarder, "nothing to turn on without the utility")
    }

    @Test("the sheet estimates the window from metadata and accepts only on its click")
    func sheetEstimatesThenAccepts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appending(path: "claude")
        let codex = root.appending(path: "codex")
        let missing = root.appending(path: "gemini")
        for folder in [claude, codex] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data(repeating: 0x61, count: 1_000).write(to: claude.appending(path: "a.jsonl"))
        let old = codex.appending(path: "b.jsonl")
        try Data(repeating: 0x62, count: 4_000).write(to: old)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-45 * 86_400)], ofItemAtPath: old.path)

        let (history, box) = store(keeps: false)
        history.offerSources = {
            [ArchiveSource(id: "claude-projects", name: "Claude Code projects", root: claude, extensions: ["jsonl"]),
             ArchiveSource(id: "codex-sessions", name: "Codex sessions", root: codex, extensions: ["jsonl"]),
             ArchiveSource(id: "gemini-chats", name: "Gemini CLI chats", root: missing, extensions: ["jsonl"])]
        }
        history.filter.text = "auth middleware"
        history.offerHoarder()
        let offer = try #require(history.hoarderOffer)
        #expect(box.accepted == nil, "opening the sheet turns nothing on")

        await offer.load()
        // A missing folder is left out; a folder with nothing recent is
        // listed but starts unchosen.
        #expect(offer.inventories.map(\.id) == ["claude-projects", "codex-sessions"])
        #expect(offer.chosen == ["claude-projects"])
        #expect(offer.days == 30)
        #expect(offer.total == ArchiveBackfillEstimate(fileCount: 1, byteCount: 1_000))
        offer.days = 90
        offer.toggle("codex-sessions")
        #expect(offer.total == ArchiveBackfillEstimate(fileCount: 2, byteCount: 5_000))

        offer.accept()
        let accepted = try #require(box.accepted)
        #expect(accepted.0 == ["claude-projects", "codex-sessions"])
        #expect(accepted.1 == 90)
        #expect(history.hoarderOffer == nil)
        #expect(history.notice?.text.contains("last 90 days") == true)
    }

    @Test("the sheet says verbatim, not redacted, when full content is already on")
    func consentFollowsFullContent() throws {
        let (redacted, _) = store(keeps: false)
        redacted.filter.text = "auth middleware"
        redacted.offerHoarder()
        let quiet = try #require(redacted.hoarderOffer)
        #expect(quiet.fullContent == false)
        #expect(DataHoarderOffer.contentNote(fullContent: false).contains("[redacted]"))

        // Ticked on the card once, then the utility switched off: Turn On
        // keeps that switch, so the backfill is read verbatim.
        let (verbatim, _) = store(keeps: false)
        verbatim.hoarderFullContent = { true }
        verbatim.filter.text = "auth middleware"
        verbatim.offerHoarder()
        let full = try #require(verbatim.hoarderOffer)
        #expect(full.fullContent)
        let note = DataHoarderOffer.contentNote(fullContent: true)
        #expect(note == "Full content is on in Data Hoarder: prompts and responses are kept verbatim.")
        #expect(!note.contains("[redacted]"))
    }

    @Test("the estimate reads in plain words")
    func summaryWords() {
        #expect(DataHoarderOffer.summary(.zero).hasPrefix("No files in this window"))
        let one = DataHoarderOffer.summary(ArchiveBackfillEstimate(fileCount: 1, byteCount: 2_000_000))
        #expect(one.contains("from 1 file,"))
        #expect(DataHoarderOffer.rowDetail(.zero, days: 7) == "nothing in 7 days")
        #expect(DataHoarderOffer.provider(of: "codex-archived-sessions") == "codex")
    }
}
