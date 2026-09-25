import Foundation

/// The dates to hand `TimelineView(.explicit(…))` so it updates at
/// exactly the moments asked for. Measured on macOS 26 (a live
/// `NSHostingView`, 2026-09-24), an explicit schedule has two edges:
///
/// * with no date at or before now, the first render reads the FIRST
///   date as its `context.date`, though it lies in the future — a view
///   that draws "as of the context's date" draws the future;
/// * the LAST date never fires.
///
/// So every schedule here opens with a date already past and closes
/// with one that never comes: the first render reads the past one, and
/// each real moment fires with its own date.
enum ExplicitTimeline {
    static func moments(_ dates: [Date]) -> [Date] {
        guard !dates.isEmpty else { return [] }
        return [.distantPast] + dates.sorted() + [.distantFuture]
    }
}
