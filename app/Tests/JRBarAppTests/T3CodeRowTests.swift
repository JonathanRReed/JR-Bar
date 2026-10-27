import AppKit
import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

@Suite struct T3CodeRowTests {
    @Test("automatic detection ignores the legacy switch")
    func automaticDetection() throws {
        for enabled in [false, true] {
            let json = try JSONDecoder().decode(JSONValue.self, from: Data(
                "{\"present\":true,\"enabled\":\(enabled),\"running\":true}".utf8))
            let status = try #require(T3CodeStatus.parse(json))
            #expect(status.line == "Running")
            #expect(status.isSettling)
            var stopped = status
            stopped.running = false
            #expect(stopped.line == "Not running")
            #expect(!stopped.isSettling)
        }
        #expect(T3CodeStatus.parse(nil) == nil)
    }
}

@Suite("T3 installation visibility")
struct T3CodeInstallationTests {
    @Test("installation status distinguishes an absent app from a stopped install")
    func installationStatus() throws {
        for (document, installed) in [
            (#"{"present":false,"enabled":false,"running":false,"installed":false}"#, false),
            (#"{"present":false,"enabled":false,"running":false,"installed":true}"#, true),
            (#"{"present":true,"enabled":false,"running":false}"#, true),
            (#"{"present":false,"enabled":false,"running":true}"#, true),
            (#"{"present":false,"enabled":false}"#, false),
        ] {
            let json = try JSONDecoder().decode(JSONValue.self, from: Data(document.utf8))
            let status = try #require(T3CodeStatus.parse(json))
            #expect(status.installed == installed)
        }
    }
}

@Suite("T3 row render proof")
@MainActor
struct T3CodeRowRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"))
    func installationStates() throws {
        let cases = [
            ("absent", false, false),
            ("stopped", true, false),
            ("running", true, true),
        ]
        for dark in [false, true] {
            var heights: [String: Int] = [:]
            for (name, installed, running) in cases {
                let status = T3CodeStatus(present: installed, enabled: false, readOnly: false,
                                          running: running, installed: installed)
                let content = VStack(alignment: .leading, spacing: 12) {
                    Text("Providers").font(.headline)
                    T3CodeRow(status: status)
                }
                .padding(16)
                .frame(width: 360, alignment: .leading)
                .background(dark ? Color.black : Color.white)
                .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                let bitmap = try #require(renderer.cgImage)
                heights[name] = bitmap.height
                let png = try #require(NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:]))
                let directory = ProofRender.directory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let filename = "t3-row-\(name)-\(dark ? "dark" : "light").png"
                try png.write(to: directory.appendingPathComponent(filename))
            }
            let absentHeight = try #require(heights["absent"])
            let stoppedHeight = try #require(heights["stopped"])
            #expect(absentHeight < stoppedHeight)
            #expect(heights["stopped"] == heights["running"])
        }
    }
}
