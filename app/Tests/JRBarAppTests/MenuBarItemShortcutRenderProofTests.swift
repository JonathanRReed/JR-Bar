import JRBarTestSupport
import AppKit
import Foundation
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@Suite("Menu bar item shortcut render proof", .serialized, .renderProofAppearance)
@MainActor struct MenuBarItemShortcutRenderProofTests {
    @Test(.enabled(if: SettingsRenderProofTests.enabled))
    func savedRows() throws {
        let registrar = HotkeyCenterTests.Recorder()
        let center = HotkeyCenter(registrar: registrar)
        let target = try #require(MenuBarItemShortcutTarget(bundleID: "com.example.fixture", selector: .soleItem))
        let samples: [(String, MenuBarItemHotkeys.State)] = [
            ("assignable", .ready), ("missing", .missing), ("ambiguous", .ambiguous),
            ("disabled", .disabled), ("conflict", .conflict("Sibling fixture")),
            ("permission", .permission), ("refused", .refused)
        ]
        try FileManager.default.createDirectory(at: SettingsRenderProofTests.directory, withIntermediateDirectories: true)
        for (name, state) in samples {
            let binding = MenuBarItemHotkeyBinding(target: target, displayName: "Fixture status",
                                                   keyCode: 12, modifiers: 6144, enabled: state != .disabled)
            let view = Form {
                Section("Menu bar items") {
                    MenuBarItemShortcutSavedRow(binding: binding, state: state, center: center,
                                                onChange: { _ in }, onEnabled: { _ in }, onTakeOver: { _ in })
                }
            }.formStyle(.grouped)
            for dark in [false, true] {
                let bitmap = try SettingsRenderProofTests.snapshot(view, size: CGSize(width: 560, height: 240), dark: dark)
                let image = try #require(SettingsRenderProofTests.cropped(bitmap))
                let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                let filename = "item-shortcut-\(name)-\(dark ? "dark" : "light").png"
                try png.write(to: SettingsRenderProofTests.directory.appendingPathComponent(filename))
            }
        }
    }
}
