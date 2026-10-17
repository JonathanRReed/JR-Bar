import Carbon
import JRBarCore
import Testing
@testable import JRBarApp

@Suite struct FoldDismissalTests {
    @Test func angleNeedsBandExit() {
        var policy = FoldDismissal()
        policy.dismiss()
        let rearmed1 = policy.note(angle: 80, closed: false, safetyClear: true, mode: .angle, activation: 90, tolerance: 1.5, at: 1)
        #expect(!rearmed1)
        let rearmed2 = policy.note(angle: 102, closed: false, safetyClear: true, mode: .angle, activation: 90, tolerance: 1.5, at: 2)
        #expect(!rearmed2)
        #expect(policy.suppressed)
        let rearmed3 = policy.note(angle: 103, closed: false, safetyClear: true, mode: .angle, activation: 90, tolerance: 1.5, at: 3)
        #expect(rearmed3)
        #expect(!policy.suppressed)
    }

    @Test func movementNeedsStillnessAndFreshOpenReading() {
        var policy = FoldDismissal()
        policy.dismiss()
        let rearmed4 = policy.note(angle: 70, closed: false, safetyClear: true, mode: .movement, activation: 90, tolerance: 1.5, at: 1)
        #expect(!rearmed4)
        let rearmed5 = policy.note(angle: 60, closed: false, safetyClear: true, mode: .movement, activation: 90, tolerance: 1.5, at: 1.3)
        #expect(!rearmed5)
        let rearmed6 = policy.note(angle: nil, closed: false, safetyClear: true, mode: .movement, activation: 90, tolerance: 1.5, at: 2)
        #expect(!rearmed6)
        let rearmed7 = policy.note(angle: 60, closed: true, safetyClear: true, mode: .movement, activation: 90, tolerance: 1.5, at: 3)
        #expect(!rearmed7)
        let rearmed8 = policy.note(angle: 60, closed: false, safetyClear: true, mode: .movement, activation: 90, tolerance: 1.5, at: 4)
        #expect(!rearmed8)
        let rearmed9 = policy.note(angle: 61, closed: false, safetyClear: true, mode: .movement, activation: 90, tolerance: 1.5, at: 4.39)
        #expect(!rearmed9)
        let rearmed10 = policy.note(angle: 60, closed: false, safetyClear: true, mode: .movement, activation: 90, tolerance: 1.5, at: 4.5)
        #expect(rearmed10)
    }

    @Test func unsafeNeutralCannotClearAngleLatch() {
        var policy = FoldDismissal()
        policy.dismiss()
        let rearmed11 = policy.note(angle: 110, closed: false, safetyClear: false, mode: .angle,
                             activation: 90, tolerance: 1.5, at: 1)
        #expect(!rearmed11)
        let rearmed12 = policy.note(angle: 80, closed: false, safetyClear: true, mode: .angle,
                             activation: 90, tolerance: 1.5, at: 2)
        #expect(!rearmed12)
        #expect(policy.suppressed)
        let rearmed13 = policy.note(angle: 110, closed: false, safetyClear: true, mode: .angle,
                            activation: 90, tolerance: 1.5, at: 3)
        #expect(rearmed13)
    }

    @Test func unsafeSampleRestartsMovementStillness() {
        var policy = FoldDismissal()
        policy.dismiss()
        let rearmed14 = policy.note(angle: 60, closed: false, safetyClear: true, mode: .movement,
                             activation: 90, tolerance: 1.5, at: 1)
        #expect(!rearmed14)
        let rearmed15 = policy.note(angle: 60, closed: false, safetyClear: false, mode: .movement,
                             activation: 90, tolerance: 1.5, at: 1.3)
        #expect(!rearmed15)
        let rearmed16 = policy.note(angle: 60, closed: false, safetyClear: true, mode: .movement,
                             activation: 90, tolerance: 1.5, at: 1.5)
        #expect(!rearmed16)
        #expect(policy.suppressed)
        let rearmed17 = policy.note(angle: 60, closed: false, safetyClear: true, mode: .movement,
                            activation: 90, tolerance: 1.5, at: 2)
        #expect(rearmed17)
    }

    @Test func silentGapRestartsMovementStillness() {
        var policy = FoldDismissal()
        policy.dismiss()
        let rearmed18 = policy.note(angle: 60, closed: false, safetyClear: true, mode: .movement,
                             activation: 90, tolerance: 1.5, at: 1)
        #expect(!rearmed18)
        let rearmed19 = policy.note(angle: 60, closed: false, safetyClear: true, mode: .movement,
                             activation: 90, tolerance: 1.5, at: 20)
        #expect(!rearmed19)
        #expect(policy.suppressed)
        let rearmed20 = policy.note(angle: 60, closed: false, safetyClear: true, mode: .movement,
                            activation: 90, tolerance: 1.5, at: 20.5)
        #expect(rearmed20)
    }

    @Test func physicalSampleSafetyUsesExistingPauseRules() {
        for blocked in 0..<6 {
            #expect(!FoldDismissal.safetyClear(
                angle: 110, closed: blocked == 0, builtInPresent: blocked != 1,
                mirrored: blocked == 2, screenAsleep: blocked == 3,
                screenLocked: blocked == 4, sessionInactive: blocked == 5))
        }
        #expect(FoldDismissal.safetyClear(angle: 110, closed: false, builtInPresent: true,
                                        mirrored: false, screenAsleep: false,
                                        screenLocked: false, sessionInactive: false))
    }

    @MainActor @Test func leaseIsLiveAndSuspensionHidesBeforeDetach() throws {
        let recorder = HotkeyCenterTests.Recorder()
        let center = HotkeyCenter(registrar: recorder)
        var dismissed = false
        var lossBeforeDetach = false
        let acquired = center.acquireFoldEscape(action: { dismissed = true }, lost: {
            lossBeforeDetach = recorder.unregistered == 0
        })
        #expect(acquired)
        #expect(center.foldEscapeIsLive)
        let keyID = try #require(recorder.registered.first?.id)
        center.fire(hotKeyID: keyID)
        #expect(dismissed)
        center.suspend()
        #expect(lossBeforeDetach)
        #expect(!center.foldEscapeIsLive)
        let acquiredWhileSuspended = center.acquireFoldEscape(action: {}, lost: {})
        #expect(!acquiredWhileSuspended)
        center.resume()
        #expect(!center.foldEscapeIsLive)
        #expect(recorder.registered.count == 1)
    }

    @MainActor @Test func refusalNeverCreatesLeaseAndReleaseIsIdempotent() {
        let recorder = HotkeyCenterTests.Recorder()
        recorder.taken.insert(HotkeyChord(keyCode: UInt32(kVK_Escape), modifiers: 0))
        let center = HotkeyCenter(registrar: recorder)
        let acquired = center.acquireFoldEscape(action: {}, lost: {})
        #expect(!acquired)
        #expect(!center.foldEscapeIsLive)
        #expect(center.entries.isEmpty)
        #expect(HotkeyChord(keyCode: UInt32(kVK_Escape), modifiers: 0).problem == .needsModifier)
        center.releaseFoldEscape()
        center.releaseFoldEscape()
        #expect(recorder.unregistered == 0)
    }
}

@Suite struct FoldEscapeConflictTests {
    @MainActor @Test func existingOwnerWinsWithoutLosingItsAction() {
        let recorder = HotkeyCenterTests.Recorder()
        let center = HotkeyCenter(registrar: recorder)
        let chord = HotkeyChord(keyCode: UInt32(kVK_Escape), modifiers: 0)
        var originalFired = false
        center.register("existing", title: "Existing", chord: chord) { originalFired = true }
        let acquired = center.acquireFoldEscape(action: {}, lost: {})
        #expect(!acquired)
        #expect(recorder.registered.count == 1)
        if let keyID = recorder.registered.first?.id { center.fire(hotKeyID: keyID) }
        #expect(originalFired)
        #expect(!center.foldEscapeIsLive)
    }

    @MainActor @Test func repeatedAcquireDoesNotRegisterAgain() {
        let recorder = HotkeyCenterTests.Recorder()
        let center = HotkeyCenter(registrar: recorder)
        var lost = false
        let firstAcquire = center.acquireFoldEscape(action: {}, lost: { lost = true })
        let repeatedAcquire = center.acquireFoldEscape(action: {}, lost: {})
        #expect(firstAcquire)
        #expect(repeatedAcquire)
        #expect(recorder.registered.count == 1)
        center.releaseFoldEscape()
        #expect(!lost)
        #expect(!center.foldEscapeIsLive)
        #expect(recorder.unregistered == 1)
    }
}
