import AppKit

// Entry point. The real work lives in AppDelegate; this file only boots AppKit
// as an accessory (menu-bar only) process.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
