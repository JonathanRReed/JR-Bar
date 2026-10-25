# Claude CLI usage PTY design for a later release

The CLI fallback does not ship in 0.10.0. `cli_fallback` is reserved and
has no effect. The production probe refuses to launch. L3c implemented the
guarded PTY candidate below, but its authorized live check stopped at credential
preflight. The existing reader returned `access_lost`; no interactive CLI
started and no PTY input was sent. See the
[L3c handoff](2026-10-25-claude-cli-usage-l3c.md).

The candidate follows this design:

- Launch in a private PTY with no positional prompt. Pass
  `--allowed-tools "" --strict-mcp-config` and settings that disable hooks
  and remote control.
- Use a private `CLAUDE_CONFIG_DIR`, pre-seeded so onboarding and trust
  screens do not appear. Trust only the probe's own empty temporary working
  directory. Strip `ANTHROPIC_*` and `CLAUDE*` environment variables, then
  set the probe's private configuration and `DISABLE_AUTOUPDATER=1`.
- Wait for the idle prompt. Abort on onboarding, trust, login, API key,
  or choice screens. Never answer them.
- Type `/usage` without Enter. Confirm that the command menu selects the
  built-in command, then press Enter exactly once. Never send periodic
  Enters.
- Wait until labelled session and weekly sections are fully drawn.
  The parser requires both sections. The candidate waits for a stable
  reconstructed screen before accepting a result.
- Send Escape, then `/exit`. Kill and reap the process group. Check the
  private `projects/**.jsonl` files for assistant entries before removing
  the configuration directory. Any assistant entry fails the probe.
- Allow only CLI versions verified by hand. Require one supervised run
  on the owner's Mac before enabling the fallback.

Synthetic TUI tests cover command order, parsing, blocked screens and cleanup
in the fake program. They do not prove command dispatch, complete rendering,
token handoff or compatibility with an installed Claude CLI.
