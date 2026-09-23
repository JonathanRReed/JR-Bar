import Foundation
import Testing
@testable import JRBarApp

/// Lost grants: a first look only records, a later look names what the
/// person had granted and no longer has — once — and a probe that could
/// not read a row forgets nothing.
@Suite struct PermissionHealthTests {
    @Test func aFirstLookOnlyRecords() {
        let review = PermissionHealth.review(remembered: nil,
                                             statuses: [.accessibility: .granted, .screenRecording: .needed])
        #expect(review.lost.isEmpty)
        #expect(review.remember == ["accessibility"])
    }

    @Test func aGrantThatWentAwayIsLostOnce() {
        let before = ["screenRecording", "accessibility", "camera"]
        let first = PermissionHealth.review(remembered: before,
                                            statuses: [.screenRecording: .needed, .accessibility: .denied,
                                                       .camera: .granted])
        // Setup's order, not the remembered order.
        #expect(first.lost == [.screenRecording, .accessibility])
        #expect(first.remember == ["camera"])
        let second = PermissionHealth.review(remembered: first.remember,
                                             statuses: [.screenRecording: .needed, .accessibility: .denied,
                                                        .camera: .granted])
        #expect(second.lost.isEmpty, "said once, not on every launch")
    }

    @Test func aRowNeverGrantedIsNeverMentioned() {
        let review = PermissionHealth.review(remembered: ["camera"],
                                             statuses: [.camera: .granted, .location: .needed, .calendar: .denied])
        #expect(review.lost.isEmpty)
    }

    @Test func anUnreadableRowForgetsNothing() {
        let review = PermissionHealth.review(remembered: ["automation", "bluetooth"],
                                             statuses: [.automation: .unknown])
        #expect(review.lost.isEmpty)
        // Setup's order: Bluetooth comes before Automation.
        #expect(review.remember == ["bluetooth", "automation"])
    }

    @Test func theLidHelperAndSystemAudioAreNotWatched() {
        #expect(!PermissionHealth.watched.contains(.lidHelper))
        #expect(!PermissionHealth.watched.contains(.audioCapture))
        let review = PermissionHealth.review(remembered: ["lidHelper"], statuses: [.lidHelper: .needed])
        #expect(review.lost.isEmpty)
    }

    @Test func theNoticeNamesWhatStopped() {
        #expect(PermissionHealth.notice(for: []) == nil)
        #expect(PermissionHealth.notice(for: [.screenRecording])
                == "Screen Recording was turned off since JR-Bar last ran — Fold cannot see the desktop.")
        #expect(PermissionHealth.notice(for: [.screenRecording, .accessibility, .camera])
                == "Screen Recording, Accessibility and Camera were turned off since JR-Bar last ran.")
    }
}

/// The store's launch look: remembers through `persist` without touching
/// this run's step outcomes, and returns what was lost.
@MainActor
@Suite struct SetupPermissionHealthStoreTests {
    @Test func theStoreRemembersAndReports() async {
        var persisted: [SetupState] = []
        var statuses: [SetupPermission: SetupPermissionStatus] = [.screenRecording: .granted]
        var model = SetupModel()
        model.refreshPermissions = { statuses }
        let store = SetupStore(model: model,
                               load: { SetupState(completedSteps: ["welcome"], finishedAt: 10, presentedCount: 1) },
                               persist: { persisted.append($0) })
        #expect(await store.reviewPermissionHealth().isEmpty)
        #expect(persisted.last?.grantedPermissions == ["screenRecording"])
        #expect(persisted.last?.completedSteps == ["welcome"], "the step record is left as it was")
        statuses = [.screenRecording: .needed]
        #expect(await store.reviewPermissionHealth() == [.screenRecording])
        #expect(persisted.last?.grantedPermissions == [])
        #expect(store.status(of: .screenRecording) == .needed)
        let writes = persisted.count
        #expect(await store.reviewPermissionHealth().isEmpty)
        #expect(persisted.count == writes, "nothing changed, nothing written")
    }

    @Test func jumpLandsOnAStepWithoutMarkingAnything() {
        let store = SetupStore(model: SetupModel(), load: { SetupState() }, persist: { _ in })
        store.jump(to: .permissions)
        #expect(store.step == .permissions)
        #expect(store.completedSteps.isEmpty)
        #expect(store.skippedSteps.isEmpty)
    }

    @Test func rememberedGrantsSurviveTheFile() throws {
        let state = SetupState(presentedCount: 1, grantedPermissions: ["camera"])
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(SetupState.self, from: data) == state)
        let old = try JSONDecoder().decode(SetupState.self, from: Data(#"{"version":1,"presentedCount":2}"#.utf8))
        #expect(old.grantedPermissions == nil)
    }
}

/// Notices wait for the panel: one per opening, oldest first, a repost
/// replaces, a withdrawal removes.
@MainActor
@Suite struct LaunchNoticesTests {
    @Test func noticesQueueReplaceAndWithdraw() {
        let notices = LaunchNotices()
        notices.post(.init(key: "a", text: "one", actionTitle: "Go", action: {}))
        notices.post(.init(key: "b", text: "two", actionTitle: "Go", action: {}))
        notices.post(.init(key: "a", text: "one again", actionTitle: "Go", action: {}))
        #expect(notices.waiting.map(\.text) == ["one again", "two"])
        notices.withdraw(key: "b")
        #expect(notices.next()?.text == "one again")
        #expect(notices.next() == nil)
    }
}
