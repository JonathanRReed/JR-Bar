import JRBarTestSupport
import SwiftUI
import Testing
@testable import JRBarApp

@Suite(.renderProofAppearance) struct MenuBarInventoryStateTests {
    @Test func permissionAndScanEvidenceStayDistinct() {
        #expect(MenuBarInventoryState.assess(granted: false, generation: 5, complete: true) == .unavailable)
        #expect(MenuBarInventoryState.assess(granted: true, generation: 0, complete: false) == .checking)
        #expect(MenuBarInventoryState.assess(granted: true, generation: 1, complete: false) == .partial)
        #expect(MenuBarInventoryState.assess(granted: true, generation: 2, complete: true) == .complete)
        #expect(MenuBarInventoryState.assess(granted: true, generation: 3, complete: false) == .partial)
    }

    @MainActor
    @Test func permissionLossClearsPartialNoticeWithoutAnotherScan() {
        let utility = MenuBarUtility()
        var granted = true
        utility.readAccessibilityTrust = { granted }
        utility.readInventoryEvidence = { (generation: 1, complete: false) }
        let first = Date(timeIntervalSince1970: 1_790_000_000)
        let accepted = utility.probeAccessibility(now: first)
        #expect(accepted)
        #expect(utility.inventoryState == .partial)
        granted = false
        let revoked = utility.probeAccessibility(now: first.addingTimeInterval(4))
        #expect(!revoked)
        #expect(utility.inventoryState == .unavailable)
    }

    @MainActor
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func incompleteInventoryRenderProof() throws {
        for width in [CGFloat(320), CGFloat(640)] {
            try WindowsRenderProofTests.write("menu-inventory-partial-\(Int(width))",
                                               size: CGSize(width: width, height: 170)) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your bar").font(.headline)
                    MenuBarInventoryNotice(state: .partial)
                }.padding(16)
            }
        }
    }
}
