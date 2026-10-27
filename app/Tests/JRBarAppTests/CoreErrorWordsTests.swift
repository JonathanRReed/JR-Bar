import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Every error a monitor command can throw reaches a person as a plain
/// sentence: never "The operation couldn't be completed", a type name, a
/// reply code or errno text.
@Suite("Core errors read as sentences")
struct CoreErrorWordsTests {
    static let clientErrors: [CoreClientError] = [.notConnected, .disconnected, .timeout, .writeFailed(EPIPE), .stopped]
    static let replyErrors: [CoreReplyError] = [
        CoreReplyError(code: "not_found", message: "no such session"),
        CoreReplyError(code: "busy"),
        CoreReplyError(code: "invalid_args"),
        CoreReplyError(code: "unauthenticated"),
        CoreReplyError(code: "provider_unavailable"),
        CoreReplyError(code: "something_new"),
        CoreReplyError(code: "disabled", message: "  "),
    ]

    static var allErrors: [Error] {
        let client: [Error] = clientErrors
        let reply: [Error] = replyErrors
        return client + reply
    }

    static func isPlain(_ words: String) -> Bool {
        let banned = ["operation couldn", "CoreReplyError", "CoreClientError", "error 1", "error 0",
                      "_", "Broken pipe", "write failed", "did not reply"]
        guard let first = words.first, first.isUppercase else { return false }
        guard ".!?…".contains(words.last ?? " ") else { return false }
        return banned.allSatisfy { !words.contains($0) }
    }

    @Test func localizedDescriptionIsASentence() {
        for error in Self.allErrors {
            let words = error.localizedDescription
            #expect(Self.isPlain(words), "\(error) -> \(words)")
        }
    }

    @MainActor @Test func everyUserFacingWordsHelperIsPlain() {
        for error in Self.allErrors {
            let helpers: [String] = [
                MonitorWords.reason(error),
                UsageCenterStore.describe(error),
                EffectStudioStore.describe(error),
                ProviderUsageSwitchesModel.words(for: error),
            ]
            for words in helpers {
                #expect(Self.isPlain(words), "\(error) -> \(words)")
            }
        }
    }

    @Test func theDaemonsOwnMessageIsKept() {
        let refused = CoreReplyError(code: "disabled", message: "Kiro usage is off. Turn it on in Settings › Providers first.")
        #expect(refused.localizedDescription == "Kiro usage is off. Turn it on in Settings › Providers first.")
        #expect(CoreReplyError(code: "not_found", message: "no such session").sentence == "No such session.")
    }

    @Test func theDiagnosticFormStaysForTheLog() {
        #expect(CoreClientError.timeout.description == "core did not reply in time")
    }
}
