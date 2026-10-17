import AppKit
import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// A one-line notice is as wide as its words: measured at the line's own
/// sizes, then fitted between the least and the most a lip may reach.
@Suite("Notch notice fits its copy")
@MainActor
struct NotchNoticeFitTests {
    private func line(_ title: String, _ subtitle: String, kind: AlcoveNoticeKind = .timer) -> AlcoveNotice {
        AlcoveNotice(id: title, kind: kind, title: title, subtitle: subtitle, key: title)
    }

    @Test("a short line measures short, a long one long, and both are real widths")
    func measuresTheLine() throws {
        let tea = try #require(NotchToy.copyWidth(of: line("Tea", "done")))
        let long = try #require(NotchToy.copyWidth(of: line("Claude · rename-the-fish", "finished the migration")))
        #expect(tea > 20 && tea < 60, "Tea done is about 45 pt: \(tea)")
        #expect(long > 150 && long > tea * 3, "and the long one is its own width: \(long)")
        let titleOnly = try #require(NotchToy.copyWidth(of: line("Caps Lock on", "")))
        #expect(titleOnly > 40)
        #expect(tea == tea.rounded(.up), "whole points, rounded up so the line never truncates for a fraction")
    }

    @Test("the lip for 'Tea done' is narrower than the fixed lip it was, a long line is not")
    func shortNoticeIsNarrower() throws {
        let slot: CGFloat = 185
        let fixed = NotchIslandLayout.noticeSize(slotWidth: slot, notchDepth: 32).width
        let tea = NotchIslandLayout.noticeSize(slotWidth: slot, notchDepth: 32,
                                               copyWidth: NotchToy.copyWidth(of: line("Tea", "done")))
        #expect(tea.width < fixed - 30, "\(tea.width) against \(fixed)")
        let long = NotchIslandLayout.noticeSize(
            slotWidth: slot, notchDepth: 32,
            copyWidth: NotchToy.copyWidth(of: line("Claude · rename-the-fish", "finished the migration")))
        #expect(long.width > tea.width && long.width <= slot + 2 * NotchIslandLayout.noticeMaxShoulder)
    }

    @Test("verbs and levels keep their own widths: they are not a line of words")
    func facesWithTheirOwnWidth() {
        #expect(NotchToy.copyWidth(of: line("Claude", "needs you", kind: .ask)) == nil)
        #expect(NotchToy.copyWidth(of: line("Standup", "in 5 min", kind: .meeting)) == nil)
        #expect(NotchToy.copyWidth(of: line("Volume", "", kind: .level)) == nil)
    }

    @Test("the toy measures the notice that is up, and nothing when none is")
    func toyReadsTheNoticeUp() {
        var state = ToysState()
        state.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core), state: state,
                              cardModel: makeTestCardModel(), notchRuntimeEnabled: false)
        defer { withExtendedLifetime(store) {} }
        let toy: NotchToy = store.notch
        #expect(toy.noticeCopyWidth == nil)
        toy.activeCapsule = line("Tea", "done")
        let short = toy.noticeCopyWidth
        toy.activeCapsule = line("Claude · rename-the-fish", "finished the migration")
        let long = toy.noticeCopyWidth
        #expect(short != nil && long != nil && long! > short!)
        toy.activeCapsule = nil
        toy.activeOverlay = line("Volume", "", kind: .level)
        #expect(toy.noticeCopyWidth == nil)
    }
}
