import Foundation
import Testing
@testable import JRBarCore

@Suite("Alerts profile")
struct AlertsProfileTests {
    private func document(_ members: [String: JSONValue]) -> SettingsDocument {
        SettingsDocument(.object(members))
    }

    /// Everything that can send, run or answer. A profile touches none of it.
    private static let outboundAndSealed: Set<String> = [
        "serve_enabled", "serve_answer_enabled", "escalation_webhook_url", "webhook_events",
        "cloud_ingest_enabled", "remote_peers", "usage_hooks", "usage_event_hook_path",
        "global_action_shortcuts", "cliproxy_hub", "provider_extra_homes", "claude_statusline_source",
        "claude_plan_limits_enabled", "claude_plan_limits_consent_version",
        "provider_status_feeds_enabled", "provider_update_checks_enabled",
        "closed_lid_awake_policy", "closed_lid_grace_minutes",
    ]

    @Test("every profile writes only the alert keys, never a sealed or outbound one")
    func writesStayLocal() {
        let allowed = Set(AlertsProfile.keys)
        for profile in AlertsProfile.allCases {
            let written = Set(profile.writes.map(\.key))
            #expect(written == allowed)
            #expect(written.isDisjoint(with: Self.outboundAndSealed))
            #expect(Set(profile.values.keys) == allowed)
        }
    }

    @Test("the three profiles differ and Balanced is the daemon's default")
    func profilesAreDistinct() {
        #expect(AlertsProfile.quiet.values != AlertsProfile.balanced.values)
        #expect(AlertsProfile.balanced.values != AlertsProfile.loud.values)
        #expect(AlertsProfile.quiet.values != AlertsProfile.loud.values)
        #expect(AlertsProfile.quiet.values["completion_notification_enabled"] == .bool(false))
        #expect(AlertsProfile.quiet.values["quota_alerts_enabled"] == .bool(false))
        #expect(AlertsProfile.quiet.values["escalation_tier"] == .string("light"))
        #expect(AlertsProfile.balanced.values["escalation_tier"] == .string("menu_bar"))
        #expect(AlertsProfile.loud.values["escalation_tier"] == .string("chime"))
        // An empty document is a fresh install: the daemon's defaults are Balanced.
        #expect(AlertsProfile.current(in: document([:])) == .balanced)
    }

    @Test("a document that matches a profile reads as that profile")
    func currentMatches() {
        for profile in AlertsProfile.allCases {
            #expect(AlertsProfile.current(in: document(profile.values)) == profile)
        }
    }

    @Test("a mixture of switches reads as Custom")
    func currentCustom() {
        var mixed = AlertsProfile.balanced.values
        mixed["quota_alerts_enabled"] = .bool(false)
        #expect(AlertsProfile.current(in: document(mixed)) == nil)

        var takeover = AlertsProfile.loud.values
        takeover["escalation_tier"] = .string("takeover")
        #expect(AlertsProfile.current(in: document(takeover)) == nil)
    }

    @Test("alias spellings of a tier still match, and extra keys are ignored")
    func tierAliases() {
        var values = AlertsProfile.balanced.values
        values["escalation_tier"] = .string("menubar")
        values["alert_burst"] = .number(3)
        #expect(AlertsProfile.current(in: document(values)) == .balanced)
    }

    @Test("a person's explicit choices are read back as they are, not as a profile")
    func explicitChoicesStayCustom() {
        let explicit = document(["completion_notification_enabled": .bool(false),
                                 "quota_alerts_enabled": .bool(true),
                                 "escalation_tier": .string("menu_bar")])
        #expect(AlertsProfile.current(in: explicit) == nil)
    }
}
