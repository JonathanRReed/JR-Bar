import Foundation
import IOKit.pwr_mgt
import JRBarCore
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite struct KeepAwakeReleaseFailureTests {
    private func state() throws -> (SystemTogglesStore.State, UserDefaults, String) {
        let suite = ScratchDefaults.suiteName("KeepAwakeReleaseFailureTests")
        let defaults = try #require(UserDefaults(suiteName: suite))
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        state.takeAssertion = { _ in 42 }
        state.releaseAssertion = { _ in kIOReturnError }
        return (state, defaults, suite)
    }

    @Test func failedReleaseKeepsTheHoldVisibleAndRetriesItsOriginalID() throws {
        let (state, defaults, suite) = try state()
        defer { defaults.removePersistentDomain(forName: suite) }
        state.holdAwake(seconds: nil)
        state.holdAwake(seconds: 0)
        #expect(state.awake.held)
        #expect(state.awake.id == 42)
        #expect(state.awakeReading.holding)
        #expect(state.isOn[.keepAwake] == true)
        #expect(state.lastError?.contains("could not stop") == true)
        var released: [IOPMAssertionID] = []
        state.releaseAssertion = { id in released.append(id); return kIOReturnSuccess }
        state.holdAwake(seconds: 0)
        #expect(released == [42])
        #expect(!state.awake.held)
        #expect(state.awake.id == 0)
        #expect(!state.awakeReading.holding)
        #expect(state.lastError == nil)
    }

    @Test func failedPolicyChangeKeepsTheActualPolicyAndDoesNotTakeAnotherAssertion() throws {
        let (state, defaults, suite) = try state()
        defer { defaults.removePersistentDomain(forName: suite) }
        state.setAwakeKeepsDisplay(false)
        state.holdAwake(seconds: 900)
        defer { state.releaseAssertion = { _ in kIOReturnSuccess }; state.setAwake(false) }
        let deadline = state.awakeUntil
        var acquisitions = 0
        state.takeAssertion = { _ in acquisitions += 1; return 43 }
        state.setAwakeKeepsDisplay(true)
        #expect(acquisitions == 0)
        #expect(state.awake.id == 42)
        #expect(state.awake.held)
        #expect(!state.awakeKeepsDisplay)
        #expect(!state.awakeReading.display)
        #expect(!defaults.bool(forKey: SystemTogglesStore.awakeDisplayDefaultsKey))
        #expect(state.awakeUntil == deadline)
        #expect(state.lastError?.contains("could not stop") == true)
        state.releaseAssertion = { _ in kIOReturnSuccess }
        state.setAwakeKeepsDisplay(true)
        #expect(acquisitions == 1)
        #expect(state.awake.id == 43)
        #expect(state.awakeKeepsDisplay)
        #expect(state.awakeUntil == deadline)
    }

    @Test(arguments: ["off", "manual", "agents"])
    func daemonReleaseFailureIsNeverPresentedAsOffOrPaused(_ demand: String) throws {
        let payload = """
        {"state":"\(demand)","active":true,"release_failed":true,"suspended":"thermal"}
        """
        let hold = try JSONDecoder().decode(CoreAwakeHold.self, from: Data(payload.utf8))
        let reading = KeepAwakeReading(hold: hold)
        #expect(reading.holding)
        #expect(reading.chipTitle(now: .distantPast) == "Still held")
        #expect(reading.chipHelp(now: .distantPast).contains("could not stop"))
        #expect(reading.footerLine(now: .distantPast)?.short == "Still held")
    }

    @Test func anExitedProcessDoesNotKeepTheWarningActive() throws {
        let hold = try JSONDecoder().decode(CoreAwakeHold.self, from: Data(
            #"{"state":"off","active":false,"release_failed":true}"#.utf8))
        let reading = KeepAwakeReading(hold: hold)
        #expect(!reading.holding)
        #expect(!reading.leaseInForce)
        #expect(reading.footerLine(now: .distantPast) == nil)
    }

    @Test func changingPolicyAfterFailedCancellationDoesNotStartANewHold() throws {
        let (state, defaults, suite) = try state()
        defer { defaults.removePersistentDomain(forName: suite) }
        state.holdAwake(seconds: nil)
        state.holdAwake(seconds: 0)
        state.takeAssertion = { _ in Issue.record("cancelled hold must not restart"); return nil }
        state.releaseAssertion = { _ in kIOReturnSuccess }
        state.setAwakeKeepsDisplay(true)
        #expect(!state.awake.held)
        #expect(!state.awakeReading.holding)
        #expect(state.awakeKeepsDisplay)
    }

    @Test func reconnectAfterFailedCancellationDoesNotCreateADaemonLease() throws {
        let (state, defaults, suite) = try state()
        defer { state.releaseAssertion = { _ in kIOReturnSuccess }; state.setAwake(false); defaults.removePersistentDomain(forName: suite) }
        state.holdAwake(seconds: nil)
        state.holdAwake(seconds: 0)
        state.sendLease = { _ in Issue.record("cancelled hold must not transfer"); return .taken }
        state.noteDaemonHold(nil, live: true)
        #expect(state.handoverTask == nil)
        #expect(state.awake.held)
        #expect(state.awakeReading.chipTitle(now: .distantPast) == "Still held")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["JRBAR_RENDER_PROOF"] == "1",
                   "set JRBAR_RENDER_PROOF=1 to write Keep Awake PNGs"))
    func failedReleaseRender() throws {
        let (state, defaults, suite) = try state()
        defer { defaults.removePersistentDomain(forName: suite) }
        state.takeAssertion = { _ in Issue.record("render must not take an assertion"); return nil }
        let hold = try JSONDecoder().decode(CoreAwakeHold.self, from: Data(
            #"{"state":"off","active":true,"release_failed":true}"#.utf8))
        state.noteDaemonHold(hold, live: true)
        let utility = KeepAwakeUtility(toggles: SystemTogglesStore(state: state))
        #expect(utility.isOn)
        #expect(utility.status.text == "Still held")
        for width: CGFloat in [430, 580] {
            let scene = Form {
                Section {
                    HStack {
                        Text(utility.name).font(.body.weight(.semibold))
                        StatusPill(utility.status.text, tint: utility.status.tint)
                        Spacer()
                        Toggle("Manual session", isOn: .constant(utility.isOn)).toggleStyle(.switch)
                    }
                    KeepAwakeUtilityControls(utility: utility, holders: [], now: .distantPast).cardBodyStyle()
                }
            }
            .formStyle(.grouped)
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            for dark in [false, true] {
                try ProofRender.write(scene, size: CGSize(width: width, height: 850),
                                      name: "keepawake-release-failed-\(Int(width))-\(dark ? "dark" : "light")", dark: dark)
            }
        }
    }
}
