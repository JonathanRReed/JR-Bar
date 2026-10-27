import JRBarCore
import SwiftUI

/// Orange is reserved for an ask or a quota warning.
public enum Tone: CaseIterable, Hashable, Sendable {
    case ask, warning, failure, stale, reset, done, live, working, neutral

    public var color: Color {
        switch self {
        case .ask, .warning: JRBarTokens.Ink.attention
        case .failure: JRBarTokens.Ink.failure
        case .stale: JRBarTokens.Ink.stale
        case .reset: JRBarTokens.Ink.reset
        case .done: JRBarTokens.Ink.done
        case .live: JRBarTokens.Ink.live
        case .working: JRBarTokens.Ink.working
        case .neutral: JRBarTokens.Ink.secondary
        }
    }
}

/// A state has one badge layout, regardless of the page that reports it.
public struct StatusBadge: View {
    public let text: String
    private let tint: Color
    private let symbol: String?

    public init(_ text: String, tone: Tone = .neutral, symbol: String? = nil) {
        self.init(text, tint: tone.color, symbol: symbol)
    }

    public init(_ text: String, tint: Color, symbol: String? = nil) {
        self.text = text
        self.tint = tint
        self.symbol = symbol
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
            } else {
                Circle().fill(tint).frame(width: 6, height: 6)
            }
            Text(text).lineLimit(1).truncationMode(.tail)
        }
        .jrbarType(.caption).fontWeight(.medium)
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(tint.opacity(0.13), in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
