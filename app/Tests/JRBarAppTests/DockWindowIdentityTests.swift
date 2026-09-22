import ApplicationServices
import Testing
@testable import JRBarApp

private let successfulDockWindowLookup: DockWindowIdentity.WindowIDFunction = { _, output in
    output.pointee = 4_242
    return .success
}

private let failedDockWindowLookup: DockWindowIdentity.WindowIDFunction = { _, output in
    output.pointee = 9_999
    return .cannotComplete
}

private let zeroDockWindowLookup: DockWindowIdentity.WindowIDFunction = { _, output in
    output.pointee = 0
    return .success
}

@MainActor
@Suite struct DockWindowIdentityTests {
    private let inertElement = AXUIElementCreateApplication(920_001)

    @Test("a successful native lookup returns its nonzero window ID")
    func successfulLookup() {
        #expect(DockWindowIdentity.windowID(
            of: inertElement,
            using: successfulDockWindowLookup
        ) == 4_242)
    }

    @Test("an AX error rejects the function's output")
    func errorResult() {
        #expect(DockWindowIdentity.windowID(
            of: inertElement,
            using: failedDockWindowLookup
        ) == nil)
    }

    @Test("a successful lookup with window zero is absent")
    func zeroResult() {
        #expect(DockWindowIdentity.windowID(
            of: inertElement,
            using: zeroDockWindowLookup
        ) == nil)
    }

    @Test("a missing runtime symbol is absent")
    func missingFunction() {
        #expect(DockWindowIdentity.windowID(
            of: inertElement,
            using: nil
        ) == nil)
    }
}
