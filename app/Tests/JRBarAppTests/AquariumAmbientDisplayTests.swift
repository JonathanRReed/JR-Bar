import CoreGraphics
import Testing
@testable import JRBarApp

@Suite("Aquarium ambient display ownership")
struct AquariumAmbientDisplayTests {
    typealias Display = AquariumAmbientDisplays.Display

    @Test("equal display labels exclude only the actual wallpaper display")
    func duplicateLabels() throws {
        let displays = [Display(id: 101, name: "Fixture display"), Display(id: 202, name: "Fixture display")]
        let selected = try #require(AquariumAmbientDisplays.wallpaper(named: "Fixture display", among: displays))
        #expect(selected.id == 101)
        #expect(AquariumAmbientDisplays.saverIDs(displays, wallpaper: selected) == [202])
    }

    @Test("a same-name replacement updates the selected wallpaper identity")
    func replacementIdentity() throws {
        let previous = Display(id: 101, name: "Fixture display")
        let displays = [Display(id: 303, name: "Fixture display"), Display(id: 202, name: "Fixture display")]
        let selected = try #require(AquariumAmbientDisplays.wallpaper(named: previous.name, among: displays))
        #expect(selected.id == 303)
        #expect(AquariumAmbientDisplays.saverIDs(displays, wallpaper: selected) == [202])
    }

    @Test("no wallpaper or a removed selection leaves all free displays eligible")
    func absentWallpaper() {
        let displays = [Display(id: 101, name: "One"), Display(id: 202, name: "Two")]
        #expect(AquariumAmbientDisplays.wallpaper(named: nil, among: displays) == nil)
        let removed = AquariumAmbientDisplays.wallpaper(named: "Removed", among: displays)
        #expect(removed == nil)
        #expect(AquariumAmbientDisplays.saverIDs(displays, wallpaper: removed) == [101, 202])
    }

    @Test("unique display labels retain their existing target selection")
    func uniqueLabels() throws {
        let displays = [Display(id: 101, name: "One"), Display(id: 202, name: "Two")]
        let selected = try #require(AquariumAmbientDisplays.wallpaper(named: "Two", among: displays))
        #expect(selected.id == 202)
        #expect(AquariumAmbientDisplays.saverIDs(displays, wallpaper: selected) == [101])
    }

    @Test("an owned display stays excluded after a label change")
    func ownedDisplayRenamed() {
        let owned = Display(id: 101, name: "Original name")
        let displays = [Display(id: 101, name: "Renamed"), Display(id: 202, name: "Original name")]
        #expect(AquariumAmbientDisplays.saverIDs(displays, wallpaper: owned) == [202])
    }

    @Test("a stale removed identity excludes no current display with the same label")
    func removedIdentityDoesNotClaimReplacement() {
        let removed = Display(id: 101, name: "Fixture display")
        let displays = [Display(id: 303, name: "Fixture display"), Display(id: 202, name: "Other")]
        #expect(AquariumAmbientDisplays.saverIDs(displays, wallpaper: removed) == [303, 202])
    }
}
