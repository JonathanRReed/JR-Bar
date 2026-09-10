import Foundation

/// The panel's geometry, computed once from what it will show rather
/// than measured after the fact. Every row has a fixed height and every
/// label is one line, so the window can be sized before it is shown and
/// the only thing that ever changes it is the content itself (rows coming
/// and going), never a late relayout.
///
/// Sessions and Usage are the two lists that grow: each has a natural cap
/// (a list longer than that scrolls, cut half a row from the end so the
/// scroll is visible), and when the whole panel would exceed
/// `screenFraction` of the screen the two give up rows in turn, whichever
/// is closer to its own cap first, each down to a floor.
public struct PanelLayout: Hashable, Sendable {
    public static let width: Double = 360

    // Fixed parts, in points, top to bottom.
    public static let headerHeight: Double = 40
    public static let hairline: Double = 1
    public static let sectionLabelHeight: Double = 26
    public static let sessionsBottomPadding: Double = 4
    public static let whyRowHeight: Double = 30
    /// "3 earlier in History →" under the Sessions list when the daemon
    /// keeps acknowledged sessions out of `state.sessions`.
    public static let hiddenFooterHeight: Double = 24
    public static let usageBottomPadding: Double = 6
    public static let devicesHeight: Double = 82
    public static let footerHeight: Double = 34

    // Rows.
    public static let sessionRowHeight: Double = 44
    public static let askRowHeight: Double = 92
    public static let rowSpacing: Double = 1
    public static let listBottomPadding: Double = 6
    public static let emptySessionsHeight: Double = 60
    public static let usageRowHeight: Double = 50
    public static let usageRowSpacing: Double = 2
    public static let emptyUsageHeight: Double = 24

    /// Natural caps and floors, in rows; a scrolling list ends half a row in.
    public static let sessionsMaxRows: Double = 7.5
    public static let sessionsMinRows: Double = 2.5
    public static let usageMaxRows: Double = 3.5
    public static let usageMinRows: Double = 1.5
    public static let screenFraction: Double = 0.7

    /// What the panel is about to show.
    public struct Content: Hashable, Sendable {
        public var asks: Int
        public var sessions: Int
        public var hasWhyRow: Bool
        public var usageProviders: Int
        /// `state.hidden_count > 0`: the History footer row is shown.
        public var hasHiddenFooter: Bool

        public init(asks: Int = 0, sessions: Int = 0, hasWhyRow: Bool = false, usageProviders: Int = 0, hasHiddenFooter: Bool = false) {
            self.asks = asks
            self.sessions = sessions
            self.hasWhyRow = hasWhyRow
            self.usageProviders = usageProviders
            self.hasHiddenFooter = hasHiddenFooter
        }

        public var sessionsEmpty: Bool { asks + sessions == 0 }
    }

    public var content: Content
    /// The Sessions list's viewport; `sessionsScroll` when the rows are taller.
    public var sessionsHeight: Double
    public var sessionsScroll: Bool
    public var usageHeight: Double
    public var usageScroll: Bool
    public var totalHeight: Double
    public var maxHeight: Double

    /// The Sessions list's full content height (asks, rows, spacing, padding).
    public static func sessionsContentHeight(_ content: Content) -> Double {
        if content.sessionsEmpty { return emptySessionsHeight }
        let rows = Double(content.asks + content.sessions)
        return Double(content.asks) * askRowHeight + Double(content.sessions) * sessionRowHeight
            + max(0, rows - 1) * rowSpacing + listBottomPadding
    }

    public static func usageContentHeight(_ content: Content) -> Double {
        if content.usageProviders == 0 { return emptyUsageHeight }
        let rows = Double(content.usageProviders)
        return rows * usageRowHeight + max(0, rows - 1) * usageRowSpacing
    }

    /// Everything but the two lists.
    public static func fixedHeight(_ content: Content) -> Double {
        headerHeight + hairline
            + sectionLabelHeight + (content.hasHiddenFooter ? hiddenFooterHeight : 0) + (content.hasWhyRow ? whyRowHeight : 0) + sessionsBottomPadding + hairline
            + sectionLabelHeight + usageBottomPadding + hairline
            + devicesHeight + hairline
            + footerHeight
    }

    public static func maxHeight(screenHeight: Double) -> Double {
        (screenHeight * screenFraction).rounded(.down)
    }

    /// A viewport of `rows` rows (a whole number plus a half, so a cut list
    /// shows half a row and reads as scrollable).
    static func viewport(rows: Double, rowHeight: Double, spacing: Double) -> Double {
        (rows * (rowHeight + spacing) - spacing).rounded()
    }

    /// The natural row count for a list: every row when it fits under the
    /// cap, else the cap's whole-plus-half rows.
    static func naturalRows(contentRows: Int, maxRows: Double) -> Double {
        Double(contentRows) <= maxRows ? Double(contentRows) : maxRows
    }

    public static func compute(content: Content, screenHeight: Double) -> PanelLayout {
        let cap = maxHeight(screenHeight: screenHeight)
        let fixed = fixedHeight(content)
        let sessionsContent = sessionsContentHeight(content)
        let usageContent = usageContentHeight(content)

        // Rows shown of each list, whole-plus-half once a list is cut.
        var sessionRows = naturalRows(contentRows: content.asks + content.sessions, maxRows: sessionsMaxRows)
        var usageRows = naturalRows(contentRows: content.usageProviders, maxRows: usageMaxRows)
        func sessionsHeight() -> Double {
            if content.sessionsEmpty { return emptySessionsHeight }
            // Asks are taller than rows: a whole list is its content; a cut
            // list is measured in session rows from the top.
            if Double(content.asks + content.sessions) <= sessionRows { return sessionsContent }
            return min(sessionsContent, viewport(rows: sessionRows, rowHeight: sessionRowHeight, spacing: rowSpacing))
        }
        func usageHeight() -> Double {
            if content.usageProviders == 0 { return emptyUsageHeight }
            if Double(content.usageProviders) <= usageRows { return usageContent }
            return min(usageContent, viewport(rows: usageRows, rowHeight: usageRowHeight, spacing: usageRowSpacing))
        }

        // Over the cap, take a row from whichever list is closer to its own
        // cap (ties go to Usage), never below either floor.
        func next(_ rows: Double) -> Double { rows == rows.rounded(.down) ? rows - 0.5 : rows - 1 }
        var guardCount = 0
        while fixed + sessionsHeight() + usageHeight() > cap, guardCount < 64 {
            guardCount += 1
            let sessionsCanShrink = !content.sessionsEmpty && next(sessionRows) >= sessionsMinRows
            let usageCanShrink = content.usageProviders > 0 && next(usageRows) >= usageMinRows
            guard sessionsCanShrink || usageCanShrink else { break }
            let shrinkSessions = sessionsCanShrink && (!usageCanShrink || sessionRows / sessionsMaxRows > usageRows / usageMaxRows)
            if shrinkSessions { sessionRows = next(sessionRows) } else { usageRows = next(usageRows) }
        }
        let sessions = sessionsHeight()
        let usage = usageHeight()
        let total = (fixed + sessions + usage).rounded()
        return PanelLayout(content: content, sessionsHeight: sessions, sessionsScroll: sessionsContent > sessions + 0.5,
                           usageHeight: usage, usageScroll: usageContent > usage + 0.5, totalHeight: total, maxHeight: cap)
    }
}
