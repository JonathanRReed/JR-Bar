// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Command Line Tools without Xcode ship swift-testing in places the default
// build does not look (the macro plugin is not auto-resolved and the runtime
// frameworks are outside dyld's rpath). Detect that setup and add the flags;
// an Xcode toolchain needs none of this and gets a plain manifest.
let commandLineTools = "/Library/Developer/CommandLineTools"
let testingMacros = commandLineTools + "/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? ""
let usingCommandLineToolsOnly = FileManager.default.fileExists(atPath: testingMacros)
    && (developerDir.isEmpty || developerDir.hasPrefix(commandLineTools))
    && !FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/swift")

var testSwiftSettings: [SwiftSetting] = []
var testLinkerSettings: [LinkerSetting] = []
if usingCommandLineToolsOnly {
    testSwiftSettings.append(.unsafeFlags(["-load-plugin-library", testingMacros]))
    testLinkerSettings.append(.unsafeFlags([
        "-Xlinker", "-rpath", "-Xlinker", commandLineTools + "/Library/Developer/Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", commandLineTools + "/Library/Developer/usr/lib",
    ]))
}

// Sparkle: `JRBAR_SPARKLE_FRAMEWORK_DIR` names a directory holding the pinned
// Sparkle.framework (the packaging script's distribution; build-app.sh finds
// it after one `make package`). With it the app imports and links Sparkle and
// expects the framework at `Contents/Frameworks` (`@executable_path/../
// Frameworks`); without it SparkleUpdater.swift compiles its stub half.
let sparkleDirectory = ProcessInfo.processInfo.environment["JRBAR_SPARKLE_FRAMEWORK_DIR"] ?? ""
let sparkleAvailable = !sparkleDirectory.isEmpty
    && FileManager.default.fileExists(atPath: sparkleDirectory + "/Sparkle.framework/Modules/module.modulemap")
var appSwiftSettings: [SwiftSetting] = []
var appLinkerSettings: [LinkerSetting] = [
    .linkedFramework("AppKit"),
    .linkedFramework("SwiftUI"),
    .linkedFramework("QuartzCore"),
    .linkedFramework("AVFoundation"),
    .linkedFramework("UserNotifications"),
]
if sparkleAvailable {
    appSwiftSettings.append(.unsafeFlags(["-F", sparkleDirectory]))
    appLinkerSettings.append(.linkedFramework("Sparkle"))
    appLinkerSettings.append(.unsafeFlags([
        "-F", sparkleDirectory,
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
    ]))
}

let package = Package(
    name: "JRBar",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "JRBarLEDS", targets: ["JRBarLEDS"]),
        .library(name: "JRBarCore", targets: ["JRBarCore"]),
        .library(name: "JRBarUI", targets: ["JRBarUI"]),
        .executable(name: "JRBarApp", targets: ["JRBarApp"]),
    ],
    targets: [
        // Pure Swift LEDS DSL model, parser and sampler. No AppKit.
        .target(name: "JRBarLEDS"),
        // The core daemon protocol: NDJSON over a Unix socket, Codable
        // models, an observable model. Foundation only.
        .target(name: "JRBarCore"),
        // AppKit pieces small enough to test without the app: the status
        // item's icon renderer.
        .target(
            name: "JRBarUI",
            dependencies: ["JRBarCore"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "JRBarApp",
            dependencies: ["JRBarLEDS", "JRBarCore", "JRBarUI"],
            swiftSettings: appSwiftSettings,
            linkerSettings: appLinkerSettings
        ),
        .testTarget(
            name: "JRBarLEDSTests",
            dependencies: ["JRBarLEDS"],
            resources: [.copy("Fixtures")],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
        .testTarget(
            name: "JRBarCoreTests",
            // JRBarLEDS parses the effect previews the mock renders.
            dependencies: ["JRBarCore", "JRBarLEDS"],
            resources: [.copy("Fixtures")],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
        .testTarget(
            name: "JRBarUITests",
            dependencies: ["JRBarUI"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
    ]
)
