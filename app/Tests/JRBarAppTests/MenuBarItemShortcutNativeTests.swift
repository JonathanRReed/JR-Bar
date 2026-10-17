import Foundation
import ApplicationServices
import JRBarCore
import Testing
@testable import JRBarApp

@Suite struct MenuBarItemShortcutNativeTests {
    @Test func menuTrackingReplyDoesNotSendASecondNativeAction() {
        let element = AXUIElementCreateApplication(404)
        var actions: [String] = []
        let delivered = MenuBarAX.pressShortcutElement(element) { _, action in
            actions.append(action as String)
            return .cannotComplete
        }
        #expect(delivered)
        #expect(actions == [kAXPressAction as String])
    }

    @Test func unsupportedPressUsesShowMenuOnTheSameElement() {
        let element = AXUIElementCreateApplication(404)
        var actions: [String] = []
        let delivered = MenuBarAX.pressShortcutElement(element) { _, action in
            actions.append(action as String)
            return actions.count == 1 ? .actionUnsupported : .success
        }
        #expect(delivered)
        #expect(actions == [kAXPressAction as String, kAXShowMenuAction as String])
    }

    private func target(_ selector: MenuBarItemShortcutTarget.Selector = .identifier("status")) throws -> MenuBarItemShortcutTarget {
        try #require(MenuBarItemShortcutTarget(bundleID: "com.example.fixture", selector: selector))
    }
    private func element(_ identifier: String?, protected: Bool = false, accepts: Bool = true) -> MenuBarItemShortcutNative.Element {
        .init(identifier: identifier, protected: protected, press: { accepts })
    }
    private func native(_ elements: [MenuBarItemShortcutNative.Element], owners: [Int32] = [404], complete: Bool = true) -> MenuBarItemShortcutNative {
        .init(processes: { _ in owners }, enumerate: { _ in .init(elements: elements, complete: complete) })
    }

    @Test func freshEnumerationRefusesVanishedIdentifiersAndSiblings() throws {
        let selection = try target()
        #expect(native([element("sibling")]).open(selection) == .missing)
        #expect(native([element("status"), element("status")]).open(selection) == .ambiguous)
        #expect(native([element("sibling"), element("status")]).open(selection) == .ready)
        #expect(native([element("status")], owners: []).open(selection) == .missing)
        #expect(native([element("status")], owners: [1, 2]).open(selection) == .ambiguous)
        #expect(native([element("status")], complete: false).open(selection) == .refused)
    }

    @Test func soleItemNeverUsesFirstOrTitleAndProtectedControlsCannotPress() throws {
        let sole = try target(.soleItem)
        #expect(native([element(nil)]).open(sole) == .ready)
        #expect(native([element(nil), element("sibling")]).open(sole) == .ambiguous)
        #expect(native([element(nil, protected: true)]).open(sole) == .invalid)
        let selection = try target()
        #expect(native([element("status", protected: true)]).open(selection) == .invalid)
        #expect(native([element("status", accepts: false)]).open(selection) == .refused)
    }

    @Test func eachPressResolvesProcessesAgainAfterRelaunch() throws {
        final class Fixture: @unchecked Sendable {
            var pid: Int32 = 11
            var enumerated: [Int32] = []
            var presses = 0
        }
        let fixture = Fixture()
        let client = MenuBarItemShortcutNative(processes: { _ in [fixture.pid] }, enumerate: { pid in
            fixture.enumerated.append(pid)
            return .init(elements: [.init(identifier: "status", protected: false,
                                           press: { fixture.presses += 1; return true })], complete: true)
        })
        let selection = try target()
        #expect(client.open(selection) == .ready)
        fixture.pid = 99
        #expect(client.open(selection) == .ready)
        #expect(fixture.enumerated == [11, 99])
        #expect(fixture.presses == 2)
    }

    @Test func ambiguousAndRefusedPathsHaveNoActivationFallback() throws {
        final class Fixture: @unchecked Sendable { var presses = 0 }
        let fixture = Fixture()
        let element = MenuBarItemShortcutNative.Element(identifier: "status", protected: false,
                                                       press: { fixture.presses += 1; return false })
        let selection = try target()
        #expect(native([element, element]).open(selection) == .ambiguous)
        #expect(fixture.presses == 0)
        #expect(native([element]).open(selection) == .refused)
        #expect(fixture.presses == 1)
    }

    @Test func retiredLeaseStopsQueuedEnumerationAndPress() throws {
        final class Fixture: @unchecked Sendable {
            var enumerations = 0
            var presses = 0
        }
        let fixture = Fixture()
        let lease = MenuBarItemShortcutLease()
        let client = MenuBarItemShortcutNative(processes: { _ in [404] }, enumerate: { _ in
            fixture.enumerations += 1
            lease.cancel()
            return .init(elements: [.init(identifier: "status", protected: false,
                                           press: { fixture.presses += 1; return true })], complete: true)
        })
        let selection = try target()
        #expect(client.open(selection, lease: lease) == .utilityOff)
        #expect(fixture.enumerations == 1)
        #expect(fixture.presses == 0)
        #expect(client.open(selection, lease: lease) == .utilityOff)
        #expect(fixture.enumerations == 1)
        #expect(fixture.presses == 0)
    }


    @Test func admittedPressCanFinishWithoutHoldingTheLeaseLock() throws {
        let lease = MenuBarItemShortcutLease()
        // Cancellation prevents admission. An admitted AX call can finish;
        // cancellation must never wait for that call's native IPC.
        let entry = MenuBarItemShortcutNative.Element(identifier: "status", protected: false, press: {
            lease.cancel()
            return true
        })
        #expect(native([entry]).open(try target(), lease: lease) == .ready)
        #expect(!lease.isValid)
    }


    @Test func ownerChangesDuringEnumerationCannotPressTheOldProcess() throws {
        final class Fixture: @unchecked Sendable {
            var owners: [Int32] = [404]
            var presses = 0
        }
        let changes: [[Int32]] = [[], [505], [404, 505]]
        for changedOwners in changes {
            let fixture = Fixture()
            let client = MenuBarItemShortcutNative(processes: { _ in fixture.owners }, enumerate: { _ in
                fixture.owners = changedOwners
                return .init(elements: [.init(identifier: "status", protected: false,
                                               press: { fixture.presses += 1; return true })], complete: true)
            })
            let result = client.open(try target())
            #expect(result == (changedOwners.count > 1 ? .ambiguous : .missing))
            #expect(fixture.presses == 0)
        }
    }


    private func axEntry(_ identifierRead: MenuBarAX.AttributeRead) throws -> MenuBarAX.ExtrasElement {
        var position = CGPoint(x: 100, y: 0)
        var size = CGSize(width: 24, height: 24)
        let point = try #require(AXValueCreate(.cgPoint, &position))
        let dimensions = try #require(AXValueCreate(.cgSize, &size))
        let reads: [MenuBarAX.AttributeRead] = [
            .init(value: "AXMenuBarItem" as CFString, error: .success),
            .init(value: point, error: .success),
            .init(value: dimensions, error: .success),
            .init(value: "Fixture" as CFString, error: .success),
            identifierRead
        ]
        return MenuBarAX.extrasElement(AXUIElementCreateApplication(404), reads: reads)
    }

    private final class PressCount: @unchecked Sendable { var value = 0 }

    private func axClient(_ entries: [MenuBarAX.ExtrasElement], presses: PressCount)
        -> MenuBarItemShortcutNative {
        var status = MenuBarAX.InventoryStatus()
        for entry in entries { status.include(entry.status) }
        let inventory = MenuBarAX.shortcutInventory(elements: entries, status: status) { _, _ in
            presses.value += 1
            return .success
        }
        return .init(processes: { _ in [404] }, enumerate: { _ in inventory })
    }

    @Test func failedSiblingIdentifierReadCannotMakeADuplicateLookUnique() throws {
        let matching = try axEntry(.init(value: "status" as CFString, error: .success))
        let selection = try target()
        let errors: [AXError] = [.cannotComplete, .failure, .apiDisabled]
        for error in errors {
            let sibling = try axEntry(.init(value: nil, error: error))
            #expect(!sibling.status.incomplete, "Identifier failure must not change layout completeness")
            #expect(!sibling.identifierComplete)
            let presses = PressCount()
            #expect(axClient([matching, sibling], presses: presses).open(selection) == .refused)
            #expect(presses.value == 0)
        }
    }

    @Test func validIdentifierAbsenceDoesNotBlockAnotherUniqueItem() throws {
        let matching = try axEntry(.init(value: "status" as CFString, error: .success))
        let selection = try target()
        let absentReads: [MenuBarAX.AttributeRead] = [
            .init(value: nil, error: .attributeUnsupported),
            .init(value: nil, error: .noValue),
            .init(value: "" as CFString, error: .success)
        ]
        for read in absentReads {
            let sibling = try axEntry(read)
            #expect(sibling.identifier == nil)
            #expect(sibling.identifierComplete)
            let presses = PressCount()
            #expect(axClient([matching, sibling], presses: presses).open(selection) == .ready)
            #expect(presses.value == 1)
        }
    }

    @Test func malformedSuccessfulIdentifierReadRefusesIdentifierTargeting() throws {
        let matching = try axEntry(.init(value: "status" as CFString, error: .success))
        let selection = try target()
        let malformedReads: [MenuBarAX.AttributeRead] = [
            .init(value: NSNumber(value: 42), error: .success),
            .init(value: nil, error: .success)
        ]
        for read in malformedReads {
            let sibling = try axEntry(read)
            #expect(!sibling.identifierComplete)
            let presses = PressCount()
            #expect(axClient([matching, sibling], presses: presses).open(selection) == .refused)
            #expect(presses.value == 0)
        }
    }

    @Test func soleItemUsesCompleteItemCountDespiteAnIrrelevantIdentifierFailure() throws {
        let unidentifiable = try axEntry(.init(value: nil, error: .cannotComplete))
        let selection = try target(.soleItem)
        let presses = PressCount()
        #expect(axClient([unidentifiable], presses: presses).open(selection) == .ready)
        #expect(presses.value == 1)
        #expect(axClient([unidentifiable, unidentifiable], presses: presses).open(selection) == .ambiguous)
        #expect(presses.value == 1)
    }

}
