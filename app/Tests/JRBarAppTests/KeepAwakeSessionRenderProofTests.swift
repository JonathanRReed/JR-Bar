import JRBarTestSupport
import JRBarUI
import AppKit
import Foundation
@testable import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Keep Awake custom session render proof", .serialized, .renderProofAppearance)
@MainActor
struct KeepAwakeSessionRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write Keep Awake PNGs"))
    func customSessionAndFailedHold() throws {
        let suite = ScratchDefaults.suiteName("KeepAwakeSessionRenderProofTests")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        state.sendLease = { _ in .taken }
        state.takeAssertion = { _ in Issue.record("render proofs must not take a power assertion"); return nil }
        let hold = try JSONDecoder().decode(CoreAwakeHold.self, from: Data(
            #"{"state":"manual","active":false,"lease":{"kind":"indefinite"}}"#.utf8))
        state.noteDaemonHold(hold, live: true)
        let utility = KeepAwakeUtility(toggles: SystemTogglesStore(state: state))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scene = Form {
            Section {
                HStack {
                    Text(utility.name).font(.body.weight(.semibold))
                    StatusBadge(utility.status.text, tint: utility.status.tint)
                    Spacer()
                    Toggle("Manual session", isOn: .constant(utility.isOn)).toggleStyle(.switch)
                }
                KeepAwakeUtilityControls(utility: utility, holders: [], now: now).cardBodyStyle()
            }
        }
        .formStyle(.grouped)
        .frame(width: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        for dark in [false, true] {
            try ProofRender.write(scene, size: CGSize(width: 580, height: 850),
                                  name: "keepawake-custom-session-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write Keep Awake PNGs"))
    func closedLidFailure() throws {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-lid-error-proof.sock")
        let lid = try JSONDecoder().decode(CoreClosedLid.self, from: Data(
            #"{"policy":"never","helper_installed":true,"holding":true,"error":"caffeinate: synthetic release refused"}"#.utf8))
        core.apply(.state(CoreState(sessions: [], power: CorePower(closedLid: lid))))
        let settings = SettingsStore(core: core)
        for width: CGFloat in [430, 580] {
            let scene = Form { PowerGroup(store: settings) }
                .formStyle(.grouped)
                .environment(settings)
                .frame(width: width)
                .background(Color(nsColor: .windowBackgroundColor))
            for dark in [false, true] {
                try ProofRender.write(scene, size: CGSize(width: width, height: 550),
                                      name: "closed-lid-failed-\(Int(width))-\(dark ? "dark" : "light")", dark: dark)
            }
        }
    }
}
