# JR-Bar compatibility

What JR-Bar 0.8 runs on, talks to, and how sure it is. A row says
"verified" when the exact thing has been exercised on the owner's Mac from
the shipped build; "reviewed" when source, fixtures and tests cover it
but the real service, device or tier has not been exercised; "best
effort" when the code recognises the input and nothing more is claimed.

## Platform

| Boundary | Claim |
| --- | --- |
| macOS | 26 or newer (`LSMinimumSystemVersion 26.0`). Developed and verified on a MacBook Pro with a notch; the Screen Bar needs one, everything else does not. |
| CPU | Apple silicon. `make package` builds for the Mac it runs on; no Intel package is published. |
| Distribution | The PKG is Developer ID signed. Until the `jrbar-notary` profile exists it is not notarized, so Gatekeeper on another Mac refuses it; build locally. |
| Python | The frozen daemon carries its own 3.12. A source checkout needs 3.12 for the pinned tooling; the package metadata still declares 3.10+ for the pure-Python parts. |
| Xcode | Not required. The Command Line Tools (Swift 6.2+) build the app and the shim. |

## Hardware

| Device | Claim |
| --- | --- |
| SidePulse Pro (8 LEDs, SD slot) | Verified: agent output, linked mode, calibration, quit-to-off. |
| SidePulse Dot (2 LEDs, USB-C), including a first-batch `PulseDot` volume | Verified in linked mode at `linked_dot_scale`; its own heartbeat display reviewed. |
| Creator Micro 2 (vendor HID over USB or Bluetooth) | Reviewed. Verified with the pad powered off only: discovery, approval prompt, keymap planning, the board without hardware. |
| Screen Bar | Verified on the owner's notched display, with and without Alcove running. |

## Providers

| Provider | Hooks | Session truth | Usage | Claim |
| --- | --- | --- | --- | --- |
| Claude Code | `~/.claude/settings.json` | hook + `~/.claude/sessions/<pid>.json` + process liveness | official endpoint (opt-in), transcripts | Verified |
| Codex CLI and desktop | `~/.codex/config.toml` (trust hash computed locally) | hook + SessionEnd/interrupt + rollout tail + liveness | native | Reviewed; real turns pending the owner's quota reset (2026-09-14) |
| Gemini CLI | `~/.gemini/settings.json` (`hooks`) | hook + `~/.gemini/tmp/*/chats` tail | derived tier | Verified on the derived tier; higher tiers reviewed |
| Pi | `~/.pi/agent/extensions/jrbar.ts` | extension events + `~/.pi/agent/sessions` tail | none | Verified (pi 0.73.1 emits no ask events, so pi has no ask lane) |
| Grok, Devin, OpenCode, OpenClaw, Antigravity | provider config or plugin | hook + liveness | native where the provider exposes it | Verified |
| Cursor, Hermes Agent, Kiro | provider config | hook + liveness | Cursor native | Best effort: not installed on the owner's Mac |
| OpenAI API org usage | credentials in Keychain | n/a | native | Reviewed, opt-in |

A hook shape changing upstream degrades that provider to `stale` or
`missing` in `state.health.hooks` and in `jrbar hooks doctor`; JR-Bar never
makes a false zero. Detail per provider is in
[NATIVE-PROVIDERS.md](NATIVE-PROVIDERS.md).

## Neighbours

| Integration | Claim |
| --- | --- |
| T3 Code | Read-only SQLite projection, `sqlite-readonly-v1`, reviewed window 0.0.33 through 0.0.33 as recorded in the packaged `integration_compatibility.json`. Additive columns are accepted; a missing required column fails closed as unsupported. Never writes, never runs T3 commands, never reads T3 credentials. |
| Alcove | The Screen Bar reads Alcove's capsule width through the window list (Screen Recording permission) and follows it; verified with Alcove 1.7.9. Without permission or without Alcove the bar keeps its measured notch geometry. |
| Tailscale | Optional. Used only to discover peers; the transport is `sftp` over SSH, never a remote command. |
| CodexBar | An engineering reference for the forecast and refresh discipline; nothing is exchanged at runtime. |

## SidePulse installs

0.8 migrates a SidePulse 0.7 install automatically (files, hooks,
LaunchAgents, Keychain items). The `sidepulse` command, the `sidepulse.*`
import shim and the `SIDEPULSE_*` environment fallbacks are supported for
this release only.

## Reporting

Reproducible, non-sensitive compatibility problems go to the
[issue tracker](https://github.com/JonathanRReed/JR-Bar/issues) with the
JR-Bar version, macOS version, provider or integration version, hardware,
and sanitised `jrbar doctor` / `jrbar hooks doctor` output. Security and
privacy reports stay private under [SECURITY.md](../SECURITY.md).
