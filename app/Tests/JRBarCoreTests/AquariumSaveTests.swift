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
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test("a saved marathon bank loads empty — nothing ticks while the app is off")
    func marathonBankResetsOnLoad() throws {
        let (file, url) = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var game = AquariumGame(pearls: 5)
        game.continuousWorkSeconds = 4 * 3600
        game.lastWorkAt = 1_800_000_000
        try file.save(AquariumSave(game: game))
        let loaded = file.load()
        #expect(loaded.game.continuousWorkSeconds == 0)
        // The document still round-trips the field — the reset is a
        // load-time rule, not a decode-time rewrite (normalization keeps
        // the stored value, so no recovery file is owed).
        #expect(loaded.game.lastWorkAt == 1_800_000_000)
        #expect(loaded.game.pearls == 5)
        try file.save(loaded)
        #expect(try Self.recoveries(in: url.deletingLastPathComponent()).isEmpty)
    }

    @Test("a missing file loads the defaults and never throws")
    func missing() {
        let (file, _) = tempFile()
        #expect(!file.exists)
        let save = file.load()
        #expect(save.version == AquariumSave.currentVersion)
        #expect(save.game == AquariumGame())
    }

    @Test("a corrupt file reads fresh and preserves its bytes before overwrite")
    func corrupt() throws {
        let (file, url) = tempFile()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let original = Data("this is not json {".utf8)
        try original.write(to: url)
        #expect(file.load().game == AquariumGame())
        try file.save(AquariumSave(game: AquariumGame(pearls: 7)))
        #expect(file.load().game.pearls == 7)
        let backups = try Self.recoveries(in: directory)
        #expect(backups.count == 1)
        if let backup = backups.first {
            #expect(try Data(contentsOf: backup) == original)
            let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
        }
        try file.save(AquariumSave(game: AquariumGame(pearls: 8)))
        #expect(try Self.recoveries(in: directory).count == 1,
                "a healthy save must not create another recovery")
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

    @Test("wrong-typed values are preserved before tolerant defaults overwrite them")
    func wrongTypeRecovery() throws {
        let (file, url) = tempFile()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data(#"{"version":"newer","game":{"pearls":"many","future":{"kept":true}}}"#.utf8)
        try original.write(to: url)

        try file.save(file.load())

        let backups = try Self.recoveries(in: directory)
        #expect(backups.count == 1)
        if let backup = backups.first { #expect(try Data(contentsOf: backup) == original) }
    }

    @Test("a failed recovery leaves the original save untouched")
    func recoveryFailureDoesNotOverwrite() throws {
        let (file, url) = tempFile()
        let directory = url.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("{broken".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: directory.path)

        #expect(throws: (any Error).self) {
            try file.save(AquariumSave(game: AquariumGame(pearls: 99)))
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("the default path follows XDG_STATE_HOME")
    func xdgPath() {
        let withXDG = AquariumSaveFile.defaultURL(environment: ["XDG_STATE_HOME": "/tmp/xstate"])
        #expect(withXDG.path == "/tmp/xstate/jrbar/aquarium-save.json")
        let without = AquariumSaveFile.defaultURL(environment: [:])
        #expect(without.path.hasSuffix("/.local/state/jrbar/aquarium-save.json"))
    }

    @Test("a pet record missing newer keys keeps the rest of itself")
    func fishCareTolerant() throws {
        // A save written before `label`/`provider`/`completionGranted`
        // existed: the record must decode with defaults rather than
        // dropping the pet (or, through `try?`, the whole pets dict).
        let json = """
        {"game": {"pets": {
            "sess-a": {"stage": 2, "feedings": 9, "workSeconds": 9000,
                       "lastNourishedAt": 111.5, "starvingAt": 222.5,
                       "lastDropAt": 33.5, "createdAt": 44.5},
            "sess-b": {"stage": 1}}}}
        """
        let data = try #require(json.data(using: .utf8))
        let save = try JSONDecoder().decode(AquariumSave.self, from: data)
        let a = try #require(save.game.pets["sess-a"])
        #expect(a.stage == 2)
        #expect(a.feedings == 9)
        #expect(a.workSeconds == 9000)
        #expect(a.lastNourishedAt == 111.5)
        #expect(a.starvingAt == 222.5)
        #expect(a.lastDropAt == 33.5)
        #expect(a.createdAt == 44.5)
        #expect(a.completionGranted == false)
        #expect(a.label == nil)
        #expect(a.provider == nil)
        let b = try #require(save.game.pets["sess-b"])
        #expect(b.stage == 1)
        #expect(b.feedings == 0)
        // And a present label/provider still parse.
        let full = """
        {"game": {"pets": {"c": {"stage": 0, "label": "Nemo",
                                "provider": "codex",
                                "completionGranted": true}}}}
        """
        let save2 = try JSONDecoder().decode(
            AquariumSave.self, from: #require(full.data(using: .utf8)))
        let c = try #require(save2.game.pets["c"])
        #expect(c.label == "Nemo")
        #expect(c.provider == "codex")
        #expect(c.completionGranted == true)
    }

    private static func recoveries(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).filter {
                $0.lastPathComponent.hasPrefix("aquarium-save.recovery-")
            }
    }
}
