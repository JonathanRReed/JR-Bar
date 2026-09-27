import Foundation
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Setup render proof")
struct SetupRenderProofTests {
    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func permissionsFollowEnabledFeatures() throws {
        for (name, active) in [
            ("setup-permissions-core", Set<SetupPermission>([.notifications])),
            ("setup-permissions-features", Set<SetupPermission>([.notifications, .camera,
                                                               .screenRecording, .accessibility])),
        ] {
            var model = SetupModel()
            model.permissionPlan = { SetupPermissionPlan(active: active) }
            let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
            try WindowsRenderProofTests.write(name, size: CGSize(width: 680, height: 440)) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Permissions").font(.system(size: 24, weight: .semibold))
                    Text("Grant what's useful. The panel works while optional features wait.")
                        .font(.callout).foregroundStyle(.secondary)
                    SetupPermissionsStep(store: store)
                }
                .padding(24)
            }
        }
    }
}
