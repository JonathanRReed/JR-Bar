import AppKit
import Foundation
import Testing
import os
import JRBarTestSupport
@testable import JRBarApp

@MainActor
@Suite("Menu bar display names", .temporaryDirectory)
struct MenuBarAppNamesTests {
    @Test func savedPicksResolveOffMainAndCacheTheResult() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let names = MenuBarAppNames()
        names.lookup = { _ in
            calls.withLock { $0 += 1 }
            return Thread.isMainThread ? "Wrong thread" : "Sample Writer"
        }
        #expect(names.name(for: "test.sample-writer") == "Sample Writer")
        #expect(await names.resolvedName(for: "test.sample-writer") == "Sample Writer")
        #expect(await names.resolvedName(for: "test.sample-writer") == "Sample Writer")
        #expect(names.name(for: "test.sample-writer") == "Sample Writer")
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func identifiersSlugsAndProcessNamesNeverBecomeLabels() {
        for (raw, expected) in [
            ("test.vendor.sample-writer", "Sample Writer"),
            ("sample-writer", "Sample Writer"),
            ("SampleWriter", "Sample Writer"),
            ("test.sample.app", "Sample"),
            ("/synthetic/Sample Writer.app", "Sample Writer"),
        ] {
            #expect(MenuBarAppNames.cleaned(raw) == expected)
            let item = MenuBarItem(id: raw, ownerPID: 123, ownerName: raw,
                                   bounds: .zero, title: nil, windowID: 0)
            #expect(item.displayName == (raw == "SampleWriter" ? "SampleWriter" : expected))
            #expect(!item.displayName.contains("test.") && !item.displayName.contains("sample-writer"))
        }
        #expect(MenuBarAppNames.lookupName("/synthetic/Missing Writer.app") == "Missing Writer (not installed)")
        #expect(MenuBarPositionCopy.suggestionLine(name: "Sample Flow (not installed)", state: .absent)
                == "Sample Flow (not installed)")
        for name in ["iStat Menus", "zoom.us", "1Password", "SampleWriter"] {
            #expect(MenuBarAppNames.displayName(name) == name)
        }
    }

    @Test func savedPathsReadTheInstalledDisplayName() async throws {
        let app = TestTemporaryDirectory.currentURL.appendingPathComponent("sample-writer.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.sample-writer", "CFBundleName": "sample-writer",
                    "CFBundleDisplayName": "Sample Writer", "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let names = MenuBarAppNames()
        #expect(await names.resolvedName(for: app.path) == "Sample Writer")
    }
}
