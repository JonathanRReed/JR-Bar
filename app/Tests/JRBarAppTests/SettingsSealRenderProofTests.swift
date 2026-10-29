import JRBarTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Render proof for the settings seal: the Settings banner for a protected
/// setting that was changed outside JR-Bar, for an unavailable Keychain and for
/// a daemon that has not sealed, and Advanced › Protected settings. Off by
/// default; set `JRBAR_RENDER_PROOF=1` to write PNGs into `JRBAR_RENDER_PROOF_DIR`.
@Suite("Settings seal render proof", .serialized, .renderProofAppearance)
@MainActor
struct SettingsSealRenderProofTests {
    private func write(_ name: String, _ view: some View, height: CGFloat = 330) throws {
        try FileManager.default.createDirectory(at: SettingsRenderProofTests.directory,
                                                withIntermediateDirectories: true)
        let size = CGSize(width: SettingsRenderProofTests.paneWidth, height: height)
        for dark in [false, true] {
            let rep = try SettingsRenderProofTests.snapshot(view, size: size, dark: dark)
            let image = try #require(SettingsRenderProofTests.cropped(rep))
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: SettingsRenderProofTests.directory
                .appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
    }

    private func page(_ notice: SettingsSealNotice) -> some View {
        Form {
            Section { SettingsPageHeader(page: .general) }
            Section { SettingsSealNoticeCard(notice: notice) }
        }
        .formStyle(.grouped)
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func banners() throws {
        try write("seal-banner-ignored-change",
                  page(.ignoredChange(names: ["Answering from the status server", "Webhook address"], canKeep: true)))
        try write("seal-banner-ignored-change-gone",
                  page(.ignoredChange(names: ["Remote peers"], canKeep: false)))
        try write("seal-banner-keychain", page(.keychainUnavailable(.needsApproval)))
        try write("seal-banner-not-sealed",
                  page(.notSealed(reason: "The monitor did not take JR-Bar's key, so a program running as you can change them by editing the settings file.")))
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func advancedGroup() throws {
        let store = InMemorySettingsSealKeyStore()
        let holder = SettingsSealKeyHolder(store: store)
        _ = holder.handoff()
        let seal = SettingsSealCoordinator(holder: holder, send: { _ in CoreReply(id: "x", ok: true) })
        seal.settingsArrived(CoreSettings(generation: 1, schema: 3,
                                          document: ["settings_seal": ["state": "sealed", "changed": nil]]),
                             authenticated: false)
        try write("seal-advanced-group",
                  Form {
                      Section { SettingsPageHeader(page: .general) }
                      SettingsSealGroup(seal: seal, isLive: true)
                  }
                  .formStyle(.grouped),
                  height: 300)
    }

    @Test("the banner offers exactly the buttons its notice needs")
    func keepIsOfferedOnlyWhenTheValuesAreStillHeld() {
        // The structure is a pure function of the notice: the buttons a person
        // can press follow from it, not from a model.
        #expect(SettingsSealNotice.ignoredChange(names: [], canKeep: true).canKeep)
        #expect(!SettingsSealNotice.ignoredChange(names: [], canKeep: false).canKeep)
        #expect(!SettingsSealNotice.keychainUnavailable(.denied).canKeep)
        #expect(!SettingsSealNotice.notSealed(reason: nil).canKeep)
    }
}
