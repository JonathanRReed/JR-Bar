import AppKit
import Carbon
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The ACTIONS track's pure halves (docs/UTILITIES.md): the palette's
/// rows and fuzzy matcher, the hotkey model's conflicts and display
/// strings, the trigger engine's edge detection, and the facade's
/// routing to its delegate. Nothing here posts a real event.
@Suite("Menu Bar actions")
struct MenuBarActionsTests {
    private func item(_ id: String, owner: String = "App", x: Double,
                      y: Double = 0, w: Double = 24) -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: 500, ownerName: owner,
                    bounds: CGRect(x: x, y: y, width: w, height: 24),
                    title: nil, windowID: 0)
    }

    // MARK: Commands — one row per app, bar-wide rows, fuzzy match

    private func appItem(_ id: String, owner: String, bundle: String? = nil,
                         title: String? = nil, x: Double) -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: 500, ownerName: owner,
                    bounds: CGRect(x: x, y: 0, width: 24, height: 24),
                    title: title, windowID: 0, bundleID: bundle)
    }

    @Test("each app is one row whose verbs follow its section")
    func commandBuild() {
        let items = [item("Free", owner: "Free", x: 600),
                     item("Hid", owner: "Hid", x: 700),
                     item("Deep", owner: "Deep", x: 800)]
        let commands = MenuBarCommands.build(
            items: items,
            sections: ["Hid": .hidden, "Deep": .alwaysHidden], ownBundleID: nil)
        let apps = commands.filter { $0.kind == .app }
        #expect(apps.map(\.title) == ["Free", "Hid", "Deep"], "bar order, one row each")
        #expect(apps.map { $0.verbs.map(\.title) } == [
            ["Open", "Hide", "Always Hide"],
            ["Open", "Show", "Always Hide"],
            ["Open", "Show", "Move to Hidden"],
        ])
        #expect(apps[0].verbs[1].action == .setAppSection(itemIDs: ["Free"], .hidden))
        #expect(apps[1].verbs[1].action == .setAppSection(itemIDs: ["Hid"], .shown))
        #expect(apps[0].verbs[0].action == .openItem(itemID: "Free"))
        #expect(apps[0].verbs[2].shortcut == .commandShift("h"))
        // Nothing describes the retired per-item covers any more.
        #expect(!commands.contains { ($0.subtitle ?? "").localizedCaseInsensitiveContains("cover") })
        let titles = commands.map(\.title)
        for title in ["Reveal Hidden Items", "Reveal Always-Hidden Items", "Toggle Hidden Items",
                      "Hide All Apps", "Show All Apps"] {
            #expect(titles.contains(title), "\(title)")
        }
    }

    @Test("an app with several items is one row that can open each by name")
    func commandBuildGroupsItems() {
        let items = [appItem("wifi", owner: "Helper", bundle: "com.example.helper", title: "VPN", x: 600),
                     appItem("status", owner: "Helper", bundle: "com.example.helper", title: "Status", x: 640),
                     appItem("other", owner: "Other", bundle: "com.example.other", x: 700)]
        let apps = MenuBarCommands.build(items: items, sections: [:], ownBundleID: nil)
            .filter { $0.kind == .app }
        #expect(apps.count == 2)
        let helper = apps[0]
        #expect(helper.id == "menubar.app.com.example.helper")
        #expect(helper.subtitle == "VPN · Status")
        #expect(helper.verbs.first?.title == "Open VPN")
        #expect(helper.verbs.contains { $0.title == "Open Status" && $0.action == .openItem(itemID: "status") })
        #expect(helper.verbs[1].action == .setAppSection(itemIDs: ["wifi", "status"], .hidden))
    }

    @Test("items of one app in different sections split into one row per section")
    func commandBuildSplitsSections() {
        let items = [appItem("a1", owner: "App", bundle: "com.example.app", x: 600),
                     appItem("a2", owner: "App", bundle: "com.example.app", x: 640)]
        let apps = MenuBarCommands.build(items: items, sections: ["a2": .hidden], ownBundleID: nil)
            .filter { $0.kind == .app }
        #expect(apps.count == 2)
        #expect(apps.map(\.section) == [.shown, .hidden])
        #expect(Set(apps.map(\.id)).count == 2, "split rows keep distinct ids")
        #expect(apps[1].verbs[1].action == .setAppSection(itemIDs: ["a2"], .shown))
    }

    @Test("protected items and our own app get no rows — the palette cannot hide the clock")
    func commandBuildProtected() {
        let items = [item("Sys", owner: "Control Center", x: 1400),
                     appItem("Own", owner: "JR-Bar", bundle: "devin.jrbar.app", x: 1300)]
        let commands = MenuBarCommands.build(items: items, sections: [:], ownBundleID: "devin.jrbar.app")
        #expect(!commands.contains { $0.kind == .app })
        #expect(!commands.flatMap(\.verbs).contains { $0.action == .openItem(itemID: "Sys") })
    }

    @Test("profiles list the built-in None first, and say what they hide")
    func commandBuildProfiles() {
        let work = MenuBarSettings.Profile(id: "p1", name: "Work",
                                           sections: ["Mail": .hidden],
                                           concealedApps: ["com.a": .hidden, "com.b": .alwaysHidden,
                                                           "com.c": .shown])
        let rows = MenuBarCommands.build(items: [], sections: [:], profiles: [work])
            .filter { $0.kind == .profile }
        #expect(rows.map(\.title) == [MenuBarProfiles.noneName, "Work", "Save Layout as Profile…"])
        #expect(rows[1].subtitle == "Hides 3 apps")
        #expect(rows[1].verbs.first?.action == .applyProfile(id: "p1"))
        #expect(rows[0].verbs.first?.action == .applyProfile(id: MenuBarProfiles.noneID))
    }

    @Test("the active profile's row says Current")
    func commandActiveProfile() {
        let work = MenuBarSettings.Profile(id: "w", name: "Work", sections: ["Mail": .hidden],
                                           concealedApps: ["com.a": .hidden, "com.b": .shown])
        let home = MenuBarSettings.Profile(id: "h", name: "Home", sections: [:],
                                           concealedApps: ["com.c": .alwaysHidden])
        let rows = MenuBarCommands.build(items: [], sections: [:], profiles: [work, home],
                                         activeProfileID: "h")
            .filter { $0.kind == .profile }
        #expect(rows.map(\.note) == [nil, nil, "Current", nil])
    }

    @Test("a rule reads as its sentence: Return runs it, ⌘Return switches it")
    func commandBuildRules() {
        let on = MenuBarTriggerRule(id: "r1", enabled: true, trigger: .screenLocked, action: .hideAll)
        let off = MenuBarTriggerRule(id: "r2", enabled: false, trigger: .chargerConnected, action: .showAll)
        let rows = MenuBarCommands.build(items: [], sections: [:], rules: [on, off])
            .filter { $0.kind == .rule }
        #expect(rows[0].title == "When the screen locks → hide all items")
        #expect(rows[0].verbs.map(\.action) == [.runRule(id: "r1"), .setRuleEnabled(id: "r1", false)])
        #expect(rows[0].note == nil)
        #expect(rows[1].verbs.map(\.action) == [.runRule(id: "r2"), .setRuleEnabled(id: "r2", true)])
        #expect(rows[1].note == "Off")
    }

    @Test("the fuzzy matcher is a subsequence with word-start and streak bonuses")
    func fuzzyScore() {
        #expect(MenuBarCommands.score("", "anything") == 0)
        #expect(MenuBarCommands.score("xyz", "Hide Mail") == nil)
        #expect(MenuBarCommands.score("hm", "Hide Mail") != nil)
        // "always" beats a longer candidate containing the same letters.
        let short = MenuBarCommands.score("always", "Always hide Mail")!
        let long = MenuBarCommands.score("always", "Always arrange all your apps")!
        #expect(short > long)
    }

    /// Collects the menu-bar verbs a palette row fires.
    @MainActor
    private final class ActionRecorder {
        var actions: [MenuBarCommandAction] = []
    }

    @MainActor
    @Test("typing a verb and an app runs that verb: “hide mail” hides Mail on Return")
    func commandVerbSearch() {
        let fired = ActionRecorder()
        let items = MenuBarCommands.build(
            items: [item("Mail", owner: "Mail", x: 600), item("Cal", owner: "Cal", x: 700)],
            sections: [:], ownBundleID: nil)
            .map { $0.paletteItem { fired.actions.append($0) } }
        let hits = PaletteRanking.rank(items, query: "hide mail", usage: PaletteUsage())
        #expect(hits.first?.title == "Mail")
        #expect(hits.first?.primary?.title == "Hide")
        #expect(hits.first?.secondary?.title == "Open", "the old first verb moves to ⌘Return")
        #expect(!hits.contains { $0.title == "Cal" })
        _ = hits.first?.primary?.run()
        #expect(fired.actions == [.setAppSection(itemIDs: ["Mail"], .hidden)])
        // A bare title still opens.
        let plain = PaletteRanking.rank(items, query: "mail", usage: PaletteUsage())
        #expect(plain.first?.primary?.title == "Open")
    }

    @MainActor
    @Test("menu-bar rows land in the palette's sections with their state tags")
    func commandPaletteItems() {
        let rows = MenuBarCommands.build(
            items: [item("Hid", owner: "Hid", x: 600)], sections: ["Hid": .hidden],
            profiles: [], rules: [MenuBarTriggerRule(id: "r", enabled: false,
                                                     trigger: .screenLocked, action: .hideAll)],
            ownBundleID: nil)
            .map { $0.paletteItem { _ in } }
        let app = rows.first { $0.title == "Hid" }
        #expect(app?.section == .menuBar)
        #expect(app?.tags == [PaletteTag(text: "Hidden")])
        #expect(app?.kind == "Menu Bar App")
        #expect(rows.first { $0.id == "menubar.rule.r" }?.section == .automation)
        #expect(rows.first { $0.id == "menubar.rule.r" }?.tags == [PaletteTag(text: "Off")])
        // A verb's confirmation is the HUD's line.
        #expect(app?.actions.first { $0.id == "show" }?.run() == "Hid shown")
    }

    // MARK: Hotkeys — model, conflicts, registration seam

    @Test("modifier bits round-trip between NSEvent and Carbon")
    func modifierRoundTrip() {
        for flags in [NSEvent.ModifierFlags.command, [.option], [.control],
                      [.shift], [.command, .shift], [.command, .option, .control]] {
            let carbon = MenuBarHotkeyBinding.carbonModifiers(flags)
            #expect(MenuBarHotkeyBinding.eventModifiers(carbon) == flags)
        }
    }

    @Test("the display string draws ⌃⌥⇧⌘ then the key")
    func hotkeyDisplay() {
        let b = MenuBarHotkeyBinding(action: .commandBar, keyCode: UInt32(kVK_ANSI_K),
                                     modifiers: UInt32(cmdKey | shiftKey), enabled: true)
        #expect(b.displayString == "⇧⌘K")
        let c = MenuBarHotkeyBinding(action: .toggleReveal, keyCode: UInt32(kVK_ANSI_B),
                                     modifiers: UInt32(cmdKey | optionKey), enabled: true)
        #expect(c.displayString == "⌥⌘B")
    }

    @Test("two enabled bindings on one chord conflict; a disabled twin does not")
    func hotkeyConflicts() {
        let a = MenuBarHotkeyBinding(action: .hideAll, keyCode: 40,
                                     modifiers: UInt32(cmdKey), enabled: true)
        let b = MenuBarHotkeyBinding(action: .showAll, keyCode: 40,
                                     modifiers: UInt32(cmdKey), enabled: true)
        let off = MenuBarHotkeyBinding(action: .commandBar, keyCode: 40,
                                       modifiers: UInt32(cmdKey), enabled: false)
        let different = MenuBarHotkeyBinding(action: .toggleReveal, keyCode: 40,
                                             modifiers: UInt32(optionKey), enabled: true)
        let pairs = MenuBarHotkeys.conflicts(in: [a, b, off, different])
        #expect(pairs.count == 1)
        #expect(pairs.first?.0 == .hideAll && pairs.first?.1 == .showAll)
    }

    /// The registrar a test injects — no Carbon, just a record.
    private final class FakeRegistrar: MenuBarHotkeyRegistering {
        var onHotKey: ((UInt32) -> Void)?
        var registered: [(key: UInt32, mods: UInt32, id: UInt32)] = []
        var unregistered = 0
        var uninstalled = false
        var refuse = false

        func register(keyCode: UInt32, modifiers: UInt32,
                      hotKeyID: UInt32) -> MenuBarHotkeyToken? {
            if refuse { return nil }
            registered.append((keyCode, modifiers, hotKeyID))
            return MenuBarHotkeyToken()
        }
        func unregister(_ token: MenuBarHotkeyToken) { unregistered += 1 }
        func uninstall() { uninstalled = true }
    }

    @MainActor
    @Test("start registers the enabled, conflict-free bindings and dispatch routes the action")
    func hotkeyRegistration() async throws {
        let registrar = FakeRegistrar()
        let hotkeys = MenuBarHotkeys(bindings: [
            MenuBarHotkeyBinding(action: .commandBar, keyCode: 40,
                                 modifiers: UInt32(cmdKey | shiftKey), enabled: true),
            MenuBarHotkeyBinding(action: .hideAll, keyCode: 4,
                                 modifiers: UInt32(cmdKey), enabled: true),
            MenuBarHotkeyBinding(action: .showAll, keyCode: 4,
                                 modifiers: UInt32(cmdKey), enabled: true), // conflicts
            MenuBarHotkeyBinding(action: .toggleReveal, keyCode: 11,
                                 modifiers: UInt32(cmdKey), enabled: false), // off
        ])
        hotkeys.registrar = registrar
        var fired: [MenuBarHotkeyAction] = []
        hotkeys.onAction = { fired.append($0) }
        hotkeys.start()
        // The conflicting pair loses both; the off binding never asks.
        #expect(registrar.registered.map(\.id) == [1])
        registrar.onHotKey?(1)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(fired == [.commandBar])
        hotkeys.stop()
        #expect(registrar.unregistered == 1)
        #expect(registrar.uninstalled)
    }

    @MainActor
    @Test("a refused registration lands in failedActions, never thrown")
    func hotkeyRefused() {
        let registrar = FakeRegistrar()
        registrar.refuse = true
        let hotkeys = MenuBarHotkeys(bindings: [
            MenuBarHotkeyBinding(action: .commandBar, keyCode: 40,
                                 modifiers: UInt32(cmdKey), enabled: true),
        ])
        hotkeys.registrar = registrar
        hotkeys.start()
        #expect(hotkeys.failedActions == [.commandBar])
        hotkeys.stop()
    }

    @MainActor
    @Test("a hotkey press claims only its own (signature, id) — the other chord's press passes through")
    func hotkeyRouting() async throws {
        // The dispatcher fans a press out to every installed handler: the
        // registrar must not claim a foreign signature's event, and inside
        // the registry the panel's id must not fire the shelf — either way
        // one key would toggle two surfaces.
        let registrar = CarbonHotkeyRegistrar()
        let ours = EventHotKeyID(signature: CarbonHotkeyRegistrar.appSignature, id: 1)
        let foreign = EventHotKeyID(signature: OSType(0x6A726273), id: 1)
        #expect(registrar.claims(ours) && !registrar.claims(foreign))

        let fake = FakeRegistrar()
        let center = HotkeyCenter(registrar: fake)
        let panel = PanelHotkey(id: PanelHotkey.panelID, title: "Show the panel",
                                defaultChord: PanelHotkey.panelDefault, center: center)
        let shelf = PanelHotkey(id: PanelHotkey.shelfID, title: "Open the shelf",
                                defaultChord: PanelHotkey.shelfDefault, center: center)
        panel.chordSource = { PanelHotkey.panelDefault }
        shelf.chordSource = { PanelHotkey.shelfDefault }
        var pressed: [String] = []
        panel.onPress = { pressed.append("panel") }
        shelf.onPress = { pressed.append("shelf") }
        panel.setEnabled(true)
        shelf.setEnabled(true)
        let shelfHotKeyID = try #require(fake.registered.first { $0.key == UInt32(kVK_ANSI_D) }?.id)
        fake.onHotKey?(shelfHotKeyID)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(pressed == ["shelf"])

        // A fabricated Carbon event reads back the pair it was stamped
        // with — the handler's routing depends on this extraction.
        var event: EventRef?
        #expect(CreateEvent(nil, OSType(kEventClassKeyboard),
                            UInt32(kEventHotKeyPressed), 0,
                            EventAttributes(kEventAttributeNone), &event) == noErr)
        guard let event else { return }
        defer { ReleaseEvent(event) }
        var stamped = foreign
        SetEventParameter(event, EventParamName(kEventParamDirectObject),
                          EventParamType(typeEventHotKeyID),
                          MemoryLayout<EventHotKeyID>.size, &stamped)
        let read = CarbonHotkeyRegistrar.hotKeyID(from: event)
        #expect(read?.signature == foreign.signature)
        #expect(read.map(registrar.claims) == false)
    }

    // MARK: Triggers — the pure engine over faked events

    private func rule(_ trigger: MenuBarTrigger,
                      _ action: MenuBarTriggerAction,
                      id: String = "r") -> MenuBarTriggerRule {
        MenuBarTriggerRule(id: id, enabled: true, trigger: trigger, action: action)
    }

    @Test("lock and unlock events fire their rules; the wrong event does not")
    func triggerLock() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.screenLocked, .hideAll, id: "lock"),
                     rule(.screenUnlocked, .showAll, id: "unlock")]
        #expect(engine.actions(for: .screenLocked, rules: rules) == [.hideAll])
        #expect(engine.actions(for: .screenUnlocked, rules: rules) == [.showAll])
        #expect(engine.actions(for: .appActivated(bundleID: "x"), rules: rules).isEmpty)
    }

    @Test("app activation matches the bundle id case-insensitively")
    func triggerApp() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.appActivated(bundleID: "com.apple.Safari"),
                          .applyProfile(name: "Browsing"))]
        #expect(engine.actions(for: .appActivated(bundleID: "COM.APPLE.SAFARI"),
                               rules: rules) == [.applyProfile(name: "Browsing")])
        #expect(engine.actions(for: .appActivated(bundleID: "com.apple.Mail"),
                               rules: rules).isEmpty)
    }

    @Test("a time-of-day rule fires once at its minute and not again that day")
    func triggerClock() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.timeOfDay(hour: 9, minute: 30), .showAll)]
        #expect(engine.actions(for: .minute(hour: 9, minute: 30),
                               rules: rules, dayStamp: "d1") == [.showAll])
        // A repeated tick inside the same minute/day must not re-fire.
        #expect(engine.actions(for: .minute(hour: 9, minute: 30),
                               rules: rules, dayStamp: "d1").isEmpty)
        #expect(engine.actions(for: .minute(hour: 9, minute: 31),
                               rules: rules, dayStamp: "d1").isEmpty)
        // Tomorrow it fires again.
        #expect(engine.actions(for: .minute(hour: 9, minute: 30),
                               rules: rules, dayStamp: "d2") == [.showAll])
    }

    @Test("the charger fires on the edge, not the level — and the first sample is a baseline")
    func triggerPower() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.chargerConnected, .applyProfile(name: "Docked"), id: "in"),
                     rule(.chargerDisconnected, .reveal(seconds: 5), id: "out")]
        // Baseline: already on AC when the source starts — no fire.
        #expect(engine.actions(for: .onACPower(true), rules: rules).isEmpty)
        // Re-sampling the same level is not an edge.
        #expect(engine.actions(for: .onACPower(true), rules: rules).isEmpty)
        // AC → battery is the disconnect edge.
        #expect(engine.actions(for: .onACPower(false), rules: rules)
                == [.reveal(seconds: 5)])
        #expect(engine.actions(for: .onACPower(false), rules: rules).isEmpty)
        // Back on AC is the connect edge.
        #expect(engine.actions(for: .onACPower(true), rules: rules)
                == [.applyProfile(name: "Docked")])
    }

    @Test("disabled rules never fire, and one event can fire several rules")
    func triggerEnabledAndMulti() {
        var engine = MenuBarTriggerEngine()
        let rules = [
            MenuBarTriggerRule(id: "off", enabled: false,
                               trigger: .screenLocked, action: .hideAll),
            rule(.screenLocked, .hideAll, id: "a"),
            rule(.screenLocked, .applyProfile(name: "Away"), id: "b"),
        ]
        #expect(engine.actions(for: .screenLocked, rules: rules)
                == [.hideAll, .applyProfile(name: "Away")])
    }

    @Test("wifi edges: a join names the network, the drop fires leave, the first sample is a baseline")
    func triggerWiFi() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.wifiJoined(ssid: "Home"), .applyProfile(name: "Home"), id: "join"),
                     rule(.wifiLeft, .hideAll, id: "left"),
                     rule(.wifiJoined(ssid: ""), .reveal(seconds: 2), id: "any")]
        // Baseline — already on "Home" when the source starts: no edge.
        #expect(engine.actions(for: .wifiSSID("Home"), rules: rules).isEmpty)
        // Home → Office: nobody claimed Office, and leaving for another
        // network is not "wifi left".
        #expect(engine.actions(for: .wifiSSID("Office"), rules: rules).isEmpty)
        // Office → nothing is the leave edge.
        #expect(engine.actions(for: .wifiSSID(nil), rules: rules) == [.hideAll])
        // Nothing → Home is the join edge.
        #expect(engine.actions(for: .wifiSSID("Home"), rules: rules)
                == [.applyProfile(name: "Home")])
        // The unnamed change event fires only the nameless rule.
        #expect(engine.actions(for: .wifiChanged, rules: rules)
                == [.reveal(seconds: 2)])
    }

    @Test("the mic and Focus fire on edges only — repeats and baselines stay silent")
    func triggerMicFocus() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.microphoneInUse, .hideAll, id: "mic-on"),
                     rule(.microphoneIdle, .showAll, id: "mic-off"),
                     rule(.focusEnabled, .applyProfile(name: "Deep"), id: "focus-on"),
                     rule(.focusDisabled, .reveal(seconds: 3), id: "focus-off")]
        // Baselines: mic already live, Focus already on — nothing fires.
        #expect(engine.actions(for: .micInUse(true), rules: rules).isEmpty)
        #expect(engine.actions(for: .focusOn(true), rules: rules).isEmpty)
        // Same levels again: still nothing.
        #expect(engine.actions(for: .micInUse(true), rules: rules).isEmpty)
        #expect(engine.actions(for: .focusOn(true), rules: rules).isEmpty)
        // The real edges.
        #expect(engine.actions(for: .micInUse(false), rules: rules) == [.showAll])
        #expect(engine.actions(for: .focusOn(false), rules: rules)
                == [.reveal(seconds: 3)])
        #expect(engine.actions(for: .micInUse(true), rules: rules) == [.hideAll])
        #expect(engine.actions(for: .focusOn(true), rules: rules)
                == [.applyProfile(name: "Deep")])
    }

    @Test("a script action rides the same pipeline — the engine hands it through verbatim")
    func triggerScript() {
        var engine = MenuBarTriggerEngine()
        let rules = [rule(.screenUnlocked,
                          .runScript(command: "say 'welcome back'"), id: "s")]
        #expect(engine.actions(for: .screenUnlocked, rules: rules)
                == [.runScript(command: "say 'welcome back'")])
        // The rule's one-line read names the command.
        #expect(rules[0].summary == "when the screen unlocks → run “say 'welcome back'”")
    }

    @Test("a script rule survives Codable — the stored command round-trips")
    func triggerScriptCodable() throws {
        let rule = MenuBarTriggerRule(id: "s", enabled: true,
                                      trigger: .chargerConnected,
                                      action: .runScript(command: "pmset displaysleepnow"))
        let data = try JSONEncoder().encode(rule)
        let back = try JSONDecoder().decode(MenuBarTriggerRule.self, from: data)
        #expect(back == rule)
        #expect(back.action == .runScript(command: "pmset displaysleepnow"))
    }

    // MARK: The facade — the maintainer's wiring contract

    /// A delegate that records — the routing table is the contract.
    @MainActor
    private final class FakeDelegate: MenuBarActionsDelegate {
        var sections: [String: MenuBarItemSection] = [:]
        var items: [MenuBarItem] = []
        var running = true
        var calls: [String] = []
        func menuBarItems(for actions: MenuBarActions) -> [MenuBarItem] { items }
        func menuBarRunning(for actions: MenuBarActions) -> Bool { running }
        func menuBarSections(for actions: MenuBarActions) -> [String: MenuBarItemSection] { sections }
        func menuBarActions(_ actions: MenuBarActions,
                            setSection section: MenuBarItemSection, for itemID: String) {
            calls.append("setSection:\(itemID):\(section.rawValue)")
        }
        func menuBarActions(_ actions: MenuBarActions, openItem itemID: String) {
            calls.append("open:\(itemID)")
        }
        func menuBarActionsRevealHidden(_ actions: MenuBarActions) { calls.append("reveal") }
        func menuBarActionsToggleReveal(_ actions: MenuBarActions) { calls.append("toggleReveal") }
        func menuBarActionsRevealAlwaysHidden(_ actions: MenuBarActions) {
            calls.append("revealAlwaysHidden")
        }
        func menuBarActions(_ actions: MenuBarActions, revealFor seconds: Double) {
            calls.append("reveal:\(seconds)")
        }
        func menuBarActionsHideAll(_ actions: MenuBarActions) { calls.append("hideAll") }
        func menuBarActionsShowAll(_ actions: MenuBarActions) { calls.append("showAll") }
        func menuBarActions(_ actions: MenuBarActions, applyProfile name: String) {
            calls.append("profile:\(name)")
        }
        func menuBarActions(_ actions: MenuBarActions, cycleProfile direction: Int) {
            calls.append("cycle:\(direction)")
        }
        var profiles: [MenuBarSettings.Profile] = []
        func menuBarProfiles(for actions: MenuBarActions) -> [MenuBarSettings.Profile] { profiles }
        func menuBarActions(_ actions: MenuBarActions, applyProfileID id: String) {
            calls.append("profileID:\(id)")
        }
        func menuBarActions(_ actions: MenuBarActions, setRule id: String, enabled: Bool) {
            calls.append("rule:\(id):\(enabled)")
        }
        func menuBarActions(_ actions: MenuBarActions, saveProfileNamed name: String) {
            calls.append("save:\(name)")
        }
        func menuBarActions(_ actions: MenuBarActions, renameProfile id: String, to name: String) {
            calls.append("rename:\(id):\(name)")
        }
        weak var palette: PaletteController?
        func menuBarActionsFoldItemBar(_ actions: MenuBarActions) {
            calls.append(palette?.isOpen == true ? "fold:over-palette" : "fold")
        }
        func menuBarActions(_ actions: MenuBarActions, holdAwake seconds: Int?) {
            calls.append("awake:\(seconds.map(String.init) ?? "held")")
        }
    }

    /// A delegate that answers only the original requirements — the
    /// palette's newer calls fall back to the protocol's defaults.
    @MainActor
    private final class MinimalDelegate: MenuBarActionsDelegate {
        func menuBarItems(for actions: MenuBarActions) -> [MenuBarItem] { [] }
        func menuBarSections(for actions: MenuBarActions) -> [String: MenuBarItemSection] { [:] }
        func menuBarActions(_ actions: MenuBarActions,
                            setSection section: MenuBarItemSection, for itemID: String) {}
        func menuBarActions(_ actions: MenuBarActions, openItem itemID: String) {}
        func menuBarActionsRevealHidden(_ actions: MenuBarActions) {}
        func menuBarActionsToggleReveal(_ actions: MenuBarActions) {}
        func menuBarActionsRevealAlwaysHidden(_ actions: MenuBarActions) {}
        func menuBarActions(_ actions: MenuBarActions, revealFor seconds: Double) {}
        func menuBarActionsHideAll(_ actions: MenuBarActions) {}
        func menuBarActionsShowAll(_ actions: MenuBarActions) {}
        func menuBarActions(_ actions: MenuBarActions, applyProfile name: String) {}
        func menuBarActions(_ actions: MenuBarActions, cycleProfile direction: Int) {}
    }

    @MainActor
    @Test("the palette's verbs route to the delegate; a rule runs its own action")
    func paletteRouting() {
        let actions = MenuBarActions(bindings: [])
        let delegate = FakeDelegate()
        actions.delegate = delegate
        actions.rules = {
            [MenuBarTriggerRule(id: "r", enabled: false, trigger: .screenLocked,
                                action: .reveal(seconds: 3))]
        }
        actions.commandBar.onAction(.setAppSection(itemIDs: ["A", "B"], .alwaysHidden))
        actions.commandBar.onAction(.revealAlwaysHidden)
        actions.commandBar.onAction(.toggleHidden)
        actions.commandBar.onAction(.applyProfile(id: "p1"))
        actions.commandBar.onAction(.runRule(id: "r"))
        actions.commandBar.onAction(.runRule(id: "missing"))
        actions.commandBar.onAction(.setRuleEnabled(id: "r", true))
        #expect(delegate.calls == [
            "setSection:A:alwaysHidden", "setSection:B:alwaysHidden", "revealAlwaysHidden",
            "toggleReveal", "profileID:p1", "reveal:3.0", "rule:r:true",
        ])
        // The palette's inputs read the delegate's truth at the keystroke.
        delegate.profiles = [MenuBarSettings.Profile(id: "p", name: "Desk", sections: [:])]
        #expect(actions.commandBar.profiles().map(\.id) == ["p"])
        #expect(actions.commandBar.rules().map(\.id) == ["r"])
        #expect(actions.commandBar.menuBarItems().contains { $0.id == "menubar.profile.p" })
    }

    @MainActor
    @Test("a profile saves and renames by the name typed into the palette, and a refused name sends nothing")
    func paletteProfileNames() {
        let desk = MenuBarSettings.Profile(id: "p", name: "Desk", sections: [:])
        let rows = MenuBarCommands.build(items: [], sections: [:], profiles: [desk])
            .filter { $0.kind == .profile }
        let save = rows.last
        #expect(save?.id == "menubar.profile.save")
        #expect(save?.verbs.first?.action == .saveProfile(name: ""))
        #expect(save?.verbs.first?.input?.existingNames == ["Desk"])
        #expect(rows[1].verbs.map(\.id) == ["apply", "rename"])
        #expect(rows[1].verbs[1].input?.initial == "Desk", "a rename starts from the name")
        // As the palette draws them: each is a field, filled on Send.
        var performed: [MenuBarCommandAction] = []
        let saveItem = save?.paletteItem { performed.append($0) }
        let field = saveItem?.primary?.input
        #expect(field?.prompt == "Name this layout…")
        #expect(field?.accepts("Travel") == true)
        #expect(field?.accepts("none") == false, "the built-in's name is taken")
        #expect(field?.submit("Travel") == "Profile “Travel” saved")
        #expect(field?.submit("desk") == "Profile “desk” updated", "a saved name updates in place")
        let rename = rows[1].paletteItem { performed.append($0) }.actions.first { $0.id == "rename" }?.input
        #expect(rename?.submit("Office") == "Renamed to “Office”")
        #expect(performed == [.saveProfile(name: "Travel"), .saveProfile(name: "desk"),
                              .renameProfile(id: "p", name: "Office")])
        // Through the facade, a name the card would refuse goes nowhere.
        let actions = MenuBarActions(bindings: [])
        let delegate = FakeDelegate()
        actions.delegate = delegate
        actions.commandBar.onAction(.saveProfile(name: "Travel"))
        actions.commandBar.onAction(.saveProfile(name: "  "))
        actions.commandBar.onAction(.renameProfile(id: "p", name: "None"))
        actions.commandBar.onAction(.renameProfile(id: "p", name: "Office"))
        #expect(delegate.calls == ["save:Travel", "rename:p:Office"])
    }

    @MainActor
    @Test("a delegate without the palette's calls still compiles and answers safely")
    func paletteRoutingDefaults() {
        let actions = MenuBarActions(bindings: [])
        let delegate = MinimalDelegate()
        actions.delegate = delegate
        #expect(actions.commandBar.running(), "a delegate that cannot say is taken as running")
        #expect(actions.commandBar.profiles().isEmpty)
        // No-ops, not crashes.
        actions.commandBar.onAction(.applyProfile(id: "p"))
        actions.commandBar.onAction(.setRuleEnabled(id: "r", false))
    }

    /// The utility's settings, boxed so a closure can write them.
    @MainActor
    private final class SettingsBox {
        var settings = MenuBarSettings(enabled: false)
        var writes = 0
    }

    @MainActor
    @Test("the utility switches a rule and applies a profile by id through its own settings write")
    func utilityPaletteWitnesses() {
        let utility = MenuBarUtility()
        let box = SettingsBox()
        box.settings.triggerRules = [MenuBarTriggerRule(id: "r", enabled: true,
                                                        trigger: .screenLocked, action: .hideAll)]
        box.settings.profiles = [MenuBarSettings.Profile(id: "p", name: "Desk",
                                                         sections: [:],
                                                         concealedApps: ["com.example.a": .hidden])]
        utility.settings = { box.settings }
        utility.onSettingsChange = { box.settings = $0; box.writes += 1 }
        utility.actions.commandBar.onAction(.setRuleEnabled(id: "r", false))
        #expect(box.settings.triggerRules.first?.enabled == false)
        // The same state again writes nothing.
        utility.actions.commandBar.onAction(.setRuleEnabled(id: "r", false))
        #expect(box.writes == 1)
        utility.actions.commandBar.onAction(.applyProfile(id: "p"))
        // A profile is a layer: the base map stays yours, the curated
        // maps carry its delta.
        #expect(box.settings.curation.activeProfileID == "p")
        #expect(box.settings.concealedApps.isEmpty)
        #expect(MenuBarProfiles.curatedMaps(box.settings).concealedApps == ["com.example.a": .hidden])
        // An unknown id is a no-op, never a clear.
        utility.actions.commandBar.onAction(.applyProfile(id: "gone"))
        #expect(box.settings.curation.activeProfileID == "p")
        #expect(!utility.actions.commandBar.running(), "a switched-off utility answers parked")
        #expect(utility.actions.commandBar.menuBarItems().map(\.id) == ["menubar.off"])
        #expect(utility.actions.commandBar.profiles().map(\.id) == ["p"])
        #expect(utility.actions.commandBar.activeProfileID() == "p", "the applied profile reads Current")
        // Save and rename are the card's own writes.
        utility.actions.commandBar.onAction(.saveProfile(name: "Travel"))
        #expect(box.settings.profiles.map(\.name) == ["Desk", "Travel"])
        #expect(box.settings.profiles.last?.concealedApps == ["com.example.a": .hidden], "the live layout")
        utility.actions.commandBar.onAction(.renameProfile(id: "p", name: "Office"))
        #expect(box.settings.profiles.map(\.name) == ["Office", "Travel"])
    }

    @MainActor
    @Test("a parked utility's palette offers no menu-bar verb the bar would ignore, and says why")
    func paletteParked() async {
        let actions = MenuBarActions(bindings: [])
        let delegate = FakeDelegate()
        delegate.items = [appItem("1p", owner: "1Password", bundle: "com.1password.1password", x: 900)]
        delegate.profiles = [MenuBarSettings.Profile(id: "p", name: "Desk", sections: [:])]
        actions.rules = {
            [MenuBarTriggerRule(id: "r", enabled: true, trigger: .screenLocked, action: .hideAll)]
        }
        actions.delegate = delegate
        // Running, the same listing makes the app's row.
        #expect(actions.commandBar.menuBarItems().contains { $0.title == "1Password" })
        // Parked (off, or handed to Bartender), the listing is the
        // card's leftovers: nothing built from it would reach the bar.
        delegate.running = false
        let rows = actions.commandBar.menuBarItems()
        #expect(rows.map(\.id) == ["menubar.off"])
        let verbs = rows.flatMap(\.actions).map(\.title)
        for word in ["Hide", "Show", "Always", "Reveal", "Toggle", "Apply", "Run", "Turn", "Save"] {
            #expect(!verbs.contains { $0.hasPrefix(word) }, "no “\(word)” verb while parked")
        }
        var opened = 0
        actions.commandBar.openSettings = { opened += 1 }
        #expect(rows.first?.primary?.run() == nil, "the settings page is its own proof")
        #expect(opened == 1)
        #expect(delegate.calls.isEmpty)
    }

    /// The parked key's binding, boxed so the test can flip it.
    @MainActor
    private final class BindingBox {
        var binding = MenuBarHotkeyBinding(action: .commandBar, keyCode: 40,
                                           modifiers: UInt32(cmdKey | shiftKey), enabled: true)
    }

    @MainActor
    @Test("⌘⇧K stays registered while the utility is parked and hands over when it starts")
    func parkedPaletteKey() {
        let box = BindingBox()
        let actions = MenuBarActions(bindings: [box.binding])
        let full = FakeRegistrar()
        let parked = FakeRegistrar()
        actions.hotkeys.registrar = full
        actions.parkedPaletteKey.registrar = parked
        func live(_ registrar: FakeRegistrar) -> Int { registrar.registered.count - registrar.unregistered }

        actions.paletteBinding = { box.binding }
        #expect(live(parked) == 1, "parked: the palette's key alone")
        #expect(parked.registered.last?.key == 40)
        actions.start()
        #expect(live(parked) == 0, "the full set takes the key over")
        #expect(live(full) == 1)
        actions.stop()
        #expect(live(full) == 0)
        #expect(live(parked) == 1, "parked again")
        box.binding.enabled = false
        actions.syncParkedPaletteKey()
        #expect(live(parked) == 0, "a binding switched off in the card stays off")
        box.binding.enabled = true
        actions.syncParkedPaletteKey()
        #expect(live(parked) == 1)
        actions.shutDownPalette()
        #expect(live(parked) == 0)
        actions.syncParkedPaletteKey()
        #expect(live(parked) == 0, "nothing re-registers on the way out")
    }

    @MainActor
    @Test("with both sets on the app's one registry, a re-sync after the full set starts leaves ⌘⇧K live")
    func parkedPaletteKeySharedCenter() {
        // Production shares HotkeyCenter.shared between the parked key and
        // the full set, under one id. The first palette verb writes state,
        // which re-syncs the parked key — that must not take the full
        // set's live ⌘⇧K down with it.
        let box = BindingBox()
        let actions = MenuBarActions(bindings: [box.binding])
        let fake = FakeRegistrar()
        let center = HotkeyCenter(registrar: fake)
        actions.hotkeys.center = center
        actions.parkedPaletteKey.center = center
        func live() -> Int { fake.registered.count - fake.unregistered }
        let id = MenuBarHotkeys.registryID(for: .commandBar)
        let chord = HotkeyChord(box.binding)

        actions.paletteBinding = { box.binding }
        #expect(center.status(of: id) == .active(chord), "parked: the palette's key alone")
        actions.start()
        #expect(actions.parkedPaletteKey.bindings.isEmpty, "the parked set forgets the key it handed over")
        #expect(center.status(of: id) == .active(chord))
        #expect(live() == 1)
        actions.syncParkedPaletteKey()
        actions.syncParkedPaletteKey()
        #expect(center.status(of: id) == .active(chord), "the full set's key survives the re-sync")
        #expect(live() == 1)
        actions.stop()
        #expect(center.status(of: id) == .active(chord), "parked again")
        #expect(live() == 1)
        actions.shutDownPalette()
        #expect(center.status(of: id) == .inactive)
        #expect(live() == 0)
    }

    @MainActor
    @Test("command, hotkey and trigger actions all land on the one delegate")
    func facadeRouting() async throws {
        let actions = MenuBarActions(bindings: [])
        let delegate = FakeDelegate()
        actions.delegate = delegate

        actions.commandBar.onAction(.setSection(itemID: "A", .hidden))
        actions.commandBar.onAction(.openItem(itemID: "B"))
        actions.commandBar.onAction(.revealHidden)
        actions.hotkeys.onAction(.toggleReveal)
        actions.hotkeys.onAction(.revealAlwaysHidden)
        actions.hotkeys.onAction(.hideAll)
        actions.hotkeys.onAction(.nextProfile)
        // The trigger path: feed the engine through the facade's own
        // event handler — a locked screen applies the profile rule.
        actions.rules = {
            [MenuBarTriggerRule(id: "r", enabled: true,
                                trigger: .screenLocked,
                                action: .applyProfile(name: "Away"))]
        }
        let source = FakeSource()
        actions.triggerSource = source
        source.onEvent?(.screenLocked)

        #expect(delegate.calls == [
            "setSection:A:hidden", "open:B", "reveal", "toggleReveal",
            "revealAlwaysHidden", "hideAll",
            "cycle:1", "profile:Away",
        ])
    }

    @MainActor
    @Test("every route to the palette folds the Item Bar before the palette opens")
    func paletteFoldsItemBar() {
        let actions = MenuBarActions(bindings: [])
        let delegate = FakeDelegate()
        actions.delegate = delegate
        delegate.palette = actions.commandBar.palette
        actions.commandBar.palette.presentsWindow = false
        actions.openCommandBar()
        #expect(actions.commandBar.isOpen)
        actions.hotkeys.onAction(.commandBar)
        #expect(!actions.commandBar.isOpen, "the hotkey toggles it shut")
        actions.parkedPaletteKey.onAction(.commandBar)
        #expect(actions.commandBar.isOpen)
        actions.commandBar.close()
        #expect(delegate.calls == ["fold", "fold:over-palette", "fold"],
                "the bar folds first, whatever the palette's state")
    }

    /// A source that only exists so the facade wires `onEvent`.
    private final class FakeSource: MenuBarTriggerSource {
        var onEvent: (@MainActor (MenuBarTriggerEvent) -> Void)?
        func start() {}
        func stop() {}
    }

    // MARK: lane menubar — keep-awake rules

    @MainActor
    @Test("a rule keeps the Mac awake for its minutes, until released, or lets it sleep — through the delegate")
    func keepAwakeRules() {
        let actions = MenuBarActions(bindings: [])
        let delegate = FakeDelegate()
        actions.delegate = delegate
        actions.rules = {
            [MenuBarTriggerRule(id: "hour", enabled: false, trigger: .appLaunched(bundleID: "com.apple.dt.Xcode"),
                                action: .holdAwake(seconds: 3600)),
             MenuBarTriggerRule(id: "held", enabled: false, trigger: .chargerConnected,
                                action: .holdAwake(seconds: nil)),
             MenuBarTriggerRule(id: "tiny", enabled: false, trigger: .chargerConnected,
                                action: .holdAwake(seconds: 5)),
             MenuBarTriggerRule(id: "off", enabled: false, trigger: .chargerDisconnected,
                                action: .releaseAwake)]
        }
        for id in ["hour", "held", "tiny", "off"] { actions.commandBar.onAction(.runRule(id: id)) }
        #expect(delegate.calls == ["awake:3600", "awake:held", "awake:60", "awake:0"],
                "a hold shorter than a minute is a minute; release is zero")
    }

    @Test("keep-awake actions round-trip and read as the card writes them")
    func keepAwakeActionCoding() throws {
        for action in [MenuBarTriggerAction.holdAwake(seconds: 7200), .holdAwake(seconds: nil), .releaseAwake] {
            let rule = MenuBarTriggerRule(id: "r", trigger: .chargerConnected, action: action)
            let back = try JSONDecoder().decode(MenuBarTriggerRule.self, from: JSONEncoder().encode(rule))
            #expect(back == rule)
        }
        let rule = { (action: MenuBarTriggerAction) in
            MenuBarTriggerRule(id: "r", trigger: .chargerConnected, action: action).summary
        }
        #expect(rule(.holdAwake(seconds: 7200)) == "when the charger connects → keep the Mac awake for 2 h")
        #expect(rule(.holdAwake(seconds: 2700)) == "when the charger connects → keep the Mac awake for 45 min")
        #expect(rule(.holdAwake(seconds: nil)) == "when the charger connects → keep the Mac awake until released")
        #expect(rule(.releaseAwake) == "when the charger connects → let the Mac sleep again")
        #expect(MenuBarTriggerAction.clampedAwake(10) == 60)
        #expect(MenuBarTriggerAction.clampedAwake(999_999) == 86_400)
        #expect(MenuBarTriggerAction.clampedAwake(nil) == nil)
    }
}
