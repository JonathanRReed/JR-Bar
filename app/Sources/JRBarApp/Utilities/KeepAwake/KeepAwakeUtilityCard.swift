import AppKit
import IOKit.pwr_mgt
import JRBarCore
import SwiftUI

/// Keep-awake as a card on the Utilities page — Amphetamine's session
/// switch and presets, beside the other utilities. The switch is the
/// person's own hold: on keeps the Mac awake until turned off, off lets
/// it sleep and leaves nothing running. It is the same hold as the notch
/// card's Awake chip and the footer's cup (`SystemTogglesStore`), so a
/// change anywhere shows everywhere. The agents' own hold is a daemon
/// setting; its four rows sit here too, and Settings › Notifications ›
/// Power keeps them as well.
@MainActor
@Observable
final class KeepAwakeUtility: Toy {
    static let shared = KeepAwakeUtility()

    let toggles: SystemTogglesStore

    init(toggles: SystemTogglesStore = SystemTogglesStore()) {
        self.toggles = toggles
    }

    let id = "keepAwake"
    let name = "Keep Awake"
    let blurb = "Hold this Mac awake for a while, until the morning, or until the agents finish — the same hold as the notch's Awake chip."
    let symbol = "cup.and.saucer.fill"

    private var reading: KeepAwakeReading { toggles.state.awakeReading }

    var isOn: Bool {
        get { reading.leaseInForce }
        // On is "until I turn it off"; off lets go of the hold, so a
        // switched-off card leaves no assertion and no clock behind.
        set { toggles.holdAwake(seconds: newValue ? nil : 0) }
    }

    var status: ToyStatus {
        let reading = reading
        if let why = reading.suspendedWords { return .paused("Paused · \(why)") }
        switch reading.state {
        case .off:
            return .off
        case .agents(let count):
            return .note(count == 1 ? "1 agent holds it" : count > 0 ? "\(count) agents hold it" : "Agents' grace")
        case .lease(.until):
            // The footer's own compact words ("42m"), rounded the same way.
            guard let words = reading.footerLine(now: toggles.state.awakeClock), words.short != "Awake"
            else { return .on }
            return .note(words.short + " left")
        case .lease(.agentsFinish):
            return .note("Until the agents finish")
        case .lease(.indefinite):
            return .on
        }
    }

    /// Fixed holders for a render proof of the real Utilities page, so no
    /// app of this Mac reaches the PNG; nil reads macOS's power assertions.
    @ObservationIgnored var proofHolders: [KeepAwakeHolders.Holder]?

    var controls: AnyView { AnyView(KeepAwakeUtilityControls(utility: self, holders: proofHolders)) }
}

/// The card's body: what holds the Mac right now, the presets, the
/// agents' own hold, the person's durations, and who else holds it.
struct KeepAwakeUtilityControls: View {
    let utility: KeepAwakeUtility
    /// Fixed holders for proofs; nil reads the power assertions.
    var holders: [KeepAwakeHolders.Holder]?
    /// A fixed moment for proofs; nil is now.
    var now: Date?
    @Environment(SettingsStore.self) private var settings: SettingsStore?
    /// The last read, shown at once while a fresh one runs off the main
    /// thread.
    @ViewState private var readHolders: [KeepAwakeHolders.Holder] = KeepAwakeHolders.lastRead
    @ViewState private var durations: [Int] = KeepAwakeMenu.durations()
    @ViewState private var newMinutes = 45

    private var toggles: SystemTogglesStore { utility.toggles }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardSectionHeader("Right now")
            nowLine
            presets
            Toggle(isOn: Binding(get: { toggles.awakeKeepsDisplay },
                                 set: { toggles.setAwakeKeepsDisplay($0) })) {
                SettingLabel(title: "Keep the display on",
                             subtitle: "Your hold keeps the screen lit too — no screen saver, no lock. Off lets the display sleep while the Mac stays up.")
            }
            if let settings {
                agentRows(settings)
            }
            durationRows
            othersRows
        }
        .task { await refreshHolders() }
    }

    // MARK: Right now

    private var nowLine: some View {
        let reading = toggles.state.awakeReading
        let at = now ?? toggles.state.awakeClock
        let words = reading.footerLine(now: at)?.full ?? "Not holding — the Mac sleeps as it normally would."
        return HStack(spacing: SettingsMetrics.s) {
            Image(systemName: reading.holding ? "cup.and.saucer.fill" : "cup.and.saucer")
                .foregroundStyle(reading.holding ? Color.accentColor : .secondary)
            Text(words)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.vertical, SettingsMetrics.rowPadding)
        .help(reading.chipHelp(now: at))
    }

    private var presets: some View {
        let items = KeepAwakeMenu.items(durations: durations, reading: toggles.state.awakeReading,
                                        displayOn: toggles.awakeKeepsDisplay,
                                        monitorLive: toggles.state.daemonLive, now: now ?? Date())
        // The display switch is its own row below; Turn off shows only
        // while there is a hold to end (the menus keep it, greyed).
        let buttons = items.filter { $0.choice != .keepDisplayOn && ($0.choice != .turnOff || $0.enabled) }
        return FlowLayout {
            ForEach(buttons) { item in
                Button(presetTitle(item)) { KeepAwakeMenu.perform(item.choice, on: toggles) }
                    .controlSize(.small)
                    .disabled(!item.enabled)
                    .help(item.choice == .untilAgentsFinish && !item.enabled
                          ? "Only the monitor knows when the agents finish, and it isn't running."
                          : item.title)
            }
        }
        .padding(.vertical, SettingsMetrics.s)
    }

    /// The buttons' short words: "15 m", "Until 08:00", "Indefinitely".
    private func presetTitle(_ item: KeepAwakeMenu.Item) -> String {
        if case .seconds(let seconds) = item.choice { return KeepAwakeMenu.shortTitle(seconds: seconds) }
        return item.title
    }

    // MARK: The agents' hold

    @ViewBuilder
    private func agentRows(_ settings: SettingsStore) -> some View {
        CardSectionHeader("While agents run")
        SettingToggle(settings, "Keep Mac awake", subtitle: "While agents run, the Mac never idles to sleep.",
                      path: "agent_keep_awake_enabled", default: true)
        SettingToggle(settings, "Keep display awake",
                      subtitle: "While agents run, the screen stays on too — so it never locks mid-run.",
                      path: "keep_display_awake", default: true)
        SettingPicker(settings, "Lid closed",
                      subtitle: ClosedLidNote.text(settings.core.state?.power?.closedLid),
                      path: "closed_lid_awake_policy", options: [
                        ("never", "Let it sleep"), ("agents", "Stay awake while agents run"),
                        ("always", "Always stay awake"),
                      ], default: "never")
        SettingToggle(settings, "Keep awake on battery", subtitle: "Off releases the hold whenever the Mac is unplugged.",
                      path: "keep_awake_on_battery", default: true)
    }

    // MARK: Durations

    @ViewBuilder
    private var durationRows: some View {
        CardSectionHeader("Presets")
        LabeledContent {
            HStack(spacing: SettingsMetrics.s) {
                Stepper(value: $newMinutes, in: 1...1440, step: newMinutes < 60 ? 5 : 15) {
                    ValueText(text: KeepAwakeMenu.shortTitle(seconds: newMinutes * 60), width: 64)
                }
                Button("Add") { setDurations(durations + [newMinutes * 60]) }
                    .controlSize(.small)
                    .disabled(durations.contains(newMinutes * 60) || durations.count >= KeepAwakeMenu.maxDurations)
            }
        } label: {
            SettingLabel(title: "Durations",
                         subtitle: "The presets the Awake chip, the footer's cup and the Screen Bar's ear offer, up to eight.")
        }
        FlowLayout {
            ForEach(durations, id: \.self) { seconds in
                HStack(spacing: 4) {
                    Text(KeepAwakeMenu.shortTitle(seconds: seconds))
                    Button {
                        setDurations(durations.filter { $0 != seconds })
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(durations.count <= 1)
                    .accessibilityLabel("Remove \(KeepAwakeMenu.title(seconds: seconds))")
                }
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            if durations != KeepAwakeMenu.defaultDurations {
                Button("Reset") { setDurations(KeepAwakeMenu.defaultDurations) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, SettingsMetrics.s)
    }

    private func setDurations(_ seconds: [Int]) {
        KeepAwakeMenu.setDurations(seconds)
        durations = KeepAwakeMenu.durations()
    }

    // MARK: Other apps

    @ViewBuilder
    private var othersRows: some View {
        let shown = holders ?? readHolders
        CardSectionHeader("Other apps")
        LabeledContent {
            Button("Refresh") { _ = Task { await refreshHolders() } }
                .controlSize(.small)
                .disabled(holders != nil)
        } label: {
            SettingLabel(title: "Other apps holding this Mac awake",
                         subtitle: "Read from macOS's power assertions, never changed. Holds stack: the Mac sleeps once every one lets go.")
        }
        if shown.isEmpty {
            CardNote("Nothing else is holding this Mac awake.")
        } else {
            ForEach(shown) { holder in
                CardNote(holder.sentence, symbol: "cup.and.saucer", tint: .secondary)
            }
        }
        // A keep-awake app running with no hold of its own yet.
        RivalGuardView(role: .keepAwake, rivals: idleRivals(besides: shown))
    }

    /// Keep-awake apps that are running but hold nothing right now — the
    /// ones already holding are named above.
    private func idleRivals(besides shown: [KeepAwakeHolders.Holder]) -> [UtilityRivals.Rival] {
        guard holders == nil else { return [] }
        _ = UtilityRivalsWatch.shared.version
        return UtilityRivals.running(for: .keepAwake).filter { rival in
            !shown.contains { rival.matches(bundleID: $0.bundleID, name: $0.name) }
        }
    }

    /// Reads the power assertions off the main thread — the read walks
    /// every process's assertions and asks LaunchServices about each
    /// holder, about 150 ms on a busy Mac — and shows the result.
    private func refreshHolders() async {
        guard holders == nil else { return }
        readHolders = await KeepAwakeHolders.readInBackground()
    }
}

/// What the "Lid closed" row says under its picker, here and in Settings ›
/// Power: a closed-lid hold rides the privileged sleep helper
/// (`pmset disablesleep`), not macOS's own closed-lid mode, so it needs no
/// charger or external display — only the helper, which the monitor
/// reports on.
enum ClosedLidNote {
    static func text(_ lid: CoreClosedLid?) -> String {
        switch lid?.helperInstalled {
        case true?:
            let holding = lid?.holding == true ? " Holding now." : ""
            return "The sleep helper is installed; closed-lid holds are honoured." + holding
        case false?:
            return "Needs the privileged sleep helper, which is not installed. The monitor will offer to install it."
        default:
            return "Needs the privileged sleep helper; the monitor reports whether it is installed."
        }
    }
}

/// The other apps holding this Mac awake, from macOS's own record of
/// power assertions (`IOPMCopyAssertionsByProcess`, public IOKit,
/// read-only). Only apps count — a daemon's housekeeping hold is not
/// something a person can act on — and JR-Bar's own hold is the card's
/// first line, so it is left out here.
enum KeepAwakeHolders {
    struct Holder: Equatable, Identifiable, Sendable {
        let name: String
        let bundleID: String?
        /// Holds the display on, not only the Mac.
        let display: Bool
        var id: String { bundleID ?? name }

        var sentence: String {
            display ? "\(name) is keeping the display on." : "\(name) is keeping the Mac awake."
        }
    }

    /// The assertion kinds that keep a Mac from sleeping.
    nonisolated static let systemKinds: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion",
    ]
    nonisolated static let displayKinds: Set<String> = [
        "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion",
    ]

    /// Pure: the per-process assertion lists as IOKit hands them out,
    /// resolved to the apps behind them — each app once, the display
    /// hold outranking the system one, in name order. `app` answers
    /// only for a real app bundle; everything else is left out.
    nonisolated static func holders(from byProcess: [Int32: [[String: Any]]],
                                    app: (Int32) -> (name: String, bundleID: String?)?,
                                    ownPID: Int32) -> [Holder] {
        var found: [String: Holder] = [:]
        for (pid, assertions) in byProcess where pid != ownPID {
            let live = assertions.filter { assertion in
                (assertion["AssertLevel"] as? Int).map { $0 > 0 } ?? true
            }
            let kinds = Set(live.compactMap { $0["AssertType"] as? String })
            let display = !kinds.isDisjoint(with: displayKinds)
            guard display || !kinds.isDisjoint(with: systemKinds), let owner = app(pid) else { continue }
            let key = owner.bundleID ?? owner.name
            let merged = display || found[key]?.display == true
            found[key] = Holder(name: owner.name, bundleID: owner.bundleID, display: merged)
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The last holders read, for the next card to show at once.
    @MainActor static var lastRead: [Holder] = []

    /// The holders right now, read on a background queue; `lastRead`
    /// keeps the answer.
    @MainActor
    static func readInBackground() async -> [Holder] {
        let holders = await Task.detached(priority: .userInitiated) { read() }.value
        lastRead = holders
        return holders
    }

    /// The holders right now. Safe off the main thread: IOKit's
    /// assertion list and `NSRunningApplication` lookups.
    nonisolated static func read() -> [Holder] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let dictionary = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var byProcess: [Int32: [[String: Any]]] = [:]
        for (pid, list) in dictionary { byProcess[pid.int32Value] = list }
        return holders(from: byProcess, app: { pid in
            guard let running = NSRunningApplication(processIdentifier: pid),
                  running.bundleURL?.pathExtension == "app",
                  let name = running.localizedName else { return nil }
            return (name, running.bundleIdentifier)
        }, ownPID: ProcessInfo.processInfo.processIdentifier)
    }
}
