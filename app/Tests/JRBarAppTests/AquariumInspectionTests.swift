import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

@Suite("Aquarium inspection")
struct AquariumInspectionTests {
    private func fish(_ id: String, state: FishState, since: Date) -> Fish {
        Fish(id: id, label: "Shared label", providerID: "codex", state: state,
             lane: 0.5, speed: 0.1, direction: 1, stateSince: since)
    }

    @Test("the menu keeps workers and residents but removes a fish when it finishes leaving")
    func visibleRoster() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var worker = fish("worker", state: .swimming, since: now)
        worker.isFry = true
        var resident = fish("resident", state: .idling, since: now)
        resident.isResident = true
        let leaving = fish("leaving", state: .leaving, since: now)
        let failed = fish("failed", state: .sinking, since: now)
        let roster = [worker, resident, leaving, failed]
        #expect(AquariumInspection.visibleFish(roster, at: now).map(\.id)
                == ["worker", "resident", "leaving", "failed"])
        #expect(AquariumInspection.visibleFish(roster, at: now.addingTimeInterval(AquariumModel.leaveDuration))
            .map(\.id) == ["worker", "resident", "failed"])
    }

    @Test("menu labels describe the session state and mark disconnected readings")
    func statusLabels() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let statuses: [(FishState, String)] = [
            (.swimming, "Working"), (.idling, "Idle"), (.surfacing, "Needs you"),
            (.sinking, "Failed"), (.leaving, "Finished"),
        ]
        for (state, word) in statuses {
            let sample = fish("session", state: state, since: now)
            #expect(AquariumInspection.title(for: sample, connected: true)
                    == "Shared label · codex · \(word)")
            #expect(AquariumInspection.title(for: sample, connected: false)
                    == "Shared label · codex · \(word) · Last known")
        }
    }

    @Test("residents and workers with the same label have distinct menu descriptions")
    func roles() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var worker = fish("worker", state: .swimming, since: now)
        worker.isFry = true
        #expect(AquariumInspection.title(for: worker, connected: true)
                == "Shared label · codex · Worker · Working")
        var resident = fish("resident", state: .idling, since: now)
        resident.isResident = true
        #expect(AquariumInspection.title(for: resident, connected: false)
                == "Shared label · codex · Resident")
    }
}
