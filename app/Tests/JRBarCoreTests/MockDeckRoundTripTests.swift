import Foundation
import Testing
@testable import JRBarCore

/// Every deck command through the real client against the mock, plus the
/// `deck_input` and `deck_receipt` events it emits.
@Suite("Mock deck round trips", .serialized)
struct MockDeckRoundTripTests {
    @Test("state.deck arrives; approve, press, pin, bank, rail, plan/apply/restore, input check, settings, clear absent")
    @MainActor
    func commands() async throws {
        let socket = MockCoreIntegrationTests.temporarySocketPath()
        let mock = try MockCoreIntegrationTests.launchMock(socket: socket, extraArguments: ["--step", "600", "--deck", "unapproved"])
        defer {
            if mock.isRunning { mock.terminate() }
            try? FileManager.default.removeItem(atPath: socket)
        }
        let model = try await MockEffectsRoundTripTests.connectedModel(socket: socket)
        defer { model.stop() }
        var events: [CoreEvent] = []
        model.onEvent = { events.append($0) }

        // The pad is connected but not yet approved: keys are dark.
        let deck = try #require(model.deck)
        let device = try #require(deck.device)
        #expect(device.serial == "WL2-7C41-0F9E" && device.transport == .bluetooth)
        #expect(device.connected && !device.approved)
        #expect(deck.keySlots.allSatisfy { !$0.isLit })
        #expect(deck.keySlots.count == 13 && deck.auxControls.count == 7)
        #expect(deck.banks.count == 2, "three live sessions and fifteen remembered identities make two banks")
        #expect(deck.keySlots[1].pinned, "codex is pinned in the seed")
        #expect(deck.keySlots[0].state == .active && deck.keySlots[2].state == .idle)
        #expect(deck.keySlots[3].isReserved && deck.keySlots[3].subtitle == "Session not observed")
        #expect(deck.keymap.state == .stock && deck.keymap.layers.count == 3 && deck.rail.edge == .off)
        #expect(deck.settings.enabled && deck.settings.sessionMode && !deck.settings.analogEnabled)
        #expect(deck.auxControls[1].mapping == "next_bank")
        #expect(deck.scope == "automatic" && deck.scopes == ["codex", "claude"])
        #expect(deck.settings.layerMap == [DeckLayerScope(layer: 1, scope: "codex"), DeckLayerScope(layer: 2, scope: "claude")])
        #expect(deck.keymap.layers.map(\.boardScope) == ["automatic", "codex", "claude"])

        // Approval binds the connected serial.
        let approved = try await model.deckApproveDevice()
        #expect(approved.ok && approved.result?["serial"]?.stringValue == device.serial)
        #expect(await MockCoreIntegrationTests.wait { model.deck?.device?.approved == true })
        #expect(model.deck?.keySlots[0].isLit == true, "approved keys are lit")
        #expect(model.deck?.keySlots[0].color == "#00E5FF" && model.deck?.keySlots[2].color == "#020204")

        // Press: a live key reveals its session; a reserved one and an
        // unmapped auxiliary control are not_found; out of range is invalid.
        let press = try await model.deckPress(index: 0)
        #expect(press.ok && press.result?["action"]?.stringValue == "reveal_session")
        #expect(press.result?["session"]?.stringValue == model.deck?.keySlots[0].session)
        let reserved = try await model.deckPress(index: 5)
        #expect(!reserved.ok && reserved.error?.code == "not_found")
        let unmapped = try await model.deckPress(index: 18)
        #expect(!unmapped.ok && unmapped.error?.message == "Configure this auxiliary control in Settings > Devices.")
        let bad = try await model.deckPress(index: 24)
        #expect(!bad.ok && bad.error?.code == "invalid_args")

        // Bank: ±1 wraps; the encoder's next_bank mapping moves it too.
        let next = try await model.deckBank(delta: 1)
        #expect(next.ok && next.result?["index"]?.intValue == 1)
        #expect(await MockCoreIntegrationTests.wait { model.deck?.banks.index == 1 })
        #expect(model.deck?.keySlots[4].isReserved == true && model.deck?.keySlots[5].isEmpty == true, "bank 2 has five remembered identities")
        let wrapped = try await model.deckBank(delta: 1)
        #expect(wrapped.result?["index"]?.intValue == 0)
        let previous = try await model.deckBank(delta: -1)
        #expect(previous.result?["index"]?.intValue == 1)
        let dial = try await model.deckPress(index: 14)
        #expect(dial.ok && dial.result?["action"]?.stringValue == "next_bank" && dial.result?["bank"]?["index"]?.intValue == 0)
        #expect(await MockCoreIntegrationTests.wait { model.deck?.banks.index == 0 })

        // Pin: toggles the identity on that key; an unassigned key is not_found.
        let pinned = try await model.deckPin(index: 0)
        #expect(pinned.ok && pinned.result?["pinned"]?.boolValue == true)
        #expect(await MockCoreIntegrationTests.wait { model.deck?.keySlots[0].pinned == true })
        let unpinned = try await model.deckPin(index: 0)
        #expect(unpinned.ok && unpinned.result?["pinned"]?.boolValue == false)
        #expect(await MockCoreIntegrationTests.wait { model.deck?.keySlots[0].pinned == false })
        #expect(model.deck?.keySlots[0].session != nil, "unpinning keeps the identity in place")
        _ = try await model.deckBank(delta: 1)
        #expect(await MockCoreIntegrationTests.wait { model.deck?.banks.index == 1 })
        let empty = try await model.deckPin(index: 12)
        #expect(!empty.ok && empty.error?.code == "not_found")
        _ = try await model.deckBank(delta: -1)
        #expect(await MockCoreIntegrationTests.wait { model.deck?.banks.index == 0 })

        // Rail.
        let rail = try await model.deckRail(edge: .bottom)
        #expect(rail.ok && rail.result?["edge"]?.stringValue == "bottom")
        #expect(await MockCoreIntegrationTests.wait { model.deck?.rail.edge == .bottom })
        #expect(model.deck?.railShown == true)
        let badEdge = try await model.deckRail(edge: .off)
        #expect(badEdge.ok)
        #expect(await MockCoreIntegrationTests.wait { model.deck?.rail.edge == .off })

        // Plan: the review text lists every key change; the auxiliary
        // switch adds the dial and joystick.
        let planReply = try await model.deckPlanKeymap(profile: 0, layer: 0, includeAuxiliary: false)
        let plan = try #require(DeckKeymapPlan(planReply.result))
        #expect(plan.changes.count == 13)
        #expect(plan.changes.first == "Key 0: KC_1 -> KV_OAI_AG00; replaces its normal keystroke with a JR-Bar device input.")
        #expect(plan.preview.hasPrefix("Selected profile 1, layer 1:\n\nKey 0: KC_1 -> KV_OAI_AG00"))
        #expect(plan.preview.contains("Dial and joystick mappings stay unchanged."))
        #expect(plan.controls.count == 13)
        let auxReply = try await model.deckPlanKeymap(profile: 0, layer: 1, includeAuxiliary: true)
        let auxPlan = try #require(DeckKeymapPlan(auxReply.result))
        #expect(auxPlan.changes.count == 20 && auxPlan.controls.count == 20)
        #expect(auxPlan.changes[13] == "Encoder 1 input 1: KC_BRID -> KV_OAI_AG13; replaces its normal firmware action.")
        #expect(auxPlan.preview.contains("Supported dial/joystick mappings listed above also change."))
        let badPlan = try await model.deckPlanKeymap(profile: 0, layer: 9, includeAuxiliary: false)
        #expect(!badPlan.ok && badPlan.error?.code == "invalid_plan")

        // Apply backs up, writes, turns input check on and sends the
        // keymap_verified receipt; the mock then "presses" controls, which
        // arrive as deck_input events.
        let generation = model.deck?.keymap.generation ?? 0
        let applied = try await model.deckApplyKeymap(profile: 0, layer: 0, includeAuxiliary: false)
        #expect(applied.ok && applied.result?["code"]?.stringValue == "keymap_verified")
        #expect(applied.result?["message"]?.stringValue == DeckReceiptMessages.message(for: "keymap_verified"))
        #expect(await MockCoreIntegrationTests.wait { model.deck?.keymap.isApplied == true && model.deck?.inputCheck == true })
        #expect((model.deck?.keymap.generation ?? 0) == generation + 1)
        #expect(model.deck?.keymap.backupAt != nil)
        #expect(await MockCoreIntegrationTests.wait { model.deck?.device?.receipt?.code == "keymap_verified" })
        #expect(await MockCoreIntegrationTests.wait { events.contains { $0.receipt?.code == "keymap_verified" } })
        #expect(await MockCoreIntegrationTests.wait { events.filter { $0.kind == "deck_input" }.count >= 5 })
        let inputs = events.filter { $0.kind == "deck_input" }.compactMap(\.input)
        #expect(inputs.prefix(5).map(\.index) == [0, 1, 2, 13, 16])
        #expect(inputs.map(\.kind).contains("dial") && inputs.map(\.kind).contains("joystick"))
        var flashes = DeckInputFlashes()
        for input in inputs { flashes.record(input, at: input.at ?? 0) }
        #expect(flashes.flashes.count == 5)
        #expect(await MockCoreIntegrationTests.wait { model.deck?.lastInput?.index == 16 })

        // Presses are refused while input check is on.
        let paused = try await model.deckPress(index: 0)
        #expect(!paused.ok && paused.error?.code == "input_check")
        let off = try await model.deckCheckInput(enabled: false)
        #expect(off.ok)
        #expect(await MockCoreIntegrationTests.wait { model.deck?.inputCheck == false })

        // Applying again is already_configured (still ok, a receipt).
        let again = try await model.deckApplyKeymap(profile: 0, layer: 0, includeAuxiliary: false)
        #expect(again.ok && again.result?["code"]?.stringValue == "already_configured")
        let noop = try #require(DeckKeymapPlan((try await model.deckPlanKeymap(profile: 0, layer: 0, includeAuxiliary: false)).result))
        #expect(noop.isNoop && noop.preview.contains("No device keys need to change."))

        // Settings: any subset of bools; anything else is invalid.
        let settings = try await model.deckSetSettings(analogEnabled: true)
        #expect(settings.ok && settings.result?["analog_enabled"]?.boolValue == true)
        #expect(await MockCoreIntegrationTests.wait { model.deck?.settings.analogEnabled == true })
        let sessionOff = try await model.deckSetSettings(sessionMode: false)
        #expect(sessionOff.ok)
        #expect(await MockCoreIntegrationTests.wait { model.deck?.settings.sessionMode == false })
        #expect(model.deck?.keySlots[0].isLit == false, "without session mode the pad is not driven per key")
        _ = try await model.deckSetSettings(sessionMode: true)

        // Explicit aux bindings replace the whole auxiliary set: index 19
        // gains next_scope, the dial keeps its bank paging, index 18 clears.
        let bound = try await model.deckSetSettings(bindings: [
            (index: 13, action: "previous_bank"), (index: 14, action: "next_bank"),
            (index: 15, action: "open_control_center"), (index: 16, action: "reveal_current_ask"),
            (index: 17, action: "open_usage"), (index: 18, action: nil), (index: 19, action: "next_scope"),
        ])
        #expect(bound.ok && bound.result?["bindings"]?.arrayValue?.count == 6)
        #expect(await MockCoreIntegrationTests.wait { model.deck?.auxControls[6].mapping == "next_scope" })
        #expect(model.deck?.settings.bindings?.last == DeckBinding(index: 19, action: "next_scope"))
        let badBinding = try await model.deckSetSettings(bindings: [(index: 5, action: "next_scope")])
        #expect(!badBinding.ok && badBinding.error?.code == "invalid_args")

        // A provider scope limits the board to that provider's live
        // sessions; next_scope cycles automatic -> codex -> claude -> wrap.
        let scoped = try await model.deckPress(index: 19)
        #expect(scoped.ok && scoped.result?["scope"]?.stringValue == "codex")
        #expect(await MockCoreIntegrationTests.wait { model.deck?.scope == "codex" })
        #expect(model.deck?.keySlots.compactMap(\.session) == ["codex:session:0f3b2c9a-71d4-4e0e-9a8e-2c1d5f6a7b8c"],
                "only codex's live session stays; archived codex identities never gain a slot")
        #expect(model.deck?.banks.count == 1)
        let scopedAgain = try await model.deckPress(index: 19)
        #expect(scopedAgain.result?["scope"]?.stringValue == "claude")
        #expect(await MockCoreIntegrationTests.wait { model.deck?.scope == "claude" })
        #expect(model.deck?.keySlots.compactMap(\.session) == ["claude:session:fca1eb06-f6d1-413e-aa5f-dd19d8e05973"])
        let wrappedScope = try await model.deckPress(index: 19)
        #expect(wrappedScope.result?["scope"]?.stringValue == "automatic")
        #expect(await MockCoreIntegrationTests.wait { model.deck?.scope == "automatic" })
        #expect(model.deck?.keySlots.filter { !$0.isEmpty }.count == 13, "automatic shows the whole board again")

        // `deck_scope` cycles the same order from the scope stepper, no
        // aux binding needed.
        let stepped = try await model.deckScope(delta: 1)
        #expect(stepped.ok && stepped.result?["scope"]?.stringValue == "codex")
        #expect(await MockCoreIntegrationTests.wait { model.deck?.scope == "codex" })
        let steppedBack = try await model.deckScope(delta: -1)
        #expect(steppedBack.result?["scope"]?.stringValue == "automatic")
        #expect(await MockCoreIntegrationTests.wait { model.deck?.scope == "automatic" })

        // The layer map re-scopes the hardware layers; the pad is on layer
        // 1, which maps to automatic, so the board stays unscoped.
        let mapped = try await model.deckSetSettings(layerMap: [
            (layer: 0, scope: "automatic"), (layer: 1, scope: "codex"), (layer: 2, scope: "devin"),
        ])
        #expect(mapped.ok)
        #expect(await MockCoreIntegrationTests.wait { model.deck?.scopes == ["codex", "devin"] })
        #expect(model.deck?.scope == "automatic")
        #expect(model.deck?.keymap.layers[2].boardScope == "devin")
        let extra = try await model.deckSetSettings(scopes: ["t3code"])
        #expect(extra.ok && extra.result?["scopes"]?.arrayValue?.compactMap(\.stringValue) == ["t3code"])
        #expect(await MockCoreIntegrationTests.wait { model.deck?.scopes == ["codex", "devin", "t3code"] })
        let nothing = try await model.deckSetSettings()
        #expect(!nothing.ok && nothing.error?.code == "invalid_args")

        // The multi-layer plan previews the same write the layers apply
        // runs; layer 1 is already claimed, so only layers 2 and 3 change.
        let multiReply = try await model.deckPlanKeymap(
            profile: 0, layer: 0,
            layers: [(layer: 0, name: "Automatic"), (layer: 1, name: "Codex"), (layer: 2, name: "Devin")],
            includeAuxiliary: false)
        let multiPlan = try #require(DeckKeymapPlan(multiReply.result))
        #expect(multiPlan.preview.hasPrefix("Selected profile 1, layers 1, 2, 3:"))
        #expect(multiPlan.changes.count == 2 + 26)
        #expect(multiPlan.changes.first == "Layer 2: 13 keys claimed for JR-Bar device inputs.")

        // A multi-layer apply claims and names every listed layer at once.
        let layers = try await model.deckApplyKeymap(
            profile: 0,
            layers: [(layer: 0, name: "Automatic"), (layer: 1, name: "Codex"), (layer: 2, name: "Devin")],
            includeAuxiliary: false)
        #expect(layers.ok && layers.result?["code"]?.stringValue == "keymap_verified")
        #expect(await MockCoreIntegrationTests.wait {
            model.deck?.keymap.layers.map(\.label) == ["Profile 1 / Layer 1: Automatic", "Profile 1 / Layer 2: Codex", "Profile 1 / Layer 3: Devin"]
        })

        // Restore puts the stock layers back, names included; again is
        // already_restored.
        let restored = try await model.deckRestoreKeymap()
        #expect(restored.ok && restored.result?["code"]?.stringValue == "keymap_restored")
        #expect(await MockCoreIntegrationTests.wait { model.deck?.keymap.state == .stock })
        #expect(model.deck?.keymap.layers.map(\.label)
                == ["Profile 1 / Layer 1: Base", "Profile 1 / Layer 2: Fn", "Profile 1 / Layer 3: Macros"])
        let restoredAgain = try await model.deckRestoreKeymap()
        #expect(restoredAgain.ok && restoredAgain.result?["code"]?.stringValue == "already_restored")
        #expect(await MockCoreIntegrationTests.wait { model.deck?.device?.receipt?.code == "already_restored" })

        // Clear absent: the fifteen unobserved, unpinned identities leave; one bank remains.
        let cleared = try await model.deckClearAbsent()
        #expect(cleared.ok && cleared.result?["removed"]?.intValue == 15)
        #expect(await MockCoreIntegrationTests.wait { model.deck?.banks.count == 1 })
        #expect(model.deck?.keySlots.filter { !$0.isEmpty }.count == 3)
    }

    @Test("the conflict step sets device.conflict and a receipt, refuses keymap writes, and clears")
    @MainActor
    func conflict() async throws {
        let socket = MockCoreIntegrationTests.temporarySocketPath()
        // Step 9 is the conflict; a long step keeps it there.
        let mock = try MockCoreIntegrationTests.launchMock(socket: socket, extraArguments: ["--step", "600", "--start-at", "9"])
        defer {
            if mock.isRunning { mock.terminate() }
            try? FileManager.default.removeItem(atPath: socket)
        }
        let model = try await MockEffectsRoundTripTests.connectedModel(socket: socket)
        defer { model.stop() }
        #expect(await MockCoreIntegrationTests.wait { model.deck?.device?.conflict == "foreign_responses" })
        #expect(model.deck?.device?.isUsable == false)
        #expect(model.deck?.device?.receipt?.code == "device_conflict")
        #expect(model.deck?.device?.receipt?.text == "Close Input and other hardware controllers, then inspect again.")
        #expect(model.deck?.keySlots.allSatisfy { !$0.isLit } == true, "keys go dark while another app owns the pad")
        let refused = try await model.deckApplyKeymap(profile: 0, layer: 0, includeAuxiliary: false)
        #expect(!refused.ok && refused.error?.code == "device_conflict")
        let restore = try await model.deckRestoreKeymap()
        #expect(!restore.ok && restore.error?.code == "device_conflict")
        // Pins, presses and the rail are host-side and still work.
        let pin = try await model.deckPin(index: 0)
        #expect(pin.ok)
        let press = try await model.deckPress(index: 0)
        #expect(press.ok)
        let rail = try await model.deckRail(edge: .top)
        #expect(rail.ok)
        #expect(await MockCoreIntegrationTests.wait { model.deck?.rail.edge == .top })
        #expect(model.deck?.railShown == true, "the rail is a host-side surface")
    }

    @Test("--deck absent has no device: presses and the rail still work, approve and apply say so")
    @MainActor
    func absent() async throws {
        let socket = MockCoreIntegrationTests.temporarySocketPath()
        let mock = try MockCoreIntegrationTests.launchMock(socket: socket, extraArguments: ["--step", "600", "--deck", "absent"])
        defer {
            if mock.isRunning { mock.terminate() }
            try? FileManager.default.removeItem(atPath: socket)
        }
        let model = try await MockEffectsRoundTripTests.connectedModel(socket: socket)
        defer { model.stop() }
        let deck = try #require(model.deck)
        #expect(deck.device == nil && !deck.hasDevice && !deck.railShown)
        #expect(deck.keySlots.count == 13, "the board is there for when a pad appears")
        #expect(deck.keySlots.allSatisfy { !$0.isLit })
        let press = try await model.deckPress(index: 0)
        #expect(press.ok, "revealing a session needs no hardware")
        let approve = try await model.deckApproveDevice()
        #expect(!approve.ok && approve.error?.code == "no_device")
        let apply = try await model.deckApplyKeymap(profile: 0, layer: 0, includeAuxiliary: false)
        #expect(!apply.ok && apply.error?.code == "connection_required")
        #expect(apply.error?.message == "Connect and approve Creator Micro 2 before setup.")
        let rail = try await model.deckRail(edge: .left)
        #expect(rail.ok)
        #expect(await MockCoreIntegrationTests.wait { model.deck?.rail.edge == .left })
        #expect(model.deck?.railShown == true, "no device, still a rail")
    }

    @Test("--deck recovering refuses Apply until Restore succeeds")
    @MainActor
    func recovering() async throws {
        let socket = MockCoreIntegrationTests.temporarySocketPath()
        let mock = try MockCoreIntegrationTests.launchMock(socket: socket, extraArguments: ["--step", "600", "--deck", "recovering"])
        defer {
            if mock.isRunning { mock.terminate() }
            try? FileManager.default.removeItem(atPath: socket)
        }
        let model = try await MockEffectsRoundTripTests.connectedModel(socket: socket)
        defer { model.stop() }
        #expect(model.deck?.keymap.needsRecovery == true)
        #expect(model.deck?.device?.receipt?.code == "recovery_required")
        let apply = try await model.deckApplyKeymap(profile: 0, layer: 0, includeAuxiliary: false)
        #expect(!apply.ok && apply.error?.code == "recovery_required")
        #expect(apply.error?.message == "A transfer was interrupted. Backup retained. Choose Restore device keymap, not Apply again.")
        let restore = try await model.deckRestoreKeymap()
        #expect(restore.ok && restore.result?["code"]?.stringValue == "keymap_restored")
        #expect(await MockCoreIntegrationTests.wait { model.deck?.keymap.state == .stock })
        let applyNow = try await model.deckApplyKeymap(profile: 0, layer: 1, includeAuxiliary: true)
        #expect(applyNow.ok && applyNow.result?["code"]?.stringValue == "keymap_verified")
        #expect(applyNow.result?["changes"]?.arrayValue?.count == 20)
    }
}
