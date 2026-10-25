import AppKit
import SwiftUI

/// Tests lay out and render views without ordering windows or taking focus.
@MainActor
struct WindowPresenter {
    enum Order { case front, regardless, key }
    enum Refusal: Error { case desktopPresentationInTests }

    private let present: (NSWindow, Order) -> Void
    private let desktop: Bool

    init(present: @escaping (NSWindow, Order) -> Void) {
        self.present = present
        self.desktop = false
    }

    private init(desktop: Bool) {
        self.desktop = desktop
        self.present = { window, order in
            switch order {
            case .front: window.orderFront(nil)
            case .regardless: window.orderFrontRegardless()
            case .key: window.makeKeyAndOrderFront(nil)
            }
        }
    }

    nonisolated static var isTestProcess: Bool {
        let process = ProcessInfo.processInfo
        return detectsTests(environment: process.environment, arguments: process.arguments)
            || NSClassFromString("XCTestCase") != nil
            || Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
    }

    nonisolated static func detectsTests(environment: [String: String], arguments: [String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["SWIFT_TESTING_ENABLED"] != nil
            || arguments.contains { $0.contains(".xctest") || $0.contains("swiftpm-testing-helper")
                || $0 == "--testing-library" }
    }

    nonisolated static var suppressesDesktop: Bool {
        isTestProcess && ProcessInfo.processInfo.environment["JRBAR_INTERACTIVE_TESTS"] != "1"
    }

    static var automatic: Self { suppressesDesktop ? .suppressed : .live }
    static var suppressed: Self { Self(present: { _, _ in }) }
    static var live: Self { Self(desktop: true) }

    func validateDesktop() throws {
        if Self.suppressesDesktop { throw Refusal.desktopPresentationInTests }
    }

    private func requireDesktop() {
        do { try validateDesktop() }
        catch {
            preconditionFailure("Desktop presentation during tests. Use WindowPresenter.automatic or inject a presenter.")
        }
    }

    func order(_ window: NSWindow?, as order: Order = .regardless) {
        guard let window else { return }
        if desktop { requireDesktop() }
        present(window, order)
    }

    /// Activation, keyboard focus and superclass ordering share the same gate.
    func perform(_ action: () -> Void) {
        guard desktop else { return }
        requireDesktop()
        action()
    }

    func runModal(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        guard desktop else { return .cancel }
        requireDesktop()
        return panel.runModal()
    }

    func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        guard desktop else { return .abort }
        requireDesktop()
        return alert.runModal()
    }

    static func presentation(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { !suppressesDesktop && binding.wrappedValue },
                set: { binding.wrappedValue = $0 })
    }

    static func presentation<Value>(_ binding: Binding<Value?>) -> Binding<Value?> {
        Binding(get: { suppressesDesktop ? nil : binding.wrappedValue },
                set: { binding.wrappedValue = $0 })
    }
}
