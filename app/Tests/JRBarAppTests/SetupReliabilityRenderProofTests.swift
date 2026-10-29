import AppKit
import JRBarTestSupport
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Setup reliability render proof", .renderProofAppearance)
struct SetupReliabilityRenderProofTests {
    init() throws {
        if ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1" { try U5Proof.pinDefaultAccent() }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func fullAccessAlertExplainsWhyWriteOnlyCannotShowEvents() throws {
        let directory = WindowsRenderProofTests.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let alert = PermissionRequest.fullAccessAlert(for: .calendar)
            #expect(alert.messageText == "Full Calendar access is needed")
            #expect(alert.informativeText.contains("Write-only access cannot show them."))
            #expect(alert.buttons.map(\.title) == ["Open Settings"])
            let window = alert.window
            let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
            window.appearance = appearance
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            alert.layout()
            let view = try #require(window.contentView)
            let text = Self.alertText(in: view).filter {
                $0.stringValue == alert.messageText || $0.stringValue == alert.informativeText
            }
            try #require(text.count == 2)
            let bounds = text.map { view.convert($0.bounds, from: $0) }
            let region = bounds.reduce(NSRect.null) { $0.union($1) }.insetBy(dx: -12, dy: -12)
            // AppKit's screen cache contains vibrancy masks. Its PDF export
            // proves the native copy/layout; foreground compositing needs a live check.
            let pdf = try #require(NSPDFImageRep(data: view.dataWithPDF(inside: region)))
            let size = pdf.size
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = size
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            appearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                let frame = NSRect(origin: .zero, size: size)
                frame.fill()
                #expect(pdf.draw(in: frame))
            }
            NSGraphicsContext.restoreGraphicsState()
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let name = "permission-full-access-copy-\(dark ? "dark" : "light").png"
            try png.write(to: directory.appendingPathComponent(name))
            #expect(!window.isVisible)
        }
    }

    private static func alertText(in view: NSView) -> [NSTextField] {
        if let text = view as? NSTextField { return [text] }
        return view.subviews.flatMap { alertText(in: $0) }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func restrictedAndWriteOnlyPermissionsNameTheirActions() async throws {
        var model = SetupModel()
        model.refreshPermissions = { [.calendar: .writeOnly, .reminders: .restricted, .camera: .denied] }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        await store.refreshPermissions()
        try WindowsRenderProofTests.write("setup-permission-full-access", size: CGSize(width: 680, height: 310)) {
            VStack(alignment: .leading, spacing: 16) {
                SetupPermissionRow(store: store, permission: .calendar)
                Divider()
                SetupPermissionRow(store: store, permission: .reminders)
                Divider()
                SetupPermissionRow(store: store, permission: .camera)
            }.padding(24)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled), .timeLimit(.minutes(2)))
    func aPermissionRequestDisablesOnlyItsRow() async throws {
        var resume: CheckedContinuation<Void, Never>?
        var model = SetupModel()
        model.refreshPermissions = { [.camera: .needed, .calendar: .denied] }
        model.act = { _ in await withCheckedContinuation { resume = $0 } }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        await store.refreshPermissions()
        let request = store.act(on: .camera)
        for _ in 0..<10_000 where resume == nil { await Task.yield() }
        let continuation = try #require(resume)
        let rendered = Result<Void, Error> {
            try WindowsRenderProofTests.write("setup-permission-waiting", size: CGSize(width: 680, height: 270)) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Permissions").font(.system(size: 24, weight: .semibold))
                    SetupPermissionRow(store: store, permission: .camera)
                    Divider()
                    SetupPermissionRow(store: store, permission: .calendar)
                }.padding(24)
            }
        }
        continuation.resume()
        await request.value
        try rendered.get()
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func offlineSetupKeepsItsLastHooksWithoutClaimingTheyAreLive() throws {
        var model = SetupModel()
        model.agents = { [SetupAgent(id: "claude", name: "Claude", detected: true, hookStatus: "ok")] }
        let store = SetupStore(model: model, load: { SetupState() }, persist: { _ in })
        try WindowsRenderProofTests.write("setup-monitor-offline", size: CGSize(width: 680, height: 390)) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Setup").font(.system(size: 24, weight: .semibold))
                SetupAgentRow(store: store, agent: store.agentRows[0])
                SetupDoneStep(store: store)
            }.padding(24)
        }
    }

    @Test(.enabled(if: WindowsRenderProofTests.enabled))
    func failedFinishShowsSaveFailureAndRetryButtons() async throws {
        let store = SetupStore(model: SetupModel(), load: { SetupState() }, persist: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        for _ in SetupStore.Step.allCases.dropLast() { store.goNext() }
        #expect(store.step == .done)
        #expect(!store.finish())
        #expect(store.persistenceFailure != nil)
        for dark in [false, true] {
            try await DesignFixBProof.write(SetupView(store: store), name: "setup-finish-save-failure", title: "Welcome to JR-Bar",
                                            size: SetupWindowController.contentSize, dark: dark)
        }
    }
}
