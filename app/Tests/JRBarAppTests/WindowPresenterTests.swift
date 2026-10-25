import AppKit
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Test window safety")
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

    @Test("native window presentation stays inside the guarded presenter")
    func noBypasses() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let forbidden = #"\b(orderFrontRegardless|makeKeyAndOrderFront|orderFront|orderBack|orderWindow|setIsVisible|runModal|beginSheet|beginSheetModal|beginModalSession|showWindow)\s*\("#
        let pattern = try NSRegularExpression(pattern: forbidden)
        let swiftUIPresentation = try NSRegularExpression(
            pattern: #"\.(sheet|alert|confirmationDialog|popover|fileImporter|fileExporter)\([\s\S]{0,400}?\b(?:isPresented|item):\s*(\w+)"#)
        var offenders: [String] = []
        for directory in ["Sources", "Tests"] {
            let walker = FileManager.default.enumerator(at: app.appending(path: directory), includingPropertiesForKeys: nil)
            while let file = walker?.nextObject() as? URL {
                guard file.pathExtension == "swift", file.lastPathComponent != "WindowPresenter.swift",
                      file.lastPathComponent != "WindowPresenterTests.swift" else { continue }
                let source = try String(contentsOf: file, encoding: .utf8)
                for match in swiftUIPresentation.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                    let binding = (source as NSString).substring(with: match.range(at: 2))
                    if binding != "WindowPresenter" { offenders.append("\(file.lastPathComponent): unguarded SwiftUI presentation") }
                }
                for (offset, line) in source.components(separatedBy: "\n").enumerated() {
                    let code = line.components(separatedBy: "//")[0]
                        .replacingOccurrences(of: "override func orderFrontRegardless()", with: "")
                        .replacingOccurrences(of: "WindowPresenter.automatic.runModal(", with: "guardedModal(")
                        .replacingOccurrences(of: "WindowPresenter.automatic.perform { super.orderFrontRegardless() }", with: "")
                    if pattern.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                        offenders.append("\(file.lastPathComponent):\(offset + 1)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "Route presentation through WindowPresenter: \(offenders)")
    }
}
