import Foundation
import JRBarCore

/// What a working agent is doing right now, read off the hook's last
/// word (`CoreSession.event`, `CoreSession.tool`) — the vocabulary a
/// `ThinkingOrb` draws. Never a state of its own: the row is working
/// (or waiting) by `SessionActivity`; this only says how.
enum AgentActivity: String, CaseIterable, Sendable {
    /// Reasoning between tool calls: a prompt just landed, a tool just
    /// finished, a sub-agent was sent off.
    case thinking
    /// Reading, listing, grepping, fetching the web.
    case searching
    /// Editing, writing, patching files.
    case writing
    /// A shell command or a process of its own.
    case running
    /// The agent is waiting on you: a permission prompt, a question.
    /// Asks keep their amber everywhere; this is only the orb's motion.
    case listening

    /// VoiceOver's word for the orb, where no text beside it says it.
    var spokenLabel: String {
        switch self {
        case .thinking: return "Thinking"
        case .searching: return "Searching"
        case .writing: return "Writing"
        case .running: return "Running"
        case .listening: return "Listening"
        }
    }

    /// The activity a session's last hook event and tool say.
    ///
    /// A tool the agent is about to run (`PreToolUse`, or an event this
    /// table does not know that names one) says what it is doing. A
    /// finished tool (`PostToolUse`, `PostToolUseFailure`) means the
    /// agent is reading its result — thinking — whatever the tool was.
    /// A permission prompt, an elicitation or a notification waits on
    /// you. Everything else, and anything unknown, is thinking: the one
    /// honest word when the hook says nothing more specific.
    static func from(event: String?, tool: String?) -> AgentActivity {
        let hook = event?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if waitingEvents.contains(hook) { return .listening }
        if finishedEvents.contains(hook) || reasoningEvents.contains(hook) { return .thinking }
        if let tool, let named = from(tool: tool) { return named }
        // Cursor's shell pair canonicalises to PreToolUse without a
        // tool name: a tool is running, and it is a command.
        if hook == "PreToolUse" { return .running }
        return .thinking
    }

    /// The activity a tool name says, across every provider JR-Bar
    /// reads; nil for an empty name. Exact names first (each provider's
    /// own spelling, lower-cased), then the words inside an unknown
    /// name — an MCP server's `batch_read_email` reads, `create_issue`
    /// writes — and thinking when nothing matches.
    static func from(tool: String) -> AgentActivity? {
        let bare = strippedTool(tool)
        let name = bare.lowercased()
        guard !name.isEmpty else { return nil }
        if let exact = exactTools[name] { return exact }
        let words = toolWords(bare)
        if !words.isDisjoint(with: delegateWords) { return .thinking }
        if !words.isDisjoint(with: writeWords) { return .writing }
        if !words.isDisjoint(with: runWords) { return .running }
        if !words.isDisjoint(with: searchWords) { return .searching }
        return .thinking
    }

    /// The orb a session row shows: only a live working row has one — a
    /// stale row's event stopped being current when its feed did, and a
    /// waiting, finished or idle row keeps its own mark.
    static func forRow(session: CoreSession, activity: SessionActivity) -> AgentActivity? {
        guard activity == .working, !session.stale else { return nil }
        return from(event: session.event, tool: session.tool)
    }

    // MARK: Events

    /// The hook is waiting on the person (canonical names, as the daemon
    /// sends them in `event`).
    static let waitingEvents: Set<String> = ["PermissionRequest", "Elicitation", "Notification"]

    /// A tool call ended: the agent is back to reasoning.
    static let finishedEvents: Set<String> = ["PostToolUse", "PostToolUseFailure", "PermissionDenied",
                                              "ElicitationResult"]

    /// Turn and session edges: a prompt landing, a compaction, a
    /// sub-agent sent off or back. A tool left over from an earlier
    /// event says nothing about them.
    static let reasoningEvents: Set<String> = ["UserPromptSubmit", "SessionStart", "PreCompact", "PostCompact",
                                               "SubagentStart", "SubagentStop", "Stop", "StopFailure",
                                               "SessionEnd", "Interrupt", "HermesTurnEnd", "SessionFinalize",
                                               "ApiRequestError"]

    // MARK: Tools

    /// `mcp__github__search_code` → `search_code`; `functions.shell` →
    /// `shell`; surrounding space dropped, case kept for `toolWords`.
    static func strippedTool(_ tool: String) -> String {
        var name = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = name.range(of: "__", options: .backwards) {
            name = String(name[range.upperBound...])
        }
        if let dot = name.lastIndex(of: "."), name.index(after: dot) < name.endIndex {
            name = String(name[name.index(after: dot)...])
        }
        return name
    }

    /// The words of a tool name: split on anything not a letter or digit,
    /// and at a lower-to-upper step (`readFile` → read, file).
    static func toolWords(_ name: String) -> Set<String> {
        var words: Set<String> = []
        var current = ""
        var previousLower = false
        for character in name {
            let isAlnum = character.isLetter || character.isNumber
            if !isAlnum || (previousLower && character.isUppercase) {
                if !current.isEmpty { words.insert(current.lowercased()) }
                current = ""
            }
            if isAlnum { current.append(character) }
            previousLower = character.isLowercase
        }
        if !current.isEmpty { words.insert(current.lowercased()) }
        return words
    }

    /// Each provider's tool names, lower-cased: Claude Code (`Read`,
    /// `Edit`, `Bash`…), Codex (`shell`, `exec_command`, `apply_patch`…),
    /// Gemini CLI (`read_file`, `replace`, `run_shell_command`…), OpenCode
    /// (`read`, `edit`, `bash`…), Cursor (`run_terminal_cmd`,
    /// `edit_file`…), Devin (`run_subagent`, `sidekick`…), Kiro
    /// (`fs_read`, `fs_write`, `execute_bash`), and the daemon's own
    /// classification tables (`mailbox._READ_TOOLS` and friends).
    static let exactTools: [String: AgentActivity] = {
        var table: [String: AgentActivity] = [:]
        for name in searchTools { table[name] = .searching }
        for name in writeTools { table[name] = .writing }
        for name in runTools { table[name] = .running }
        for name in thinkTools { table[name] = .thinking }
        for name in askTools { table[name] = .listening }
        return table
    }()

    static let searchTools: [String] = [
        "read", "grep", "glob", "ls", "websearch", "webfetch", "web_search", "web_fetch",
        "google_web_search", "read_file", "read_many_files", "read_text_file", "readfile", "view_file",
        "open_file", "view", "view_image", "list", "list_dir", "list_directory", "list_files", "find",
        "find_files", "search", "search_files", "search_file_content", "file_search", "codebase_search",
        "grep_search", "codesearch", "code_search", "rg", "ripgrep", "fetch", "fs_read", "notebookread",
        "toolsearch", "lsp",
    ]

    static let writeTools: [String] = [
        "edit", "write", "multiedit", "notebookedit", "apply_patch", "patch", "replace", "write_file",
        "edit_file", "create_file", "str_replace", "str_replace_editor", "str_replace_based_edit_tool",
        "insert", "fs_write", "edit_notebook", "search_replace", "delete_file",
    ]

    static let runTools: [String] = [
        "bash", "shell", "exec", "exec_command", "run", "local_shell", "unified_exec", "shell_command",
        "run_shell_command", "run_terminal_command", "run_terminal_cmd", "execute_bash", "execute_command",
        "execute", "terminal", "powershell", "zsh", "write_stdin", "bashoutput", "bash_output",
        "killshell", "killbash", "run_command",
    ]

    /// Planning and handing work off: still the agent's own reasoning.
    static let thinkTools: [String] = [
        "task", "agent", "run_subagent", "sidekick", "todowrite", "todoread", "todo_write",
        "update_plan", "think", "reason", "thinking", "skill", "slashcommand",
    ]

    /// Tools whose call is a question to the person.
    static let askTools: [String] = ["askuserquestion", "exitplanmode"]

    static let delegateWords: Set<String> = ["agent", "subagent", "task", "plan", "todo", "think"]
    static let writeWords: Set<String> = ["write", "edit", "patch", "replace", "create", "insert", "save",
                                          "append", "delete", "rename", "update"]
    static let runWords: Set<String> = ["bash", "shell", "exec", "execute", "run", "terminal", "command", "cmd"]
    static let searchWords: Set<String> = ["read", "search", "grep", "glob", "find", "fetch", "list", "view",
                                           "open", "get", "query", "lookup", "browse", "scan", "ls"]
}
