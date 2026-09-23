import Foundation
import JRBarCore

/// A resident's logbook (docs/TOYS.md): the fish that stayed after its
/// session left is a memory of that session, so tapping it says when it
/// swam and what the session got done — read from the daemon's own
/// history, the same rows the History window shows. Nothing is invented:
/// a session the history has already let go of says only what the tank
/// itself remembers.
struct AquariumResidentLog: Equatable {
    /// "Swam 3 Sep – 5 Sep", "Swam 3 Sep", "In the tank since 3 Sep".
    var swam: String
    /// "Finished 3 runs · 2 asks answered · longest run 14 min"; nil when
    /// the history has nothing on it.
    var record: String?

    static func make(sessionID: String, care: FishCare?, rows: [CoreHistoryRow],
                     calendar: Calendar = .current) -> AquariumResidentLog {
        let own = rows.filter { $0.session == sessionID }.sorted { $0.at < $1.at }
        let raised = (care?.createdAt ?? 0) > 0 ? care?.createdAt : nil
        func day(_ t: Double) -> String {
            Date(timeIntervalSince1970: t).formatted(.dateTime.day().month(.abbreviated))
        }
        guard let first = own.first?.at, let last = own.last?.at else {
            return AquariumResidentLog(swam: raised.map { "In the tank since \(day($0))" }
                                       ?? "In the tank", record: nil)
        }
        let start = min(first, raised ?? first)
        let swam = calendar.isDate(Date(timeIntervalSince1970: start),
                                   inSameDayAs: Date(timeIntervalSince1970: last))
            ? "Swam \(day(start))" : "Swam \(day(start)) – \(day(last))"
        var bits: [String] = []
        let finished = own.filter { $0.kind == "completed" }
        if !finished.isEmpty {
            bits.append(finished.count == 1 ? "Finished 1 run" : "Finished \(finished.count) runs")
        }
        let answered = own.filter { $0.kind == "answered" }.count
        if answered > 0 { bits.append(answered == 1 ? "1 ask answered" : "\(answered) asks answered") }
        let failed = own.filter { $0.kind == "failed" }.count
        if failed > 0 { bits.append(failed == 1 ? "1 failed" : "\(failed) failed") }
        if let longest = finished.compactMap(\.duration).filter(\.isFinite).max(), longest >= 60 {
            bits.append("longest run \(BuddyPalCard.duration(longest))")
        }
        return AquariumResidentLog(swam: swam, record: bits.isEmpty ? nil : bits.joined(separator: " · "))
    }
}
