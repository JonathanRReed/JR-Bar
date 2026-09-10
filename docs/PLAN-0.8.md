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
alerts, auto-dim by time/ambient light/screen brightness (done 2026-09-10:
the `auto_dim` setting).

## Delete

iOS app and its Mac half, Agent Deck, Waybar client, weather, timebox/timer,
operator export, architecture-policing meta-tests, dead code.

## Phases

| Phase | Deliverable | Status |
| --- | --- | --- |
| A | Stale-session truth: process registry + 5 s liveness sweep, Codex SessionEnd/Interrupt hooks, local Codex trust hashes; hooks reinstalled from this checkout; dev checkout runs as the LaunchAgent | done 2026-09-09 (kill-to-ended measured at 2 s; Codex turn testing deferred to 2026-09-14 when the usage limit resets) |
| B | Deletions (iOS, Agent Deck, Waybar, weather, timebox, export, night warmth: -14k lines) and the full SidePulse→JR-Bar rename with live migration of config/state/hooks/LaunchAgents on the Mac | done 2026-09-09 (signed PKG moves to Phase F once the app bundle nests the daemon) |
| C | Daemon boundary: `python -m jrbar core` headless, core_server + core_projection, compiled `jrbar-hook` shim, Swift app becomes the UI on this Mac | done 2026-09-09 (headless controller serves protocol 1 on `core.sock`; every command the app sends is real, including the app-proposed Effect Studio and `usage_history` extensions; shim 6 ms per hook spawn of which ~3 ms is the shim vs 88 ms for the Python client; `jrbar hooks doctor`; the Mac runs two LaunchAgents from `scripts/install-agents.sh`: `com.jonathanreed.jrbar.core` (installed venv in `~/.local/share/jrbar`, not the checkout: launchd jobs reading `~/Downloads` block on a TCC prompt) and `com.jonathanreed.jrbar.ui` (`~/Applications/JR-Bar.app`); the Python status-bar agent is booted out and its plist parked in `~/.local/state/jrbar`. Revert: `launchctl bootout gui/$UID/com.jonathanreed.jrbar.ui`, `launchctl bootout gui/$UID/com.jonathanreed.jrbar.core`, then `.venv/bin/python -m jrbar status-bar start`. Re-run `scripts/install-agents.sh` after each commit that should be running) |
| D | Swift app: LEDS engine (firmware-parity), Screen Bar, protocol client, glass panel, Settings window, tooltip/click, notifications, history, icon styles, core supervision | mostly done 2026-09-09 (against the mock daemon; live switch happens with C) |
| E | Swift Settings, Control Center, Usage, Effects, Calibration, Activity History | pending |
| F | Hardware verification (Pro, Dot, linked mode, Creator Micro 2), Pi + Gemini providers, Sparkle + notarization | in progress 2026-09-10: the Creator Micro 2 is in the daemon (`state.deck`, the `deck_*` commands, `deck_input` / `deck_receipt` events, the session-key answer rule; verified against the fake HID pad and live in the absent/unapproved states since the owner's pad was off on 2026-09-10); auto-dim (schedule / display / ambient light) replaces night warmth and was verified live with a schedule covering now; the first-batch Dot (`/Volumes/PulseDot`) is detected as a 2-LED Dot with a stable serial id and gets a 2-LED program; Pro + Dot linked mode (`devices_linked`, default on) writes both in one worker command with 11 ms measured skew; session labels are human (Claude session names, Codex titles, cwd); `lights.why` is a documented enum with `why_detail`; usage windows are `5h`/`7d`/…; pi (extension) and Gemini CLI (settings.json hooks) are providers with shim hooks and transcript fallbacks, every provider re-pointed at the shim by `install-agents.sh`; packaging landed 2026-09-10: `make package` builds one signed bundle (Swift app + `Contents/Helpers/jrbar-core.app`, the PyInstaller-frozen daemon, + `Contents/Helpers/jrbar-hook` + Sparkle 2.9.6) and `dist/JR-Bar-0.8.0.pkg` / `.zip`, Developer ID signed with hardened runtime, verified by `packaging/verify_macos_app.py`; the app supervises the bundled daemon, re-points every provider's hook at the bundled shim on the first launch of a build and registers itself as a login item; `make clean-install` / `scripts/install-agents.sh --pkg` install the PKG into `~/Applications` without a password and park the dev LaunchAgents (`packaging/README.md`, `docs/PRODUCTION-RELEASE.md`). Still pending: notarization (`jrbar-notary` profile), the signed appcast (the keychain's only Sparkle key, account `ed25519`, is not the committed public key), the in-app Sparkle updater, Creator Micro 2 hardware |

## Definition of done

When the work is declared done, the Mac must be running the latest commit: rebuild `app/build/JR-Bar.app` and `hook/build/jrbar-hook`, run `scripts/install-agents.sh` (installs the package, shim and app outside `~/Downloads` and reloads both LaunchAgents), and verify the running daemon and app come from HEAD (the daemon's `doctor` reply carries `commit`, written by the install script; `-dirty` means uncommitted changes were installed). Then commit everything and `git push origin main`.

## Open items needing Jonathan

- `xcrun notarytool store-credentials jrbar-notary --apple-id ... --team-id AJ9VWBRNZN`
- Plug in the Dot when Phase F asks.
