import Foundation
import Testing
@testable import JRBarLEDS

/// LEDS_FORMAT.md is the spec people write programs from, so it is held
/// to the parser that was probed against the firmware: every ```leds
/// block must parse on both device shapes, and every ```leds-error block
/// must fail with exactly the error it names. A spec that drifts from the
/// firmware again fails here instead of in a red blink on the desk.
@Suite("LEDS_FORMAT.md against the parser")
struct FormatSpecTests {
    struct Block {
        let info: String
        let body: String
        let line: Int
    }

    static var specURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // JRBarLEDSTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repository
            .appending(path: "LEDS_FORMAT.md")
    }

    static func blocks(in text: String) -> [Block] {
        var blocks: [Block] = []
        var info: String?
        var body: [String] = []
        var start = 0
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if line.hasPrefix("```") {
                if let open = info {
                    blocks.append(Block(info: open, body: body.joined(separator: "\n"), line: start))
                    info = nil
                    body = []
                } else {
                    info = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    start = index + 1
                }
            } else if info != nil {
                body.append(line)
            }
        }
        return blocks
    }

    @Test func everyProgramInTheSpecParsesOnBothDevices() throws {
        let blocks = Self.blocks(in: try String(contentsOf: Self.specURL, encoding: .utf8))
        let programs = blocks.filter { $0.info == "leds" }
        #expect(programs.count >= 20, "the spec's examples are fenced as ```leds")
        for block in programs {
            for leds in [8, 2] {
                do {
                    _ = try LEDSProgram.parse(block.body, ledCount: leds)
                } catch {
                    Issue.record("LEDS_FORMAT.md:\(block.line) (\(leds) LEDs) \(error)")
                }
            }
        }
    }

    @Test func everyErrorInTheSpecFailsTheWayItSays() throws {
        let blocks = Self.blocks(in: try String(contentsOf: Self.specURL, encoding: .utf8))
        let failures = blocks.filter { $0.info.hasPrefix("leds-error") }
        #expect(failures.count >= 8)
        var kinds: Set<LEDSParseError.Kind> = []
        for block in failures {
            let name = String(block.info.dropFirst("leds-error".count)).trimmingCharacters(in: .whitespaces)
            let expected = try #require(LEDSParseError.Kind(rawValue: name), "LEDS_FORMAT.md:\(block.line) names \(name)")
            kinds.insert(expected)
            do {
                _ = try LEDSProgram.parse(block.body, ledCount: 8)
                Issue.record("LEDS_FORMAT.md:\(block.line) says \(name), but the program parses")
            } catch {
                #expect(error.kind == expected, "LEDS_FORMAT.md:\(block.line)")
            }
        }
        #expect(kinds.isSuperset(of: [.syntax, .badColor, .badIndex, .badTime, .badBrightness, .badRepeat, .trailingInput]))
    }

    @Test func onlyKnownFencesAppear() throws {
        let blocks = Self.blocks(in: try String(contentsOf: Self.specURL, encoding: .utf8))
        for block in blocks {
            #expect(block.info == "leds" || block.info == "text" || block.info.hasPrefix("leds-error "),
                    "LEDS_FORMAT.md:\(block.line) fence `\(block.info)`")
        }
    }
}
