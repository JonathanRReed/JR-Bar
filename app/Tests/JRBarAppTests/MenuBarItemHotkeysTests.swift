import Carbon
import Foundation
import JRBarCore
import Testing
@testable import JRBarApp

@Suite @MainActor struct MenuBarItemHotkeysTests {
    private func item(_ identifier: String? = "status", pid: Int32 = 101,
                      protected: Bool = false) -> MenuBarItem {
        MenuBarItem(id: "fixture", ownerPID: pid, ownerName: "Fixture",
                    bounds: CGRect(x: 0, y: 0, width: 24, height: 24), title: "Mutable title",
                    windowID: 0, identifier: identifier,
                    isNativeOverflowControl: protected, bundleID: "com.example.fixture")
    }
    private func target(_ selector: MenuBarItemShortcutTarget.Selector = .identifier("status")) throws -> MenuBarItemShortcutTarget {
        try #require(MenuBarItemShortcutTarget(bundleID: "com.example.fixture", selector: selector))
    }
    private func binding(_ selector: MenuBarItemShortcutTarget.Selector = .identifier("status")) throws -> MenuBarItemHotkeyBinding {
        MenuBarItemHotkeyBinding(target: try target(selector), displayName: "Fixture", keyCode: 12,
                                modifiers: UInt32(controlKey | optionKey))
    }
    private func reconcile(_ controller: MenuBarItemHotkeys, _ rows: [MenuBarItemHotkeyBinding],
                           _ inventory: [MenuBarItem], running: Bool = true, permission: Bool = true) {
        controller.reconcile(bindings: rows, inventory: inventory, running: running, permission: permission)
    }

    @Test func selectionSurvivesReorderingAndRelaunchButNeverSelectsASibling() throws {
        let selection = try target()
        #expect(MenuBarItemHotkeys.availability(selection, in: [item("sibling"), item()]) == .ready)
        #expect(MenuBarItemHotkeys.availability(selection, in: [item(pid: 909), item("sibling", pid: 909)]) == .ready)
        #expect(MenuBarItemHotkeys.availability(selection, in: [item("sibling")]) == .missing)
        #expect(MenuBarItemHotkeys.availability(selection, in: [item(), item()]) == .ambiguous)
        #expect(MenuBarItemHotkeys.availability(selection, in: [item(), item("sibling", pid: 202)]) == .ambiguous)
        #expect(MenuBarItemHotkeys.availability(selection, in: [item(protected: true)]) == .invalid)
    }

    @Test func soleItemRequiresExactlyOneAndPickerPrefersIdentifier() throws {
        let sole = try target(.soleItem)
        #expect(MenuBarItemHotkeys.availability(sole, in: [item(nil)]) == .ready)
        #expect(MenuBarItemHotkeys.availability(sole, in: [item(nil), item("sibling")]) == .ambiguous)
        #expect(MenuBarItemHotkeys.target(for: item(), in: [item()]) == (try target()))
        #expect(MenuBarItemHotkeys.target(for: item(nil), in: [item(nil)]) == sole)
        #expect(MenuBarItemHotkeys.target(for: item(nil), in: [item(nil), item("sibling")]) == nil)
        #expect(MenuBarItemHotkeys.target(for: item(protected: true), in: [item(protected: true)]) == nil)
    }

    @Test func duplicateChordsRegisterNeitherAndDiscoveryNeverActivates() throws {
        let registrar = HotkeyCenterTests.Recorder()
        let center = HotkeyCenter(registrar: registrar)
        let controller = MenuBarItemHotkeys(center: center)
        var activations = 0
        controller.activate = { _, _ in activations += 1; return .ready }
        let first = try binding()
        var sibling = try binding(.identifier("sibling"))
        sibling.displayName = "Sibling fixture"
        reconcile(controller, [first, sibling], [item(), item("sibling")])
        #expect(center.entries.isEmpty)
        #expect(controller.states[first.id] == .conflict("Sibling fixture"))
        reconcile(controller, [first], [])
        #expect(controller.states[first.id] == .missing)
        reconcile(controller, [first], [item()])
        #expect(center.entries[first.id] != nil)
        #expect(activations == 0)
        controller.stop()
        #expect(center.entries.isEmpty)
        #expect(registrar.unregistered == 1)
    }

    @Test func failedAndConflictedIDsAreRemovedOnEditAndStop() throws {
        let registrar = HotkeyCenterTests.Recorder()
        let center = HotkeyCenter(registrar: registrar)
        let controller = MenuBarItemHotkeys(center: center)
        let row = try binding()
        let chord = HotkeyChord(keyCode: row.keyCode, modifiers: row.modifiers)
        center.register("fixture.other", title: "Other feature", chord: chord) {}
        reconcile(controller, [row], [item()])
        #expect(controller.states[row.id] == .conflict("Other feature"))
        #expect(center.conflicts[row.id] != nil)
        controller.stop()
        #expect(center.conflicts[row.id] == nil)
        center.unregister("fixture.other")
        registrar.taken = [chord]
        reconcile(controller, [row], [item()])
        #expect(controller.states[row.id] == .refused)
        reconcile(controller, [], [item()])
        #expect(center.refusals[row.id] == nil)
        controller.stop()
    }

    @Test func permissionUtilityAndDisabledStatesHoldNoKeys() throws {
        let registrar = HotkeyCenterTests.Recorder()
        let center = HotkeyCenter(registrar: registrar)
        let controller = MenuBarItemHotkeys(center: center)
        var row = try binding()
        reconcile(controller, [row], [item()], permission: false)
        #expect(controller.states[row.id] == .permission)
        reconcile(controller, [row], [item()], running: false)
        #expect(controller.states[row.id] == .utilityOff)
        row.enabled = false
        reconcile(controller, [row], [item()])
        #expect(controller.states[row.id] == .disabled)
        row.enabled = true
        row.modifiers = 0
        reconcile(controller, [row], [item()])
        #expect(controller.states[row.id] == .invalid)
        #expect(center.entries.isEmpty)
        #expect(registrar.registered.isEmpty)
    }

    @Test func profilesAndSettingsTransferPreserveBothKeyLists() throws {
        let itemBinding = try binding()
        let barBinding = MenuBarHotkeyBinding(action: .showAll, keyCode: 13, modifiers: 6144, enabled: true)
        var state = UtilitiesState(menuBar: MenuBarSettings(hotkeyBindings: [barBinding], itemHotkeyBindings: [itemBinding]))
        let profile = MenuBarProfiles.capture(name: "Fixture profile", from: state.menuBar)
        MenuBarProfiles.apply(profile, to: &state.menuBar)
        MenuBarProfiles.apply(nil, to: &state.menuBar)
        #expect(state.menuBar.itemHotkeyBindings == [itemBinding])
        #expect(state.menuBar.hotkeyBindings == [barBinding])
        let result = SettingsBundle.utilitiesForImport(state, over: UtilitiesState())
        #expect(result.state.menuBar.itemHotkeyBindings == [itemBinding])
        #expect(result.state.menuBar.hotkeyBindings == [barBinding])
    }

    @Test func itemWritesWaitForAValidChordAndTakeoverClearsTheActualPreference() throws {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-item-fixture.sock")
        let settings = SettingsStore(core: core)
        let utilities = UtilitiesStore(core: core, settings: settings, state: UtilitiesState())
        settings.utilities = utilities
        let selection = try target()
        utilities.menuBar.setItemHotkeyChord(nil, for: selection)
        #expect(utilities.state.menuBar.itemHotkeyBindings.isEmpty)
        utilities.menuBar.setItemHotkeyChord(HotkeyChord(keyCode: 12, modifiers: 0), for: selection)
        #expect(utilities.state.menuBar.itemHotkeyBindings.isEmpty)
        let chord = HotkeyChord(keyCode: 12, modifiers: UInt32(controlKey | optionKey))
        utilities.menuBar.setItemHotkeyChord(chord, for: selection, displayName: "Fixture")
        #expect(utilities.state.menuBar.itemHotkeyBindings.count == 1)
        settings.setShortcut(nil, for: selection.registryID)
        #expect(utilities.state.menuBar.itemHotkeyBindings.isEmpty)
        #expect(!utilities.menuBar.running)
    }

    @Test func lateActivationResultCannotReplaceStoppedOrEditedRowState() async throws {
        let registrar = HotkeyCenterTests.Recorder()
        let center = HotkeyCenter(registrar: registrar)
        let controller = MenuBarItemHotkeys(center: center)
        let row = try binding()
        let started = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<MenuBarItemHotkeys.State, Never>?
        controller.activate = { _, _ in
            await withCheckedContinuation { continuation in
                release = continuation
                started.continuation.yield(())
            }
        }
        reconcile(controller, [row], [item()])
        let task = Task { await controller.activateBinding(row) }
        var events = started.stream.makeAsyncIterator()
        _ = await events.next()
        controller.stop()
        release?.resume(returning: .missing)
        await task.value
        #expect(controller.states[row.id] == .utilityOff)
        #expect(center.entries.isEmpty)
        started.continuation.finish()

        let editedStarted = AsyncStream<Void>.makeStream()
        controller.activate = { _, _ in
            await withCheckedContinuation { continuation in
                release = continuation
                editedStarted.continuation.yield(())
            }
        }
        reconcile(controller, [row], [item()])
        let editedTask = Task { await controller.activateBinding(row) }
        var editedEvents = editedStarted.stream.makeAsyncIterator()
        _ = await editedEvents.next()
        var edited = row
        edited.enabled = false
        reconcile(controller, [edited], [item()])
        release?.resume(returning: .refused)
        await editedTask.value
        #expect(controller.states[row.id] == .disabled)
        #expect(center.entries.isEmpty)
        editedStarted.continuation.finish()
    }


    @Test func queuedUserCallbackCannotActivateARestartedBinding() async throws {
        let registrar = HotkeyCenterTests.Recorder()
        let center = HotkeyCenter(registrar: registrar)
        let controller = MenuBarItemHotkeys(center: center)
        let row = try binding()
        var activations = 0
        controller.activate = { _, _ in activations += 1; return .ready }
        reconcile(controller, [row], [item()])
        let keyID = try #require(registrar.registered.first?.id)
        center.fire(hotKeyID: keyID)
        let queued = try #require(controller.activationTask)
        controller.stop()
        reconcile(controller, [row], [item()])
        await queued.value
        #expect(activations == 0)
        #expect(controller.states[row.id] == .ready)
        controller.stop()
    }

    @Test func geometryAndTitleChangesPreserveRegistrationAndStillRouteTheTypedTarget() async throws {
        let registrar = HotkeyCenterTests.Recorder()
        let center = HotkeyCenter(registrar: registrar)
        let controller = MenuBarItemHotkeys(center: center)
        let row = try binding()
        var opened: [MenuBarItemShortcutTarget] = []
        controller.activate = { target, _ in opened.append(target); return .ready }
        reconcile(controller, [row], [item()])
        let moved = MenuBarItem(id: "different-listing-id", ownerPID: 101, ownerName: "Changed owner label",
                                bounds: CGRect(x: 800, y: 40, width: 32, height: 24),
                                title: "Changed title", windowID: 999, identifier: "status", bundleID: "com.example.fixture")
        reconcile(controller, [row], [moved])
        #expect(registrar.registered.count == 1)
        #expect(registrar.unregistered == 0)
        let keyID = try #require(registrar.registered.first?.id)
        center.fire(hotKeyID: keyID)
        let queued = try #require(controller.activationTask)
        await queued.value
        #expect(opened == [row.target])
        controller.stop()
    }


    @Test func unavailablePickerRowsExplainTheirIdentityProblem() {
        let unlabelled = item(nil)
        #expect(MenuBarItemHotkeys.selectionProblem(for: unlabelled, in: [unlabelled, item("sibling")])
                == "This app has multiple items and this item has no unique Accessibility identifier.")
        #expect(MenuBarItemHotkeys.selectionProblem(for: item(), in: [item(), item()])
                == "This Accessibility identifier is shared by multiple items.")
        #expect(MenuBarItemHotkeys.selectionProblem(for: item(), in: [item(), item(pid: 202)])
                == "More than one running app owns this item.")
        let noBundle = MenuBarItem(id: "fixture-helper", ownerPID: 404, ownerName: "Fixture helper",
                                   bounds: .zero, title: nil, windowID: 0)
        #expect(MenuBarItemHotkeys.selectionProblem(for: noBundle, in: [noBundle])
                == "This owner has no bundle identifier.")
    }

}
