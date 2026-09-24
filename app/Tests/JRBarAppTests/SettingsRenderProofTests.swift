import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// Render proof for the Settings window: every page, and the Utilities
/// and Toys pages with each card open, in light and dark, so a human can
/// eyeball the grouped forms, the card shells and the atoms they are
/// built from. Off by default; set `JRBAR_RENDER_PROOF=1` to write
/// `settings-*.png` into `JRBAR_RENDER_PROOF_DIR` (default
/// `/tmp/jrbar-settings-proof`). The document is the mock monitor's
/// defaults (`app/scripts/mock-core.py`), or the JSON file named by
/// `JRBAR_RENDER_PROOF_SETTINGS`.
@Suite("Settings render proof")
@MainActor
struct SettingsRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    /// The detail pane's width at the window's default size.
    static let paneWidth: CGFloat = 560

    private static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_DIR"]
            ?? "/tmp/jrbar-settings-proof", isDirectory: true)
    }

    /// The mock monitor's settings document, read through its own script
    /// so the proof never drifts from what `mock-core.py` serves.
    private static func document() throws -> JSONValue {
        let env = ProcessInfo.processInfo.environment
        let data: Data
        if let path = env["JRBAR_RENDER_PROOF_SETTINGS"] {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            let script = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "scripts/mock-core.py")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-c", """
                import importlib.util, json, sys
                spec = importlib.util.spec_from_file_location("mock_core", sys.argv[1])
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                print(json.dumps(module.default_settings_document()))
                """, script.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// A Settings store over the mock document, with its toys and
    /// utilities built the way the delegate builds them but never started.
    private struct Fixture {
        let core: CoreModel
        let settings: SettingsStore
        let toys: ToysStore
        let utilities: UtilitiesStore
    }

    private static func fixture() throws -> Fixture {
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-render-proof.sock")
        core.apply(.settings(CoreSettings(generation: 1, schema: CoreProtocol.knownSettingsSchema,
                                          document: try document())))
        let settings = SettingsStore(core: core)
        let toys = ToysStore(core: core, settings: settings, state: ToysState(),
                             cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        settings.toys = toys
        let utilities = UtilitiesStore(core: core, settings: settings, state: UtilitiesState())
        settings.utilities = utilities
        return Fixture(core: core, settings: settings, toys: toys, utilities: utilities)
    }

    /// Every card id on the Utilities and Toys pages.
    private static func cardIDs(_ fixture: Fixture) -> [String] {
        var ids = [fixture.utilities.menuBar.id, fixture.utilities.dock.id,
                   fixture.utilities.agents.id, fixture.utilities.dataHoarder.id]
        if let notch = fixture.toys.notch { ids.append(notch.id) }
        ids += fixture.toys.toys.map(\.id)
        return ids
    }

    // MARK: Rendering

    /// Draws `view` in an offscreen window at `size` under the given
    /// appearance and returns its layer tree as a bitmap — AppKit-backed
    /// controls included, which `ImageRenderer` cannot draw.
    private static func snapshot<V: View>(_ view: V, size: CGSize, dark: Bool) throws -> NSBitmapImageRep {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let scale: CGFloat = 2
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance?.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        NSGraphicsContext.restoreGraphicsState()
        window.contentView = nil
        window.close()
        return rep
    }

    /// Crops a snapshot's empty tail: rows at the bottom that match the
    /// last row's colour everywhere.
    private static func cropped(_ rep: NSBitmapImageRep, margin: Int = 24) -> CGImage? {
        guard let image = rep.cgImage else { return nil }
        let width = image.width, height = image.height
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return image }
        let row = image.bytesPerRow, pixel = image.bitsPerPixel / 8
        func color(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let offset = y * row + x * pixel
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
        }
        let background = color(width / 2, height - 1)
        var last = height - 1
        scan: while last > 0 {
            for x in stride(from: 0, to: width, by: 3) {
                let c = color(x, last)
                if abs(c.0 - background.0) + abs(c.1 - background.1) + abs(c.2 - background.2) > 12 { break scan }
            }
            last -= 1
        }
        let keep = min(height, last + margin * 2)
        return image.cropping(to: CGRect(x: 0, y: 0, width: width, height: keep))
    }

    /// `JRBAR_RENDER_PROOF_ONLY=notch` keeps a run to the shots whose
    /// name holds that word.
    private static func wanted(_ name: String) -> Bool {
        guard let only = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF_ONLY"] else { return true }
        return name.contains(only)
    }

    private static func write(_ rep: NSBitmapImageRep, named name: String) throws {
        let image = try #require(cropped(rep))
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: Proofs

    /// Every page, cards closed, in both appearances.
    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the Settings PNGs"))
    func pages() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        for page in SettingsStore.Page.allCases {
            for dark in [false, true] where Self.wanted("settings-\(page.rawValue)") {
                fixture.settings.page = page
                let view = SettingsPageContainer(store: fixture.settings, page: page)
                let rep = try Self.snapshot(view, size: CGSize(width: Self.paneWidth, height: 6000), dark: dark)
                try Self.write(rep, named: "settings-\(page.rawValue)-\(dark ? "dark" : "light")")
            }
        }
        withExtendedLifetime(fixture) {}
    }

    /// Each Utilities and Toys card open on its own page, in both
    /// appearances.
    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the card PNGs"))
    func cards() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        for card in Self.cardIDs(fixture) {
            fixture.settings.expandedCards = [card]
            let page: SettingsStore.Page = fixture.toys.toys.contains { $0.id == card } ? .toys : .utilities
            for dark in [false, true] where Self.wanted("card-\(card)") {
                let view = SettingsPageContainer(store: fixture.settings, page: page)
                let rep = try Self.snapshot(view, size: CGSize(width: Self.paneWidth, height: 6000), dark: dark)
                try Self.write(rep, named: "card-\(card)-\(dark ? "dark" : "light")")
            }
        }
        withExtendedLifetime(fixture) {}
    }

    /// The whole window — sidebar, toolbar-less split and the Toys page.
    @Test(.enabled(if: Self.enabled, "set JRBAR_RENDER_PROOF=1 to write the window PNGs"))
    func window() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fixture = try Self.fixture()
        for page in [SettingsStore.Page.utilities, .toys, .general] {
            fixture.settings.page = page
            for dark in [false, true] where Self.wanted("window-\(page.rawValue)") {
                let view = SettingsRootView(store: fixture.settings)
                let rep = try Self.snapshot(view, size: CGSize(width: 780, height: 620), dark: dark)
                try Self.write(rep, named: "window-\(page.rawValue)-\(dark ? "dark" : "light")")
            }
        }
        withExtendedLifetime(fixture) {}
    }
}
