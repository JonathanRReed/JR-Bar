import AppIntents
import Foundation
import JRBarCore

// Shortcuts actions for JR-Bar's main verbs, every one a thin door onto
// the same `AppCommandRouter` a `jrbar://` link and a bound key use — so
// they share its rules: a refusal is thrown as the router's sentence, and
// nothing here answers an ask.
//
// Discovery: Shortcuts finds App Intents through the Metadata.appintents
// bundle Xcode's metadata processor writes at build time. The Command
// Line Tools build this app ships with has no such processor, so until the
// bundle is built by Xcode (the same step the widget waits on) these
// intents compile and link but Shortcuts cannot list them; in the
// meantime Shortcuts reaches every verb through "Open URLs" with a
// jrbar:// link.

/// A router refusal, in the words the router used.
struct JRBarIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// The intents' one way in.
@MainActor
enum JRBarIntentBridge {
    static func run(_ command: AppCommand) throws {
        if case .refused(let why) = AppCommandRouter.shared.perform(command) {
            throw JRBarIntentError(message: why)
        }
    }

    /// The sessions a "Open Session" parameter can pick from — wired by
    /// the delegate to the core's live list: (id, label, provider).
    static var sessions: () -> [(id: String, label: String, provider: String)] = { [] }
}

// MARK: - Parameters

enum QuickToggleOption: String, AppEnum {
    case keepAwake, darkMode, desktopIcons, hiddenFiles, mute, screenSaver, lock, dockAutoHide,
         micMute, eject, sleep

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Quick Toggle"
    static let caseDisplayRepresentations: [QuickToggleOption: DisplayRepresentation] = [
        .keepAwake: "Keep Awake",
        .darkMode: "Dark Mode",
        .desktopIcons: "Desktop Icons",
        .hiddenFiles: "Hidden Files",
        .mute: "Mute Output",
        .screenSaver: "Screen Saver",
        .lock: "Lock Screen",
        .dockAutoHide: "Dock Auto-Hide",
        .micMute: "Mute Microphone",
        .eject: "Eject Disks",
        .sleep: "Sleep",
    ]

    var toggle: SystemToggle? { SystemToggle(rawValue: rawValue) }
}

enum QuickToggleChange: String, AppEnum {
    case toggle, on, off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Change"
    static let caseDisplayRepresentations: [QuickToggleChange: DisplayRepresentation] = [
        .toggle: "Toggle", .on: "Turn On", .off: "Turn Off",
    ]
}

enum QuietModeOption: String, AppEnum {
    case pause, dim, mute, asksOnly = "asks_only", dark

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Quiet Mode"
    static let caseDisplayRepresentations: [QuietModeOption: DisplayRepresentation] = [
        .pause: "Pause", .dim: "Dim", .mute: "Mute", .asksOnly: "Asks Only", .dark: "Dark",
    ]
}

/// A live agent session, as Shortcuts lists it.
struct AgentSessionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent Session"
    static let defaultQuery = AgentSessionQuery()

    let id: String
    let label: String
    let provider: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(label)", subtitle: "\(provider)")
    }
}

struct AgentSessionQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [AgentSessionEntity] {
        JRBarIntentBridge.sessions()
            .filter { identifiers.contains($0.id) }
            .map { AgentSessionEntity(id: $0.id, label: $0.label, provider: $0.provider) }
    }

    @MainActor
    func suggestedEntities() async throws -> [AgentSessionEntity] {
        JRBarIntentBridge.sessions().map { AgentSessionEntity(id: $0.id, label: $0.label, provider: $0.provider) }
    }
}

// MARK: - Intents

struct ShowPanelIntent: AppIntent {
    static let title: LocalizedStringResource = "Show JR-Bar Panel"
    static let description = IntentDescription("Opens the panel: your agents, what they ask, and usage.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try JRBarIntentBridge.run(.panel(toggle: false))
        return .result()
    }
}

struct SetQuickToggleIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Quick Toggle"
    static let description = IntentDescription("Flips, or sets, one of the notch strip's quick toggles.")

    @Parameter(title: "Toggle") var toggle: QuickToggleOption
    @Parameter(title: "Change", default: .toggle) var change: QuickToggleChange

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$change) \(\.$toggle)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let chip = toggle.toggle else { throw JRBarIntentError(message: "Unknown toggle.") }
        let on: Bool? = switch change {
        case .toggle: nil
        case .on: true
        case .off: false
        }
        try JRBarIntentBridge.run(.toggle(chip, on: on))
        return .result()
    }
}

struct KeepAwakeIntent: AppIntent {
    static let title: LocalizedStringResource = "Keep Mac Awake"
    static let description = IntentDescription("Holds the Mac awake for a number of minutes; 0 lets it sleep again.")

    @Parameter(title: "Minutes", default: 60, inclusiveRange: (0, 1440)) var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        try JRBarIntentBridge.run(.keepAwake(seconds: minutes * 60))
        return .result()
    }
}

struct QuietIntent: AppIntent {
    static let title: LocalizedStringResource = "Quiet JR-Bar"
    static let description = IntentDescription("Quiets JR-Bar's lights and sounds for a while. Asks still reach the panel.")

    @Parameter(title: "Mode", default: .pause) var mode: QuietModeOption
    @Parameter(title: "Minutes", default: 60, inclusiveRange: (1, 1440)) var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        try JRBarIntentBridge.run(.quiet(mode: mode.rawValue, seconds: minutes * 60))
        return .result()
    }
}

struct EndQuietIntent: AppIntent {
    static let title: LocalizedStringResource = "End JR-Bar Quiet"

    @MainActor
    func perform() async throws -> some IntentResult {
        try JRBarIntentBridge.run(.endQuiet)
        return .result()
    }
}

struct DeepWorkIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Deep Work"
    static let description = IntentDescription(
        "Holds JR-Bar's quiet at asks-only for a focused stretch, then says what the agents did meanwhile.")

    @Parameter(title: "Minutes", default: 25, inclusiveRange: (1, 1440)) var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        try JRBarIntentBridge.run(.deepWork(seconds: minutes * 60))
        return .result()
    }
}

struct FireConfettiIntent: AppIntent {
    static let title: LocalizedStringResource = "Fire Confetti"

    @MainActor
    func perform() async throws -> some IntentResult {
        try JRBarIntentBridge.run(.confetti())
        return .result()
    }
}

struct ShowHiddenMenuBarItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Hidden Menu Bar Items"
    static let description = IntentDescription("Reveals the items the Menu Bar utility hides, until they tuck away again.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try JRBarIntentBridge.run(.menuBar(.reveal))
        return .result()
    }
}

struct ShowWaitingAskIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Waiting Ask"
    static let description = IntentDescription("Opens the panel on the agent that is waiting for you, where you can answer it.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try JRBarIntentBridge.run(.revealAsk)
        return .result()
    }
}

struct OpenAgentSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Agent Session"
    static let description = IntentDescription("Brings an agent session's terminal or app to the front.")

    @Parameter(title: "Session") var session: AgentSessionEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try JRBarIntentBridge.run(.openSession(session.id))
        return .result()
    }
}

struct JRBarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShowPanelIntent(), phrases: ["Show \(.applicationName)"],
                    shortTitle: "Show Panel", systemImageName: "rectangle.stack")
        AppShortcut(intent: ShowWaitingAskIntent(), phrases: ["What is \(.applicationName) waiting on"],
                    shortTitle: "Waiting Ask", systemImageName: "questionmark.bubble")
        AppShortcut(intent: KeepAwakeIntent(), phrases: ["Keep awake with \(.applicationName)"],
                    shortTitle: "Keep Awake", systemImageName: "cup.and.saucer")
        AppShortcut(intent: QuietIntent(), phrases: ["Quiet \(.applicationName)"],
                    shortTitle: "Quiet", systemImageName: "moon")
        AppShortcut(intent: DeepWorkIntent(), phrases: ["Start deep work with \(.applicationName)"],
                    shortTitle: "Deep Work", systemImageName: "timer")
        AppShortcut(intent: SetQuickToggleIntent(), phrases: ["Toggle with \(.applicationName)"],
                    shortTitle: "Quick Toggle", systemImageName: "switch.2")
    }
}
