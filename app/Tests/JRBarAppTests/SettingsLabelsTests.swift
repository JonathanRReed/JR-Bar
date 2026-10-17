import Foundation
import Testing

/// A control drawn with an empty title and its label hidden has no name
/// for VoiceOver unless it is given one. The pages build such controls in
/// a row whose own label sits beside them; this holds each to naming
/// itself, so a new one cannot slip in mute.
@Suite struct SettingsLabelsTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/JRBarApp")

    /// Controls whose empty title is a SwiftUI idiom for "no visible label".
    private static let mute = ["ColorPicker(\"\"", "Stepper(\"\"", "DatePicker(\"\"", "TextField(\"\"", "Picker(\"\""]

    @Test func everyUntitledSettingsControlNamesItself() throws {
        let files = ["SettingsView.swift", "SettingsPagesA.swift", "SettingsPagesB.swift", "SettingsPagesShell.swift",
                     "SettingsAtoms.swift", "ControlCenterView.swift", "CalibrationProfilesSection.swift"]
        var unnamed: [String] = []
        for file in files {
            let text = try String(contentsOf: Self.sources.appending(path: file), encoding: .utf8)
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where Self.mute.contains(where: line.contains) {
                // The control's modifiers follow it: its own name is within a dozen lines.
                let window = lines[index..<min(index + 12, lines.count)].joined(separator: "\n")
                if !window.contains("accessibilityLabel") { unnamed.append("\(file):\(index + 1)") }
            }
        }
        #expect(unnamed.isEmpty, "controls with no accessibility name: \(unnamed)")
    }
}
