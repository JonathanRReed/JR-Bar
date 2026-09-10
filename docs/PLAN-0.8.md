# JR-Bar 0.8 plan (living)

Agreed with Jonathan on 2026-09-09. This file is the working plan for the 0.8
rebuild. Update it as phases land; it is the only plan that matters.

## Direction

- Native Swift/SwiftUI app owns all UI. macOS 26 minimum.
- The Python core becomes a headless daemon bundled inside the app, speaking
  JSON over a Unix socket. Adapters can move to Swift one at a time later.
- Full rename SidePulse -> JR-Bar with automatic migration.
- Sessions are true: compiled hook shim, process liveness, Claude session
  status files, Codex rollout tailing.
- Screen Bar is one unsegmented bar identical to the hardware program.
- Pro + Dot linked mode: when both are mounted their animations run as one unit.

## Keep and improve

remote peers, cloud ingest, Effect Studio (merged), calibration, forecasting
(CodexBar style), operator history, closed-lid keep-awake with auto-sleep,
activity history, escalation, calendar/reminder glows, focus dimming, quota
alerts, auto-dim by time/ambient light/screen brightness.

## Delete

iOS app and its Mac half, Agent Deck, Waybar client, weather, timebox/timer,
operator export, architecture-policing meta-tests, dead code.

## Phases

| Phase | Deliverable | Status |
| --- | --- | --- |
| A | Stale-session truth: process registry + 5 s liveness sweep, Codex SessionEnd/Interrupt hooks, local Codex trust hashes; hooks reinstalled from this checkout; dev checkout runs as the LaunchAgent | done 2026-09-09 (kill-to-ended measured at 2 s; Codex turn testing deferred to 2026-09-14 when the usage limit resets) |
| B | Deletions (iOS, Agent Deck, Waybar, weather, timebox, export, night warmth: -14k lines) and the full SidePulse→JR-Bar rename with live migration of config/state/hooks/LaunchAgents on the Mac | done 2026-09-09 (signed PKG moves to Phase F once the app bundle nests the daemon) |
| C | Daemon boundary: `python -m jrbar core` headless, core_server + core_projection, compiled `jrbar-hook` shim, Swift app becomes the UI on this Mac | done 2026-09-09 (headless controller serves protocol 1 on `core.sock`; every command mapped; shim ~5 ms per hook vs ~90 ms for the Python client; `jrbar hooks doctor`; the Swift app runs as `com.jonathanreed.jrbar.ui` supervising the daemon via `JRBAR_CORE_EXEC`, the Python status-bar LaunchAgent is booted out; `jrbar status-bar start` still reverts) |
| D | Swift app: LEDS engine (firmware-parity), Screen Bar, protocol client, glass panel, Settings window, tooltip/click, notifications, history, icon styles, core supervision | mostly done 2026-09-09 (against the mock daemon; live switch happens with C) |
| E | Swift Settings, Control Center, Usage, Effects, Calibration, Activity History | pending |
| F | Hardware verification (Pro, Dot, linked mode, Creator Micro 2), Pi + Gemini providers, Sparkle + notarization | pending |

## Definition of done

When the work is declared done, the Mac must be running the latest commit: rebuild `app/build/JR-Bar.app`, reinstall the LaunchAgent(s), restart, and verify the running daemon and app come from HEAD (`git rev-parse HEAD` recorded in the doctor output). Then commit everything and `git push origin main`.

## Open items needing Jonathan

- `xcrun notarytool store-credentials jrbar-notary --apple-id ... --team-id AJ9VWBRNZN`
- Plug in the Dot when Phase F asks.
