import Foundation
import Testing
@testable import JRBarCore

/// `AquariumSaveFile` is the game's own document (docs/TOYS.md), kept
/// out of app-state.json: round-trips, tolerant decode, corrupt-file
/// recovery.
@Suite("Aquarium save file")
struct AquariumSaveTests {
    private func tempFile() -> (file: AquariumSaveFile, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "jrbar-aqtest-\(UUID().uuidString)")
            .appending(path: "aquarium-save.json")
        return (AquariumSaveFile(url: url), url)
    }

    @Test("a save round-trips every field")
    func roundTrip() throws {
        let (file, url) = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var game = AquariumGame(pearls: 42, lifetimePearls: 100, pearlProgress: 0.4,
                                themeID: "midnight", streakDays: 3,
                                lastStreakDay: 1_800_000_000)
        game.pets["a"] = FishCare(stage: 1, feedings: 2, workSeconds: 300,
                                  lastNourishedAt: 5, starvingAt: 9, lastDropAt: 7,
                                  completionGranted: true, createdAt: 4)
        game.inventory[ShopItem.snail.rawValue] = 1
        game.hats["a"] = ShopItem.hatCrown.rawValue
        game.drops = [PearlDrop(id: "d1", fishID: "a", at: 3, value: 1)]
        game.totals.feedings = 9
        game.dropSeq = 1
        try file.save(AquariumSave(game: game))
        let loaded = file.load()
        #expect(loaded.version == AquariumSave.currentVersion)
        #expect(loaded.game == game)
    }

    @Test("a missing file loads the defaults and never throws")
    func missing() {
        let (file, _) = tempFile()
        #expect(!file.exists)
        let save = file.load()
        #expect(save.version == AquariumSave.currentVersion)
        #expect(save.game == AquariumGame())
    }

    @Test("a corrupt file recovers to a fresh save")
    func corrupt() throws {
        let (file, url) = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "this is not json {".write(to: url, atomically: true, encoding: .utf8)
        #expect(file.load().game == AquariumGame())
        // Not even an object.
        try "[1,2,3]".write(to: url, atomically: true, encoding: .utf8)
        #expect(file.load().game == AquariumGame())
    }

    @Test("a partially mistyped document keeps what parses")
    func tolerant() throws {
        let (file, url) = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let json = """
        {"version": "oops",
         "game": {"pearls": 17, "themeID": "lagoon",
                  "pets": "not a dict",
                  "inventory": {"snail": 1, "not-an-item": 3},
                  "hats": {"a": "hatBeanie", "b": "not-a-hat", "c": "snail"},
                  "streakDays": -4}}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        let save = file.load()
        #expect(save.version == AquariumSave.currentVersion)
        #expect(save.game.pearls == 17)
        #expect(save.game.themeID == "lagoon")
        #expect(save.game.pets.isEmpty)                 // mistyped → default
        #expect(save.game.owns(.snail))                 // known items keep
        #expect(save.game.inventory["not-an-item"] == nil)
        #expect(save.game.hat(for: "a") == .hatBeanie)  // real hats keep
        #expect(save.game.hats["b"] == nil && save.game.hats["c"] == nil)
        #expect(save.game.streakDays == 0)              // negative clamps
    }

    @Test("the default path follows XDG_STATE_HOME")
    func xdgPath() {
        let withXDG = AquariumSaveFile.defaultURL(environment: ["XDG_STATE_HOME": "/tmp/xstate"])
        #expect(withXDG.path == "/tmp/xstate/jrbar/aquarium-save.json")
        let without = AquariumSaveFile.defaultURL(environment: [:])
        #expect(without.path.hasSuffix("/.local/state/jrbar/aquarium-save.json"))
    }
}
