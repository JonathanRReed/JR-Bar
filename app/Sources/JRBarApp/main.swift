import AppKit

// Entry point. The real work lives in AppDelegate; this file only boots AppKit
// as an accessory (menu-bar only) process.
// Line-buffer stdout so the frame lines reach a log file as they happen.
setvbuf(stdout, nil, _IOLBF, 0)
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
