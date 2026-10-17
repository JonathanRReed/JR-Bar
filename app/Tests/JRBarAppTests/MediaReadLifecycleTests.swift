import Testing
import JRBarCore
@testable import JRBarApp

@MainActor
@Suite("Media read lifecycle")
struct MediaReadLifecycleTests {
    @Test("helper takeover rejects old empty and nonempty bridge answers",
          arguments: [false, true])
    func helperTakeover(_ hasTrack: Bool) {
        let monitor = AlcoveMediaMonitor()
        monitor.markRunning(true)
        var reported: [AlcoveMedia?] = []
        monitor.onChange = { reported.append($0) }
        let oldRead = monitor.beginBridgeRead()
        let current = AlcoveMedia(title: "Current helper track", playing: true)
        monitor.markAdapterLive(true)
        monitor.adapterDidReport(current)
        oldRead(hasTrack ? AlcoveMedia(title: "Old bridge track", playing: false) : nil)
        #expect(reported == [current])
    }

    @Test("helper failure does not revive a read retired by takeover",
          arguments: [false, true])
    func helperFailsAfterTakeover(_ hasTrack: Bool) {
        let monitor = AlcoveMediaMonitor()
        monitor.markRunning(true)
        var reported: [AlcoveMedia?] = []
        monitor.onChange = { reported.append($0) }
        let oldRead = monitor.beginBridgeRead()
        let current = AlcoveMedia(title: "Helper track", playing: true)
        monitor.markAdapterLive(true)
        monitor.adapterDidReport(current)
        monitor.markAdapterLive(false)
        oldRead(hasTrack ? AlcoveMedia(title: "Retired bridge track", playing: false) : nil)
        #expect(reported == [current])
        let fallback = AlcoveMedia(title: "Fresh fallback", playing: true)
        monitor.beginBridgeRead()(fallback)
        #expect(reported == [current, fallback])
    }

    @Test("stopped reads cannot publish after restart")
    func stopAndRestart() {
        let monitor = AlcoveMediaMonitor()
        monitor.markRunning(true)
        var reported: [AlcoveMedia?] = []
        monitor.onChange = { reported.append($0) }
        let oldRead = monitor.beginBridgeRead()
        monitor.stop()
        oldRead(AlcoveMedia(title: "Stopped", playing: true))
        #expect(reported == [nil])
        monitor.markRunning(true)
        oldRead(AlcoveMedia(title: "Previous run", playing: true))
        #expect(reported == [nil])
        let current = AlcoveMedia(title: "New run", playing: true)
        monitor.beginBridgeRead()(current)
        #expect(reported == [nil, current])
    }

    @Test("a newer bridge read retires earlier completions")
    func overlappingReads() {
        let monitor = AlcoveMediaMonitor()
        monitor.markRunning(true)
        var reported: [AlcoveMedia?] = []
        monitor.onChange = { reported.append($0) }
        let older = monitor.beginBridgeRead()
        let newer = monitor.beginBridgeRead()
        older(AlcoveMedia(title: "Old", playing: true))
        #expect(reported.isEmpty)
        let current = AlcoveMedia(title: "Latest", playing: true)
        newer(current)
        older(nil)
        #expect(reported == [current])
    }

    @Test("a current fallback read publishes media and empty results")
    func currentFallback() {
        let monitor = AlcoveMediaMonitor()
        monitor.markRunning(true)
        var reported: [AlcoveMedia?] = []
        monitor.onChange = { reported.append($0) }
        let current = AlcoveMedia(title: "Fallback", playing: true)
        monitor.beginBridgeRead()(current)
        monitor.beginBridgeRead()(nil)
        #expect(reported == [current, nil])
    }
}
