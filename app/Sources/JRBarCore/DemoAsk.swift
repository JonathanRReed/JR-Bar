import Foundation

/// The "Try it" ask: a made-up ask the app draws in the real ask card so
/// a person can see Approve and Deny, the destructive mark and the
/// expanding chevron, and where an ask appears, before an agent ever asks.
///
/// It is made inside the app. The daemon never hears of it, no agent is
/// behind it, it is not in `state.asks`, History or usage, and answering
/// it sends nothing anywhere. It is labelled as a demo in its summary, its
/// label and its tint, so it cannot be mistaken for a real ask.
public enum DemoAsk {
    /// The made-up session it belongs to. No provider ever has this id.
    public static let sessionID = "jrbar-demo:try-it"
    public static let requestID = "jrbar-demo-request"

    /// What the card says it is.
    public static let label = "Demo"
    public static let summary = "Demo — this answers nothing"
    /// A short word for a surface with room for one line.
    public static let badge = "DEMO"

    /// How long it waits before it puts itself away: nobody has to click it off.
    public static let lifetime: TimeInterval = 600

    /// Said once it has been answered or dismissed.
    public static let answeredLine = "That was a demo — nothing was sent to any agent."
    public static let dismissedLine = "Demo put away."

    /// What a person is told it shows.
    public static let whereLine = "Real asks look like this in the panel and on the notch, and the menu bar icon marks one."

    /// The made-up command the demo expands to: multi-line, and
    /// destructive-looking so the risk mark is on the card, but pointed at
    /// a folder that does not exist.
    public static let command = "cd ~/demo-project\nrm -rf ./build-that-does-not-exist\nnpm ci && npm run build"

    /// A fresh demo ask, "opened" at `now`.
    public static func make(now: Date) -> CoreAsk {
        CoreAsk(session: sessionID, kind: "permission", openedAt: now.timeIntervalSince1970, summary: summary,
                answerable: true, replyable: false, request: requestID,
                decision: CoreAskDecision(holdUntil: nil, always: false, decided: false, choices: []),
                preview: "rm -rf ./build-that-does-not-exist", risk: "destructive",
                detail: CoreAskDetail(command: command, truncated: false))
    }

    public static func isDemo(session: String?) -> Bool { session == sessionID }
}

extension CoreAsk {
    /// The Try it ask (`DemoAsk`). Whatever else a surface does with an
    /// ask, it never sends this one anywhere.
    public var isDemo: Bool { session == DemoAsk.sessionID || request == DemoAsk.requestID }
}
