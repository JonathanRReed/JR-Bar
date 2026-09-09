# Gemini CLI and Pi hook facts (researched 2026-09-09)

Inputs for the Gemini and Pi providers in Phase F.

## Gemini CLI 0.46.0 (`/opt/homebrew/bin/gemini`)

- Hooks live under a top-level `hooks` key in `~/.gemini/settings.json`
  (project `.gemini/settings.json` overrides). Shape:
  `{"hooks": {"BeforeTool": [{"matcher": "*", "hooks": [{"name": "jrbar", "type": "command", "command": "...", "timeout": 5000}]}]}}`.
  `timeout` is milliseconds (default 60000). `hooksConfig.enabled`,
  `hooksConfig.disabled` (by hook name) exist.
- Events: `SessionStart`, `SessionEnd`, `BeforeAgent`, `AfterAgent`,
  `BeforeModel`, `AfterModel`, `BeforeToolSelection`, `BeforeTool`,
  `AfterTool`, `PreCompress`, `Notification`.
- stdin JSON always carries `session_id`, `transcript_path`, `cwd`,
  `hook_event_name`, `timestamp`. `SessionStart.source`, `SessionEnd.reason`
  (`exit|clear|logout|prompt_input_exit|other`), `BeforeAgent.prompt`,
  `AfterAgent.prompt_response`, `BeforeTool.tool_name`, `Notification`
  with `notification_type: "ToolPermission"` (the only waiting-for-you
  signal; nothing fires when the user answers).
- stdout must be nothing but a JSON object; `echo "{}"` and exit 0 is the
  minimal hook. Exit 2 blocks; other non-zero is a warning. Non-zero is
  ignored for SessionStart/SessionEnd/Notification/PreCompress.
- Env: `GEMINI_PROJECT_DIR`, `GEMINI_SESSION_ID`, `GEMINI_CWD`.
- Mapping for JR-Bar: SessionStart→SessionStart, BeforeAgent→UserPromptSubmit,
  BeforeTool→PreToolUse, AfterTool→PostToolUse, Notification(ToolPermission)
  →PermissionRequest, AfterAgent→Stop, SessionEnd→SessionEnd. AfterModel
  fires per streamed chunk: do not register it.
- Transcripts: `~/.gemini/tmp/<project name from ~/.gemini/projects.json>/chats/session-<ts>-<id>.jsonl`;
  `transcript_path` in the hook payload points at that file.
- Quota: `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
  with the OAuth bearer from `~/.gemini/oauth_creds.json` and the Code
  Assist project id; response `buckets[]` with `modelId`, `remainingFraction`,
  `remainingAmount`, `resetTime`. Not persisted anywhere on disk.

## Antigravity `agy` 1.1.27 (already integrated; new facts)

- Also has `PreToolUse` (requires a `decision`, so never register it as an
  observer) and `PostInvocation`. Timeout is seconds (default 30).
- `Stop` payload adds `fullyIdle`, `terminationReason`.

## Pi (`@mariozechner/pi-coding-agent` 0.73.1, installed globally 2026-09-09)

- Extensions: TypeScript modules auto-loaded from `~/.pi/agent/extensions/*.ts`.
  Events: `session_start` (reason startup/reload/new/resume/fork),
  `session_shutdown`, `before_agent_start`, `agent_start`, `agent_end`,
  `agent_settled`, `turn_start`, `turn_end`, `tool_call` (can block; use
  `ctx.ui.confirm` for permission gates), `tool_execution_start/end`,
  `ui_prompt_start/end`.
- `ctx.sessionManager.getSessionFile()/getSessionId()` give identity.
- Session logs: `~/.pi/agent/sessions/--<cwd with / \ : → ->--/<timestamp>_<uuid>.jsonl`,
  first line `{"type":"session","version":3,...}`; no end-of-session marker.
- Child env markers: `PI_SESSION_ID`, `PI_SESSION_FILE`, `PI_CODING_AGENT=true`.
- Mapping: session_start→SessionStart, turn_start→UserPromptSubmit,
  tool_execution_start→PreToolUse, tool_execution_end→PostToolUse,
  ui_prompt_start→PermissionRequest (ui_prompt_end resolves it),
  agent_end→Stop, session_shutdown→SessionEnd. The extension posts each
  event to the hook shim / socket with `{session_id, cwd, hook_event_name}`.
