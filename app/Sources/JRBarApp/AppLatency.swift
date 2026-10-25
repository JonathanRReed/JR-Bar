import OSLog

@MainActor
enum AppLatency {
    private static let signposter = OSSignposter(subsystem: "devin.jrbar", category: .pointsOfInterest)

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    static func end(_ name: StaticString, _ interval: OSSignpostIntervalState) {
        signposter.endInterval(name, interval)
    }
}
