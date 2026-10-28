import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// The status item's menu speaks the shared words: no socket text, no
/// `why` codes, and the usage figures the meters draw.
@Suite("Status menu lines")
struct StatusMenuLinesTests {
    static let now: Double = 1_790_000_000

    @Test func monitorLinesUseTheSharedWords() {
        #expect(StatusMenuLines.monitor(.connected, hasState: true) == "Monitor · Connected")
        #expect(StatusMenuLines.monitor(.connected, hasState: false) == "Monitor · \(MonitorWords.waiting)")
        #expect(StatusMenuLines.monitor(.connecting(attempt: 1), hasState: false) == "Monitor · \(MonitorWords.starting)")
        #expect(StatusMenuLines.monitor(.connecting(attempt: 3), hasState: false) == "Monitor · \(MonitorWords.reconnecting)")
        #expect(StatusMenuLines.monitor(.disconnected(reason: "connect: Connection refused"), hasState: false)
                == "Monitor · Not connected. The monitor is not running.")
        #expect(StatusMenuLines.monitor(.idle, hasState: false) == "Monitor · \(MonitorWords.notStarted)")
        #expect(StatusMenuLines.monitor(.disconnected(reason: "x"), hasState: false, supervisor: .crashed(failures: 10))
                == "The monitor crashed 10 times. Restart it from the panel.")
        #expect(StatusMenuLines.monitor(.disconnected(reason: "x"), hasState: false,
                                        supervisor: .backingOff(failures: 2, delay: 1.5))
                == "The monitor stopped. Restarting in 2 s.")
    }

    @Test func noLineShowsRawText() {
        let raw = ["core closed the socket", "core sent no hello within 5 s", "Connection refused"]
        for reason in raw {
            let line = StatusMenuLines.monitor(.disconnected(reason: reason), hasState: false)
            #expect(!line.contains(reason), "\(line)")
            #expect(!line.contains("disconnected ·"))
        }
    }

    @Test func lightsSayWhatPlays() {
        let explanation = LightExplanation(why: "waiting", kind: .waiting, motion: "Amber pulse",
                                           reason: "Claude is waiting on you")
        #expect(StatusMenuLines.lights(live: true, explanation: explanation, offline: nil, refused: false)
                == "Lights · Amber pulse: Claude is waiting on you")
        #expect(StatusMenuLines.lights(live: false, explanation: nil, offline: .idleBreath, refused: true,
                                       notes: ["still under Reduce Motion"])
                == "Lights · Playing the built-in idle breath · refused a program, holding the last safe one · still under Reduce Motion")
        let offline = StatusMenuLines.lights(live: false, explanation: nil, offline: .strip, refused: false)
        #expect(!offline.contains("/"), "a feed's path never reaches the menu")
    }

    @Test func usageLinesNameTheWindowTheUseAndTheReset() {
        let utc = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        var claude = CoreProviderUsage(id: "claude", windows: [
            CoreUsageWindow(name: "5h", usedPct: 42, resetsAt: Self.now + 25 * 60),
            CoreUsageWindow(name: "7d", usedPct: 18, resetsAt: Self.now + 86_400 * 3),
        ], state: "ready")
        claude.availability = "available"
        let codex = CoreProviderUsage(id: "codex", windows: [
            CoreUsageWindow(name: "5h", usedPct: 90, resetsAt: Self.now - 60),
        ], state: "ready")
        let lines = StatusMenuLines.usage([claude, codex], live: true, now: Self.now, locale: locale, timeZone: utc)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("Claude "))
        #expect(lines[0].contains("% used · resets "))
        #expect(lines[1] == "Codex 5h · reset, waiting for a new reading")
        let offline = StatusMenuLines.usage([claude], live: false, now: Self.now, locale: locale, timeZone: utc)
        #expect(offline[0].hasSuffix(" · Stale"))
    }
}
