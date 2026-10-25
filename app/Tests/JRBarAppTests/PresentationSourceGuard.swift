import Foundation

/// Mask strings and comments before matching calls, keeping all offsets intact.
func presentationCode(_ source: String) throws -> String {
    let trivia = #"(?s)//[^\n]*|/\*.*?\*/|[#]*\"\"\".*?\"\"\"[#]*|[#]*\"(?:\\.|[^\"\\])*\"[#]*"#
    let regex = try NSRegularExpression(pattern: trivia)
    let code = NSMutableString(string: source)
    for match in regex.matches(in: source, range: NSRange(location: 0, length: code.length)).reversed() {
        let text = code.substring(with: match.range)
        let masked = text.map { $0 == "\n" ? "\n" : " " }
        code.replaceCharacters(in: match.range, with: masked.joined())
    }
    return code as String
}

func presentationViolations(in source: String) throws -> [String] {
    let code = try presentationCode(source)
    let text = code as NSString
    let full = NSRange(location: 0, length: text.length)
    let modifiers = try NSRegularExpression(
        pattern: #"\.(sheet|alert|confirmationDialog|popover|fileImporter|fileExporter|inspector)\s*\("#)
    let binding = try NSRegularExpression(pattern: #"\b(?:isPresented|item):\s*([$\w.]+)\s*(\(?)"#)
    var offenders: [String] = []
    for modifier in modifiers.matches(in: code, range: full) {
        let start = NSMaxRange(modifier.range)
        var end = start
        var depth = 1
        while end < text.length, depth > 0 {
            let char = text.character(at: end)
            if char == 40 { depth += 1 }
            if char == 41 { depth -= 1 }
            end += 1
        }
        let arguments = NSRange(location: start, length: end - start)
        for match in binding.matches(in: code, range: arguments) {
            let name = text.substring(with: match.range(at: 1))
            let call = text.substring(with: match.range(at: 2))
            if name != "WindowPresenter.presentation" || call != "(" {
                offenders.append("unguarded SwiftUI presentation: \(name)")
            }
        }
    }

    let forbidden = #"\b(orderFrontRegardless|makeKeyAndOrderFront|orderFront|orderBack|orderWindow|setIsVisible|runModal|beginSheet|beginSheetModal|beginModalSession|showWindow|makeKey|addChildWindow|performClick|deminiaturize)\s*\(|\.popUp\s*\(\s*positioning:|\b(?:NSApp|app)[!?]?\s*\.\s*(?:hide|unhide)\s*\(|\.activate\s*\(\s*(?:\)|ignoringOtherApps:|options:)|\bNSStatusBar\.system\.statusItem\s*\(|\b(?:NSWorkspace\.shared|workspace)\.\s*(?:open|openApplication)\s*\("#
    let calls = try NSRegularExpression(pattern: forbidden)
    var guardedBraces: [Bool] = []
    var scanned = 0
    var lineStart = 0
    for match in calls.matches(in: code, range: full) {
        while scanned < match.range.location {
            let char = text.character(at: scanned)
            if char == 10 { lineStart = scanned + 1 }
            if char == 123 {
                let prefix = text.substring(with: NSRange(location: lineStart, length: scanned - lineStart))
                let gated = prefix.contains("WindowPresenter.automatic.perform") || prefix.contains("presenter.perform")
                guardedBraces.append(gated || guardedBraces.last == true)
            }
            if char == 125, !guardedBraces.isEmpty { guardedBraces.removeLast() }
            scanned += 1
        }
        let prefix = text.substring(with: NSRange(location: lineStart, length: match.range.location - lineStart))
        let isOverride = prefix.contains("override func")
        let isGuardedModal = prefix.hasSuffix("WindowPresenter.automatic.")
        if guardedBraces.last != true, !isOverride, !isGuardedModal {
            let line = text.substring(to: match.range.location).filter { $0 == "\n" }.count + 1
            offenders.append("line \(line): \(text.substring(with: match.range))")
        }
    }
    return offenders
}
