import JRBarTestSupport
import Foundation
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Menu Bar rule profile render proof", .renderProofAppearance)
struct MenuBarRuleProfileRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func selections() throws {
        var renamed = MenuBarSettings(enabled: false)
        renamed.profiles = [MenuBarSettings.Profile(id: "work", name: "Work")]
        MenuBarProfiles.rename(id: "work", to: "Office", in: &renamed)
        var deleted = renamed
        MenuBarProfiles.delete(id: "work", in: &deleted)
        var ambiguous = renamed
        ambiguous.profiles = [MenuBarSettings.Profile(id: "first", name: "Work"),
                              MenuBarSettings.Profile(id: "second", name: "work")]
        let samples: [(String, MenuBarSettings, MenuBarRuleProfileSelection, Bool)] = [
            ("renamed", renamed, .saved(id: "work"), true),
            ("deleted", deleted, .saved(id: "work"), false),
            ("ambiguous", ambiguous, .saved(id: "second"), false),
            ("none", renamed, .none, true),
        ]
        for (name, settings, selection, available) in samples {
            #expect(selection.resolve(in: settings).isAvailable == available)
            for width: CGFloat in [400, 520] {
                let scene = VStack(alignment: .leading, spacing: 16) {
                    Text("Rule profile").font(.headline)
                    HStack(alignment: .top, spacing: 12) {
                        Text("Hold").font(.callout)
                        Picker("Bar", selection: Binding.constant("quiet")) {
                            Text("Tuck everything away").tag("quiet")
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                        MenuBarRuleProfilePicker(selection: .constant(selection), settings: settings,
                                                 allowsNoProfile: true)
                    }
                }
                .padding(20)
                .frame(width: width, height: 180, alignment: .topLeading)
                for dark in [false, true] {
                    let framed = scene.background(Color(nsColor: .windowBackgroundColor))
                    let rep = try SettingsRenderProofTests.snapshot(framed,
                        size: CGSize(width: width, height: 180), dark: dark)
                    let png = try #require(rep.representation(using: .png, properties: [:]))
                    try FileManager.default.createDirectory(at: ProofRender.directory,
                                                            withIntermediateDirectories: true)
                    let filename = "rule-profile-\(name)-\(Int(width))-\(dark ? "dark" : "light").png"
                    try png.write(to: ProofRender.directory.appendingPathComponent(filename))
                }
            }
        }
    }
}
