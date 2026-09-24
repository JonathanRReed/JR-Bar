import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The utilities store's own wiring. Every reply is staged; nothing here
/// reaches a daemon or raises a window.
@Suite("Utilities store")
@MainActor
struct UtilitiesStoreTests {
    @MainActor
    final class Log {
        var calls: [String] = []
    }

    private static let live = CoreSession(id: "claude:session:a", provider: "claude", label: "Ship it",
                                          mode: "working")

    private func staged(_ log: Log, reply: CoreReply, raises: Bool) -> SessionOpener.Wiring {
        SessionOpener.Wiring(
            send: { id in
                log.calls.append("open:\(id)")
                return reply
            },
            sessions: { [Self.live] },
            raise: { id in
                log.calls.append("raise:\(id)")
                return raises
            })
    }

    @Test("an archived record opens its session through the opener, and a refusal is the archive's line")
    func archivedSessionOpens() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hoarder = DataHoarderModel(archive: DataHoarderArchive(root: root.appending(path: "archive")))
        let log = Log()
        let notFound = CoreReply(id: "1", ok: false, error: CoreReplyError(code: "not_found", message: "no window"))

        await UtilitiesStore.openArchived(Self.live.id, via: staged(log, reply: notFound, raises: true), on: hoarder)
        #expect(log.calls == ["open:claude:session:a", "raise:claude:session:a"],
                "the daemon first, then the Dock's window locator — the panel's path")
        #expect(hoarder.message == nil, "in front: nothing to say")

        await UtilitiesStore.openArchived(Self.live.id, via: staged(log, reply: notFound, raises: false), on: hoarder)
        #expect(hoarder.message == "no window", "the refusal is heard, not dropped")

        await UtilitiesStore.openArchived("claude:session:a", via: nil, on: hoarder)
        #expect(hoarder.message == SessionOpener.notAnswering)
    }
}
