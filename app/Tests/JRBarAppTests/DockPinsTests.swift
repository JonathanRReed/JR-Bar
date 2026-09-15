import Foundation
import Testing
@testable import JRBarApp

/// The Apple-Dock seed reads `com.apple.dock persistent-apps` — the
/// real plist shape, exercised end to end: a serialized fixture goes
/// through `UserDefaults`-style arrays into `AppleDockPins.bundleIDs`.
/// Read-only is the contract; nothing here writes the suite.
@Suite struct DockPinsTests {

    /// A minimal `persistent-apps` the way `defaults read
    /// com.apple.dock persistent-apps` prints it: `file-tile`s with a
    /// `tile-data` carrying either `bundle-identifier` or a
    /// `file-data._CFURLString`, plus a directory tile and a spacer
    /// that must not parse.
    private func fixturePlist() throws -> [[String: Any]] {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <array>
            <dict>
                <key>GUID</key><integer>1</integer>
                <key>tile-type</key><string>file-tile</string>
                <key>tile-data</key>
                <dict>
                    <key>bundle-identifier</key><string>com.apple.finder</string>
                    <key>file-data</key>
                    <dict>
                        <key>_CFURLString</key><string>file:///System/Library/CoreServices/Finder.app/</string>
                        <key>_CFURLStringType</key><integer>15</integer>
                    </dict>
                </dict>
            </dict>
            <dict>
                <key>GUID</key><integer>2</integer>
                <key>tile-type</key><string>file-tile</string>
                <key>tile-data</key>
                <dict>
                    <key>bundle-identifier</key><string>com.apple.Safari</string>
                </dict>
            </dict>
            <dict>
                <key>GUID</key><integer>3</integer>
                <key>tile-type</key><string>directory-tile</string>
                <key>tile-data</key>
                <dict>
                    <key>file-data</key>
                    <dict>
                        <key>_CFURLString</key><string>file:///Users/j/Downloads/</string>
                    </dict>
                </dict>
            </dict>
            <dict>
                <key>GUID</key><integer>4</integer>
                <key>tile-type</key><string>spacer-tile</string>
                <key>tile-data</key><dict/>
            </dict>
            <dict>
                <key>GUID</key><integer>5</integer>
                <key>tile-type</key><string>file-tile</string>
                <key>tile-data</key>
                <dict>
                    <key>file-data</key>
                    <dict>
                        <key>_CFURLString</key><string>file:///Applications/OldSchool.app/</string>
                    </dict>
                </dict>
            </dict>
            <dict>
                <key>GUID</key><integer>6</integer>
                <key>tile-type</key><string>file-tile</string>
                <key>tile-data</key>
                <dict>
                    <key>bundle-identifier</key><string>com.apple.Safari</string>
                </dict>
            </dict>
        </array>
        </plist>
        """
        let object = try PropertyListSerialization.propertyList(
            from: Data(xml.utf8), options: [], format: nil)
        let entries = try #require(object as? [[String: Any]])
        return entries
    }

    @Test func bundleIdentifiersParseInDockOrder() throws {
        let entries = try fixturePlist()
        var resolved: [URL] = []
        let ids = AppleDockPins.bundleIDs(fromEntries: entries) { url in
            resolved.append(url)
            return url.lastPathComponent == "OldSchool.app" ? "com.example.oldschool" : nil
        }
        #expect(ids == [
            "com.apple.finder",
            "com.apple.Safari",
            "com.example.oldschool",
        ])
        #expect(resolved.count == 1, "only the bundle-id-less tile hits the resolver")
        #expect(resolved.first?.lastPathComponent == "OldSchool.app")
    }

    @Test func directoryAndSpacerTilesNeverSeed() throws {
        let entries = try fixturePlist()
        let seeds = AppleDockPins.seeds(fromEntries: entries)
        #expect(seeds.count == 4, "two bundle-id tiles, one file-URL tile, one dupe")
        #expect(!seeds.contains { seed in
            if case .fileURL(let url) = seed { return url.lastPathComponent == "Downloads" }
            return false
        })
    }

    @Test func aRepeatedPinSeedsOnce() throws {
        let entries = try fixturePlist()
        let ids = AppleDockPins.bundleIDs(fromEntries: entries) { _ in "dup.app" }
        #expect(ids.filter { $0 == "com.apple.Safari" }.count == 1)
    }

    @Test func malformedEntriesAreSkippedNotFatal() {
        let entries: [[String: Any]] = [
            ["tile-data": "garbage"],
            ["tile-data": ["file-data": ["_CFURLString": 42]]],
            ["tile-data": ["file-data": ["_CFURLString": "file:///tmp/NotAnApp.txt"]]],
            ["tile-data": ["bundle-identifier": ""]],
            ["tile-data": ["bundle-identifier": "com.real.app"]],
        ]
        #expect(AppleDockPins.bundleIDs(fromEntries: entries) == ["com.real.app"])
    }

    @Test func anUnreadableSuiteIsNilNotEmpty() {
        // A suite name that will never exist: the read must say
        // "couldn't read" (nil), not "the dock is empty".
        let missing = UserDefaults(suiteName: "com.jrbar.test.suite.\(UUID().uuidString)")
        #expect(AppleDockPins.persistentAppBundleIDs(defaults: missing) == nil)
    }
}
