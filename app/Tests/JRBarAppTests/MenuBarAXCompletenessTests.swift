import AppKit
import ApplicationServices
import Testing
@testable import JRBarApp

@Suite("Menu Bar AX completeness")
struct MenuBarAXCompletenessTests {
    private func itemReads() throws -> [MenuBarAX.AttributeRead] {
        var position = CGPoint(x: 100, y: 0)
        var size = CGSize(width: 24, height: 24)
        let point = try #require(AXValueCreate(.cgPoint, &position))
        let dimensions = try #require(AXValueCreate(.cgSize, &size))
        return [
            .init(value: "AXMenuBarItem" as CFString, error: .success),
            .init(value: point, error: .success),
            .init(value: dimensions, error: .success),
            .init(value: nil, error: .noValue),
            .init(value: nil, error: .attributeUnsupported),
        ]
    }

    @Test("required read failures mark an owner incomplete and preserve timeouts",
          arguments: [0, 1, 2])
    func requiredFailures(index: Int) throws {
        var reads = try itemReads()
        reads[index] = .init(value: nil, error: .cannotComplete)
        let status = MenuBarAX.elementStatus(reads)
        #expect(status.incomplete && status.timedOut)
        reads[index] = .init(value: nil, error: .noValue)
        let missing = MenuBarAX.elementStatus(reads)
        #expect(missing.incomplete && !missing.timedOut)
    }

    @Test("batch AXError entries propagate like fallback copy failures")
    func batchErrors() throws {
        var error = AXError.cannotComplete
        let value = try #require(AXValueCreate(.axError, &error))
        let decoded = MenuBarAX.batchAttribute(value)
        #expect(decoded.error == .cannotComplete && decoded.value == nil)
        var reads = try itemReads()
        reads[2] = decoded
        #expect(MenuBarAX.elementStatus(reads).incomplete)
        #expect(MenuBarAX.elementStatus(reads).timedOut)
    }

    @Test("missing optional labels and identifiers do not invalidate item geometry")
    func optionalReads() throws {
        var reads = try itemReads()
        #expect(!MenuBarAX.elementStatus(reads).incomplete)
        reads[3] = .init(value: nil, error: .cannotComplete)
        reads[4] = .init(value: nil, error: .cannotComplete)
        let status = MenuBarAX.elementStatus(reads)
        #expect(!status.incomplete && !status.timedOut)
    }

    @Test("invalid geometry types are incomplete rather than successful zero frames")
    func malformedGeometry() throws {
        var reads = try itemReads()
        reads[1] = .init(value: NSNumber(value: 1), error: .success)
        #expect(MenuBarAX.elementStatus(reads).incomplete)
        reads = try itemReads()
        reads[2] = reads[1]
        #expect(MenuBarAX.elementStatus(reads).incomplete)
    }

    @Test("group geometry is optional but group children must answer completely")
    func groupedChildren() throws {
        var reads = try itemReads()
        reads[0] = .init(value: "AXGroup" as CFString, error: .success)
        reads[1] = .init(value: nil, error: .attributeUnsupported)
        reads[2] = .init(value: nil, error: .attributeUnsupported)
        #expect(!MenuBarAX.elementStatus(reads).incomplete)
        let timedOut = MenuBarAX.childrenStatus(error: .cannotComplete, hasChildren: false)
        #expect(timedOut.incomplete && timedOut.timedOut)
        #expect(MenuBarAX.childrenStatus(error: .success, hasChildren: false).incomplete)
        #expect(!MenuBarAX.childrenStatus(error: .success, hasChildren: true).incomplete)
        var aggregate = MenuBarAX.InventoryStatus()
        aggregate.include(timedOut)
        aggregate.include(MenuBarAX.InventoryStatus())
        #expect(aggregate.incomplete && aggregate.timedOut)
    }

    @Test("an unsupported extras bar is a complete empty owner while a timeout is incomplete")
    func absentExtras() {
        for error in [AXError.attributeUnsupported, .noValue] {
            let status = MenuBarAX.extrasStatus(.init(value: nil, error: error))
            #expect(!status.incomplete && !status.timedOut)
        }
        let timedOut = MenuBarAX.extrasStatus(.init(value: nil, error: .cannotComplete))
        #expect(timedOut.incomplete && timedOut.timedOut)
        #expect(MenuBarAX.extrasStatus(.init(value: nil, error: .success)).incomplete)
    }

    @Test("ignored grouped buttons do not require geometry that the inventory never uses")
    func ignoredGroupedButtonGeometry() throws {
        var reads = try itemReads()
        reads[0] = .init(value: "AXButton" as CFString, error: .success)
        reads[1] = .init(value: nil, error: .noValue)
        #expect(MenuBarAX.elementStatus(reads).incomplete)
        #expect(!MenuBarAX.elementStatus(reads, includeButtons: false).incomplete)
        reads[0] = .init(value: nil, error: .cannotComplete)
        #expect(MenuBarAX.elementStatus(reads, includeButtons: false).incomplete)
    }
}
