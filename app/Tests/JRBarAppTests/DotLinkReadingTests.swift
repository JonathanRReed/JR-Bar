import Foundation
@testable import JRBarApp
import JRBarCore
import Testing

/// The linked Dot's own rows against what the daemon reads: Continue
/// enters the Dot at its LED nearest the strip (`dot_role.continue_geometry`),
/// so the Dot's Strip direction still acts while it extends with Continue.
/// Mirror, Asks and Call never read it, and there the row waits.
@MainActor
@Suite("Linked Dot rows")
struct DotLinkReadingTests {
    private func store(role: String, style: String? = nil) -> SettingsStore {
        var document = LEDMotionRenderProofTests.deviceDocument(role: role)
        if let style, case .object(var fields) = document {
            fields["dot_extend_style"] = .string(style)
            document = .object(fields)
        }
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-dot-link-reading.sock")
        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
                                          document: document)))
        return SettingsStore(core: core)
    }

    @Test("Extend with Continue, the default look, still reads the Dot's direction")
    func continueReadsTheDotsDirection() {
        for style in [nil, "continue"] {
            let settings = store(role: "extend", style: style)
            #expect(DotLinkReading.followsPro(settings))
            #expect(DotLinkReading.directionActs(settings))
        }
    }

    @Test("Mirror, Asks and Call leave the Dot's direction with nothing to act on")
    func otherRolesDoNot() {
        #expect(!DotLinkReading.directionActs(store(role: "extend", style: "mirror")))
        #expect(!DotLinkReading.directionActs(store(role: "asks")))
        #expect(!DotLinkReading.directionActs(store(role: "call")))
        let own = store(role: "status")
        #expect(!DotLinkReading.followsPro(own))
    }
}
