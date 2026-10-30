import Foundation
import JRBarTestSupport
import Testing
@testable import JRBarCore

@Suite("Dock preview size migration", .temporaryDirectory)
struct DockPreviewSizeMigrationTests {
    @Test func oldSettings() throws {
        let cases: [(String, DockPreviewSize)] = [
            ("{}", .medium), (#"{"largePreviews":false}"#, .medium),
            (#"{"largePreviews":true}"#, .large), (#"{"largePreviews":null}"#, .medium),
            (#"{"largePreviews":"true"}"#, .medium), (#"{"previewSize":"unknown"}"#, .medium),
            (#"{"previewSize":4,"largePreviews":true}"#, .large),
            (#"{"previewSize":"small","largePreviews":true}"#, .small),
            (#"{"previewSize":"medium","largePreviews":true}"#, .medium),
        ]
        for (json, expected) in cases {
            let decoded = try JSONDecoder().decode(DockEnhanceSettings.self, from: Data(json.utf8))
            #expect(decoded.previewSize == expected)
        }
    }

    @Test(arguments: DockPreviewSize.allCases)
    func newSettingsRoundTrip(_ size: DockPreviewSize) throws {
        let settings = DockEnhanceSettings(previewSize: size)
        let encoded = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["previewSize"] as? String == size.rawValue)
        #expect(object["largePreviews"] == nil)
        #expect(try JSONDecoder().decode(DockEnhanceSettings.self, from: encoded) == settings)
    }
    @Test(arguments: [false, true])
    func stateFileMigratesAndRemembersAppChoices(_ wasLarge: Bool) throws {
        let directory = TestTemporaryDirectory.currentURL.appending(path: UUID().uuidString)
        let file = AppStateFile(url: directory.appending(path: "app-state.json"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = "{\"utilities\":{\"dock\":{\"enhance\":{\"largePreviews\":\(wasLarge)}}}}"
        try Data(json.utf8).write(to: file.url)
        var state = file.load()
        #expect(state.utilities.dock.enhance.previewSize == (wasLarge ? .large : .medium))
        state.utilities.dock.enhance.previewSizeOverrides["test.synthetic.mail"] = .small
        try file.save(state)
        let restored = file.load().utilities.dock.enhance
        #expect(restored.previewSize(for: "test.synthetic.mail") == .small)
        #expect(restored.previewSize(for: "test.synthetic.other") == (wasLarge ? .large : .medium))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == ["app-state.json"], "a normal migration creates no recovery copy")
    }
}
