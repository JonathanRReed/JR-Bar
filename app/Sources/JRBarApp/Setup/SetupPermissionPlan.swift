import JRBarCore

struct SetupPermissionPlan: Equatable {
    let active: [SetupPermission]
    let optional: [SetupPermission]

    init(active: Set<SetupPermission>) {
        self.active = SetupPermission.allCases.filter { active.contains($0) }
        self.optional = SetupPermission.allCases.filter { !active.contains($0) }
    }

    static func features(toys: ToysState, utilities: UtilitiesState,
                         document: SettingsDocument, followsAlcove: Bool) -> Self {
        var active: Set<SetupPermission> = [.notifications]
        let notch = toys.notch
        let ownIsland = notch.enabled && notch.provider == .jrbar && notch.islandEnabled
        if toys.fold.enabled && toys.fold.provider == .jrbar { active.insert(.screenRecording) }
        if ownIsland {
            if notch.mirror { active.insert(.camera) }
            if notch.audioVisualizer { active.insert(.audioCapture) }
            if notch.alerts { active.insert(.bluetooth) }
            if notch.calendar { active.insert(.calendar) }
            if notch.reminders { active.insert(.reminders) }
            if notch.replaceSystemHUD { active.insert(.accessibility) }
        }
        if document.bool("calendar_alerts_enabled") == true { active.insert(.calendar) }
        if document.bool("reminder_alerts_enabled") == true { active.insert(.reminders) }
        if document.bool("focus_sync_enabled") == true { active.insert(.fullDiskAccess) }
        if (document.string("closed_lid_awake_policy") ?? "never") != "never" { active.insert(.lidHelper) }
        if followsAlcove { active.insert(.accessibility) }
        if utilities.enabled {
            if utilities.dock.previewsWanted && utilities.dock.enhance.showThumbnails {
                active.insert(.screenRecording)
            }
            let menu = utilities.menuBar
            if menu.enabled && menu.provider == .jrbar {
                active.insert(.accessibility)
                for rule in menu.triggerRules where rule.enabled {
                    switch rule.trigger {
                    case .wifiJoined, .wifiLeft: active.insert(.location)
                    case .focusEnabled, .focusDisabled: active.insert(.focusStatus)
                    default: break
                    }
                }
                for rule in menu.curation.stateRules where rule.enabled {
                    switch rule.condition {
                    case .wifiIs: active.insert(.location)
                    case .focusOn: active.insert(.focusStatus)
                    default: break
                    }
                }
            }
        }
        return Self(active: active)
    }
}
