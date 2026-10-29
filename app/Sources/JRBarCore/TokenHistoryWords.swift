import Foundation

public enum TokenHistoryWords {
    public static func title(_ state: String?) -> String {
        switch state {
        case "ready": "Token history ready"
        case "building": "Building token history"
        case "stale": "Token history is stale"
        case "failed": "Token history refresh failed"
        case "disk_full": "Disk full"
        case "damaged": "Token history needs repair"
        case "over_cap": "Token history reached its size limit"
        case "disabled", "off": "Token history is off"
        default: "Token history unavailable"
        }
    }
}
