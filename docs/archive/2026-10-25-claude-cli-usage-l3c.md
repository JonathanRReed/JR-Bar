# L3c Claude usage fallback handoff

Do not ship the CLI fallback in 0.10.0. The authorized live check stopped
at credential preflight. JR-Bar's existing noninteractive Keychain reader
returned `access_lost`. No interactive CLI started, no input was sent, and
there was no retry. The version allowlist stays empty. Settings still
hides the toggle, and `cli_fallback` remains reserved in CORE-PROTOCOL.

Started from `8c07896a`, `merge: L3 Claude usage and provider states`.
No commits were made.

## Changes

[claude_cli_usage.py](../../src/jrbar/claude_cli_usage.py) replaces the old
positional `/usage` experiment with a guarded candidate. Production still
refuses to launch it. The candidate resolves the executable before checking
its version, isolates HOME, configuration and an empty cwd, and hands the
access token through a private 0600 descriptor. No token goes into argv or
the environment. The child receives only an allowlist of environment keys.

The candidate pre-seeds onboarding, theme and trust for its resolved temp
cwd. It passes `--allowed-tools ""`, `--tools ""`, `--strict-mcp-config`,
`--safe-mode`, `--no-chrome`, empty setting sources, and settings that disable
hooks and remote control. Auto-update and nonessential traffic are off.
The installed `2.1.309` help listed these flags. Inspection of the installed
CLI code found its inherited-descriptor reader. Live authentication through
that reader remains unproved.

The candidate waits for the idle prompt, types `/usage`, checks the selected
built-in command and sends one Enter. It requires stable labelled session
and weekly sections, then sends Escape and types `/exit` without another
Enter. It kills and reaps the process group before auditing and removing
the private configuration. Unknown terminal operations and blocked screens
fail closed. It sends no terminal-query replies or periodic Enters.

The audit checks private project JSONL records for assistant entries, models
and usage. Detection stops the probe, disables fallback in provider settings
for every Claude instance and sets a persistent `cli_fallback_disabled`
option. A process latch also prevents another attempt if saving fails.
This path is tested with synthetic data. It has not run against real usage.

## Verification

- 68 tests passed across `test_claude_cli_usage.py`,
  `test_provider_usage_codex_claude.py`, `test_provider_source_options.py`,
  `test_deterministic_timing_contract.py` and `test_unwired_modules_ratchet.py`.
- The fake TUI covers successful command dispatch, slow and partial draws,
  onboarding, trust, login, API-key and choice screens, crashes, wrong or
  unselected commands, cleanup and persistent model-entry lockout.
- The successful synthetic writes are exactly `/usage`, carriage return,
  Escape and `/exit`. No other bytes are sent.
- Ruff and `git diff --check` passed.
- `cd app && env -u JRBAR_INTERACTIVE_TESTS swift build` passed in 65.62 s,
  with warnings in unchanged code. No Swift tests or rendered UI ran.

## Live-check receipt

The [machine-readable receipt](2026-10-25-claude-cli-usage-l3c-receipt.json)
records the attempt. The small verifier remains at
`/tmp/jrbar-l3c-verification/run_once.py` on this Mac.

- Installed CLI observed before preflight: `2.1.309`.
- Credential outcome: `credential_read_access_lost`.
- Interactive CLI launches: zero. PTY bytes: none. Screens: none.
- Parsed result: none. Probe wall time: zero because it never started.
  The preflight command took 0.108 s.
- Private projects audit: not run because no private CLI session existed.
  The attempt made no model turn because it never launched the interactive CLI.
  Real command dispatch and local usage accounting remain unproved.

The check used `read_keychain_secret` with `allow_prompt=False` and JR-Bar's
existing consent ledger. It did not copy credentials, change Claude's config,
request a new Keychain grant or bypass a denied read.

The next authorized live check needs working credential access through
JR-Bar's existing reader. It must still run once and stop on any deviation.
Only a passing receipt can justify adding a verified version, wiring the
collector, publishing the option and exposing the requested Settings copy.
