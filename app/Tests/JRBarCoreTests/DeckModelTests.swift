import CoreGraphics
import Foundation
import Testing
@testable import JRBarCore

/// `state.deck`: decoding, the slot / bank / pin reducers, input flashes
/// from `deck_input` events, receipts, the control names and the rail's
/// fourteen-cell geometry.
@Suite("Deck model")
struct DeckModelTests {
    static func fixture() throws -> CoreState {
        guard case .state(let state) = try CoreFixtures.message("deck_state.json") else {
            throw CoreReplyError(code: "fixture", message: "not a state")
        }
        return state
    }

    @Test("decodes state.deck with every field, tolerating unknown keys, states and out-of-range slots")
    func decode() throws {
        let state = try Self.fixture()
        let deck = try #require(state.deck)
        let device = try #require(deck.device)
        #expect(device.serial == "WL2-7C41-0F9E")
        #expect(device.transport == .usb)
        #expect(device.connected && device.approved && !device.hasConflict)
        #expect(device.isUsable)
        #expect(device.firmware == "v0.6.1" && device.layer == 1 && device.profile == 0)
        #expect(device.receipt?.code == "keymap_verified")
        #expect(device.receipt?.text == "Creator Micro 2 stored keymap verified. Reconnect if needed, then check inputs.",
                "a receipt without a message reads from the Python table")
        #expect(deck.banks == DeckBanks(index: 1, count: 3))
        #expect(deck.rail.edge == .right && deck.railShown)
        #expect(deck.keymap.state == .applied)
        #expect(deck.keymap.backupAt == 1788990000.0)
        #expect(deck.keymap.generation == 4)
        #expect(deck.keymap.layers.map(\.id) == ["0/0", "0/1"])
        #expect(deck.keymap.layers[1].label == "Profile 1 / Layer 2: Fn")
        #expect(deck.inputCheck)
        #expect(deck.lastInput == DeckInput(index: 14, kind: "dial", at: 1788999900.0))
        #expect(deck.lastInput?.sentence == "Encoder 1 input 2 turned")
        #expect(deck.settings == DeckSettings(enabled: true, sessionMode: true, analogEnabled: false))
        #expect(deck.slots.count == 11, "the raw list keeps what the daemon sent")

        let keys = deck.keySlots
        #expect(keys.count == 13)
        #expect(keys.map(\.index) == Array(0..<13))
        #expect(keys[0].session == "claude:session:a" && keys[0].state == .active && keys[0].isLit)
        #expect(keys[1].pinned && keys[1].state == .inputRequired && keys[1].subtitle == "Needs you")
        #expect(keys[2].isReserved && keys[2].title == "notes-refactor" && keys[2].subtitle == "Session not observed" && !keys[2].isLit)
        #expect(keys[3].state == .completed && keys[3].subtitle == "Completed")
        #expect(keys[4].state == .failure && keys[4].subtitle == "Error")
        #expect(keys[5].state == .stale && keys[5].subtitle == "Stale")
        #expect(keys[6].state == .endedUnconfirmed && keys[6].subtitle == "Ended, unconfirmed")
        #expect(keys[7].state == .unknown, "an unknown state word degrades to unknown")
        #expect(keys[8].isReserved && keys[8].pinned)
        #expect(keys[9].isEmpty && keys[9].title == "Unassigned" && keys[9].subtitle == "No session assigned", "a missing index is padded")
        #expect(keys[12].isEmpty && !keys[12].navigable)
        #expect(!keys.contains { $0.session == "ghost" }, "index 13 is not one of the thirteen keys")
        #expect(deck.boundSessions.contains("ghost"), "but the raw list still carries it")
        #expect(deck.slot(bound: "codex:session:b")?.index == 1)
        #expect(deck.absentSlots.map(\.index) == [2], "absent = reserved and unpinned")

        let aux = deck.auxControls
        #expect(aux.map(\.index) == Array(13..<20))
        #expect(aux[0].mapping == "previous_bank" && aux[0].mappingLabel == "Previous bank" && aux[0].isEncoder)
        #expect(aux[3].isJoystick && aux[3].mappingLabel == "Reveal current ask")
        #expect(aux[4].mapping == nil)
        #expect(aux[5].label == "Joystick sector 3" && aux[5].mapping == nil, "missing controls get their default label")
        #expect(!aux.contains { $0.label == "not an aux control" }, "index 3 is a key, not an auxiliary control")
    }

    @Test("the owner's daemon frame: pad off, nothing approved, nulls for transport / layer / receipt, seven banks, stock keymap with three layers")
    func realShape() throws {
        guard case .state(let state) = try CoreFixtures.message("real_state.json") else {
            Issue.record("not a state"); return
        }
        let deck = try #require(state.deck)
        let device = try #require(deck.device, "a remembered serial is a device even while the pad is off")
        #expect(device.serial == "D0CF130481EC" && device.name == "Creator Micro 2")
        #expect(device.transport == nil && device.firmware == nil && device.layer == nil && device.profile == nil)
        #expect(!device.connected && !device.approved && !device.hasConflict && !device.isUsable)
        #expect(device.receipt == nil)
        #expect(!deck.hasDevice)
        #expect(deck.banks == DeckBanks(index: 0, count: 7) && deck.banks.hasMultiple && deck.banks.title == "Bank 1 of 7")
        #expect(deck.rail.edge == .off && !deck.railShown)
        #expect(deck.keymap.state == .stock && !deck.keymap.isApplied && !deck.keymap.needsRecovery)
        #expect(deck.keymap.generation == 0 && deck.keymap.backupAt != nil)
        #expect(deck.keymap.layers.map(\.id) == ["0/0", "0/1", "0/2"])
        #expect(deck.keymap.layers.map(\.label) == ["Profile 1 / Layer 1: Layer 1", "Profile 1 / Layer 2: Layer 2", "Profile 1 / Layer 3: Layer 3"])
        #expect(!deck.inputCheck && deck.lastInput == nil)
        #expect(deck.settings == DeckSettings(enabled: true, sessionMode: false, analogEnabled: false))
        // Thirteen remembered identities, none observed: every key is Reserved and dark.
        let keys = deck.keySlots
        #expect(keys.count == 13 && deck.slots.count == 13)
        #expect(keys.allSatisfy { $0.isReserved && !$0.isEmpty && $0.session == nil && $0.label == nil && $0.provider == nil })
        #expect(keys.allSatisfy { $0.state == .unavailable && !$0.pinned && !$0.navigable && !$0.isLit && $0.color == "#000000" })
        #expect(keys[0].title == "Reserved" && keys[0].subtitle == "Session not observed" && keys[0].shortSubtitle == "Not observed")
        #expect(deck.boundSessions.isEmpty)
        #expect(deck.absentSlots.count == 13, "Clear absent would take every one of them")
        // Seven auxiliary controls, none mapped, with the daemon's labels.
        let aux = deck.auxControls
        #expect(aux.map(\.index) == Array(13...19))
        #expect(aux.allSatisfy { $0.mapping == nil && $0.mappingLabel == nil })
        #expect(aux[0].label == "Encoder 1 input 1" && aux[0].isEncoder && aux[3].label == "Joystick sector 1" && aux[3].isJoystick)
        // The rest of the real frame decodes around it.
        #expect(state.sessions.count == 21)
        #expect(state.sessions.allSatisfy { $0.shortId != nil })
        #expect(state.aggregate.mode == "working")
    }

    @Test("a state without a deck, or with a malformed one, still decodes")
    func absent() throws {
        let plain = try CoreCodec.decode(frame: Data(#"{"t":"state","v":1,"generation":1,"aggregate":{"mode":"idle"}}"#.utf8))
        guard case .state(let state) = plain else { Issue.record("not a state"); return }
        #expect(state.deck == nil)

        let bad = try CoreCodec.decode(frame: Data(#"{"t":"state","v":1,"generation":1,"aggregate":{"mode":"idle"},"deck":"nope"}"#.utf8))
        guard case .state(let broken) = bad else { Issue.record("not a state"); return }
        #expect(broken.deck == nil, "a malformed deck is dropped, not fatal")

        let sparse = try CoreCodec.decode(frame: Data(#"{"t":"state","v":1,"generation":1,"aggregate":{"mode":"idle"},"deck":{"device":null,"slots":[],"last_input":"x"}}"#.utf8))
        guard case .state(let empty) = sparse else { Issue.record("not a state"); return }
        let deck = try #require(empty.deck)
        #expect(deck.device == nil && !deck.hasDevice && !deck.railShown)
        #expect(deck.banks == DeckBanks(index: 0, count: 1))
        #expect(deck.rail.edge == .off)
        #expect(deck.keymap.state == .stock && deck.keymap.layers.isEmpty)
        #expect(deck.lastInput == nil, "a malformed last_input is dropped")
        #expect(deck.keySlots.count == 13 && deck.keySlots.allSatisfy { $0.isEmpty })
        #expect(deck.auxControls.count == 7)
        #expect(deck.settings == DeckSettings())
    }

    @Test("unknown enum values degrade instead of failing")
    func unknownWords() throws {
        let text = #"{"t":"state","v":1,"generation":1,"aggregate":{"mode":"idle"},"deck":{"device":{"serial":"S","transport":"thunderbolt","connected":true,"approved":true,"conflict":"foreign_responses","receipt":{"code":"weird_thing"}},"rail":{"edge":"diagonal"},"keymap":{"state":"melting"},"banks":{"index":7,"count":2}}}"#
        guard case .state(let state) = try CoreCodec.decode(frame: Data(text.utf8)) else { Issue.record("not a state"); return }
        let deck = try #require(state.deck)
        #expect(deck.device?.transport == nil)
        #expect(deck.device?.hasConflict == true && deck.device?.isUsable == false)
        #expect(deck.device?.receipt?.text == "Creator Micro 2: weird thing.", "an unknown receipt code gets the Python fallback")
        #expect(deck.rail.edge == .off)
        #expect(deck.keymap.state == .unknown)
        #expect(deck.banks.index == 1, "a bank index past the end is clamped")
    }

    @Test("slot states carry the Python display names, rail marks and lighting colours")
    func slotStates() {
        let names = DeckSlotState.allCases.map(\.displayName)
        #expect(names == ["Needs you", "Error", "Working", "Completed", "Idle", "Stale", "Not observed", "Unknown", "Ended, unconfirmed"])
        #expect(DeckSlotState.inputRequired.railMark == "!" && DeckSlotState.failure.railMark == "!")
        #expect(DeckSlotState.active.railMark == "·")
        #expect(DeckSlotState.completed.railMark == "" && DeckSlotState.idle.railMark == "")
        #expect(DeckSlotState.inputRequired.lightingHex == "#FF3A00" && DeckSlotState.failure.lightingHex == "#FF3A00")
        #expect(DeckSlotState.active.lightingHex == "#00E5FF")
        #expect(DeckSlotState.completed.lightingHex == "#00FF66")
        #expect(DeckSlotState.idle.lightingHex == "#020204" && DeckSlotState.unavailable.lightingHex == "#020204")
        #expect(DeckLighting.isDark("#020204") && DeckLighting.isDark("#000000") && DeckLighting.isDark(nil) && DeckLighting.isDark("nope"))
        #expect(!DeckLighting.isDark("#00E5FF"))
    }

    @Test("controls: 13 keys in rows 2/4/4/3, the encoder, the joystick, the analog sectors, their names and keycodes")
    func controls() {
        #expect(DeckControls.slotCount == 13 && DeckControls.rows == [2, 4, 4, 3])
        #expect(DeckControls.rowIndices == [[0, 1], [2, 3, 4, 5], [6, 7, 8, 9], [10, 11, 12]])
        #expect(DeckControls.position(of: 0)! == (0, 0))
        #expect(DeckControls.position(of: 5)! == (1, 3))
        #expect(DeckControls.position(of: 12)! == (3, 2))
        #expect(DeckControls.position(of: 13) == nil)
        #expect(DeckControls.label(for: 0) == "Key 1" && DeckControls.label(for: 12) == "Key 13")
        #expect(DeckControls.label(for: 13) == "Encoder 1 input 1" && DeckControls.label(for: 15) == "Encoder 1 input 3")
        #expect(DeckControls.label(for: 16) == "Joystick sector 1" && DeckControls.label(for: 19) == "Joystick sector 4")
        #expect(DeckControls.label(for: 20) == "Analog sector 1" && DeckControls.label(for: 23) == "Analog sector 4")
        #expect(DeckControls.label(for: 24) == "AG24")
        #expect(DeckControls.keycode(for: 0) == "KV_OAI_AG00" && DeckControls.keycode(for: 19) == "KV_OAI_AG19")
        #expect(DeckControls.actionLabel("open_control_center") == "Control Center")
        #expect(DeckControls.actionLabel("something_else") == "Something Else")
        #expect(DeckInput(index: 3).sentence == "Key 4 pressed")
        #expect(DeckInput(index: 17, kind: "joystick").sentence == "Joystick sector 2 moved")
    }

    @Test("banks wrap both ways and a single bank is a fixed point")
    func banks() {
        let two = DeckBanks(index: 1, count: 2)
        #expect(two.advanced(by: 1).index == 0)
        #expect(two.advanced(by: -1).index == 0)
        #expect(two.advanced(by: 3).index == 0)
        #expect(DeckBanks(index: 0, count: 3).advanced(by: -1).index == 2)
        let one = DeckBanks(index: 0, count: 1)
        #expect(one.advanced(by: 1) == one && one.advanced(by: -5) == one)
        #expect(!one.hasMultiple && two.hasMultiple)
        #expect(DeckBanks(index: 0, count: 0).count == 1, "count never drops below one")
        #expect(DeckBanks(index: 9, count: 3).index == 2, "the initialiser clamps too")
        #expect(two.title == "Bank 2 of 2")
    }

    @Test("the pin, bank and clear-absent reducers describe the state the daemon will confirm")
    func reducers() throws {
        let deck = try #require(try Self.fixture().deck)

        let pinned = deck.togglingPin(at: 0)
        #expect(pinned.keySlots[0].pinned && !deck.keySlots[0].pinned)
        #expect(pinned.togglingPin(at: 0).keySlots[0].pinned == false)
        #expect(deck.togglingPin(at: 1).keySlots[1].pinned == false, "toggling an existing pin removes it")
        #expect(deck.togglingPin(at: 12).keySlots[12].pinned == false, "an unassigned key cannot be pinned")
        #expect(pinned.keySlots.count == 13)

        let next = deck.advancingBank(by: 1)
        #expect(next.banks.index == 2 && next.slots.isEmpty, "the slots of the new bank are the daemon's to send")
        #expect(next.keySlots.allSatisfy { $0.isEmpty })
        let wrapped = next.advancingBank(by: 1)
        #expect(wrapped.banks.index == 0)
        let same = DeckState(slots: deck.slots, banks: DeckBanks(index: 0, count: 1)).advancingBank(by: 1)
        #expect(same.slots.count == deck.slots.count, "with one bank nothing moves and the slots stay")

        let cleared = deck.clearingAbsent()
        let titles = cleared.keySlots.prefix(9).map(\.title)
        #expect(!titles.contains("notes-refactor"), "the unpinned reserved slot leaves")
        #expect(titles.contains("reserved-pinned"), "the pinned reserved slot stays")
        #expect(cleared.keySlots[2].title == "docs-sweep", "later keys move up")
        #expect(cleared.keySlots.map(\.index) == Array(0..<13))
        #expect(cleared.slots.count == 8)

        #expect(deck.settingRail(edge: .top).rail.edge == .top)
    }

    @Test("input flashes follow deck_input events and expire on their own")
    func flashes() {
        var flashes = DeckInputFlashes()
        #expect(flashes.isEmpty)
        flashes.record(DeckInput(index: 2), at: 100)
        flashes.record(DeckInput(index: 14, kind: "dial"), at: 100)
        flashes.record(DeckInput(index: 23, kind: "analog"), at: 100)
        flashes.record(DeckInput(index: 24), at: 100)
        #expect(flashes.flashes.count == 3, "index 24 is not a control")
        #expect(flashes.isLit(2, at: 100.5) && flashes.isLit(14, at: 100.5) && flashes.isLit(23, at: 100.5))
        #expect(!flashes.isLit(2, at: 100 + DeckInputFlashes.duration + 0.01), "a flash lasts 0.9 s")
        #expect(flashes.nextExpiry == 100 + DeckInputFlashes.duration)
        flashes.expire(at: 101.5)
        #expect(flashes.isEmpty && flashes.nextExpiry == nil)
        flashes.record(DeckInput(index: 2), at: 101.5)
        #expect(flashes.flashes[2]?.kind == "press")
    }

    @Test("deck_input and deck_receipt events decode; receipts that mean trouble become toasts")
    func events() throws {
        let text = #"{"t":"event","v":1,"id":"ev-9","kind":"deck_input","input":{"index":3,"kind":"press","at":1.0},"at":1.0,"notify":false}"#
        guard case .event(let event) = try CoreCodec.decode(frame: Data(text.utf8)) else { Issue.record("not an event"); return }
        #expect(event.kind == "deck_input" && event.input == DeckInput(index: 3, kind: "press", at: 1.0))
        #expect(EventPolicy.delivery(for: event, state: nil, settings: nil).toast == nil, "an input is not a toast")

        let odd = #"{"t":"event","v":1,"id":"ev-10","kind":"deck_input","input":{"index":"x"}}"#
        guard case .event(let broken) = try CoreCodec.decode(frame: Data(odd.utf8)) else { Issue.record("not an event"); return }
        #expect(broken.input == nil, "a non-integer index is ignored, not fatal")

        let conflict = CoreEvent(id: "ev-11", kind: "deck_receipt", label: "Creator Micro 2", code: "device_conflict")
        #expect(conflict.receipt?.isProblem == true)
        #expect(EventPolicy.delivery(for: conflict, state: nil, settings: nil).toast == "Another app is talking to the device; JR-Bar stopped writing")

        let recovery = CoreEvent(id: "ev-12", kind: "deck_receipt", code: "recovery_required", message: "custom words")
        #expect(EventPolicy.delivery(for: recovery, state: nil, settings: nil).toast == "custom words", "the daemon's message wins")

        let verified = CoreEvent(id: "ev-13", kind: "deck_receipt", code: "keymap_verified")
        #expect(verified.receipt?.isProblem == false)
        #expect(EventPolicy.delivery(for: verified, state: nil, settings: nil).toast == nil, "a good receipt stays in the window")

        let plan = DeckKeymapPlan(.object([
            "profile": .number(0), "layer": .number(1), "include_auxiliary": .bool(true),
            "changes": .array([.string("Key 0: KC_1 -> KV_OAI_AG00; replaces its normal keystroke with a JR-Bar device input.")]),
            "preview": .string("Selected profile 1, layer 2:"),
            "controls": .array([.object(["index": .number(0), "label": .string("Key 1")]), .object(["index": .number(13)])]),
        ]))
        let decoded = try #require(plan)
        #expect(decoded.layer == 1 && decoded.includeAuxiliary && decoded.changes.count == 1 && !decoded.isNoop)
        #expect(decoded.controls.map(\.label) == ["Key 1", "Encoder 1 input 1"])
        #expect(DeckKeymapPlan(.object(["changes": .array([])])) == nil, "no preview, no plan")
    }

    // MARK: Rail geometry

    static let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
    static let external = CGRect(x: 1512, y: -100, width: 2560, height: 1415)

    @Test("the rail has fourteen 18–30 pt cells in a 34 pt band, centred on each edge, inside the visible frame")
    func railEdges() {
        #expect(DeckRailGeometry.cellCount == 14 && DeckRailGeometry.depth == 34)
        #expect(DeckRailGeometry.unit(forExtent: 944) == 30, "(944 - 20) / 14 = 66, clamped to 30")
        #expect(DeckRailGeometry.unit(forExtent: 300) == 20, "(300 - 20) / 14 = 20")
        #expect(DeckRailGeometry.unit(forExtent: 100) == 18, "never below 18")
        for screen in [Self.screen, Self.external] {
            let run: CGFloat = 30 * 14
            let left = DeckRailGeometry(edge: .left, visibleFrame: screen)
            #expect(left.frame.minX == screen.minX + DeckRailGeometry.edgeInset)
            #expect(left.frame.width == DeckRailGeometry.depth && left.frame.height == run)
            #expect(abs(left.frame.midY - screen.midY) <= 1)

            let right = DeckRailGeometry(edge: .right, visibleFrame: screen)
            #expect(right.frame.maxX == screen.maxX - DeckRailGeometry.edgeInset)
            #expect(right.frame.width == DeckRailGeometry.depth)

            let top = DeckRailGeometry(edge: .top, visibleFrame: screen)
            #expect(top.frame.maxY == screen.maxY - DeckRailGeometry.edgeInset)
            #expect(top.frame.height == DeckRailGeometry.depth && top.frame.width == run)
            #expect(abs(top.frame.midX - screen.midX) <= 1)

            let bottom = DeckRailGeometry(edge: .bottom, visibleFrame: screen)
            #expect(bottom.frame.minY == screen.minY + DeckRailGeometry.edgeInset)
            #expect(bottom.frame.height == DeckRailGeometry.depth)

            for geometry in [left, right, top, bottom] {
                #expect(screen.contains(geometry.frame), "\(geometry.edge) on \(screen)")
                #expect(geometry.cellRects.count == 14)
                #expect(geometry.unit == 30)
                for rect in geometry.cellRects {
                    #expect(CGRect(origin: .zero, size: geometry.frame.size).contains(rect))
                }
            }
        }
    }

    @Test("cells run top-to-bottom on vertical edges and left-to-right on horizontal ones, contiguous, and hit-test")
    func railCells() {
        let left = DeckRailGeometry(edge: .left, visibleFrame: Self.screen)
        #expect(left.cellRects[0].maxY == left.frame.height, "key 1 at the top")
        #expect(left.cellRects[13].minY == 0, "the … cell at the bottom")
        #expect(left.cellRects[0].minY == left.cellRects[1].maxY, "contiguous")
        #expect(left.cellRects.allSatisfy { $0.width == DeckRailGeometry.depth - DeckRailGeometry.cellInset * 2 })
        #expect(left.cell(at: CGPoint(x: 10, y: left.cellRects[2].midY)) == 2)
        #expect(left.cell(at: CGPoint(x: 10, y: left.cellRects[13].midY)) == 13)
        #expect(DeckRailGeometry.isOverflowCell(13) && !DeckRailGeometry.isOverflowCell(12))
        #expect(left.cell(at: CGPoint(x: 0.5, y: 100)) == nil, "the band's inset belongs to nobody")

        let bottom = DeckRailGeometry(edge: .bottom, visibleFrame: Self.screen)
        #expect(bottom.cellRects[0].minX == 0, "key 1 on the left")
        #expect(bottom.cellRects[13].maxX == bottom.frame.width, "… on the right")
        #expect(bottom.cell(at: CGPoint(x: bottom.cellRects[4].midX, y: 10)) == 4)
        #expect(bottom.cellRects.allSatisfy { $0.height == DeckRailGeometry.depth - DeckRailGeometry.cellInset * 2 })
    }

    @Test("a short edge shrinks the cells to the 18 pt floor instead of overflowing")
    func railClips() {
        let small = CGRect(x: 0, y: 0, width: 200, height: 300)
        let top = DeckRailGeometry(edge: .top, visibleFrame: small)
        #expect(top.unit == 18 && top.frame.width == 18 * 14)
        #expect(top.frame.width > small.width, "18 pt cells cannot fit a 200 pt edge; the floor wins, as in the Python")
        let side = DeckRailGeometry(edge: .left, visibleFrame: small)
        #expect(side.unit == 20 && small.contains(side.frame))
    }
}
