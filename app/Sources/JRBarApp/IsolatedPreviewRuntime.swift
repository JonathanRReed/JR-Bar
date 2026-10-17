import Foundation
import JRBarCore

struct IsolatedPreviewRuntime: Sendable {
    let stateDirectory: URL

    enum Failure: Error {
        case invalidConfiguration
    }

    static func readCurrent() throws -> Self? {
        #if DEBUG
        return try read(bundleID: Bundle.main.bundleIdentifier,
                        environment: ProcessInfo.processInfo.environment)
        #else
        return nil
        #endif
    }

    static func read(bundleID: String?, environment: [String: String],
                     temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws -> Self? {
        guard let requested = environment["JRBAR_ISOLATED_PREVIEW"] else { return nil }
        guard requested == "1", bundleID?.hasPrefix("com.jonathanreed.jrbar.preview.") == true,
              let statePath = environment["XDG_STATE_HOME"], statePath.hasPrefix("/"),
              let socketPath = environment["JRBAR_CORE_SOCKET"], socketPath.hasPrefix("/"),
              (environment["JRBAR_CORE_EXEC"] ?? "").isEmpty,
              (environment["JRBAR_LOGIN_ITEM"] ?? "").isEmpty else {
            throw Failure.invalidConfiguration
        }
        let state = URL(fileURLWithPath: statePath).standardizedFileURL.resolvingSymlinksInPath()
        let socket = URL(fileURLWithPath: socketPath).standardizedFileURL.resolvingSymlinksInPath()
        let root = state.deletingLastPathComponent()
        let temporary = temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard state.lastPathComponent == "state", socket.lastPathComponent == "mock.sock",
              socket.deletingLastPathComponent() == root,
              root.deletingLastPathComponent() == temporary,
              root.lastPathComponent.hasPrefix("jrbar-native-preview-") else {
            throw Failure.invalidConfiguration
        }
        if FileManager.default.fileExists(atPath: state.path) {
            guard let files = FileManager.default.enumerator(at: state,
                includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
                throw Failure.invalidConfiguration
            }
            for case let file as URL in files {
                if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    throw Failure.invalidConfiguration
                }
            }
        }
        return Self(stateDirectory: state)
    }

    func file(_ name: String) -> URL {
        stateDirectory.appending(path: "jrbar", directoryHint: .isDirectory).appending(path: name)
    }

    func reviewState() -> AppState {
        var state = AppState()
        state.toys.fold.enabled = false
        state.toys.aquarium.enabled = false
        state.toys.notchBuddy.enabled = false
        state.toys.confetti.enabled = false
        state.toys.notch.enabled = true
        state.toys.notch.islandEnabled = true
        state.toys.notch.provider = .jrbar
        state.toys.notch.mediaEnabled = false
        state.toys.notch.mediaHUD = false
        state.toys.notch.calendar = false
        state.toys.notch.reminders = false
        state.toys.notch.mirror = false
        state.toys.notch.meetingAlerts = false
        state.toys.notch.lyrics = false
        state.toys.notch.lyricsConsented = false
        state.toys.notch.audioVisualizer = false
        state.toys.notch.hapticTick = false
        state.toys.notch.alerts = false
        state.toys.notch.soundEffects = false
        state.toys.notch.capsuleNotifications = false
        state.utilities.dock.enabled = false
        state.utilities.menuBar.enabled = true
        state.utilities.menuBar.itemSpacing = 0
        state.utilities.menuBar.itemSpacingManaged = false
        state.utilities.menuBar.triggerRules = []
        return state
    }
}
