import JRBarTestSupport
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

@MainActor
@Suite("Menu Bar hover timing controls", .renderProofAppearance)
struct MenuBarHoverTimingRenderTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    @Test("entry and exit controls fit in both appearances", .enabled(if: enabled))
    func render() throws {
        let utility = MenuBarUtility()
        let settings = MenuBarSettings()
        utility.settings = { settings }
        for dark in [false, true] {
            let scene = MenuBarHoverTimingControls(utility: utility)
                .padding(16)
                .frame(width: 520, height: 180, alignment: .top)
                .background(dark ? Color.black : Color.white)
            try ProofRender.write(scene, size: CGSize(width: 520, height: 180),
                                  name: "menu-hover-timing-\(dark ? "dark" : "light")", dark: dark)
        }
    }
}
