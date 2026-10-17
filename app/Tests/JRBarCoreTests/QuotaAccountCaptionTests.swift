import Foundation
import Testing
@testable import JRBarCore

@Suite("Quota account captions")
struct QuotaAccountCaptionTests {
    @Test func currentPrivacyControlsStoredAliases() {
        let event = CoreEvent(id: "event", kind: "quota_pace", notify: true, provider: "claude", instance: "work", instanceLabel: "Work")
        let row = CoreHistoryRow(at: 1, kind: "quota_pace", provider: "claude", instance: "work", instanceLabel: "Work")
        for privacy in [true, nil] as [Bool?] {
            #expect(LightLog.text(for: event, privacyMode: privacy) == "Claude is running low")
            #expect(row.displayTitle(privacyMode: privacy) == "Claude")
        }
        #expect(LightLog.text(for: event, privacyMode: false) == "Claude · Work is running low")
        #expect(row.displayTitle(privacyMode: false) == "Claude · Work")
    }

    @Test func unsafeMissingAndDefaultAliasesStayProviderOnly() {
        for alias in [nil, "", "person@example.test", "Work\nprivate", "Work\u{0000}"] as [String?] {
            #expect(QuotaAccountCaption.provider("claude", instance: "private-slug", label: alias, privacyMode: false) == "Claude")
        }
        #expect(QuotaAccountCaption.provider("claude", instance: "default", label: "Work", privacyMode: false) == "Claude")
        #expect(QuotaAccountCaption.provider("claude", instance: nil, label: "Work", privacyMode: false) == "Claude")
    }

    @Test func notificationsUseCurrentPrivacyAndStableIdentity() {
        let settings = SettingsDocument(.object(["quota_alerts_enabled": .bool(true)]))
        for kind in ["quota_crossed", "quota_pace", "quota_reset"] {
            let event = CoreEvent(id: "event", kind: kind, notify: true, provider: "claude", instance: "work", instanceLabel: "Work")
            let visible = EventPolicy.delivery(for: event, state: CoreState(usage: CoreUsage(privacyMode: false)), settings: settings).notification
            let privateResult = EventPolicy.delivery(for: event, state: CoreState(usage: CoreUsage(privacyMode: true)), settings: settings).notification
            let unknown = EventPolicy.delivery(for: event, state: nil, settings: settings).notification
            #expect(visible?.title.contains("Claude · Work") == true)
            #expect(privateResult?.title.contains("Work") == false)
            #expect(unknown?.title.contains("Work") == false)
            #expect(visible?.identifier == privateResult?.identifier)
        }
    }

    @Test func captionBoundariesMatchConfiguredAliases() {
        #expect(QuotaAccountCaption.provider("claude", instance: " default ", label: "Work", privacyMode: false) == "Claude")
        #expect(QuotaAccountCaption.provider("claude", instance: "work", label: String(repeating: "a", count: 97), privacyMode: false) == "Claude")
        #expect(QuotaAccountCaption.provider("claude", instance: "work", label: String(repeating: "a", count: 96), privacyMode: false) == "Claude · " + String(repeating: "a", count: 96))
        #expect(QuotaAccountCaption.provider("claude", instance: "work", label: "Claude Work", privacyMode: false) == "Claude Work")
        #expect(QuotaAccountCaption.provider("claude", instance: "work", label: "Work CLAUDE", privacyMode: false) == "Work CLAUDE")
    }

    @Test func oldDocumentsAndOptionalMetadataDecode() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(CoreUsage.self, from: Data(#"{"providers":[]}"#.utf8))
        #expect(old.privacyMode == nil)
        let usage = try decoder.decode(CoreUsage.self, from: Data(#"{"privacy_mode":false,"providers":[]}"#.utf8))
        #expect(usage.privacyMode == false)
        let event = try decoder.decode(CoreEvent.self, from: Data(#"{"id":"e","kind":"quota_pace","instance":"work","instance_label":"Work"}"#.utf8))
        #expect(event.instanceLabel == "Work")
        let row = try decoder.decode(CoreHistoryRow.self, from: Data(#"{"at":1,"kind":"quota_pace","instance":"work","instance_label":"Work"}"#.utf8))
        #expect(row.instanceLabel == "Work")
        let legacyRow = try decoder.decode(CoreHistoryRow.self, from: Data(#"{"at":1,"kind":"quota_pace"}"#.utf8))
        #expect(legacyRow.instance == nil)
        #expect(legacyRow.instanceLabel == nil)
    }

    @Test func historyIdentityUsesInstanceNotCaption() {
        var row = CoreHistoryRow(at: 1, kind: "quota_pace", provider: "claude", instance: "work", instanceLabel: "Work")
        let identity = row.id
        row.instanceLabel = "Renamed"
        #expect(row.id == identity)
        row.instance = "personal"
        #expect(row.id != identity)
    }

    @Test func historyCaptionsPreserveQuotaWindowAndLegacyTitle() {
        var row = CoreHistoryRow(at: 1, kind: "quota_crossed", provider: "codex", label: "Codex five-hour",
                                 detail: "95%", instance: "work", instanceLabel: "Work")
        #expect(row.displayTitle(privacyMode: false) == "Codex · Work five-hour")
        #expect(row.displayTitle(privacyMode: true) == row.displayTitle)
        #expect(row.displayTitle(privacyMode: nil) == row.displayTitle)
        row.instanceLabel = nil
        #expect(row.displayTitle(privacyMode: false) == row.displayTitle)
        row.instanceLabel = "Work"
        row.instance = "default"
        #expect(row.displayTitle(privacyMode: false) == row.displayTitle)
        row.instance = "work"
        row.provider = nil
        #expect(row.displayTitle(privacyMode: false) == row.displayTitle)
        row.provider = "codex"
        row.label = "Weekly window"
        #expect(row.displayTitle(privacyMode: false) == "Weekly window · Codex · Work")
    }
}
