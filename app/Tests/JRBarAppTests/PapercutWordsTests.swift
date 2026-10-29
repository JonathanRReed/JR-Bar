import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

@MainActor
@Suite("Papercut words")
struct PapercutWordsTests {
    @Test("ask kinds have display titles", arguments: ["permission", "approval", "review", "input", "input_required", "question", "dialog", "new_internal_kind"])
    func asks(kind: String) {
        let title = AskKindWords.title(kind)
        #expect(!title.contains("_"))
        #expect(title.first?.isUppercase == true)
    }

    @Test("source states never become raw UI labels", arguments: ["ready", "stale", "disabled", "needs_consent", "needs_sign_in", "new_source_state"])
    func sourceStates(state: String) {
        let usage = CoreProviderUsage(id: "codex", windows: [], state: state)
        #expect(!UsageStatus.sourceState(state).word.contains("_"))
        #expect(!PanelStore.quietWord(usage).contains("_"))
        let line = PanelStore.usageResetLine(for: usage, primary: nil, secondary: nil, noRoomForOneMore: false,
                                             now: Date(timeIntervalSince1970: 100))
        #expect(!line.contains("_"))
        #expect(!UsageCenterStore.fidelityLabel(state).contains("_"))
    }

    @Test("token history state words agree across surfaces", arguments: ["ready", "building", "stale", "failed", "disk_full", "damaged", "over_cap", "future_state"])
    func tokenHistory(state: String) {
        #expect(!TokenHistoryWords.title(state).contains("_"))
        var provider = CoreProviderUsage(id: "codex")
        provider.tokenHistoryState = state
        if let notice = UsageHistoryPresentation.state(provider: provider, history: nil, disabled: false,
                                                       loading: false, scanning: false, error: nil),
           ["building", "stale", "failed", "disk_full", "damaged", "over_cap"].contains(state) {
            #expect(notice.title == TokenHistoryWords.title(state))
        }
    }

    @Test("activity captions use shared states instead of hook event codes", arguments: ["working", "tool_running", "waiting_for_input", "idle_ready", "ended_unconfirmed", "new_mode"])
    func activityCaptions(mode: String) {
        let session = CoreSession(id: "fixture", provider: "codex", mode: mode, event: "PreToolUse")
        #expect(session.activityCaption == SessionActivity.reduce(session).word)
        #expect(!session.activityCaption.contains("_"))
    }

    @Test("unknown codes have neutral fallbacks")
    func unknownCodes() {
        #expect(AskKindWords.title("new_internal_kind") == "Ask")
        #expect(UsageStatus.sourceState("new_source_state") == .unavailable)
        #expect(PanelStore.paceHint("new_pace") == nil)
        #expect(PanelStore.deviceWord("new_device") == "Light device")
        #expect(UsageCenterStore.fidelityLabel("new_fidelity") == "Source not reported")
        #expect(AuditGapWords.text("new_gap") == "Some session details are unavailable.")
        #expect(AuditGapWords.text("The export has partial coverage.") == "The export has partial coverage.")
        #expect(CoreHistoryRow(at: 0, kind: "new_kind").kindWord == "Other event")
    }

    @Test("light and fish states have words", arguments: LightWhy.allCases)
    func lightStates(kind: LightWhy) {
        #expect(!kind.displayName.contains("_"))
        for state in FishState.allCases {
            #expect(!state.displayName.contains("_"))
            #expect(state.displayName.first?.isUppercase == true)
        }
    }
}
