# Claude CLI usage PTY design for a later release

The CLI fallback does not ship in 0.10.0. `cli_fallback` is reserved and
has no effect. The production probe refuses to launch. The verifier
recommended the following design before enabling a later release.

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
  The current parser returns on its first usable session section, which
  is too early to establish a complete reading.
- Send Escape, then `/exit`. Kill and reap the process group. Check the
  private `projects/**.jsonl` files for assistant entries before removing
  the configuration directory. Any assistant entry fails the probe.
- Allow only CLI versions verified by hand. Require one supervised run
  on the owner's Mac before enabling the fallback.

Synthetic executables test parsing and process cleanup only. They do not
prove command dispatch, complete rendering, token handoff, or compatibility
with an installed Claude CLI.
