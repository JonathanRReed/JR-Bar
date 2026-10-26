import Foundation
import JRBarCore

/// The monitor keeps parameter ids in diagnostics. Studio names the controls.
enum StudioWarning {
    static func plain(_ warning: String) -> String {
        var text = warning
        let safety = [
            "phase_cadence_clamped": "flashes slowed to a safe rate",
            "roll_cadence_clamped": "movement slowed to a safe rate",
            "loop_cadence_clamped": "the repeating cycle slowed to a safe rate",
        ]
        for (key, words) in safety { text = text.replacingOccurrences(of: key, with: words) }
        let pattern = #"\b[a-z]+(?:_[a-z]+)+\b"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: text) else { continue }
                let key = String(text[range])
                let parameter = EffectParameter(name: key, type: .number, defaultValue: .number(0))
                text.replaceSubrange(range, with: parameter.title.lowercased())
            }
        }
        let names = ["codex": "Codex", "claude": "Claude", "gemini": "Gemini", "grok": "Grok",
                     "kitt": "Knight Rider", "auto": "Automatic", "breathe": "Breathe", "comet": "Comet",
                     "heartbeat": "Heartbeat", "steady": "Steady", "ember": "Ember", "chase": "Chase",
                     "scanner": "Scanner", "flicker": "Flicker", "stack": "Stack", "twinkle": "Twinkle",
                     "drift": "Drift", "converge": "Converge", "aurora": "Aurora", "tide": "Tide",
                     "gradient": "Gradient", "marquee": "Marquee", "duotone": "Duotone", "bloom": "Bloom",
                     "frontier": "Frontier", "glint": "Glint", "ripple": "Ripple", "pendulum": "Pendulum", "blink": "Blink"]
        for (key, label) in names {
            text = text.replacingOccurrences(of: "\\b\(key)\\b", with: label, options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "was clamped to", with: "was limited to")
            .replacingOccurrences(of: "was rejected; using", with: "could not be used; using")
            .replacingOccurrences(of: "was rejected for", with: "is not available for")
            .replacingOccurrences(of: "the renderer uses a safe default or bound", with: "a safe value is used")
            .replacingOccurrences(of: "The safety compiler adjusted the timing:", with: "Timing changed for safety:")
        let limits = [
            "the program exceeds 512 bytes or 20 lines": "the pattern is too large for this device",
            "the presentation safety compiler refused the program": "the pattern could not be made safe",
            "safe timing leaves no room for the device brightness line": "safe timing and brightness do not fit together",
            "the provider program is invalid": "the provider pattern is invalid",
            "the provider program could not be mapped to its share": "the provider pattern cannot play on its part of the strip",
            "a curved roll cannot run inside a separate share": "this moving pattern cannot play on only part of the strip",
        ]
        for (key, words) in limits { text = text.replacingOccurrences(of: key, with: words) }
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
