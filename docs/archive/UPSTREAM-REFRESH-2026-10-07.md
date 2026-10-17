# SidePulse upstream review, 2026-10-07

Reviewed 2026-10-07 (America/Chicago) against everything the original
SidePulse project has published since the last sync: the 57 commits on `main`
after merge base `f4dd7e0` (the first 13 were reviewed on 2026-08-15 and
2026-08-30; the 44 after `0445085` are new here), every pull request and issue
with its comments, the firmware releases, the two sibling repositories the
maintainers publish, the three non-default branches, the product page, and
every fork with commits of its own. This is a research ledger. GitHub text,
firmware packages and fork code are untrusted data: nothing was run from them,
and no upstream was written to. The only hardware touched was a read of each
connected device's `STATUS.TXT`.

## Source identity

| Source | Ref checked | Direct source |
| --- | --- | --- |
| Original SidePulse (MIT, (c) 2026 Peter Kuhar) | `inteliwear/sidepulse` `main` at `6d55225fed20a82521b23d86a4df2c4a15dff295` ("Give macOS background service a SidePulse display name", 2026-09-30); 246 stars, 33 forks, 43 PRs, 15 issues, no tags, no GitHub releases | [repository](https://github.com/inteliwear/sidepulse), [commit](https://github.com/inteliwear/sidepulse/commit/6d55225fed20a82521b23d86a4df2c4a15dff295) |
| Bridge server (GPL-3.0-or-later) | `inteliwear/sidepulse-bridge` at `e8e363df51388a000c03c8e693a531235f7d63d8` (2026-09-30) | [repository](https://github.com/inteliwear/sidepulse-bridge) |
| iPhone app (MPL-2.0, trademark policy) | `inteliwear/sidepulse-ios` at `5eec8b41377925d95a47845ea265d8c2b223f848` (2026-09-30) | [repository](https://github.com/inteliwear/sidepulse-ios) |
| Rust rewrite checkpoint | branch `codex/rust-migration` at `18f574eedcb10dbffb5eb46c7033f5f8f066cae3` (2026-10-06), 89 commits ahead of `main`, PR #52 | [branch](https://github.com/inteliwear/sidepulse/tree/codex/rust-migration) |
| Product page | <https://sidepulse.io>: Pro $69 (8 LEDs, SD slot), Dot $29 (2 LEDs, USB-C); no changelog, firmware table, FAQ or macOS compatibility statement | [sidepulse.io](https://sidepulse.io) |
| JR-Bar | `lane/upstream-sidepulse` from `main` at `3864d17952c4eebbac1ed8457644b94539989bab` | local |
| Devices on this desk (read-only `STATUS.TXT`) | Pro `SPP-000067`, `release_version 1.0.2`; Dot `SPD-000120`, `app_version 1.0.4` | local |

Disposition words used below: **ported** (JR-Bar change, with its commit),
**superseded** (JR-Bar already does it, where), **not applicable** (and why),
**risk** (a report that points at a JR-Bar exposure), **waiting on evidence**
(plausible, but nothing here can prove it), **rejected** (conflicts with an
AGENTS.md standing decision).

## What this review changed in JR-Bar

| Commit | Change | Test |
| --- | --- | --- |
| `708596d0` | A command whose output merely mentions a traceback is no longer read as a failed tool (upstream #48) | `tests/test_upstream_2026_10_hook_state.py` |
| `1b179c5d` | The SD eject guard keeps one retry timer per disk, stops after 240 tries, logs only the first dissent, trims its own log past 10 MB (upstream #42 and `0445085`) | `tests/test_sd_eject_guard_retry_table.py` (compiles the retry table with the system C compiler) |
| `833df71f` | `jrbar firmware version [--json]`: model, release and "newer release published" from each device's own `STATUS.TXT`, read-only and offline | `tests/test_device_firmware.py` |
| docs commit (this note) | `LEDS_FORMAT.md` names the drives the firmware notes name; `ATTRIBUTION.md` carries upstream's trademark wording; `scripts/check_upstreams.py` follows the two sibling repositories | `tests/test_check_upstreams.py` |

## Hardware and firmware findings

1. **Firmware is now distributed in the upstream repository**
   ([`firmware/README.md`](https://github.com/inteliwear/sidepulse/blob/6d55225fed20a82521b23d86a4df2c4a15dff295/firmware/README.md)):
   Pro 1.1.0 and Dot 1.1.0 / 1.1.14, installed by copying `FIRMWARE.BIN` to
   the drive and waiting 10 seconds. The packages are encrypted
   (`fw_cipher chacha20-poly1305` in the Dot's `STATUS.TXT`), with a
   `SHA256SUMS.txt` beside each. The Pro's drive is `SidePulse`, the Dot's is
   `PulseDot`. **Both devices here are behind**: the Pro runs 1.0.2, the Dot
   1.0.4. `jrbar firmware version` now says so. Updating is a manual copy;
   JR-Bar does not write `FIRMWARE.BIN` (see "Not ported" below).
2. **DSL unchanged.** `LEDS_FORMAT.md` is byte-identical between `f4dd7e0` and
   `6d55225` and `sdled.wasm` has the same blob hash as ours
   (`524a7639...`), so the packaged firmware parser JR-Bar validates against is
   the one upstream still ships. All 35 `.LED` programs upstream ships
   (cyan, ember, purple families, KITT, night rider, lid looks) pass JR-Bar's
   firmware-parser check at their device's LED count and our 512-byte / 20-line
   gate (largest: `kitt-8.LED`, 450 bytes). The bridge's agent instructions
   (`repeat N`, `roll`, per-index timing) describe syntax JR-Bar already
   documents.
3. **STATUS.TXT fields.** Pro: `release_version`, `firmware_version`,
   `firmware_slot`, `active_slot`/`target_slot`, `ota`, `uptime_ms`. Dot:
   `app_version`, `app_build`, `fw_state`, `fw_msg`, `fw_reboot`, `ticks`.
   Both: `serial` (`SPP-` / `SPD-`). JR-Bar's identity code already keys on
   the serial prefix, and `device_clock` already reads `uptime_ms` / `ticks`
   past the host cache. No field JR-Bar reads changed. The non-idle values of
   `ota` / `fw_state` are not documented, so JR-Bar does not yet pause writes
   during an update (waiting on evidence: capture a `STATUS.TXT` mid-update).
4. **Keepalive.** Upstream moved from `touch keepalive` to an uncached read of
   `STATUS.TXT` (`05bc5ed`, `2f8e6af`), because read-only mounts refuse the
   write. JR-Bar already does this first (`status_bar_legacy._keepalive_fresh_read`,
   `touch` only if the clock did not move). Superseded.
5. **Read-only storage** (`05bc5ed`): firmware 1.1+ lets a Pro take programs
   through SD reads of `setup.html` ("READ2ME") and a Dot through a USB
   vendor control interface (`1a86:fe10`, "SPC2"), for Macs whose storage
   policy mounts the drives read-only. Not applicable here (no managed
   storage policy, and both devices are on pre-1.1 firmware). A write that
   fails on a read-only mount already surfaces as a device error.
6. **Brightness and colour (Pro 1.1.0).** The release notes say the Pro now
   uses "calibrated WS2816 red, green, and blue gains", applies "brightness and
   color balance together, with a single final rounding to 16-bit LED output",
   and that "source colors and animation interpolation remain 8-bit". The Dot
   notes say existing brightness behaviour is retained. See the LED review
   below.
7. **Multiple Dots.** Dot 1.1.14 "improves drive identification when using
   multiple Dots" and Android USB compatibility. JR-Bar identifies by serial
   already and accepts `PulseDot ...` volume names.

## LED lane review: `lift_emission_to_floor` against upstream's rules

Upstream's host app has no brightness floor, no gamma and no strip transfer:
it writes `brightness N` and colour bytes, and `LEDS_FORMAT.md` says
"Brightness scales the RGB values". JR-Bar's own model (colour byte times
`brightness / 255` is the drive code; linear PWM, `STRIP_CODE_TO_LIGHT_EXPONENT = 1.0`)
agrees with that sentence, and with the Pro 1.1.0 note that brightness and
balance are multiplied before one rounding. So the *rule* the LED lane's floor
relies on (the die sees colour times scalar) is consistent with the firmware.

What differs is the *rounding*. The drive-12 emission target
(`STRIP_VISIBLE_EMISSION_DRIVE`), the hue-holding drive of 3, and the
hue-readable lift of 14 exist because, on firmware before 1.1.0, brightness
and balance rounded separately and a dim colour lost its hue (the green die
won). That matches the Pro on this desk (1.0.2) and every Dot (1.1.0 changes
nothing for it). On a Pro at 1.1.0 or later the floors are conservative: a dim
colour keeps its hue, so the lift makes the strip brighter than strictly
necessary, never the wrong hue. **No discrepancy for today's hardware.**

The one interaction to watch is the owner-tuned channel gain (green near 0.38):
it was measured against the old, uncorrected die imbalance. A Pro on 1.1.0
corrects balance itself, so the stored gain would stack on top and over-correct
(white drifting magenta). `jrbar firmware version` prints this note for a Pro
at 1.1.0 or later. Recommendation when the Pro is updated: reset the channel
gains and run Calibrate again; whether JR-Bar should bypass the gains by
itself on 1.1.0+ needs a measurement on a 1.1.0 Pro.

## Commits after `0445085` (44), one row each

| Commit | Upstream change | Disposition |
| --- | --- | --- |
| [`49827c2`](https://github.com/inteliwear/sidepulse/commit/49827c2) #37 | Find the event socket across state dirs; provider icons by app name | Superseded: `state_paths.candidate_state_dirs`, `hook_client` (see 2026-08-30 ledger). Icons: not applicable, the Swift app resolves its own. |
| [`1afa8fe`](https://github.com/inteliwear/sidepulse/commit/1afa8fe) #35 | Cursor as a hook provider | Superseded: Cursor in `providers.py` / `install.py`. |
| [`e0d578f`](https://github.com/inteliwear/sidepulse/commit/e0d578f) #38 | Animation profiles, shared `.LED` library, customization | Superseded: Effect Studio, effect packs, scene packs (`effect_packs.py`, `scene_packs.py`); the shipped programs pass our parser (above). |
| [`8482d7f`](https://github.com/inteliwear/sidepulse/commit/8482d7f) #31 | Drop `-d` from `caffeinate` | Superseded: adapted 2026-08-29 (`power_policy`, `keep_awake`). |
| [`2178d8b`](https://github.com/inteliwear/sidepulse/commit/2178d8b) #39 | `macos-sd-diagnostics.sh`: eject-guard state and `diskarbitrationd` / kernel log queries | Not applicable as a script; the knowledge ("`kind = disk eject` from loginwindow means macOS started the eject") is what the guard already acts on. `jrbar sdejectguard logs` covers the guard's own logs. |
| [`cd01d69`](https://github.com/inteliwear/sidepulse/commit/cd01d69), [`4063ee6`](https://github.com/inteliwear/sidepulse/commit/4063ee6) #40, #41 | Idle patterns across profiles; centre-bright idle gradient | Not applicable: JR-Bar draws idle per device in `motion_shapes.py`. |
| [`8edca48`](https://github.com/inteliwear/sidepulse/commit/8edca48) | One-command installer, calendar releases | Not applicable: JR-Bar ships a signed package (`scripts/release.sh`). |
| [`16526e1`](https://github.com/inteliwear/sidepulse/commit/16526e1) | Revert "Write LED programs in place" | Superseded: JR-Bar writes a scratch file and renames, with readback (`device_writer.py`). |
| [`f9f1d84`](https://github.com/inteliwear/sidepulse/commit/f9f1d84) | Recover agent state after the status bar restarts | Superseded: activity ledger and `reconcile_cursors.py`. |
| [`c39ac1f`](https://github.com/inteliwear/sidepulse/commit/c39ac1f) | iOS app moved out; native hook capture experiment | Not applicable (separate repository; C++ capture experiment is the idea behind our C `jrbar-hook`). |
| [`fc2474c`](https://github.com/inteliwear/sidepulse/commit/fc2474c), [`aeff0f9`](https://github.com/inteliwear/sidepulse/commit/aeff0f9), [`efc8ce8`](https://github.com/inteliwear/sidepulse/commit/efc8ce8), [`77b35ad`](https://github.com/inteliwear/sidepulse/commit/77b35ad), [`13ed504`](https://github.com/inteliwear/sidepulse/commit/13ed504), [`c4eac7d`](https://github.com/inteliwear/sidepulse/commit/c4eac7d) | `sidepulse link`: pair an iPhone through the bridge, QR rendering | Rejected: an outbound relay to `bridge.sidepulse.io`; AGENTS.md says nothing leaves the Mac without opt-in. |
| [`0af7434`](https://github.com/inteliwear/sidepulse/commit/0af7434), [`3de64bd`](https://github.com/inteliwear/sidepulse/commit/3de64bd), [`d1e77fd`](https://github.com/inteliwear/sidepulse/commit/d1e77fd), [`a20833c`](https://github.com/inteliwear/sidepulse/commit/a20833c), [`8a5b46f`](https://github.com/inteliwear/sidepulse/commit/8a5b46f), [`330ccbb`](https://github.com/inteliwear/sidepulse/commit/330ccbb), [`a9ade22`](https://github.com/inteliwear/sidepulse/commit/a9ade22) | Targeted writes, push notifications, linked-phone menu, key handling, unlink | Rejected, same reason. |
| [`d09f42b`](https://github.com/inteliwear/sidepulse/commit/d09f42b) | CLI on Linux | Not applicable (macOS only). |
| [`776f7cd`](https://github.com/inteliwear/sidepulse/commit/776f7cd), [`45f24d9`](https://github.com/inteliwear/sidepulse/commit/45f24d9) | Headless remote agent relay (marked work in progress) | Rejected as built (default-on relay; see issue #57). JR-Bar's remote observation is opt-in, authenticated and read-only. |
| [`1249a26`](https://github.com/inteliwear/sidepulse/commit/1249a26) | JetBrains Junie agent support | Waiting on evidence: Junie is not installed here, so a hook cannot be verified live. |
| [`95f9bbd`](https://github.com/inteliwear/sidepulse/commit/95f9bbd) | Flush LED writes to the device on Omarchy Linux (directory sync) | Not applicable (Linux). The file is already `fsync`ed on macOS. |
| [`f4098e0`](https://github.com/inteliwear/sidepulse/commit/f4098e0), [`8395c33`](https://github.com/inteliwear/sidepulse/commit/8395c33) | `version` command; `write` asks for content | Not applicable: `jrbar` has its own. |
| [`53f2cf8`](https://github.com/inteliwear/sidepulse/commit/53f2cf8), [`6d55225`](https://github.com/inteliwear/sidepulse/commit/6d55225), [`f206fad`](https://github.com/inteliwear/sidepulse/commit/f206fad) | Restart the service on upgrade; the service's Login Items name; install Python with uv | Not applicable: the package installs and restarts the app, and JR-Bar ships no Python install step. |
| [`6744439`](https://github.com/inteliwear/sidepulse/commit/6744439) | Codex `Interrupt` hook | Superseded: `collector.py` maps `Interrupt` to idle; `codex_hook_trust.py` installs it. |
| [`441ed38`](https://github.com/inteliwear/sidepulse/commit/441ed38) | Simplified menu-bar settings, shared update installer | Not applicable (PyObjC controller; JR-Bar's Settings is SwiftUI). |
| [`f939c4a`](https://github.com/inteliwear/sidepulse/commit/f939c4a), [`fedc0ad`](https://github.com/inteliwear/sidepulse/commit/fedc0ad) | Keep the internal display off with the lid closed through private framebuffer power calls; removed five days later | Risk checked, absent: JR-Bar has no `IOMobileFramebuffer` use (see issue #51). |
| [`48a04b8`](https://github.com/inteliwear/sidepulse/commit/48a04b8) | Closed-lid display sleep: `pmset displaysleepnow` once the lid is closed with no external display, plus `docs/design/closed-lid-power.md` | Waiting on evidence: JR-Bar holds `disablesleep` and sleeps explicitly on release (`lid_sleep.py`). Whether the built-in panel stays lit under `disablesleep` with the lid shut needs a hand check on this Mac. |
| [`74aa7c4`](https://github.com/inteliwear/sidepulse/commit/74aa7c4) | `write_led_raw.py`: raw FAT12 write to `/dev/rdiskN` for an unmounted device | Rejected: a `sudo` write to a raw disk is exactly the device write AGENTS.md forbids from scripts and tests. |
| [`05bc5ed`](https://github.com/inteliwear/sidepulse/commit/05bc5ed), [`2f8e6af`](https://github.com/inteliwear/sidepulse/commit/2f8e6af) | Read-only mounts: READ2ME and SPC2 transports; keepalive becomes a `STATUS.TXT` read | Keepalive superseded (above). Transports not applicable (above). |
| [`0454ef5`](https://github.com/inteliwear/sidepulse/commit/0454ef5) | `sidepulse firmware version / upgrade`, v1.1.0 OTA packages | Ported read-only half in `833df71f`; the upgrade half is not ported (a download-and-flash command; JR-Bar never writes `FIRMWARE.BIN`, and a fetch of release data would be a new outbound request). |
| [`85f5c38`](https://github.com/inteliwear/sidepulse/commit/85f5c38) | Dot 1.1.14 OTA | Recorded in `device_firmware.LATEST_KNOWN_VERSIONS`. |

The 13 commits from `e30ec59` to `0445085` keep the dispositions in
[UPSTREAM-REFRESH-2026-08-30.md](../UPSTREAM-REFRESH-2026-08-30.md) and
[UPSTREAM-SYNC.md](../UPSTREAM-SYNC.md), with one correction: `0445085`
("Reduce SidePulse memory and log churn") cut the eject guard's per-retry log
line and truncated its log at 10 MB, and JR-Bar had not taken it. `1b179c5d`
does, in our own words.

## Pull requests (43), one row each

| PR | Title (state) | Disposition |
| --- | --- | --- |
| [#58](https://github.com/inteliwear/sidepulse/pull/58) | GitHub Copilot hooks; Codex automatic-review status (open, 2026-10-02) | Copilot: waiting on evidence (not installed). Codex automatic review: **risk**. Codex fires `PermissionRequest` when it evaluates an escalation, and with `approvals_reviewer = auto_review` a reviewer grants most without a person; the status then reads Ask for the length of the command. This Mac's Codex is `approval_policy = "never"` with `approvals_reviewer = "user"`, so it does not reach us today; it would if that changes. The PR's fix needs reviewer metadata read from the transcript tail, which cannot be verified without a real auto-review session. |
| [#56](https://github.com/inteliwear/sidepulse/pull/56) | Socket commands to show, hold and clear an LED program (open) | Superseded in part: `preview_program` (timed) and `play_lid_preset` in `docs/CORE-PROTOCOL.md`. An indefinite hold for Home Assistant is not wanted. |
| [#53](https://github.com/inteliwear/sidepulse/pull/53) | Read timeout on the hook event server (open) | Superseded: `hook_ingress` bounds every read (0.25 s) and every connection (5 s). A stalled client cannot wedge the accept loop. |
| [#52](https://github.com/inteliwear/sidepulse/pull/52) | Rust migration checkpoint, 57k lines (open) | Not applicable. Worth watching: keepalive in the Rust service is still a `touch keepalive` (`sidepulse-device/src/lib.rs`), so upstream's own two implementations disagree about it. |
| [#50](https://github.com/inteliwear/sidepulse/pull/50) | Recognise a closing question however phrased (open) | Waiting on evidence. JR-Bar's `_assistant_message_asks_question` also misses "Do you mean A, or B?" (no allow-listed prefix), but it is tuned against phantom asks and has a test table; loosening it needs a sample of real closing lines. Next action: measure on local hook logs before changing. |
| [#49](https://github.com/inteliwear/sidepulse/pull/49) | Move the on-screen strip to the top-right (open) | Not applicable: JR-Bar's Screen Bar has its own placement. |
| [#48](https://github.com/inteliwear/sidepulse/pull/48) | Stop reading tool output text as a tool failure (open) | **Ported**, `708596d0`. JR-Bar had the same text match in the transcript reader. |
| [#46](https://github.com/inteliwear/sidepulse/pull/46) | A fifth LED state, Blocked, separate from Ask (open) | Superseded: failure has its own colour (`ERROR_RED`) and rhythm, with dichromacy tests (`led_status.py`, `colors.separated_error_color`). |
| [#44](https://github.com/inteliwear/sidepulse/pull/44) | Clear pending approvals when a subagent stops (open) | Superseded; pinned by a regression test in `708596d0`'s test file (a stopped subagent clears its own asks, a sibling's stay). |
| [#43](https://github.com/inteliwear/sidepulse/pull/43) | Menu-bar status text optional (open) | Not applicable: the status item is the icon only. |
| [#42](https://github.com/inteliwear/sidepulse/pull/42) | Stop mount-retry timers accumulating per eject (open) | **Ported**, `1b179c5d`. |
| [#41](https://github.com/inteliwear/sidepulse/pull/41), [#40](https://github.com/inteliwear/sidepulse/pull/40), [#39](https://github.com/inteliwear/sidepulse/pull/39), [#38](https://github.com/inteliwear/sidepulse/pull/38) | Merged 2026-09-01 | See the commit table. |
| [#37](https://github.com/inteliwear/sidepulse/pull/37), [#35](https://github.com/inteliwear/sidepulse/pull/35), [#31](https://github.com/inteliwear/sidepulse/pull/31), [#9](https://github.com/inteliwear/sidepulse/pull/9) | Merged | See the commit table and earlier ledgers. |
| [#36](https://github.com/inteliwear/sidepulse/pull/36) | Read Control Center brightness via DisplayServices (open) | Superseded: `display_brightness.py` already prefers DisplayServices and falls back to `BrightnessMilliNits`. |
| [#34](https://github.com/inteliwear/sidepulse/pull/34) | Push server serves its own shared secret (closed) | Not applicable: JR-Bar has no push server. Pattern noted: never render a credential into a page. |
| [#33](https://github.com/inteliwear/sidepulse/pull/33) | Rate-limit LED writes, keep the trailing edge (closed; "will be fixed elsewhere") | Superseded: latest-wins hardware worker (`hardware_write_policy.py`, `runtime_scheduler.py`). The maintainer's own comment names the cause as inefficient animation updates. |
| [#32](https://github.com/inteliwear/sidepulse/pull/32) | Run hooks off the critical path (closed; "native rewrite instead") | Superseded: C `jrbar-hook` plus a bounded ordered FIFO. |
| [#30](https://github.com/inteliwear/sidepulse/pull/30) | Stale and stuck session states (closed) | Superseded, except the long-ask horizon below. |
| [#29](https://github.com/inteliwear/sidepulse/pull/29) | Idle LEDs off; KITT scanner (closed) | Superseded: idle auto-off in `brightness_policy.py`; scanner rejected earlier as noise. |
| [#28](https://github.com/inteliwear/sidepulse/pull/28) | Do Not Disturb with a schedule (closed) | Superseded: `dnd_policy.py`, `dnd_controller.py`. |
| [#27](https://github.com/inteliwear/sidepulse/pull/27), [#22](https://github.com/inteliwear/sidepulse/pull/22) | Remote monitoring over SSH (closed, split out) | Rejected as host management; see 2026-08-30 ledger. |
| [#26](https://github.com/inteliwear/sidepulse/pull/26) | Idle LEDs when the lid is closed; Clear Agents (open) | Superseded: lid presets (`lid_presets.py`), `clear_agents.py`. |
| [#21](https://github.com/inteliwear/sidepulse/pull/21) | Persist keep-awake; skip `caffeinate` on battery (open) | Superseded: `keep_awake.py` yields on low battery, thermal and Low Power Mode. |
| [#20](https://github.com/inteliwear/sidepulse/pull/20) | Keep LEDs from sticking on green or idle (open) | Superseded by the LED lane (`2cbc2d7a`, `6f27e5e2`). Its idea of not letting a battery preview override a working strip is in `active_led_display_kind`. |
| [#19](https://github.com/inteliwear/sidepulse/pull/19) | Invocation-scoped Claude monitoring (open) | Superseded: `watch_run.py`. |
| [#17](https://github.com/inteliwear/sidepulse/pull/17) | Polish local status bar runtime (open) | Not applicable (PyObjC controller). |
| [#16](https://github.com/inteliwear/sidepulse/pull/16), [#14](https://github.com/inteliwear/sidepulse/pull/14), [#13](https://github.com/inteliwear/sidepulse/pull/13), [#11](https://github.com/inteliwear/sidepulse/pull/11), [#8](https://github.com/inteliwear/sidepulse/pull/8), [#7](https://github.com/inteliwear/sidepulse/pull/7), [#5](https://github.com/inteliwear/sidepulse/pull/5) | Kiro, OpenCode and T3 Code, Hermes (two), Cursor (two), Antigravity | Superseded at the provider-adapter level (`providers.py`, `provider_adapters.py`, `t3_compat.py`); Kiro and Hermes are not installed here (waiting on evidence). |
| [#15](https://github.com/inteliwear/sidepulse/pull/15) | Completed-session visibility setting (closed) | Superseded: `completion_visibility.py`. |
| [#10](https://github.com/inteliwear/sidepulse/pull/10) | Expanded diagnostics and a bounded bundle (open) | Superseded: `doctor.py` with a fixed vocabulary and a previewable export. |
| [#6](https://github.com/inteliwear/sidepulse/pull/6) | Codex usage-limit completion (open) | Superseded: transcript reconciliation (`transcript_runtime.py`). |

## Issues (15), one row each

| Issue | Title (state) | Disposition |
| --- | --- | --- |
| [#57](https://github.com/inteliwear/sidepulse/issues/57) | Make the remote relay opt-in (open) | Confirms a standing decision: a default-on relay with a capability code printed in setup output is what JR-Bar's "nothing leaves the Mac without opt-in" avoids. |
| [#55](https://github.com/inteliwear/sidepulse/issues/55) | Keep an interface for third-party event clients after the Rust migration (open) | **Risk**: the opencode-sidepulse plugin (third party) sends events to `~/.local/state/sidepulse/agent-monitor/events.sock` and, when nothing answers, writes `LEDS.LED` itself. JR-Bar listens elsewhere, so that plugin would become a second writer racing the device. Do not install it next to JR-Bar's own OpenCode integration. |
| [#54](https://github.com/inteliwear/sidepulse/issues/54) | Homebrew distribution for the Rust release (open) | Not applicable. |
| [#51](https://github.com/inteliwear/sidepulse/issues/51) | Closing the lid crashes WindowServer, also with sleep prevention off (open; macOS 26.5.2 and 26.6.2, SD and USB devices) | Not reachable: the report traces to upstream's private `IOMobileFramebufferRequestPowerChange` calls (`f939c4a`, removed in `fedc0ad`). JR-Bar has none (`grep` of `src/` and `app/Sources/` finds no framebuffer call; it uses `pmset disablesleep` and `sleepnow` only). |
| [#47](https://github.com/inteliwear/sidepulse/issues/47) | Status bar blocks the main thread 4.5 minutes on a cold boot, bouncing Python icon (open; macOS 27.0) | Not applicable: JR-Bar's daemon is headless and started by the Swift app's supervisor, and the UI is a Swift app, so no Python interpreter bundle is the app a user sees in the Dock. Its cause (a synchronous recovery scan before the socket listens) is the pattern `hook_pending.py`'s bounded first-pass drain already avoids. |
| [#45](https://github.com/inteliwear/sidepulse/issues/45) | Colour themes per agent (open) | Superseded: per-provider colours and identity palettes. |
| [#25](https://github.com/inteliwear/sidepulse/issues/25) | Battery preview on plug/unplug often not rendered (open) | Waiting on evidence. JR-Bar's preview deadline starts at detection (`battery_preview_until`) and detection polls `ioreg` at most every 5 s, so the same "preview expired before the write" race is conceivable. Upstream's fix, an `IOPSNotificationCreateRunLoopSource` notification (`power_source_notifications.py`), needs a run loop the headless daemon does not have. Reproduce with a write trace first. |
| [#24](https://github.com/inteliwear/sidepulse/issues/24) | Hybrid battery plus agent LEDs (open) | Waiting on evidence for a fixed 1+7 layout; arbitrary segments rejected, as in the 2026-08-30 ledger. |
| [#23](https://github.com/inteliwear/sidepulse/issues/23) | "Disk Not Ejected Properly" after suspend/resume on macOS 26 (open, no comments) | **Risk**, waiting on evidence. A USB re-enumeration cannot be vetoed by a software-eject guard. JR-Bar's guard also matches only volume names starting `SidePulse`, so it never covers a Dot (`PulseDot`). On this Mac the guard is installed but not running (`RunAtLoad` false, `KeepAlive` false). |
| [#18](https://github.com/inteliwear/sidepulse/issues/18) | Wrapper and uninstall (open) | Superseded: `watch_run.py`, `jrbar agent-monitor uninstall all`. |
| [#12](https://github.com/inteliwear/sidepulse/issues/12) | OpenCode / T3 Code (open) | Superseded; see #55 for the plugin caveat. |
| [#4](https://github.com/inteliwear/sidepulse/issues/4) | Codex usage limit reached leaves Working (open) | Superseded. |
| [#3](https://github.com/inteliwear/sidepulse/issues/3) | Support Kiro (open) | Superseded at adapter level; Kiro not installed. |
| [#2](https://github.com/inteliwear/sidepulse/issues/2) | venv support (closed) | Not applicable. |
| [#1](https://github.com/inteliwear/sidepulse/issues/1) | Demo video (closed) | Not applicable. |

## Releases, tags, branches

| Item | Finding | Disposition |
| --- | --- | --- |
| GitHub releases and tags | None. Versions are calendar-derived at install; firmware is versioned by directory. | Not applicable. |
| `codex/rust-migration` | 89 commits: Rust core, daemon, tray, Tauri settings, relay, installer | Not applicable; tracked by `check_upstreams.py` only through `main`. |
| `codex/android-cli-support` | One commit: Android pairing and FCM through the bridge | Rejected (same outbound relay). |
| `codex/agent-animation-settings` | Seven commits that became #38 | Superseded by the merge. |

## Sibling and related repositories

| Repository | Finding | Disposition |
| --- | --- | --- |
| [`inteliwear/sidepulse-bridge`](https://github.com/inteliwear/sidepulse-bridge) (GPL-3.0-or-later) | Rust HTTPS and SSE bridge with APNs delivery; `/agents` instructions for LED syntax | Studied for the documented syntax only. Not copied: GPL is incompatible with this MIT project. Rejected as a dependency. |
| [`inteliwear/sidepulse-ios`](https://github.com/inteliwear/sidepulse-ios) (MPL-2.0) | iPhone app with a pattern library, firmware updates through the phone | Not applicable. Not copied (file-level copyleft). Its `TRADEMARKS.md` matters: see below. |
| [`benkelly/opencode-sidepulse`](https://github.com/benkelly/opencode-sidepulse), [`benkelly/sidepulse-mqtt`](https://github.com/benkelly/sidepulse-mqtt), [`d31tcjg/hermes-sidepulse`](https://github.com/d31tcjg/hermes-sidepulse), [`fainir/mac-keepawake`](https://github.com/fainir/mac-keepawake) | Third-party integrations named in issues and PRs | Not reviewed in depth; see issue #55 for the writer-race caveat. |
| sidepulse.io | Product page only | Nothing to port. |

## Forks

33 forks. Compared against `main` on 2026-10-07.

| Fork | Ahead / behind | Disposition |
| --- | --- | --- |
| [alex-fung](https://github.com/alex-fung/sidepulse) | 11 / 8 | Mostly the PRs above (#48, #49, #50). Three ideas worth a look: stop treating Codex `PermissionRequest` as a human ask (see #58), let a waiting agent outrank an erroring one in the aggregate, and keep an unanswered question lit past the stale window. **Risk found by testing it here**: JR-Bar's monitor drops an unanswered ask once it is an hour old (`PRESENCE_HORIZON_SECONDS`, `collector.py` snapshot), even though `operator_state.py` says a waiting ask must never expire into invisibility. A 59-minute-old question shows, a 61-minute-old one reads idle. Four modules share the horizon (`collector`, `operator_state`, `mailbox`, `operator_accessibility`), so the fix is one owner decision across them, not a local patch. |
| [timngmsft](https://github.com/timngmsft/sidepulse) | 14 / 44 | Copilot, herdr (a terminal multiplexer), remote options; not installed here. Waiting on evidence. |
| [HypeLaser](https://github.com/HypeLaser/sidepulse), [adamstambouli](https://github.com/adamstambouli/sidepulse), [seanhellwig](https://github.com/seanhellwig/sidepulse) | 4, 5, 7 ahead; unchanged since 2026-08-30 | Dispositions in the 2026-08-30 ledger stand. |
| [spacemike574](https://github.com/spacemike574/sidepulse) | 2 / 14 | The Blocked state of #46; superseded. |
| [wvabrinskas](https://github.com/wvabrinskas/sidepulse), [tlip](https://github.com/tlip/sidepulse) | 1 / 45 each | #26; a Codex state-resolution fix; superseded. |
| `djmango/sidepulse` | compare returns 404 | Unavailable (PR #36 and #11 are read from the upstream threads). |
| Identical to `main` (7): ohmygaugh-crypto, alobadon, PAVADI234, vitco, cappuccinoassasino, SiNiSon-99, caubert (PR #58 lives on a branch) | 0 / 0 | Nothing to review. |
| Behind only (15): Balaxxe, bizantl, sreuter, SpinnerMaster, chris-nowicki, mickr, benkelly, sreyemnayr, cameronhorst, zschwendi, xlwc, quinnypig, d31tcjg, CoolColby23, nepeat, epijimenez, lily-gh | 0 ahead | Nothing of their own on `main`; their work is in the PRs above. |

## Trademark and licences

The 2026-09-14 commit in `sidepulse-ios` adds a trademark policy: "SidePulse"
and its logos and app icons belong to InteliWEAR LLC; truthful references and
fork attribution are allowed without permission; a distributed fork must use a
distinct name, logo and icon. JR-Bar is named JR-Bar and its references to
"SidePulse" in the app are nominative (the hardware it drives). Two things to
decide, not changed here: the eject-guard tool is still named "SidePulse Pro
Eject Prevention" (`sd_eject_guard_launch.SD_EJECT_GUARD_DISPLAY_NAME`, and its
launchd label and binary name), which is upstream's own product name for a
tool, and the app icon and any logo should be checked against the policy's
"distinct logo and app icon" line. `ATTRIBUTION.md` now carries the policy's
suggested sentence.

Licences studied and not copied from: the main repository is MIT, the bridge is
GPL-3.0-or-later, the iOS app is MPL-2.0. Firmware images are binary and were
only inspected for their text files.

## Open items

1. Decide the long-ask horizon (above): one owner call across four modules.
2. Capture `STATUS.TXT` during a real firmware update, then decide whether
   LED writes should pause while `ota` / `fw_state` is not idle.
3. After a Pro is updated to 1.1.0, measure gains and floors on it and decide
   whether the strip transfer should bypass owner gains on 1.1.0 or later.
4. Hand check, lid closed on this Mac with agents running and no external
   display: does the built-in panel stay lit under `disablesleep`?
5. Decide the eject-guard name and the icon question under the trademark policy.
6. Measure closing-question phrasing on local hook logs before touching
   `_assistant_message_asks_question` (#50).
7. If Codex is ever run with `approvals_reviewer = auto_review`, revisit #58.

Next scheduled review: within 30 days of 2026-10-07, per
[the cadence](../UPSTREAM-RESEARCH-CADENCE.md).
