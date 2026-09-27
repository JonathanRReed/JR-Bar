import JRBarCore
import Testing
@testable import JRBarApp

@Suite("Setup permission plan")
struct SetupPermissionPlanTests {
    private let empty = SettingsDocument(.object([:]))

    @Test("disabled parents leave their child permissions optional")
    func disabledParents() {
        var toys = ToysState()
        toys.notch.mirror = true
        toys.notch.audioVisualizer = true
        let plan = SetupPermissionPlan.features(toys: toys, utilities: UtilitiesState(enabled: false),
                                               document: empty, followsAlcove: false)
        #expect(plan.active == [.notifications])
        #expect(plan.optional.contains(.camera))
        #expect(plan.optional.contains(.calendar))
        #expect(plan.optional.contains(.reminders))
    }

    @Test("enabled toys and the island name only their used grants in stable order")
    func activeToyFeatures() {
        var toys = ToysState()
        toys.fold.enabled = true
        toys.notch.enabled = true
        toys.notch.mirror = true
        toys.notch.audioVisualizer = true
        toys.notch.replaceSystemHUD = true
        let plan = SetupPermissionPlan.features(toys: toys, utilities: UtilitiesState(enabled: false),
                                               document: empty, followsAlcove: false)
        #expect(plan.active == [.notifications, .calendar, .reminders, .camera,
                               .screenRecording, .audioCapture, .bluetooth, .accessibility])
        #expect(Set(plan.active).isDisjoint(with: Set(plan.optional)))
        #expect(plan.active.count + plan.optional.count == SetupPermission.allCases.count)
        toys.notch.provider = .alcove
        let external = SetupPermissionPlan.features(toys: toys, utilities: UtilitiesState(enabled: false),
                                                   document: empty, followsAlcove: true)
        #expect(external.active == [.notifications, .screenRecording, .accessibility])
    }

    @Test("active daemon signals and menu rules contribute their specific grants")
    func daemonAndRuleFeatures() {
        let document = SettingsDocument(.object([
            "calendar_alerts_enabled": .bool(true), "reminder_alerts_enabled": .bool(true),
            "focus_sync_enabled": .bool(true), "closed_lid_awake_policy": .string("agents"),
        ]))
        var utilities = UtilitiesState()
        utilities.menuBar.triggerRules = [
            MenuBarTriggerRule(trigger: .wifiLeft, action: .hideAll),
            MenuBarTriggerRule(trigger: .focusEnabled, action: .hideAll),
        ]
        let plan = SetupPermissionPlan.features(toys: ToysState(), utilities: utilities,
                                               document: document, followsAlcove: false)
        #expect(plan.active == [.notifications, .calendar, .reminders, .accessibility,
                               .location, .fullDiskAccess, .focusStatus, .lidHelper])
        utilities.enabled = false
        let stopped = SetupPermissionPlan.features(toys: ToysState(), utilities: utilities,
                                                  document: empty, followsAlcove: false)
        #expect(stopped.active == [.notifications])
    }
}
