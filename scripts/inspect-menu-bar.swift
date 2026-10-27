// Read Accessibility geometry without opening windows or changing the bar.
// Run with: swift scripts/inspect-menu-bar.swift > /tmp/menu-bar.json
import AppKit
import ApplicationServices

func read(_ element: AXUIElement, _ name: String) -> (CFTypeRef?, AXError) {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (value, error)
}

func geometry(_ element: AXUIElement) -> [CGFloat]? {
    let (position, _) = read(element, kAXPositionAttribute)
    let (size, _) = read(element, kAXSizeAttribute)
    guard let position, let size,
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
          AXValueGetType(position as! AXValue) == .cgPoint,
          AXValueGetType(size as! AXValue) == .cgSize else { return nil }
    var point = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
    return [point.x, point.y, extent.width, extent.height]
}

func items(_ element: AXUIElement, depth: Int = 0) -> [[String: Any]] {
    guard depth < 3 else { return [] }
    AXUIElementSetMessagingTimeout(element, 0.3)
    let (roleValue, _) = read(element, kAXRoleAttribute)
    let role = roleValue as? String ?? ""
    if role == kAXMenuBarItemRole || role == kAXButtonRole {
        var row: [String: Any] = ["role": role]
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, "AXIdentifier"] {
            if let value = read(element, attribute).0 as? String { row[attribute] = value }
        }
        if let frame = geometry(element) { row["frame"] = frame }
        return [row]
    }
    // Extras bars and their groups only. Never descend into an app menu.
    guard depth == 0 || role == kAXGroupRole else { return [] }
    let (children, error) = read(element, kAXChildrenAttribute)
    guard error == .success, let children = children as? [AXUIElement] else {
        return [["childrenError": error.rawValue]]
    }
    return children.flatMap { items($0, depth: depth + 1) }
}

let startedAt = ISO8601DateFormatter().string(from: Date())
var owners: [[String: Any]] = []
if AXIsProcessTrusted() {
    for app in NSWorkspace.shared.runningApplications {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        let (extras, error) = read(element, "AXExtrasMenuBar")
        var owner: [String: Any] = [
            "pid": app.processIdentifier, "name": app.localizedName ?? "",
            "bundleID": app.bundleIdentifier ?? "", "extrasError": error.rawValue,
        ]
        if let extras, CFGetTypeID(extras) == AXUIElementGetTypeID() {
            owner["items"] = items(extras as! AXUIElement)
        }
        owners.append(owner)
    }
}
let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
let screens: [[String: Any]] = NSScreen.screens.map { screen in
    ["name": screen.localizedName,
     "frame": [screen.frame.minX, mainHeight - screen.frame.maxY, screen.frame.width, screen.frame.height],
     "barHeight": NSStatusBar.system.thickness]
}
let result: [String: Any] = [
    "startedAt": startedAt, "finishedAt": ISO8601DateFormatter().string(from: Date()),
    "accessibilityTrusted": AXIsProcessTrusted(), "system": ProcessInfo.processInfo.operatingSystemVersionString,
    "screens": screens, "owners": owners,
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
