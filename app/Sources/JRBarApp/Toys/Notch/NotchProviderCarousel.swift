import Foundation
import JRBarCore

/// Provider turns keep their place when session order or recency changes.
struct NotchProviderCarousel: Equatable {
    static let interval: TimeInterval = 3
    private let turnInterval: TimeInterval

    init(interval: TimeInterval = NotchProviderCarousel.interval) {
        turnInterval = interval
    }

    private(set) var providers: [String] = []
    private(set) var current: String?
    private(set) var nextChange: TimeInterval?
    private var lastClock: TimeInterval?

    @discardableResult
    mutating func update(_ activeProviders: [String], now: TimeInterval) -> String? {
        let active = Set(activeProviders.map(ProviderID.canonical))
        let oldProviders = providers
        let oldCurrent = current
        providers = oldProviders.filter { active.contains($0) }
        providers += active.subtracting(providers).sorted()
        guard !providers.isEmpty else {
            current = nil
            nextChange = nil
            lastClock = nil
            return nil
        }
        if let oldCurrent, active.contains(oldCurrent) {
            current = oldCurrent
        } else {
            let successor = oldCurrent.flatMap { oldProviders.firstIndex(of: $0) }.flatMap { index in
                (1...oldProviders.count).map { oldProviders[(index + $0) % oldProviders.count] }
                    .first { active.contains($0) }
            }
            current = successor ?? providers.first
            nextChange = nil
        }
        guard now.isFinite, now >= Date.distantPast.timeIntervalSince1970,
              now <= Date.distantFuture.timeIntervalSince1970 else {
            nextChange = nil
            lastClock = nil
            return current
        }
        if let lastClock, now < lastClock { nextChange = nil }
        lastClock = now
        guard providers.count > 1 else {
            nextChange = nil
            return current
        }
        guard let boundary = nextChange else {
            nextChange = now + turnInterval
            return current
        }
        if now >= boundary, let current, let index = providers.firstIndex(of: current) {
            let elapsed = now - boundary
            let cycle = turnInterval * Double(providers.count)
            let turns = 1 + Int(elapsed.truncatingRemainder(dividingBy: cycle) / turnInterval)
            self.current = providers[(index + turns % providers.count) % providers.count]
            nextChange = now + turnInterval - elapsed.truncatingRemainder(dividingBy: turnInterval)
        }
        return current
    }
}
