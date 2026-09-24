import Foundation
import Testing
@testable import JRBarApp
@testable import JRBarCore

/// macOS's menu-bar layout table, read-only: the parser against a
/// fixture of the table's likely shape, the keys' owners, the order it
/// gives the Item Bar, the drop it confirms and the mismatches it flags.
/// The real file sits in a TCC-protected container no grant existed for
/// while this was built; the fixture follows Thaw's description of it
/// and a status item's own Preferred Position record (a larger position
/// sorts further left).
@Suite("Menu Bar — the layout table")
struct MenuBarLayoutTableTests {
    /// The fixture: the positions map, with a key that is a bare bundle
    /// id, keys that add an item's name, our own item, and the system's.
    static let fixture = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>TrailingItemPreferredPositions</key>
            <dict>
                <key>com.tinyspeck.slackmacgap</key><real>420</real>
                <key>com.openai.chat.Item-0</key><real>400</real>
                <key>com.jonathanreed.jrbar.status-item</key><real>300</real>
                <key>io.tailscale.ipn.macsys</key><real>280</real>
                <key>com.bjango.istatmenus:cpu</key><real>260</real>
                <key>com.bjango.istatmenus:memory</key><real>255</real>
                <key>com.apple.menuextra.wifi</key><real>246</real>
                <key>com.apple.menuextra.clock</key><real>10</real>
            </dict>
            <key>SomethingElse</key><true/>
        </dict>
        </plist>
        """

    static let apps: Set<String> = ["com.tinyspeck.slackmacgap", "com.openai.chat", "io.tailscale.ipn.macsys",
                                    "com.bjango.istatmenus"]
    static let ours = "com.jonathanreed.jrbar"

    @Test("the fixture parses left to right — a larger position sorts further left")
    func parseFixture() throws {
        let table = try #require(MenuBarLayoutTable.parse(Data(Self.fixture.utf8)))
        #expect(table.entries.map(\.key) == [
            "com.tinyspeck.slackmacgap", "com.openai.chat.Item-0", "com.jonathanreed.jrbar.status-item",
            "io.tailscale.ipn.macsys", "com.bjango.istatmenus:cpu", "com.bjango.istatmenus:memory",
            "com.apple.menuextra.wifi", "com.apple.menuextra.clock",
        ])
        #expect(table.entries.first?.position == 420)
        // Binary plists read the same.
        let root = try PropertyListSerialization.propertyList(from: Data(Self.fixture.utf8), format: nil)
        let binary = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        #expect(MenuBarLayoutTable.parse(binary) == table)
    }

    @Test("the other likely shapes parse; anything else is nil")
    func otherShapes() throws {
        // A list of keys from the trailing edge reads right to left.
        let list = try PropertyListSerialization.data(
            fromPropertyList: ["TrailingItemPreferredPositions": ["clock", "wifi", "a.app"]],
            format: .xml, options: 0)
        #expect(MenuBarLayoutTable.parse(list)?.entries.map(\.key) == ["a.app", "wifi", "clock"])
        // A list of records with positions.
        let records = try PropertyListSerialization.data(
            fromPropertyList: ["TrailingItemPreferredPositions": [
                ["identifier": "b.app", "position": 10], ["identifier": "a.app", "position": 20]]],
            format: .xml, options: 0)
        #expect(MenuBarLayoutTable.parse(records)?.entries.map(\.key) == ["a.app", "b.app"])
        #expect(MenuBarLayoutTable.parse(Data("not a plist".utf8)) == nil)
        let empty = try PropertyListSerialization.data(
            fromPropertyList: ["TrailingItemPreferredPositions": [String: Int]()], format: .xml, options: 0)
        #expect(MenuBarLayoutTable.parse(empty) == nil)
    }

    @Test("a key belongs to the longest known bundle id it starts with, before a separator")
    func keyOwners() {
        let known: Set<String> = ["com.bjango.istatmenus", "com.bjango", "com.openai.chat", Self.ours]
        #expect(MenuBarLayoutTable.bundleID(forKey: "com.bjango.istatmenus:cpu", known: known)
                == "com.bjango.istatmenus")
        #expect(MenuBarLayoutTable.bundleID(forKey: "com.openai.chat.Item-0", known: known) == "com.openai.chat")
        #expect(MenuBarLayoutTable.bundleID(forKey: "com.openai.chatter", known: known) == nil,
                "a longer word is not the same app")
        #expect(MenuBarLayoutTable.bundleID(forKey: "com.jonathanreed.jrbar.status-item", known: known) == Self.ours)
    }

    @Test("the table orders the Item Bar and confirms a drop by the side of our slot")
    func orderAndConfirm() throws {
        let table = try #require(MenuBarLayoutTable.parse(Data(Self.fixture.utf8)))
        let rankOf = MenuBarLayoutTable.ranks(apps: Self.apps, table: table)
        #expect(rankOf["com.tinyspeck.slackmacgap"] == 0)
        #expect(rankOf["com.openai.chat"] == 1)
        #expect(rankOf["io.tailscale.ipn.macsys"] == 3)
        #expect(rankOf["com.bjango.istatmenus"] == 4)
        #expect(MenuBarLayoutTable.side(of: "com.openai.chat", ours: Self.ours, table: table, known: Self.apps) == .left)
        #expect(MenuBarLayoutTable.side(of: "io.tailscale.ipn.macsys", ours: Self.ours, table: table,
                                        known: Self.apps) == .right)
        #expect(MenuBarLayoutTable.confirms(app: "com.openai.chat", section: .hidden, ours: Self.ours,
                                            table: table, known: Self.apps))
        #expect(!MenuBarLayoutTable.confirms(app: "io.tailscale.ipn.macsys", section: .hidden, ours: Self.ours,
                                             table: table, known: Self.apps))
        #expect(MenuBarLayoutTable.confirms(app: "io.tailscale.ipn.macsys", section: .shown, ours: Self.ours,
                                            table: table, known: Self.apps))
        #expect(!MenuBarLayoutTable.confirms(app: "gone.app", section: .shown, ours: Self.ours,
                                             table: table, known: Self.apps), "an app the table never names")
        // The Item Bar's order under the concealer follows the ranks.
        let order = MenuBarUtility.concealedOrder(
            apps: ["io.tailscale.ipn.macsys": .hidden, "com.openai.chat": .hidden, "x.app": .hidden],
            lastX: rankOf.mapValues { CGFloat($0) })
        #expect(order.map(\.id) == ["com.openai.chat", "io.tailscale.ipn.macsys", "x.app"])
    }

    @Test("under the slot seat a hidden app right of our slot and a shown app left of it are flagged, each with its fix")
    func mismatches() throws {
        let table = try #require(MenuBarLayoutTable.parse(Data(Self.fixture.utf8)))
        let sections: [String: MenuBarItemSection] = [
            "io.tailscale.ipn.macsys": .hidden,          // right of us — a reveal shows it there
            "com.openai.chat": .hidden,                  // left of us — as it should be
            "com.bjango.istatmenus": .shown,             // right of us — as it should be
        ]
        let found = MenuBarLayoutTable.mismatches(table: table, sections: sections, apps: Self.apps,
                                                  ours: Self.ours, seat: .slot)
        // Slack is left of us with no pick at all: shown, flagged.
        #expect(found.map(\.app) == ["com.tinyspeck.slackmacgap", "io.tailscale.ipn.macsys"])
        #expect(found.map(\.fix) == [.hidden, .shown])
        #expect(MenuBarLayoutTableRows.words(found[1], name: "Tailscale").contains("hidden but sits right"))
        // Under the gap seat the icon stands flush left of the drawn run,
        // not on our slot: the slot's sides say nothing about the icon's,
        // so nothing is flagged — never "Hide it" for an app shown right
        // of the icon.
        #expect(MenuBarLayoutTable.mismatches(table: table, sections: sections, apps: Self.apps,
                                              ours: Self.ours, seat: .gap).isEmpty)
    }
}
