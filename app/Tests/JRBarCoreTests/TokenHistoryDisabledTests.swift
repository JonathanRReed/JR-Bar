import Foundation
import Testing
@testable import JRBarCore

@Suite("Token history disabled replies")
struct TokenHistoryDisabledTests {
    @Test(arguments: ["usage_history", "usage_graph", "session_usage"])
    func disabledReply(command: String) throws {
        let frame = "{\"t\":\"reply\",\"v\":1,\"id\":\"\(command)\",\"ok\":false,\"error\":{\"code\":\"disabled\",\"message\":\"Token history is off.\"}}"
        guard case .reply(let reply) = try CoreCodec.decode(line: frame) else {
            Issue.record("Expected a disabled reply")
            return
        }
        #expect(reply.ok == false)
        #expect(reply.error?.isTokenHistoryDisabled == true)
        #expect(CoreReplyError.tokenHistoryOffMessage == "Token history is off")
    }

    @Test func otherErrorsKeepTheirMeaning() throws {
        #expect(CoreReplyError(code: "unavailable").isTokenHistoryDisabled == false)
    }
    @Test func tokenFreshnessIsIndependentOfQuota() throws {
        let data = Data(#"{"id":"codex","state":"ready","token_history_state":"stale","windows":[]}"#.utf8)
        let provider = try JSONDecoder().decode(CoreProviderUsage.self, from: data)
        #expect(provider.state == "ready")
        #expect(provider.tokenHistoryState == "stale")
    }

}
