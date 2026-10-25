import AppKit
import OSLog
import SwiftUI

enum LayoutDiagnostics {
    private static let log = Logger(subsystem: "devin.jrbar", category: "layout")
    private static let lock = NSLock()
    private nonisolated(unsafe) static var reported: Set<String> = []
    private nonisolated(unsafe) static var output: (@Sendable (String) -> Void)?
    static var sink: (@Sendable (String) -> Void)? {
        get { lock.withLock { output } }
        set { lock.withLock { output = newValue } }
    }

    static func check(_ size: CGSize, viewType: @autoclosure () -> String, phase: String) {
        guard !size.width.isFinite || !size.height.isFinite || size.width < 0 || size.height < 0 else { return }
        let viewType = viewType()
        let key = viewType + ":" + phase
        let emit = lock.withLock {
            reported.count < 64 && reported.insert(key).inserted
        }
        guard emit else { return }
        let line = "invalid layout \(viewType) \(phase) proposed=\(size.width)x\(size.height)"
        sink?(line)
        log.error("\(line, privacy: .public)")
    }

    static func nonnegative(_ value: CGFloat) -> CGFloat { value.isFinite ? max(0, value) : 0 }
}

struct CheckedContent<Content: View>: View {
    let content: Content
    var body: some View {
        CheckedLayout(viewType: String(reflecting: Content.self)) { content }
    }
}

/// Checks both sides of the hosting boundary once per view type.
struct CheckedLayout: Layout {
    let viewType: String

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposed = CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
        // An unspecified dimension and infinity are legitimate proposals.
        if proposed.width < 0 || proposed.height < 0 || proposed.width.isNaN || proposed.height.isNaN {
            LayoutDiagnostics.check(proposed, viewType: viewType, phase: "SwiftUI proposal")
        }
        let size = subviews.first?.sizeThatFits(proposal) ?? .zero
        LayoutDiagnostics.check(size, viewType: viewType, phase: "SwiftUI result")
        return CGSize(width: LayoutDiagnostics.nonnegative(size.width), height: LayoutDiagnostics.nonnegative(size.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

final class DiagnosedHostingView<Content: View>: NSHostingView<Content> {
    override func setFrameSize(_ newSize: NSSize) {
        LayoutDiagnostics.check(newSize, viewType: String(reflecting: Content.self), phase: "AppKit frame")
        super.setFrameSize(newSize)
    }

    override func setBoundsSize(_ newSize: NSSize) {
        LayoutDiagnostics.check(newSize, viewType: String(reflecting: Content.self), phase: "AppKit bounds")
        super.setBoundsSize(newSize)
    }
}
