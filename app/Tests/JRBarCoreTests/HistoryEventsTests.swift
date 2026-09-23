import Foundation
import Testing
@testable import JRBarCore

/// History's Events tab (Event Replay folded in), the light log the Why
/// popover draws from it, and which rows open a timeline.
@Suite("History events")
struct HistoryEventsTests {
    static let journal: [CoreEvent] = [
        CoreEvent(id: "1", kind: "ask_opened", session: "codex:session:a", label: "sidepulse-core", at: 100, provider: "codex"),
        CoreEvent(id: "2", kind: CoreEvent.usageHistoryReadyKind, at: 101, provider: "claude"),
        CoreEvent(id: "3", kind: "device_connected", label: "SidePulse Pro", at: 102),
        CoreEvent(id: "4", kind: "failed", session: "claude:session:b", label: "JR-Bar", at: 103, provider: "claude", detail: "Bash failed"),
        CoreEvent(id: "5", kind: "escalation_stage", at: 104, stage: 2),
        CoreEvent(id: "6", kind: "quota_crossed", at: 105, provider: "claude", detail: "5h 80%"),
    ]

    @Test("kinds sort into the categories a person asks about")
    func categories() {
        #expect(EventLogCategory.of("ask_resolved") == .asks)
        #expect(EventLogCategory.of("completed") == .runs)
        #expect(EventLogCategory.of("failed") == .failures)
        #expect(EventLogCategory.of("escalation_stage") == .escalation)
        #expect(EventLogCategory.of("quota_reset") == .quota)
        #expect(EventLogCategory.of("peer_departed") == .devices)
        #expect(EventLogCategory.of("deck_something_new") == .devices)
        #expect(EventLogCategory.of("send_failed") == .failures)
        #expect(EventLogCategory.of("mystery") == .other)
        #expect(!EventLogCategory.devices.movesALight)
    }

    @Test("the filter hides bookkeeping, narrows by chip and text, and lists newest first")
    func filter() {
        #expect(EventLogFilter().apply(Self.journal).map(\.id) == ["6", "5", "4", "3", "1"])
        #expect(EventLogFilter(categories: [.asks, .failures]).apply(Self.journal).map(\.id) == ["4", "1"])
        #expect(EventLogFilter(text: "sidepulse").apply(Self.journal).map(\.id) == ["3", "1"])
        #expect(EventLogFilter(categories: [.devices], text: "sidepulse").apply(Self.journal).map(\.id) == ["3"])
    }

    @Test("the light log keeps what moved a light, newest first, in plain words")
    func lightLog() {
        let entries = LightLog.entries(from: Self.journal, limit: 3)
        #expect(entries.map(\.id) == ["6", "5", "4"])
        #expect(entries[0].text == "Claude crossed a quota threshold · 5h 80%")
        #expect(entries[1].text == "escalated to stage 2")
        #expect(entries[2].text == "Claude failed · JR-Bar")
        #expect(LightLog.text(for: Self.journal[0]) == "Codex asked · sidepulse-core")
    }

    @Test("a row opens its timeline when it names a local session a reader exists for")
    func expandable() {
        let uuid = "8870963f-850a-4bd2-9a4f-0c1a2b3c4d5e"
        #expect(HistoryTimelineRequest.sessionUUID(from: "claude:session:\(uuid)") == uuid)
        #expect(HistoryTimelineRequest.sessionUUID(from: "claude:not-a-uuid") == nil)
        #expect(HistoryTimelineRequest.canExpand(CoreHistoryRow(at: 1, kind: "completed", provider: "claude", session: "claude:session:\(uuid)")))
        #expect(HistoryTimelineRequest.canExpand(CoreHistoryRow(at: 1, kind: "completed", session: "codex:session:\(uuid)")))
        #expect(!HistoryTimelineRequest.canExpand(CoreHistoryRow(at: 1, kind: "completed", provider: "grok", session: "grok:x")))
        #expect(!HistoryTimelineRequest.canExpand(CoreHistoryRow(at: 1, kind: "completed", provider: "claude", session: "remote:studio:claude:x")))
        #expect(!HistoryTimelineRequest.canExpand(CoreHistoryRow(at: 1, kind: "quota_crossed", provider: "claude")))
    }
}
