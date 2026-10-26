import AppKit
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Test window safety", .timeLimit(.minutes(2)))
struct WindowPresenterTests {
    @Test("Swift Testing is detected without an environment flag")
    func detectsRunner() {
        #expect(WindowPresenter.isTestProcess)
        #expect(WindowPresenter.detectsTests(environment: [:], arguments: ["/tmp/Tests.xctest/Contents/MacOS/Tests"]))
        #expect(WindowPresenter.detectsTests(environment: [:], arguments: ["swiftpm-testing-helper"]))
        #expect(WindowPresenter.detectsTests(environment: ["XCTestConfigurationFilePath": "fixture"], arguments: []))
        #expect(!WindowPresenter.detectsTests(environment: [:], arguments: ["JR-Bar"]))
    }

    @Test("automatic presentation never orders a window or runs desktop actions")
    func suppressesOrdering() throws {
        guard ProcessInfo.processInfo.environment["JRBAR_INTERACTIVE_TESTS"] != "1" else { return }
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.borderless], backing: .buffered, defer: true)
        for order in [WindowPresenter.Order.front, .regardless, .key] {
            WindowPresenter.automatic.order(window, as: order)
            #expect(!window.isVisible && !window.isKeyWindow)
        }
        var activated = false
        WindowPresenter.automatic.perform { activated = true }
        #expect(!activated)
        #expect(WindowPresenter.automatic.runModal(NSAlert()) == .abort)
        #expect(WindowPresenter.automatic.runModal(NSSavePanel()) == .cancel)
        #expect(throws: WindowPresenter.Refusal.self) { try WindowPresenter.live.validateDesktop() }
    }

    @Test("key render proofs require their explicit opt-in")
    func keyProofRequiresOptIn() {
        guard ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] != "1" else { return }
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        #expect(throws: WindowPresenter.Refusal.self) { try WindowPresenter.renderProofKey(window) }
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test("key render proofs refuse a visible desktop frame")
    func keyProofCannotAppearOnScreen() {
        let window = NSWindow(contentRect: NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        #expect(throws: WindowPresenter.Refusal.self) { try WindowPresenter.renderProofKey(window) }
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test("motion accepts an injected presenter without ordering its panel")
    func injectedPresenter() {
        let panel = NSPanel()
        var orders = 0
        let presenter = WindowPresenter { window, _ in
            #expect(window === panel)
            orders += 1
        }
        NotchSurfaceMotion.present(panel, duration: 0, reducedDuration: 0, presenter: presenter)
        #expect(orders == 1)
        #expect(!panel.isVisible)
    }

    @Test("Screen Bar show keeps every app window hidden")
    func screenBarCannotReachDesktop() {
        guard WindowPresenter.suppressesDesktop else { return }
        let controller = ScreenBarController(reduceMotionOverride: false)
        defer { controller.hide() }
        controller.show()
        controller.apply(programText: "#ff0000 1s linear")
        #expect(NSApplication.shared.windows.allSatisfy { !$0.isVisible })
    }

    @Test("SwiftUI presentation bindings keep model intent without opening a sheet")
    func sheetsStayHidden() {
        guard WindowPresenter.suppressesDesktop else { return }
        var wanted = true
        let binding = Binding(get: { wanted }, set: { wanted = $0 })
        let gated = WindowPresenter.presentation(binding)
        #expect(!gated.wrappedValue)
        #expect(wanted)
        gated.wrappedValue = false
        #expect(!wanted)
        let item = Binding<String?>(get: { "fixture" }, set: { _ in })
        #expect(WindowPresenter.presentation(item).wrappedValue == nil)
    }

    @Test("the source guard rejects projected and dotted presentation bindings", arguments: [
        ".sheet(isPresented: $x) {}",
        ".popover(isPresented: $open, arrowEdge: .top) {}",
        ".sheet(item: $store.sheet) { _ in }",
        ".inspector(isPresented: $open) {}",
        ".alert(\"" + String(repeating: "Long title ", count: 60) + "\", isPresented: $open) {}",
        ".sheet(isPresented: WindowPresenter.other($x)) {}",
    ])
    func rejectsPresentationBypasses(source: String) throws {
        #expect(try !presentationViolations(in: source).isEmpty)
    }

    @Test("the source guard accepts only wrapped presentation bindings", arguments: [
        ".sheet(isPresented: WindowPresenter.presentation($x)) {}",
        ".sheet(item: WindowPresenter.presentation($store.sheet)) { _ in }",
        ".inspector(isPresented: WindowPresenter.presentation($open)) {}",
        ".alert(\"" + String(repeating: "Long title ", count: 60) + "\", isPresented: WindowPresenter.presentation($open)) {}",
    ])
    func acceptsWrappedPresentation(source: String) throws {
        #expect(try presentationViolations(in: source).isEmpty)
    }

    @Test("the source guard rejects desktop effects", arguments: [
        "NSApp.activate()", "NSRunningApplication.current.activate()", "window.makeKey()",
        "menu.popUp(positioning: nil, at: .zero, in: nil)", "panel.addChildWindow(child, ordered: .above)",
        "button.performClick(nil)", "window.deminiaturize(nil)", "NSApp.hide(nil)", "NSApp.unhide(nil)",
        "NSStatusBar.system.statusItem(withLength: 24)", "NSWorkspace.shared.open(url)",
        "NSWorkspace.shared.openApplication(at: url, configuration: config)",
    ])
    func rejectsDesktopBypasses(source: String) throws {
        #expect(try !presentationViolations(in: source).isEmpty)
        #expect(try presentationViolations(in: "WindowPresenter.automatic.perform { " + source + " }").isEmpty)
    }

    @Test("desktop service defaults are inert in tests")
    func desktopServicesStaySuppressed() async throws {
        #expect(WindowPresenter.suppressesDesktop)
        let desktop = DesktopServices.automatic
        #expect(!desktop.open(URL(string: "https://example.test")!))
        #expect(try await desktop.openApplication(at: URL(fileURLWithPath: "/synthetic.app"),
                                                 configuration: NSWorkspace.OpenConfiguration()) == nil)
        let item = desktop.makeStatusItem(24)
        #expect(item.button == nil)
        desktop.removeStatusItem(item)
        var opened: [URL] = []
        let injected = DesktopServices(openURL: { opened.append($0); return true })
        let url = URL(string: "https://example.test")!
        #expect(injected.open(url))
        #expect(opened == [url])
    }

    @Test("unexpected suppression is logged only for a process without runner arguments")
    func suppressionDiagnostic() {
        #expect(WindowPresenter.shouldLogSuppression(suppressed: true, arguments: ["JR-Bar"]))
        #expect(!WindowPresenter.shouldLogSuppression(suppressed: false, arguments: ["JR-Bar"]))
        #expect(!WindowPresenter.shouldLogSuppression(suppressed: true, arguments: ["Tests.xctest"]))
        WindowPresenter.logSuppressionAtLaunch()
        WindowPresenter.logSuppressionAtLaunch()
    }

    @Test("native window presentation stays inside the guarded presenter")
    func noBypasses() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        for directory in ["Sources", "Tests"] {
            let walker = FileManager.default.enumerator(at: app.appending(path: directory), includingPropertiesForKeys: nil)
            while let file = walker?.nextObject() as? URL {
                guard file.pathExtension == "swift", file.lastPathComponent != "WindowPresenter.swift",
                      file.lastPathComponent != "WindowPresenterTests.swift",
                      file.lastPathComponent != "DesktopServices.swift" else { continue }
                let source = try String(contentsOf: file, encoding: .utf8)
                offenders += try presentationViolations(in: source).map { "\(file.lastPathComponent): \($0)" }
            }
        }
        #expect(offenders.isEmpty, "Route presentation through WindowPresenter: \(offenders)")
    }
}
