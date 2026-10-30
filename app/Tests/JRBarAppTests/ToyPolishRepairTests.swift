import AppKit
import Foundation
import IOKit.pwr_mgt
import JRBarCore
import JRBarTestSupport
import JRBarUI
import SwiftUI
import Testing
@testable import JRBarApp

@MainActor
@Suite("Toy polish repairs", .temporaryDirectory)
struct ToyPolishRepairTests {
    private func store() -> ToysStore {
        let core = CoreModel()
        return ToysStore(core: core, settings: SettingsStore(core: core), state: ToysState(),
                         cardModel: makeTestCardModel(), notchRuntimeEnabled: false,
                         nativeSourcesEnabled: false, aquariumSave: AquariumToy.scratchSave())
    }

    @Test func artGlyphsKeepReleaseProportions() {
        let cases: [(JRBarTokens.ArtGlyph, CGFloat)] = [
            (.buddyWorking, 5.4), (.miniWorking, 8.5), (.miniAsk, 7), (.buddyAsk, 5.2),
            (.buddyCrumb, 4.6), (.buddySleep, 4.5), (.buddySparkle, 5), (.buddyGear, 5.5),
        ]
        for (glyph, points) in cases {
            #expect(abs(glyph.size(figure: 18) - points) < 0.0001)
            #expect(abs(glyph.size(figure: 54) - points * 3) < 0.0001)
        }
        #expect(JRBarTokens.ArtGlyph.snailSleep.size(figure: 18, phase: 0) == 9)
        #expect(JRBarTokens.ArtGlyph.snailSleep.size(figure: 18, phase: 0.5) == 10.5)
        #expect(JRBarTokens.ArtGlyph.snailSleep.size(figure: 18, phase: 1) == 12)
    }

    @Test func closedWindowStatusAndReopenUseTheRealToy() throws {
        let owner = store()
        defer { owner.shutdown() }
        let tank = try #require(owner.aquarium)
        // The window lifecycle is under test, not this Mac's power source.
        tank.power = { .normal }
        #expect(tank.status == .off)
        tank.showAquarium()
        #expect(tank.isOn && tank.ownsWindow && tank.game.windowOpen)
        #expect(tank.status == .on)
        tank.closeWindow()
        #expect(tank.isOn && !tank.ownsWindow && !tank.game.windowOpen)
        #expect(tank.status == .note("Window closed · still counting pearls"))
        tank.showAquarium()
        #expect(tank.isOn && tank.ownsWindow && tank.game.windowOpen)
        #expect(tank.status == .on)
    }

    @Test func noIdleTimerWhenOffOrAlreadyIdle() throws {
        let owner = store()
        defer { owner.shutdown() }
        let tank = try #require(owner.aquarium)
        let ambient = AquariumAmbientController(toy: tank, readIdle: { 30 })
        defer { ambient.tearDown() }
        ambient.sync()
        #expect(!ambient.hasIdleDeadline && !ambient.watchingInput)
        owner.state.aquarium.enabled = true
        owner.state.aquarium.idleFillMinutes = 10
        ambient.sync()
        #expect(ambient.hasIdleDeadline && !ambient.watchingInput)
        // A movement doesn't replace an already armed deadline.
        ambient.inputReceived()
        #expect(ambient.hasIdleDeadline)
        ambient.scheduleIdleDeadline(idle: 600)
        #expect(!ambient.hasIdleDeadline && !ambient.watchingInput)
        ambient.inputReceived()
        #expect(ambient.hasIdleDeadline)
        owner.state.aquarium.idleFillMinutes = 0
        ambient.sync()
        #expect(!ambient.hasIdleDeadline && !ambient.watchingInput)
        owner.state.aquarium.enabled = false
        ambient.inputReceived()
        #expect(!ambient.hasIdleDeadline)
    }

    @Test func deadlineUsesOnlyTheRemainingIdleTime() {
        #expect(AquariumScreensaver.deadlineDelay(enabled: true, showing: false,
                                                 idleSeconds: 42, minutes: 10) == 558)
        for idle in [600.0, 900, .nan, .infinity, -1] {
            #expect(AquariumScreensaver.deadlineDelay(enabled: true, showing: false,
                                                     idleSeconds: idle, minutes: 10) == nil)
        }
        #expect(AquariumScreensaver.deadlineDelay(enabled: false, showing: false,
                                                 idleSeconds: 0, minutes: 10) == nil)
        #expect(AquariumScreensaver.deadlineDelay(enabled: true, showing: true,
                                                 idleSeconds: 0, minutes: 10) == nil)
        #expect(AquariumScreensaver.deadlineDelay(enabled: true, showing: false,
                                                 idleSeconds: 0, minutes: 0) == nil)
    }

    @Test func fishMenuNeedsNoDeadlineForAnIdleRoster() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stable = Fish(id: "stable", label: "Resting", providerID: "codex", state: .idling,
                          lane: 0.5, speed: 0.1, direction: 1, stateSince: now)
        #expect(AquariumInspection.nextRetirement([], after: now) == nil)
        #expect(AquariumInspection.nextRetirement([stable], after: now) == nil)
        var leaving = stable
        leaving.state = .leaving
        leaving.isFry = true
        let end = now.addingTimeInterval(AquariumModel.leaveDuration)
        #expect(AquariumInspection.nextRetirement([stable, leaving], after: now) == end)
        #expect(AquariumInspection.visibleFish([stable, leaving], at: end).count == 1)
        #expect(AquariumInspection.nextRetirement([stable, leaving], after: end) == nil)
    }

    @Test func counterpartChipsNameTheOwnerOrMissingApp() {
        #expect(UtilityProviderStatus.make(name: "Ice", surface: "the menu bar", installed: true, running: true)
                == .external("Ice draws the menu bar"))
        #expect(UtilityProviderStatus.make(name: "DockDoor", surface: "the previews", installed: true, running: false)
                == .unavailable("DockDoor isn't running"))
        #expect(UtilityProviderStatus.make(name: "Ice", surface: "the menu bar", installed: false, running: false)
                == .unavailable("Ice isn't installed"))
    }

    @Test func menuBarRivalsProjectTheSharedTable() {
        #expect(MenuBarRivals.known.map(\.name) == UtilityRivals.known.filter { $0.roles.contains(.menuBar) }.map(\.name))
        #expect(UtilityRivals.running(for: .menuBar, in: [("com.jordanbaird.Ice", "Ice")]).map(\.name) == ["Ice"])
        #expect(UtilityRivals.known.first { $0.name == "Ice" }?.handoff(for: .menuBar) == .menuBar(.ice))
    }

    @Test func eachShopCategoryContainsOnlyItsItemsWithOwnedLast() {
        var game = AquariumGame()
        game.inventory[ShopItem.plant.rawValue] = 1
        for category in ShopItem.Category.allCases {
            let items = AquariumShopShelf.items(category: category, game: game)
            #expect(Set(items) == Set(ShopItem.allCases.filter { $0.category == category }))
            if let firstOwned = items.firstIndex(where: game.owns) {
                #expect(items[firstOwned...].allSatisfy(game.owns))
            }
        }
    }

    @Test func retryKeepsTheManualLeaseKindAndRemainingTime() async throws {
        let suite = ScratchDefaults.suiteName("ToyPolishRetry")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SystemTogglesStore.State(dockDriver: nil, defaults: defaults)
        state.takeAssertion = { _ in Issue.record("retry must use the connected monitor"); return nil }
        var sent: [CoreAwakeRequest?] = []
        state.sendLease = { request in sent.append(request); return .taken }
        let leases = [#"{"kind":"indefinite"}"#, #"{"kind":"agents"}"#,
                      #"{"kind":"duration","until":1800000120}"#]
        for lease in leases {
            let hold = try JSONDecoder().decode(CoreAwakeHold.self, from: Data(
                "{\"state\":\"manual\",\"active\":false,\"lease\":\(lease)}".utf8))
            state.noteDaemonHold(hold, live: true)
            state.retryAwake()
            await state.leaseTask?.value
        }
        #expect(sent.count == 3)
        #expect(sent[0]?.shape == .indefinite)
        #expect(sent[1]?.shape == .untilAgentsFinish(sessions: nil))
        #expect(sent[2]?.shape == .until(1_800_000_120), "a countdown keeps its own end")
    }
}
