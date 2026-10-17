import AppKit
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Notch stage transaction ownership")
struct NotchStageTransactionTests {
    private final class Record {
        var updates: [(revision: Int, animated: Bool)] = []
    }

    private struct Probe: NSViewRepresentable {
        let revision: Int
        let record: Record

        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ view: NSView, context: Context) {
            record.updates.append((revision, context.transaction.animation != nil
                                   && !context.transaction.disablesAnimations))
        }
    }

    private struct Scene: View {
        let stage: NotchStageModel
        let revision: Int
        let record: Record

        var body: some View {
            Probe(revision: revision, record: record)
                .animation(.easeOut(duration: 0.2), value: revision)
                .modifier(NotchStageFrame(stage: stage))
        }
    }

    @Test("a changing face cannot add a second animation to the stage's geometry")
    func stagedFaceCannotAnimateAgain() throws {
        let stage = NotchStageModel()
        let record = Record()
        stage.shape = CGRect(x: 100, y: 0, width: 180, height: 32)
        let host = NSHostingView(rootView: Scene(stage: stage, revision: 0, record: record))
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        host.layoutSubtreeIfNeeded()
        stage.shape = CGRect(x: 10, y: 0, width: 380, height: 320)
        host.rootView = Scene(stage: stage, revision: 1, record: record)
        host.layoutSubtreeIfNeeded()
        let updates = record.updates.filter { $0.revision == 1 }
        try #require(!updates.isEmpty, "the hosted face did not receive its update")
        #expect(updates.allSatisfy { !$0.animated }, "the frame spring must own all staged geometry")
    }

    @Test("a settled face keeps its ordinary crossfade transaction")
    func settledFaceCanCrossfade() throws {
        let stage = NotchStageModel()
        let record = Record()
        let host = NSHostingView(rootView: Scene(stage: stage, revision: 0, record: record))
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        host.layoutSubtreeIfNeeded()
        host.rootView = Scene(stage: stage, revision: 1, record: record)
        host.layoutSubtreeIfNeeded()
        let updates = record.updates.filter { $0.revision == 1 }
        try #require(!updates.isEmpty, "the settled face did not receive its update")
        #expect(updates.contains { $0.animated })
    }
}
