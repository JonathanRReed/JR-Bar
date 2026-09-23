import Foundation
import Testing
import JRBarCore
@testable import JRBarApp

/// The level capsule as a slider: which levels a scroll may set, how far
/// a scroll moves them, and the toy writing through its level path while
/// the capsule holds. The writer is a recorder; nothing touches the
/// Mac's volume or brightness.
@Suite("Notch level scrub")
@MainActor
struct NotchLevelScrubTests {
    @Test("the key names the level, and the keyboard backlight only shows")
    func targets() {
        #expect(NotchLevelScrub.target(ofKey: NotchLevelScrub.key(for: .volume)) == .volume)
        #expect(NotchLevelScrub.target(ofKey: "level:brightness") == .brightness)
        #expect(NotchLevelScrub.target(ofKey: "level") == nil, "an unnamed level is never set")
        #expect(NotchLevelScrub.target(ofKey: "focus:on") == nil)
        #expect(NotchLevelScrub.settable(.volume))
        #expect(NotchLevelScrub.settable(.brightness))
        #expect(!NotchLevelScrub.settable(.keyboard))
    }

    @Test("a trackpad moves the fill with the fingers; a wheel moves one key step a click")
    func steps() {
        let half = Double(NotchLevelScrub.pointsPerRange / 2)
        #expect(abs(NotchLevelScrub.step(0.2, fingerDelta: CGFloat(half), precise: true) - 0.7) < 1e-9)
        #expect(NotchLevelScrub.step(0.9, fingerDelta: 100, precise: true) == 1, "clamped at the top")
        #expect(NotchLevelScrub.step(0.1, fingerDelta: -100, precise: true) == 0, "and at the bottom")
        #expect(NotchLevelScrub.step(0.5, fingerDelta: 3, precise: false) == 0.5 + 1.0 / 16.0)
        #expect(NotchLevelScrub.step(0.5, fingerDelta: -40, precise: false) == 0.5 - 1.0 / 16.0)
    }

    @Test("natural scrolling's deltas are turned back into finger travel, up positive")
    func fingerTravel() {
        // Natural: fingers down → content down → +deltaY in AppKit.
        #expect(NotchScrollFinger.travel(dx: 0, dy: 5, inverted: true).dy == -5)
        // Legacy wheel rolled up → +deltaY, and up is up.
        #expect(NotchScrollFinger.travel(dx: 0, dy: 5, inverted: false).dy == 5)
        // Natural: fingers left → content left → −deltaX.
        #expect(NotchScrollFinger.travel(dx: -4, dy: 0, inverted: true).dx == -4)
        #expect(NotchScrollFinger.travel(dx: -4, dy: 0, inverted: false).dx == 4)
    }

    private func makeToy() -> (NotchToy, ToysStore) {
        var toys = ToysState()
        toys.notch = NotchSettings(enabled: true, provider: .jrbar, islandEnabled: true)
        let core = CoreModel()
        let store = ToysStore(core: core, settings: SettingsStore(core: core),
                              state: toys, cardModel: makeTestCardModel(),
                              notchRuntimeEnabled: false)
        let toy: NotchToy = store.notch
        toy.islandVisible = true
        return (toy, store)
    }

    private func level(_ target: NotchLevelScrub.Target, _ fraction: Double,
                       muted: Bool = false) -> AlcoveNotice {
        AlcoveNotice(id: "l", kind: .level, title: "Volume", subtitle: "",
                     key: NotchLevelScrub.key(for: target), fraction: fraction, muted: muted)
    }

    @Test("a scroll over a volume capsule sets the volume and the fill follows")
    func scrubVolume() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        var written: [(NotchLevelScrub.Target, Float)] = []
        toy.levelWriter = { target, value in
            written.append((target, value))
            return true
        }
        #expect(toy.presentSystemNotice(level(.volume, 0.5)))
        #expect(toy.scrubLevel(fingerDelta: NotchLevelScrub.pointsPerRange / 4, precise: true))
        #expect(written.count == 1)
        #expect(written.first?.0 == .volume)
        #expect(abs(Double(written.first?.1 ?? 0) - 0.75) < 1e-6)
        #expect(abs((toy.activeOverlay?.fraction ?? 0) - 0.75) < 1e-9)
    }

    @Test("a muted output scrubbed up is no longer drawn muted")
    func scrubUnmutes() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        toy.levelWriter = { _, _ in true }
        toy.presentSystemNotice(level(.volume, 0.4, muted: true))
        #expect(toy.scrubLevel(fingerDelta: 22, precise: true))
        #expect(toy.activeOverlay?.muted == false)
        #expect(toy.activeOverlay?.symbol != "speaker.slash.fill")
    }

    @Test("the keyboard backlight, a refused write, and no level up leave the scroll alone")
    func scrubRefusals() {
        let (toy, store) = makeToy()
        defer { withExtendedLifetime(store) {} }
        var writes = 0
        toy.levelWriter = { _, _ in writes += 1; return false }
        #expect(!toy.scrubLevel(fingerDelta: 20, precise: true), "nothing up: the scroll is a swipe")
        toy.presentSystemNotice(level(.keyboard, 0.5))
        #expect(!toy.scrubLevel(fingerDelta: 20, precise: true))
        toy.endOverlay(settle: false)
        toy.presentSystemNotice(level(.brightness, 0.5))
        #expect(toy.scrubLevel(fingerDelta: 20, precise: true), "the scroll is still the slider's")
        #expect(writes == 1)
        #expect(toy.activeOverlay?.fraction == 0.5, "a refused write moves nothing")
    }
}
