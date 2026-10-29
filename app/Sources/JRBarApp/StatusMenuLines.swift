import Foundation
import JRBarCore
import JRBarUI

/// The status item's menu lines in plain words: how the monitor is, what
/// the lights are playing, and one line per provider shown in the menu bar.
/// Raw socket reasons and the daemon's `why` codes stay in the log.
enum StatusMenuLines {
    /// "Monitor · Connected", "Monitor · Reconnecting…", "Monitor · Not
    /// connected. The monitor is not running.", or the supervisor's own
    /// sentence while it restarts or has given up.
    static func monitor(_ connection: CoreModel.Connection, hasState: Bool,
                        supervisor: CoreSupervisor.State? = nil) -> String {
        switch supervisor {
        case .crashed(let failures)?: return MonitorWords.crashed(failures: failures)
        case .backingOff(let failures, let delay)?: return MonitorWords.restarting(failures: failures, delay: delay)
        default: break
        }
        let status = MonitorWords.connection(connection, hasState: hasState)
        if case .disconnected(let reason) = connection {
            return "Monitor · \(status). \(MonitorWords.reason(reason))"
        }
        return "Monitor · \(status)"
    }

    /// What the lights play: the monitor's explanation while it is live
    /// ("Amber pulse: Claude is waiting on you"), the app's own fallback
    /// while it is not, then why the band holds still or what it follows.
    static func lights(live: Bool, explanation: LightExplanation?, offline: ScreenBarSourceLine.OfflineFeed?,
                       refused: Bool, notes: [String] = []) -> String {
        var parts: [String] = []
        if live {
            parts.append(explanation?.headline ?? "Playing the monitor's program")
        } else {
            let playing = (offline ?? .strip).playing
            parts.append(playing.prefix(1).uppercased() + playing.dropFirst())
        }
        if refused { parts.append("refused a program, holding the last safe one") }
        parts.append(contentsOf: notes)
        return "Lights · " + parts.joined(separator: " · ")
    }

    /// The menu's first lights line, before anything has been played.
    static let lightsStarting = "Lights · Starting"

    /// One line per provider, for the providers the menu bar meters:
    /// "Claude 5h 42% used · resets 1:17 PM". A reading the monitor no
    /// longer vouches for says Stale; a window past its reset says so.
    static func usage(_ providers: [CoreProviderUsage], live: Bool, now: Double,
                      locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .current) -> [String] {
        providers.compactMap { provider in
            let name = provider.instanceLabel ?? ProviderPalette.displayName(for: provider.id)
            if let kind = provider.actionKind, ["sign_in", "manage", "resign_in"].contains(kind),
               let action = provider.action {
                return "\(name) · \(action)"
            }
            guard let window = provider.headlineWindow else { return nil }
            let lead = "\(name) \(window.placementLabel)"
            let stale = !live || provider.isStale
            let tail = stale ? " · \(UsageStatus.stale.word)" : ""
            if let resets = window.resetsAt, resets <= now {
                return "\(lead) · reset, waiting for a new reading"
            }
            guard let used = window.usedPct else { return "\(lead) · \(UsageStatus.noReading.word)" }
            var line = "\(lead) \(UsageNumber.percent(used)) used"
            if let resets = window.resetsAt {
                line += " · resets " + UsageTime.resetLine(resets, now: now, locale: locale, timeZone: timeZone)
            }
            return line + tail
        }
    }
}
