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

let package = Package(
    name: "JRBar",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "JRBarLEDS", targets: ["JRBarLEDS"]),
        .library(name: "JRBarCore", targets: ["JRBarCore"]),
        .executable(name: "JRBarApp", targets: ["JRBarApp"]),
    ],
    targets: [
        // Pure Swift LEDS DSL model, parser and sampler. No AppKit.
        .target(name: "JRBarLEDS"),
        // The core daemon protocol: NDJSON over a Unix socket, Codable
        // models, an observable model. Foundation only.
        .target(name: "JRBarCore"),
        .executableTarget(
            name: "JRBarApp",
            dependencies: ["JRBarLEDS", "JRBarCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("QuartzCore"),
            ]
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
            dependencies: ["JRBarCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
    ]
)
