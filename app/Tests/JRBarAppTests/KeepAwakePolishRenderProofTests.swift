import JRBarUI
import AppKit
import Foundation
@testable import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

/// Render proof for the 0.10.1 utilities pass: the Keep Awake card failing
/// with Try again, the card holding a countdown with its steam and armed
/// heads-up, the steam's steps, the heads-up's words, every utility's cost
/// line and the honest chips. Fixed fixtures: no power assertion is taken,
/// no notification is posted, no app of this Mac reaches a PNG. Off by
/// default; `JRBAR_RENDER_PROOF=1` writes into `JRBAR_RENDER_PROOF_DIR`.
@Suite("Keep Awake polish render proof", .serialized)
@MainActor
struct KeepAwakePolishRenderProofTests {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1"

    final class Ticket: KeepAwakeHeadsUpTicket {
        func cancel() {}
    }

    private func utility(_ json: String, defaults: UserDefaults) throws -> KeepAwakeUtility {
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        state.sendLease = { _ in .taken }
        state.takeAssertion = { _ in Issue.record("render proofs must not take a power assertion"); return nil }
        state.headsUp.schedule = { _, _ in Ticket() }
        state.headsUp.deliver = { _ in Issue.record("render proofs post no notification") }
        let hold = try JSONDecoder().decode(CoreAwakeHold.self, from: Data(json.utf8))
        state.noteDaemonHold(hold, live: true)
        let utility = KeepAwakeUtility(toggles: SystemTogglesStore(state: state))
        // Nobody else's power assertions reach a PNG.
        utility.proofHolders = []
        return utility
    }

    private func card(_ utility: KeepAwakeUtility, settings: SettingsStore) -> some View {
        Form {
            Section { ToyCard(toy: utility, tint: ToyCard.tint(for: utility.id, page: .accentColor)) }
        }
        .formStyle(.grouped)
        .environment(settings)
        .frame(width: 580)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write Keep Awake PNGs"))
    func cards() throws {
        let suite = ScratchDefaults.suiteName("KeepAwakePolishRenderProofTests")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let core = CoreModel(socketPath: NSTemporaryDirectory() + "jrbar-keepawake-polish-proof.sock")
        let settings = SettingsStore(core: core)
        settings.setCard("keepAwake", expanded: true)

        let failed = try utility(#"{"state":"manual","active":false,"lease":{"kind":"indefinite"}}"#, defaults: defaults)
        #expect(failed.toggles.canRetryAwake)
        for dark in [false, true] {
            try ProofRender.write(card(failed, settings: settings), size: CGSize(width: 580, height: 980),
                                  name: "u1-keepawake-failed-try-again-\(dark ? "dark" : "light")", dark: dark)
        }

        let now = Date().timeIntervalSince1970
        let timed = try utility(
            "{\"state\":\"manual\",\"active\":true,\"lease\":{\"kind\":\"duration\",\"started_at\":\(now - 2400),\"until\":\(now + 1200)}}",
            defaults: defaults)
        #expect(timed.toggles.state.headsUp.isArmed)
        for dark in [false, true] {
            try ProofRender.write(card(timed, settings: settings), size: CGSize(width: 580, height: 980),
                                  name: "u1-keepawake-countdown-\(dark ? "dark" : "light")", dark: dark)
        }

        let process = try utility(
            "{\"state\":\"manual\",\"active\":true,\"lease\":{\"kind\":\"process\",\"pid\":4242,\"label\":\"swift\",\"started_at\":\(now - 60),\"until\":\(now + 86000)}}",
            defaults: defaults)
        try ProofRender.write(card(process, settings: settings), size: CGSize(width: 580, height: 980),
                              name: "u1-keepawake-while-command-dark", dark: true)
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write Keep Awake PNGs"))
    func steamLevels() throws {
        let levels: [KeepAwakeSteam] = [.full, .low, .faint, .none]
        let scene = HStack(spacing: 36) {
            ForEach(levels, id: \.self) { level in
                VStack(spacing: 10) {
                    KeepAwakeCup(steam: level).font(.system(size: 54))
                    Text(level.words).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .frame(width: 110)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        for dark in [false, true] {
            try ProofRender.write(scene, size: CGSize(width: 560, height: 170),
                                  name: "u1-steam-levels-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    /// The notice's own words and action on a banner-shaped card — the
    /// system draws the real banner, so this pins what goes into it.
    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write Keep Awake PNGs"))
    func headsUpNotice() throws {
        let plan = KeepAwakeHeadsUp(end: Date(timeIntervalSince1970: 1_800_003_600))
        let body = plan.body(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(secondsFromGMT: 0)!)
        let banner = HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cup.and.heat.waves.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 3) {
                Text("JR-Bar").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(plan.title).font(.system(size: 13, weight: .semibold))
                Text(body).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text("+30 min")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.1)))
        }
        .padding(14)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
        for dark in [false, true] {
            try ProofRender.write(banner, size: CGSize(width: 430, height: 150),
                                  name: "u1-heads-up-notice-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    @Test(.enabled(if: enabled, "set JRBAR_RENDER_PROOF=1 to write Keep Awake PNGs"))
    func chipsAndCostLines() throws {
        let chips: [(String, ToyStatus)] = [
            ("Menu Bar", UtilityProviderStatus.make(name: "Ice", surface: "the menu bar", installed: true, running: true)),
            ("Menu Bar", UtilityProviderStatus.make(name: "Bartender", surface: "the menu bar",
                                                    installed: true, running: false)),
            ("Dock", UtilityProviderStatus.make(name: "DockDoor", surface: "the previews", installed: true, running: true)),
            ("Dock", DockUtility.idleChip(previewsOn: false, switcherOn: false)),
            ("Keep Awake", .failed("Couldn't hold the Mac awake")),
            ("Keep Awake", .failed("Couldn't let go")),
            ("Keep Awake", .note("Lets go at 14:32")),
            ("Keep Awake", .note("While swift runs")),
        ]
        let zone = TimeZone(secondsFromGMT: 0)!
        let held = KeepAwakeReading(state: .lease(.until(Date(timeIntervalSince1970: 1_800_003_600))))
        let costs: [(String, String)] = [
            ("Menu Bar", MenuBarUtility.costLine(rechecking: true, conditionRules: true)),
            ("Menu Bar, Ice draws it", MenuBarUtility.costLine(rechecking: false, conditionRules: false)),
            ("Dock", DockUtility.costLine(watching: true, switcher: true, previews: 3, captures: 1)),
            ("Keep Awake", KeepAwakeUtility.costLine(reading: held, appHolds: false, clockRunning: true,
                                                     headsUpAt: Date(timeIntervalSince1970: 1_800_003_300),
                                                     locale: Locale(identifier: "en_GB"), timeZone: zone)),
            ("Keep Awake, off", KeepAwakeUtility.costLine(reading: KeepAwakeReading(state: .off), appHolds: false,
                                                          clockRunning: false, headsUpAt: nil)),
            ("Agent Overview", AgentUtility.costLine(updates: 4)),
        ]
        let scene = Form {
            Section("Chips") {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    HStack(spacing: 8) {
                        Text(chip.0).font(.body.weight(.semibold))
                        StatusBadge(chip.1.text, tint: chip.1.tint)
                        Spacer()
                    }
                }
            }
            Section("Cost lines") {
                ForEach(Array(costs.enumerated()), id: \.offset) { _, cost in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cost.0).font(.body.weight(.semibold))
                        ToyCostCapsule(line: cost.1)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        for dark in [false, true] {
            try ProofRender.write(scene, size: CGSize(width: 580, height: 900),
                                  name: "u1-utility-chips-costs-\(dark ? "dark" : "light")", dark: dark)
        }
    }
}
