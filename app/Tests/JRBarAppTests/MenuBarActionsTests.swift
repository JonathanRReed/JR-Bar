import AppKit
import Carbon
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The ACTIONS track's pure halves (docs/UTILITIES.md): the arrange
/// plan's ordering and skip rules, the palette's fuzzy matcher, the
/// hotkey model's conflicts and display strings, the trigger engine's
/// edge detection — plus the arrange coordinator's abort semantics
/// driven through an injected fake watcher and a recording poster.
/// Nothing here posts a real event or moves a real cursor: every
/// event-posting seam is a recorder.
@Suite("Menu Bar actions")
struct MenuBarActionsTests {
    private let row = CGRect(x: 0, y: 0, width: 1512, height: 24)

    private func item(_ id: String, owner: String = "App", x: Double,
                      y: Double = 0, w: Double = 24) -> MenuBarItem {
        MenuBarItem(id: id, ownerPID: 500, ownerName: owner,
                    bounds: CGRect(x: x, y: y, width: w, height: 24),
                    title: nil, windowID: 0)
    }

    // MARK: ArrangePlan — the order model

    @Test("a run already in the desired order earns no drags")
    func arrangeAlreadyOrdered() {
        let items = [item("A", x: 600), item("B", x: 700)]
        let steps = MenuBarArrangePlan.steps(items: items, order: ["A", "B"],
                                             boundary: 900, row: row)
        #expect(steps.isEmpty)
    }

    @Test("only the out-of-order item moves — the kept chain is the LCS")
    func arrangeMinimalMove() {
        // Current [A, B, C], desired [C, A, B]: A and B already sit in
        // the right relative order — only C is lifted out and dropped
        // at the deep end.
        let items = [item("A", x: 600), item("B", x: 700), item("C", x: 800)]
        let steps = MenuBarArrangePlan.steps(items: items, order: ["C", "A", "B"],
                                             boundary: 1000, row: row)
        #expect(steps.map(\.itemID) == ["C"])
        // C's slot is the run's deep end: two items pack right of it.
        let targets = MenuBarArrangePlan.targetCenters(
            MenuBarArrangePlan.resolvedOrder(items: items,
                                             order: ["C", "A", "B"], row: row),
            boundary: 1000)
        #expect(steps.first?.to.x == targets["C"])
    }

    @Test("steps emit desired-rightmost first so each drop lands on a placed neighbor")
    func arrangeStepOrder() {
        // Desired is a full reversal — two of three must move, and the
        // one that belongs furthest right is dragged first.
        let items = [item("A", x: 600), item("B", x: 700), item("C", x: 800)]
        let steps = MenuBarArrangePlan.steps(items: items, order: ["C", "B", "A"],
                                             boundary: 1000, row: row)
        #expect(steps.count == 2)
        #expect(steps.map(\.itemID) == ["A", "B"])
        #expect(steps[0].to.x > steps[1].to.x,
                "the desired-rightmost item drops at the largest x")
    }

    @Test("unnamed items keep their order as a block at the deep end; unknown ids are ignored")
    func arrangeResolvedOrder() {
        let items = [item("X", x: 600), item("A", x: 700), item("B", x: 800)]
        let resolved = MenuBarArrangePlan.resolvedOrder(
            items: items, order: ["Ghost", "B", "A"], row: row)
        #expect(resolved.map(\.id) == ["X", "B", "A"])
    }

    @Test("protected and parked items are never in the movable run")
    func arrangeExclusions() {
        let items = [item("A", x: 600),
                     item("Sys", owner: "Control Center", x: 1400),
                     item("Parked", x: 7, y: 970)]
        let movable = MenuBarArrangePlan.movableItems(items, row: row)
        #expect(movable.map(\.id) == ["A"])
        // The boundary packs against the leftmost fixed item — the
        // protected one — not the display edge.
        let boundary = MenuBarArrangePlan.rightBoundary(items: items,
                                                        regionMax: 1512, row: row)
        #expect(boundary == 1400)
        let steps = MenuBarArrangePlan.steps(
            items: items, order: ["Sys", "Parked", "A"], boundary: boundary, row: row)
        #expect(steps.allSatisfy { $0.itemID == "A" })
    }

    @Test("simulated drags converge: replaying the plan against a fake bar reaches the order")
    func arrangeConverges() {
        // Re-planning after each drop is the coordinator's loop; the
        // fake bar's insert-at-slot reflow is what the real system does.
        let bar = FakeBar()
        bar.setOrder(["A", "B", "C", "D"])
        let desired = ["D", "B", "A", "C"]
        var moves = 0
        for _ in 0..<10 {
            let steps = MenuBarArrangePlan.steps(items: bar.items(), order: desired,
                                               boundary: bar.boundary, row: row)
            guard let step = steps.first else { break }
            bar.post(from: step.from, to: step.to)
            moves += 1
        }
        #expect(bar.barOrder == desired)
        #expect(moves >= 1 && moves <= 4,
                "the LCS keeps a subsequence seated — at most the out-of-order items move, plus reflow slack")
    }

    // MARK: The coordinator — abort semantics with a fake watcher

    /// A watcher a test flips by hand — no event ever posts. The
    /// coordinator reads `cancelled` on the main actor; a test's
    /// `postDrag` (a @Sendable closure on the detached task) may write
    /// it, so both sides take the lock.
    private final class FakeWatcher: MenuBarArrangeWatching, @unchecked Sendable {
        private let lock = NSLock()
        private var _cancelled = false
        private var _stopped = false
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
        var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }
        func setCancelled() { lock.lock(); _cancelled = true; lock.unlock() }
        func stop() { lock.lock(); _stopped = true; lock.unlock() }
    }

    /// A bar a test steers, modeled the way macOS actually behaves:
    /// the state is an *order* (left→right ids); slot frames derive
    /// from it by packing against a fixed right boundary. A drop on a
    /// slot takes that slot — the occupant slides toward the gap the
    /// dragged item left, the same reflow the real bar does.
    /// Lock-guarded because `postDrag` runs on the coordinator's
    /// detached task while `listItems` runs on the main actor.
    private final class FakeBar: @unchecked Sendable {
        private let lock = NSLock()
        private var order: [String] = []
        private var _drags: [(from: CGPoint, to: CGPoint)] = []
        private var _warps: [CGPoint] = []
        let boundary: CGFloat = 900
        let width: CGFloat = 24
        let gap: CGFloat = 2

        var drags: [(from: CGPoint, to: CGPoint)] {
            lock.lock(); defer { lock.unlock() }; return _drags
        }
        var warps: [CGPoint] {
            lock.lock(); defer { lock.unlock() }; return _warps
        }
        var barOrder: [String] {
            lock.lock(); defer { lock.unlock() }; return order
        }
        /// Seed the bar left→right.
        func setOrder(_ ids: [String]) {
            lock.lock(); order = ids; lock.unlock()
        }

        /// Slot frames for an ordering, packed right against boundary.
        private func slots(for ids: [String]) -> [String: CGRect] {
            var edge = boundary
            var out: [String: CGRect] = [:]
            for id in ids.reversed() {
                let minX = edge - gap - width
                out[id] = CGRect(x: minX, y: 0, width: width, height: 24)
                edge = minX
            }
            return out
        }

        func items() -> [MenuBarItem] {
            lock.lock(); defer { lock.unlock() }
            let s = slots(for: order)
            return order.map {
                MenuBarItem(id: $0, ownerPID: 1, ownerName: "App",
                            bounds: s[$0] ?? .zero, title: nil, windowID: 0)
            }
        }

        /// The recorder standing in for `postCommandDrag`: the drop
        /// takes the slot containing `to.x` and the displaced items
        /// slide toward the gap — remove, then insert on the side the
        /// item came from.
        func post(from: CGPoint, to: CGPoint) {
            lock.lock(); defer { lock.unlock() }
            _drags.append((from, to))
            let s = slots(for: order)
            guard let oldIndex = order.firstIndex(where: { s[$0]?.contains(
                CGPoint(x: from.x, y: 12)) == true }) else { return }
            let id = order[oldIndex]
            let dropIndex = order.firstIndex(where: { s[$0]?.contains(
                CGPoint(x: to.x, y: 12)) == true })
                ?? (to.x > (s[order.last ?? id]?.midX ?? 0) ? order.count - 1 : 0)
            order.remove(at: oldIndex)
            order.insert(id, at: min(dropIndex, order.count))
        }

        func warp(_ point: CGPoint) {
            lock.lock(); _warps.append(point); lock.unlock()
        }
    }

    @MainActor
    private func makeCoordinator(bar: FakeBar,
                                 watcher: FakeWatcher) -> MenuBarArrangeCoordinator {
        let coordinator = MenuBarArrangeCoordinator()
        coordinator.bannerSuppressed = true
        coordinator.listItems = { bar.items() }
        coordinator.rowRect = { CGRect(x: 0, y: 0, width: 1512, height: 24) }
        // The fake bars below pack contiguously against 900 the way a
        // real extras run packs against its fixed items — the plan's
        // absolute targets coincide with real slots.
        coordinator.rightBoundary = { 900 }
        coordinator.cursorLocation = { CGPoint(x: 400, y: 400) }
        coordinator.warpCursor = { bar.warp($0) }
        coordinator.postDrag = { bar.post(from: $0, to: $1) }
        coordinator.settle = { }
        coordinator.makeWatcher = { _ in watcher }
        return coordinator
    }

    @MainActor
    @Test("a clean run drags each step, restores the cursor, and reports completed")
    func coordinatorCompletes() async throws {
        let bar = FakeBar()
        bar.setOrder(["A", "B", "C"])
        let watcher = FakeWatcher()
        let coordinator = makeCoordinator(bar: bar, watcher: watcher)
        let outcome = await coordinator.arrange(to: ["C", "A", "B"])
        #expect(outcome == .completed(moves: 1))
        #expect(bar.drags.count == 1)
        #expect(bar.warps == [CGPoint(x: 400, y: 400)],
                "the cursor goes home after the drag")
        #expect(watcher.stopped)
        #expect(bar.barOrder == ["C", "A", "B"])
    }

    @MainActor
    @Test("a bar already in order reports alreadyInOrder and never touches the poster")
    func coordinatorNoOp() async {
        let bar = FakeBar()
        bar.setOrder(["A", "B"])
        let watcher = FakeWatcher()
        let coordinator = makeCoordinator(bar: bar, watcher: watcher)
        let outcome = await coordinator.arrange(to: ["A", "B"])
        #expect(outcome == .alreadyInOrder)
        #expect(bar.drags.isEmpty)
        #expect(bar.warps.isEmpty)
    }

    @MainActor
    @Test("a foreign event mid-run aborts after the in-flight drag and still restores the cursor")
    func coordinatorAborts() async {
        let bar = FakeBar()
        // A non-converging bar: the drag never lands (the fake refuses
        // to move items), so the loop would run to the cap without the
        // abort — the watcher is the only way out.
        bar.setOrder(["A", "B"])
        let watcher = FakeWatcher()
        let coordinator = makeCoordinator(bar: bar, watcher: watcher)
        coordinator.postDrag = { _, _ in watcher.setCancelled() }
        let outcome = await coordinator.arrange(to: ["B", "A"])
        #expect(outcome == .aborted(completedMoves: 1))
        #expect(bar.warps.count == 1)
        #expect(watcher.stopped)
    }

    @MainActor
    @Test("a second arrange call while one runs reports busy, not a stacked cursor driver")
    func coordinatorBusy() async throws {
        let bar = FakeBar()
        bar.setOrder(["A", "B"])
        let watcher = FakeWatcher()
        let coordinator = makeCoordinator(bar: bar, watcher: watcher)
        // Hold the run inside settle until released.
        let gate = Gate()
        coordinator.settle = { await gate.wait() }
        let first = Task { await coordinator.arrange(to: ["B", "A"]) }
        await Task.yield()
        let second = await coordinator.arrange(to: ["B", "A"])
        #expect(second == .busy)
        await gate.open()
        _ = await first.value
    }

    /// A one-shot async gate for the busy test.
    private actor Gate {
        var opened = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            for w in waiters { w.resume() }
            waiters = []
        }
    }

    // MARK: Commands — build + fuzzy match

    @Test("each item earns Open plus the section toggle its assignment implies")
    func commandBuild() {
        let items = [item("Free", owner: "Free", x: 600),
                     item("Hid", owner: "Hid", x: 700),
                     item("Deep", owner: "Deep", x: 800)]
        let commands = MenuBarCommands.build(
            items: items,
            sections: ["Hid": .hidden, "Deep": .alwaysHidden])
        let titles = commands.map(\.title)
        #expect(titles.contains("Open Free"))
        #expect(titles.contains("Hide Free"))      // shown → offer hide
        #expect(titles.contains("Always hide Free"))
        #expect(titles.contains("Show Hid"))       // hidden → offer show
        #expect(!titles.contains("Hide Hid"))
        #expect(titles.contains("Always hide Deep") == false)
        #expect(titles.contains("Reveal hidden items"))
        #expect(titles.contains("Arrange menu bar items…"))
        #expect(titles.contains("Hide all items"))
        #expect(titles.contains("Show all items"))
    }

    @Test("protected items get no commands — the palette cannot hide the clock")
    func commandBuildProtected() {
        let items = [item("Sys", owner: "Control Center", x: 1400)]
        let commands = MenuBarCommands.build(items: items, sections: [:])
        #expect(commands.allSatisfy { $0.action != .openItem(itemID: "Sys") })
        #expect(!commands.map(\.title).contains { $0.contains("Sys") })
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
        // Filter orders by score and drops non-matches.
        let commands = MenuBarCommands.build(
            items: [item("Mail", owner: "Mail", x: 600),
                    item("Cal", owner: "Cal", x: 700)], sections: [:])
        let hits = MenuBarCommands.filter(commands, query: "hide mail")
        #expect(hits.first?.title == "Hide Mail")
        #expect(!hits.contains { $0.title == "Open Cal" })
    }

    @Test("hideAll assigns every listed unprotected item and spares the rest")
    func hideAllSections() {
        let items = [item("A", x: 600),
                     item("Sys", owner: "MenuBarAgent", x: 1400)]
        let map = MenuBarCommands.hideAllSections(items: items)
        #expect(map == ["A": .hidden])
    }

    @MainActor
    @Test("the palette model refilters and clamps the selection")
    func paletteModel() {
        let model = MenuBarCommandBarModel()
        model.load(items: [item("Mail", owner: "Mail", x: 600),
                           item("Cal", owner: "Cal", x: 700)], sections: [:])
        #expect(model.filtered.count == model.all.count)
        model.query = "mail"
        #expect(!model.filtered.isEmpty)
        // The title matches outrank the detail-only matches, and every
        // Mail row is in.
        #expect(model.filtered.first?.title.hasSuffix("Mail") == true)
        #expect(model.filtered.contains { $0.title == "Hide Mail" })
        #expect(model.filtered.contains { $0.title == "Open Mail" })
        model.move(-1)
        #expect(model.selection == model.filtered.count - 1, "arrows wrap")
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

    // MARK: The facade — the maintainer's wiring contract

    /// A delegate that records — the routing table is the contract.
    @MainActor
    private final class FakeDelegate: MenuBarActionsDelegate {
        var sections: [String: MenuBarItemSection] = [:]
        var calls: [String] = []
        func menuBarItems(for actions: MenuBarActions) -> [MenuBarItem] { [] }
        func menuBarSections(for actions: MenuBarActions) -> [String: MenuBarItemSection] { sections }
        func menuBarArrangeOrder(for actions: MenuBarActions) -> [String] { [] }
        func menuBarArrangeBoundary(for actions: MenuBarActions) -> CGFloat { 1512 }
        func menuBarActions(_ actions: MenuBarActions,
                            setSection section: MenuBarItemSection, for itemID: String) {
            calls.append("setSection:\(itemID):\(section.rawValue)")
        }
        func menuBarActions(_ actions: MenuBarActions, openItem itemID: String) {
            calls.append("open:\(itemID)")
        }
        func menuBarActionsRevealHidden(_ actions: MenuBarActions) { calls.append("reveal") }
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
            "setSection:A:hidden", "open:B", "reveal", "hideAll",
            "cycle:1", "profile:Away",
        ])
    }

    /// A source that only exists so the facade wires `onEvent`.
    private final class FakeSource: MenuBarTriggerSource {
        var onEvent: (@MainActor (MenuBarTriggerEvent) -> Void)?
        func start() {}
        func stop() {}
    }
}
