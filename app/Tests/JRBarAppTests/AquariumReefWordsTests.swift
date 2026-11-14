import Foundation
import SwiftUI
import Testing
import JRBarCore
@testable import JRBarApp

/// The Reef page's sentences and the one fact the tank derives itself:
/// which asks closed while their session lived.
@Suite("Aquarium reef words")
@MainActor
struct AquariumReefWordsTests {
    @Test("an ask is settled when it is gone and its session is still here and neither ended nor failed")
    func settledAsks() {
        let before = ["ask-a": "s1", "ask-b": "s2", "ask-c": "s3", "ask-d": "s4", "ask-e": "s5"]
        let activities: [String: SessionActivity] = [
            "s1": .working,   // answered, the agent carried on
            "s2": .ended,     // the session left with its ask
            "s3": .failed,    // the run failed with the ask open
            "s5": .waiting,   // still open
        ]
        let settled = AquariumToy.settledAsks(before: before, open: ["ask-e": "s5"], activities: activities)
        #expect(settled == ["ask-a"], "ask-d's session is gone from the list, so nobody saw how it closed")
        #expect(AquariumToy.settledAsks(before: before, open: before, activities: activities).isEmpty)
        #expect(AquariumToy.settledAsks(before: [:], open: [:], activities: activities).isEmpty)
        // A run that finished after its ask was answered still counts.
        #expect(AquariumToy.settledAsks(before: ["x": "s9"], open: [:], activities: ["s9": .done]) == ["x"])
        // An ask whose id changed under it is the same ask, still open.
        #expect(AquariumToy.settledAsks(before: ["old-id": "s1"], open: ["request:v1:new": "s1"],
                                        activities: activities).isEmpty)
    }

    @Test("pearl amounts read as whole numbers from a hundred up and one decimal below, never with a trailing zero")
    func pearlWords() {
        #expect(TankReefWords.pearls(12) == "12")
        #expect(TankReefWords.pearls(13.5) == "13.5")
        #expect(TankReefWords.pearls(13.46) == "13.5")
        #expect(TankReefWords.pearls(96.04) == "96")
        #expect(TankReefWords.pearls(431.6) == "432")
        #expect(TankReefWords.pearls(.nan) == "0")
    }

    @Test("each builder's line says what it pays in words, or what opens it")
    func builderLines() {
        var game = AquariumGame(pearls: 30)
        #expect(TankReefWords.line(.kelp, game: game) == "12 pearls an agent-hour. Doubles at level 10.")
        #expect(TankReefWords.line(.oyster, game: game) == "5 pearls a finished run. Doubles at level 10.")
        #expect(TankReefWords.line(.anemone, game: game)
                == "Opens at tank level 2. Pays when an ask is settled and its session carries on.")
        game.lifetimePearls = 150
        #expect(TankReefWords.line(.anemone, game: game)
                == "Pays when an ask is settled and its session carries on. The first level pays 3 pearls an answered ask.")
        game.reef.bought = ["kelp": 9]
        game.reef.harvest = ["kelp": 41.7]
        #expect(TankReefWords.line(.kelp, game: game) == "96 pearls an agent-hour. Doubles at level 25. 41 waiting.")
        // Tank level 2 holds eleven levels.
        game.reef.bought = ["kelp": 10]
        game.reef.harvest = [:]
        #expect(TankReefWords.line(.kelp, game: game)
                == "104 pearls an agent-hour. As big as this tank holds; level 12 opens with the next tank level.")
    }

    @Test("the care line counts what the tank really has, and explains the rule when it has nothing")
    func careLine() {
        var game = AquariumGame()
        #expect(TankReefWords.care(game).hasPrefix("Every builder pays more in a tank that is looked after"))
        game.inventory = ["rock": 1, "plant": 1, "snail": 1]
        game.streakDays = 3
        game.pets = ["a": FishCare(stage: 2), "b": FishCare(stage: 1)]
        #expect(TankReefWords.care(game)
                == "This tank adds 13 % to every builder: 1 raised fish, a 3-day streak, 2 decor pieces.")
    }

    @Test("the bed in the tank grows with the kelp level and lights a pod for each doubling of the harvest")
    func bedInTheTank() {
        #expect(AquariumView.reefBedHeight(level: 1) == 70)
        #expect(AquariumView.reefBedHeight(level: 4) == 100)
        #expect(AquariumView.reefBedHeight(level: 200) == 132, "it settles at its full height")
        var last = 0.0
        for level in 1...60 {
            let height = AquariumView.reefBedHeight(level: level)
            #expect(height >= last)
            last = height
        }
        #expect(AquariumView.reefBedBlades(level: 1) == 3)
        #expect(AquariumView.reefBedBlades(level: 5) == 4)
        #expect(AquariumView.reefBedBlades(level: 100) == 9)
        #expect(AquariumView.reefPods(waiting: 0) == 0)
        #expect(AquariumView.reefPods(waiting: 1) == 1)
        #expect(AquariumView.reefPods(waiting: 19) == 1)
        #expect(AquariumView.reefPods(waiting: 20) == 2)
        #expect(AquariumView.reefPods(waiting: 79) == 3)
        #expect(AquariumView.reefPods(waiting: 80) == 4)
        #expect(AquariumView.reefPods(waiting: 1_000_000) == 6)
    }

    @Test("the bed takes a tap only while a harvest waits")
    func bedTapBox() {
        var fixture = AquariumView.Fixture(fish: [], game: AquariumGame(), night: 0)
        let empty = AquariumView(fixture: fixture)
        _ = ImageRenderer(content: Canvas { c, size in empty.drawReefBed(canvas: &c, size: size, t: 0) }
            .frame(width: 600, height: 400)).cgImage
        #expect(empty.motion.reefBox == nil)
        fixture.game?.reef.harvest = ["kelp": 45]
        let ready = AquariumView(fixture: fixture)
        _ = ImageRenderer(content: Canvas { c, size in ready.drawReefBed(canvas: &c, size: size, t: 0) }
            .frame(width: 600, height: 400)).cgImage
        let box = ready.motion.reefBox
        #expect(box != nil)
        #expect(box.map { $0.contains(CGPoint(x: 600 * AquariumView.reefBedX, y: $0.midY)) } == true)
        #expect(ready.motion.reefPods.count == 3)
    }

    @Test("a fish near the pointer looks at it, in its own mirrored space, and one far from it looks ahead")
    func gaze() {
        let fish = CGPoint(x: 100, y: 100)
        #expect(AquariumView.gaze(from: fish, to: nil, facing: 1, reach: 200) == nil)
        #expect(AquariumView.gaze(from: fish, to: CGPoint(x: 400, y: 100), facing: 1, reach: 200) == nil)
        let ahead = AquariumView.gaze(from: fish, to: CGPoint(x: 200, y: 100), facing: 1, reach: 200)
        #expect(ahead == CGVector(dx: 1, dy: 0))
        // The same pointer, for a fish swimming the other way, is behind it.
        let behind = AquariumView.gaze(from: fish, to: CGPoint(x: 200, y: 100), facing: -1, reach: 200)
        #expect(behind == CGVector(dx: -1, dy: 0))
        let below = AquariumView.gaze(from: fish, to: CGPoint(x: 100, y: 180), facing: -1, reach: 200)
        #expect(below == CGVector(dx: 0, dy: 1))
        // Right on top of the fish the eye eases back to centre.
        let close = AquariumView.gaze(from: fish, to: CGPoint(x: 111, y: 100), facing: 1, reach: 200)
        #expect(close.map { $0.dx > 0.2 && $0.dx < 0.3 } == true)
        #expect(AquariumView.gaze(from: fish, to: fish, facing: 1, reach: 200) == nil)
    }
}

