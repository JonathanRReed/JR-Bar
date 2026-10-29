import Foundation

/// Event titles shared by History and the light log. Unknown wire kinds stay in diagnostics.
public enum EventKindWords {
    public static let titles: [String: String] = [
        "event": "Event",
        "ask_opened": "Asked for input",
        "ask_resolved": "Ask answered",
        "started": "Session started",
        "ended": "Session ended",
        "completed": "Session completed",
        "failed": "Session failed",
        "session_failed": "Session failed",
        "escalation_stage": "Escalation changed",
        "quota_crossed": "Quota threshold crossed",
        "quota_reset": "Quota reset",
        "quota_pace": "Quota running low",
        "device_connected": "Device connected",
        "device_disconnected": "Device disconnected",
        "peer_arrived": "Peer connected",
        "peer_departed": "Peer disconnected",
        "deck_receipt": "Deck action result",
        "deck_input": "Deck control used",
        "deck_device": "Deck connection changed",
        "power": "Keep Awake changed",
        "milestone": "Completion milestone",
        "reset_save_failed": "Quota reset could not be saved",
        "reset_saved": "Quota reset saved",
        "confetti": "Confetti requested",
        "open_window": "Window requested",
        "reveal_ask": "Ask selected",
        "usage_history_ready": "Token history ready",
        "usage_history_failed": "Token history refresh failed",
    ]

    public static func title(_ kind: String) -> String { titles[kind] ?? "Other event" }
}
