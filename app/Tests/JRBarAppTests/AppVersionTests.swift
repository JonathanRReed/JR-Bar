import Foundation
import Testing
@testable import JRBarApp

/// `AppVersion.describe`: the Version row's "0.9.9 (build 1801, 1800c0a)" —
/// the marketing version, then the build number Sparkle orders by and the
/// commit the packager stamped, each only when it says something.
@Suite struct AppVersionTests {
    @Test func aPackagedBuildNamesItsBuildAndCommit() {
        #expect(AppVersion.describe(shortVersion: "0.9.9", build: "1801",
                                    commit: "1800c0a3d2b1f0e9a8b7c6d5e4f3a2b1c0d9e8f7")
                == "0.9.9 (build 1801, 1800c0a)")
    }

    @Test func aDirtyCommitKeepsItsTail() {
        #expect(AppVersion.describe(shortVersion: "0.9.9", build: "1801",
                                    commit: "1800c0a3d2b1f0e9a8b7c6d5e4f3a2b1c0d9e8f7-dirty")
                == "0.9.9 (build 1801, 1800c0a-dirty)")
    }

    @Test func aBuildStampedWithTheVersionTwiceSaysNothingNew() {
        // Every build before the build number wrote the marketing version
        // into CFBundleVersion too; repeating it would read as a build.
        #expect(AppVersion.describe(shortVersion: "0.9.9", build: "0.9.9", commit: nil) == "0.9.9")
        #expect(AppVersion.describe(shortVersion: "0.9.9", build: "0.9.9", commit: "abc1234")
                == "0.9.9 (abc1234)")
    }

    @Test func anUnknownOrMissingCommitIsLeftOut() {
        #expect(AppVersion.describe(shortVersion: "0.9.9", build: "12", commit: "unknown") == "0.9.9 (build 12)")
        #expect(AppVersion.describe(shortVersion: "0.9.9", build: "12", commit: "  ") == "0.9.9 (build 12)")
    }

    @Test func aSwiftRunHasNoBundleVersionAtAll() {
        #expect(AppVersion.describe(shortVersion: nil, build: nil, commit: nil) == "dev")
        #expect(AppVersion.describe(shortVersion: "", build: "", commit: "") == "dev")
    }
}

/// `InstalledCopies.stale`: another *installed* JR-Bar goes stale on the
/// first update; the build folders a checkout leaves are not installs.
@Suite struct InstalledCopiesTests {
    let home = URL(fileURLWithPath: "/Users/j")
    let running = URL(fileURLWithPath: "/Users/j/Applications/JR-Bar.app")

    @Test func theOtherInstallLocationIsNamed() {
        let copies = [
            running,
            URL(fileURLWithPath: "/Applications/JR-Bar.app"),
            URL(fileURLWithPath: "/Users/j/Downloads/JR-Bar/build/macos-pkg/app/JR-Bar.app"),
            URL(fileURLWithPath: "/Users/j/Downloads/JR-Bar/app/build/JR-Bar.app"),
        ]
        #expect(InstalledCopies.stale(among: copies, running: running, home: home)
                == [URL(fileURLWithPath: "/Applications/JR-Bar.app")])
    }

    @Test func theRunningCopyAndDuplicatesAreNot() {
        let copies = [running, URL(fileURLWithPath: "/Users/j/Applications/./JR-Bar.app"),
                      URL(fileURLWithPath: "/Applications/Utilities/JR-Bar.app"),
                      URL(fileURLWithPath: "/Applications/Utilities/JR-Bar.app")]
        #expect(InstalledCopies.stale(among: copies, running: running, home: home)
                == [URL(fileURLWithPath: "/Applications/Utilities/JR-Bar.app")])
        #expect(InstalledCopies.stale(among: [running], running: running, home: home).isEmpty)
    }
}
