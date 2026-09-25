# Overnight upgrade plan, 2026-09-24

Morning, Jonathan. Last night nine read-only audits went over build 1399 (main at 7bc4b999). They covered the running app and daemon, every Swift surface, the daemon code, both slimming passes, performance, polish, and what is still open from the atlas. The implementation wave works from this plan. Every problem below was measured or reproduced.

What they found, worst first:

- **⌘⇧K has never opened on an installed build.** `PalettePanel` asks for `.canJoinAllSpaces` and `.moveToActiveSpace` at the same time. AppKit throws on every open and leaves a half-built window behind. A second bug unregisters ⌘⇧K after the first palette verb.
- **Closed windows keep drawing.** Effect Studio, Overview, History and Usage Center were opened and then closed. Afterwards JR-Bar ran at 45–97% CPU for more than 25 minutes; its normal level is 1.6–2.7%. Effect Studio's 30 fps LED previews and a min-size layout pass on every frame did it.
- **The Codex usage index has been stuck since Sep 13.** Each Codex scan re-reads about 14.7 GB of transcripts, taking 60–135 s and peaking at 2.4–2.6 GB. Opening the panel starts one. A one-function fix brings a warm scan down to 1.4 s and 365 MB.
- **Approve can wait minutes.** The daemon runs each client's commands in order. One `usage_graph` took 107 s and another 195 s, and a `ping` queued behind each waited just as long. An Approve gives up after 8 s, says the ask is still open, and then goes through late anyway.
- **After a daemon restart, the app shows the dead daemon's asks** with Approve buttons that look like they work.
- **Synced lyrics send every track to lrclib.net by default.** That breaks the rule that nothing leaves the Mac without opt-in.
- **Hook events refused under load are lost for good.** 29 Claude events were dropped in the last day.
- **Opening a Claude session lands on whatever Claude.app showed last.** Every live session on this Mac runs in Claude.app or ChatGPT.app.

Slimming: about 17k lines of Python can go (the retired PyObjC menu bar, its windows and their plumbing, all still loaded into the headless daemon). About 3.6k lines of Swift can go too: Arrange, a Replay window nothing can reach, a third session roster, and duplicate answer paths.

**Rules for every lane.** Your standing decisions apply everywhere:
- one unsegmented Screen Bar
- ears draw marks, never words
- one JR-Bar status item (the mirror is the icon under the concealer)
- no synthetic mouse input and no cursor moves
- Fold's motion feel stays as it is
- nothing leaves the Mac without opt-in
- an agent is answered only on an explicit click

Each lane edits only the files it owns. The eight shared files take small additive hunks only: AppDelegate.swift, CoreMessages.swift, CoreModel.swift, SettingsDocument.swift, UtilitiesState.swift, ToysState.swift, core_runtime.py and CORE-PROTOCOL.md. Every task is one commit, and the suites must be green after each. No lane changes your live settings or defaults. CHANGELOG.md gets written once, at the end, from what merged.

**Merge order and hand-offs**
1. `usage` task 1 (the index fix) merges first. It is the biggest single CPU and memory win.
2. `dock` task 1 (async session raise), then `agentloop` task 2 (`SessionOpener`), then the SessionOpener adoption tasks in `windows`, `menubar`, `dock`, `notch` and `past`. Last, `dock` deletes the sync raise.
3. `agentloop` task 5 (`CoreAsk.isHeld(at:)`), then the hold rings in `windows` (Rail) and `notch`.
4. `windows` adds `AppWindow.whatsNew`, then `agentloop` and `menubar` list it.
5. `past` adds `UnseenDot`, then `agentloop` and `notch` adopt it.
6. Inside `pyslim`: SP-05, then SP-01, then SP-04; separately, SP-06, then SP-02.
7. File splits (MenuBarUtility, DockEnhance, NotchToy, AquariumView) come last in their lanes, as pure moves.
8. Closing step: full pytest and Swift suites, notarized build, install. Then write the CHANGELOG section and the What's New catalog text from what actually merged.

## Tonight's lanes

Tags read `[kind · effort · risk]`. The IDs in parentheses point back to the audit.

### 1. Usage engine (`usage`), Python, M, low–medium

**Owns:** src/jrbar/usage_file_index.py, usage_stats.py, core_usage_history.py, usage_graph_worker.py, _collector_legacy.py; tests/test_usage_*.py, tests/test_freshness.py, tests/test_core_usage_history.py.
**Shared:** none.

1. `[bug · S · low]` **Unstick the Codex index.** Rewrite `usage_file_index.py:261-273` `prune()`:
   - reset `_progress_budget`, `SELECT file_key` into a list, and pick the stale keys in Python;
   - delete them in chunks of 128, resetting the budget before each `executemany`;
   - do it all inside `SAVEPOINT usage_file_prune`, with `ROLLBACK TO` on `sqlite3.Error` that does not set `_failed`;
   - keep the progress handler on `get`/`put`.

   Test: 6,000 stale rows prune fully, puts succeed, close commits, and the next scan is all hits. No `CACHE_VERSION` bump. The live index repairs itself on the first scan (one rebuild of about 70 s). After that a warm Codex 30d scan takes about 1.5 s instead of 60–135 s. (health-codex-index-never-persists, perf-usage-index-wedged)
2. `[memory · M · medium]` **Stream transcripts instead of loading them whole.** Keep the name and contract of `_read_verified_prefix(path, expected_stat, resume_offset=0)`, including returning None when the identity check fails; tests/test_freshness.py:645 and tests/test_usage_cache_bounds.py:335-371 rely on it. Instead of the whole text it returns a small iterable that:
   - runs the O_NOFOLLOW, fstat and identity checks eagerly;
   - reads in binary up to the snapshot size and yields lines split on `b"\n"`;
   - drops the trailing partial line and exposes `parsed_size` once consumed;
   - skips lines over `USAGE_RECORD_MAX_BYTES` with a bounded readline;
   - tests the marker bytes before `decode(errors="replace")`.

   Apply it to `_parse_file` (1411-1432), `_parse_codex_file` (934-957) and `_parse_file_tail` (1455-1459 and the Claude branch). New tests: old/new parity over fixture rollouts, a file that grows mid-read, one line over 1 MB, and a raw U+2028 line. That line is now recovered, so update the malformed-line counts. Target: cold Codex 30d peak drops from 2.58 GB to about 400 MB, and the daemon's idle footprint stops climbing. (health-whole-file-transcript-reads, perf-usage-cold-scan-streaming)
3. `[perf · S · low]` **Skip files older than the window.** In `_provider_inventory` (usage_stats.py:2490-2514), don't parse files whose mtime is older than `since_epoch − USAGE_CACHE_RETENTION_HEADROOM_SECONDS`. Keep them in the candidate set so prune doesn't evict them. That is about a third fewer bytes on a cold scan. (perf-usage-cold-scan-streaming)
4. `[energy · S · low]` **Write latest.json less often.** At `_collector_legacy.py:132`, raise `LATEST_STATE_WRITE_INTERVAL_SECONDS` from 1.0 to 5.0, and skip a write whose byte hash matches the last one. Keep the fsync, and don't touch `atomic_private_write`: the file is the restore snapshot. The `force=True` write at shutdown stays. (health-latest-json-churn)
5. `[slim · S · none]` Delete the test-only twin `build_usage_inventory` (usage_stats.py:1823-1862), after moving any assertion that matters onto the live inventory path. (SP-09)
6. `[verify]` Run the health lane's `scan_repro.py` on a scratch copy of the caches (with `XDG_STATE_HOME` in scratch) before and after, and put the numbers in the commit message.

### 2. Daemon connection, hooks and opening sessions (`daemon`), Python + C, L, medium

**Owns:** src/jrbar/core_server.py, answer_decisions.py, answer_surfaces.py, hook_ingress.py, hook_client.py, hook_pending.py, hook/jrbar-hook.c, serve.py, serve_answers.py, remote_observation.py, remote_peers.py, local_api_contract.py, session_actions.py, navigation_policy.py, provider_usage_feedback.py, session_usage.py, core_deck.py; app/Sources/JRBarCore/EventPolicy.swift, HistoryModelEvents.swift; the tests for these. In tests/test_jrbar.py, touch only the claude:// open test near line 7045.
**Shared:** core_runtime.py (usage_graph QoS, `_core_launch` deferral, broker wiring, quota events, `list_history` relabel); CORE-PROTOCOL.md (the ordering line at :891, new event rows).

1. `[bug · M · low–medium]` **Stop losing hook events.** (hook-refusal-drop)
   - hook_ingress.py:42: raise `MAX_HOOK_INGRESS_ACCEPTED` from 32 to 128 and add a 16 MB cap on outstanding payload bytes.
   - jrbar-hook.c:186: parse the disposition, and call `queue_pending` on `refused_full` or `refused_closed` (never on `refused_invalid`), within the existing 250 ms budget.
   - hook_client.py:57-61: `run_hook_client` and `run_decide_hook_client` append to `<provider>.pending.jsonl` instead of the synchronous fallback.
   - hook_pending.py: call `drain_now()` as soon as the ingress queue drains after any refusal.
   - Tests: a fake daemon that answers `refused_full` in tests/test_hook_shim.py, and the ordering test changed to assert spool-not-process.
2. `[bug · M · medium]` **Approve no longer waits behind scans.** (core-hol-single-lane, daemon-hol-qos)
   - core_server.py: add one serial slow-lane worker thread for `usage_graph`, `usage_history`, `session_timeline`, `list_history`, `compare_sessions` and `session_usage`, plus `doctor` if it is `main_thread=False`. One worker means two scans never overlap. It replies by id through `_Client.send`, which holds write_lock. Every other command stays inline as today; `audit_export` and `replay_events` are untouched.
   - core_runtime.py:2178-2191: `_drop_to_utility_qos` runs on the worker, never on the client's reader thread.
   - CORE-PROTOCOL.md:891: replies are in order except the named slow-lane commands.
   - Check that the serve bridge and cli_control match replies by id.
   - Tests: a slow off-main command doesn't delay a fast one on the same socket, and two slow ones never overlap.
3. `[bug · S · low]` **Republish when a decide-lane hold ends.** (decide-hold-stale-card)
   - answer_decisions.py: `DecisionBroker(on_change=)` is called outside the lock at the end of `wait()` and wired to `_core_publish_state_soon()`.
   - `release_for_open` (1267-1278) releases only `PROMPT_BEHIND_HOOK_PROVIDERS`, so opening a Claude session keeps its Always Allow and choices.
   - Move tests/test_answer_decisions.py:358-364 onto Codex facts.
4. `[bug · S · low]` **Fix the SurfaceRecorder lost wakeup.** (surface-recorder-race)
   - answer_surfaces.py:764-777: the worker waits on a `threading.Condition` on `self._lock`, and the producer notifies under the lock.
   - Stamp each item with `time.monotonic()` on arrival. If it is more than 2 s old when probed, record only host_bundle and cwd, with `terminal_id=None`.
   - Add the audit's repro as a test.
5. `[bug · S · low]` **Deliver critical-pace quota alerts.** (open-04)
   - provider_usage_feedback.py:235-285: after the existing gates, `_core_publish_event("quota_pace", …)` with % left, projected run-out and reset.
   - Also publish `quota_reset` from the reset notification channel (109-115), and record not-delivered when `deliver` returns False.
   - EventPolicy.swift: add a `quota_pace` case gated on `quota_alerts_enabled`, and check that the History row renders.
   - Add the event rows to CORE-PROTOCOL.
6. `[bug · M · medium]` **Open lands on the exact Claude session.** (open-02)
   - session_actions.py:187-194: for rows hosted by `com.anthropic.claudefordesktop`, find the `local_…` id by matching `cliSessionId` in `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json`. Read-only, cached by directory mtime, and any failure falls back to bare `claude://`. Emit `claude://code/continue?session=local_…`.
   - navigation_policy.py:256: allow exactly that shape and `claude://code/needs-input`.
   - answer_surfaces.py:1476-1484: apply a saved 'app' preference only to app-hosted rows, so Claude CLI sessions in Ghostty raise their pane.
   - session_actions.py:275-276: drop VS Code from Automatic unless LaunchServices has a `vscode://` handler.
   - Update tests/test_jrbar.py:7045.
7. `[bug · S · low]` **Harden serve.** (serve-slowloris) `_ServeHandler.timeout = 5.0`; a `BoundedSemaphore(16)` in `_ServeServer.process_request`, released in `shutdown_request`.
8. `[ux · S · low]` **Pin Stream Deck slot answers.** (serve-slot-answer-pin)
   - serve_answers.py `CoreSocketAnswers` reads settings and state from one connection per HTTP request, cached for about 1 s.
   - A slot answer without `request` is refused `stale_request` when the slot's ask opened less than 1.5 s ago. This applies to the serve path only; `deck_answer` is unchanged.
9. `[perf · M · low–medium]` **Faster launch to live data.** (perf-launch-to-live-data)
   - core_runtime.py:3946-4001: move `optional_integration_runtime`, `_core_deck_probe_now`, `start_remote_peer_refresh`, `refresh_installed_agent_inventory` and the log trims to `afterDelay:0` after `core: ready`. The drain still runs before the hook-ingress socket opens.
   - hook_pending.py: parse each provider log once per drain, not once per hook (84 ms per hook today).
   - Log one `launch timing` line.
   - Target: spawn to ready goes from about 3.3 s to about 2.5 s.
10. `[slim · S · none]` **Delete the test-only facades.** (SP-08) Delete remote_observation.py (690 lines) and remote_peers.py:78-82 and 1550-1570. Delete local_api_contract.py (299 lines) and serve.py:34-40, 227-256 and 498, plus their tests. Keep `provider_contracts.REMOTE_OBSERVATION`.
11. `[copy · S · low]` **Give History real names.** (polish-05, daemon half) `_cmd_list_history` (core_runtime.py:2648-2670) relabels rows from a read-only id→label map taken from the last published roster. Keep the stored labels for sessions it no longer knows. Never call `_core_extras_for` from this off-main command.
12. `[copy · S · low]` Rename in core_deck.py:106: `AUXILIARY_MESSAGE` should say the Creator Micro window, not "Control Center (⌘K)". Update the two tests. (polish-08, daemon part)

### 3. Python slimming, the retired PyObjC UI (`pyslim`), Python, L, medium

**Owns:** src/jrbar/status_bar_legacy.py, status_bar.py, _status_bar_production.py, provider_usage_status_bar.py, application_composition.py, menu_projection.py, intake_health.py, deck_status_bar.py, deck_control_center.py, global_action_controller.py, creator_micro_setup_controller.py, cli.py, cli_entry.py, status_bar_launch.py, _status_bar_launch_legacy.py, doctor.py, attention.py, global_actions.py, operator_accessibility.py, render_policy.py, virtual_device.py (SP-09 twin only), every module this lane deletes, src/sidepulse/, pyproject.toml, Makefile, .github/workflows/tests.yml, scripts/verify_fast.py, scripts/verify.sh, scripts/verify_clean_install.py, scripts/uninstall-macos.sh, scripts/install-agents.sh, scripts/install-user.sh, docs/ROADMAP.md, docs/PLAN-0.8.md, docs/ARCHITECTURE.md, docs/FEATURE-MATRIX.md, docs/feature-disposition.md, STATUS.md, and the tests for all of these.
**Shared:** core_runtime.py (remove `open_legacy_window`/`LEGACY_WINDOWS`, change the deck executor lambdas); CORE-PROTOCOL.md (remove rows, add the `open_window`/`reveal_ask` events); CoreMessages.swift and AppDelegate.swift (decode those two events and route them through the existing AppCommand router, additively).

Run the full suite after every step. Before deleting anything the walker marks unreachable, grep for its selector string and check scripts/.

1. `[test · M · low]` **Parallel pytest.** (perf-pytest-wall) Add pytest-xdist as a dev dependency. `make test` runs `-n auto --dist loadfile`, and `make test-serial` stays. Run the parallel suite 5 times; switch tests.yml only if all 5 are green. This goes first because it cuts every later verification from about 290 s to about 70 s.
2. `[bug · M · low]` **Stop `jrbar setup` installing the retired menu bar.** (SP-05)
   - cli.py:646-661, 1279-1300, 459-471 and 762-780: remove `install_launch_agent` from setup, and remove status-bar start and --foreground. Keep `install-sleep-helper`, `uninstall-sleep-helper` and `sleep-helper-status`. Keep a hidden `status-bar stop` that only boots out and unlinks `com.jonathanreed.jrbar.app.plist` and the legacy labels, and call it from `run_startup_migration`.
   - scripts/uninstall-macos.sh:79-89: point at Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core and use `launchctl bootout` plus unlink. Update install-agents.sh:37 and :96.
   - doctor.py:395-427: drop `LAUNCH_AGENT_STATE`, bump the doctor schema, and update tests/test_module_entrypoint.py:67-75.
   - Delete _status_bar_launch_legacy.py:295-562, keeping 1-293 because answer_surfaces.py:480 uses it.
3. `[perf · S · none]` **Name the stage behind refresh stalls.** (perf-refresh-main-thread-stalls) In the timing line (status_bar_legacy.py:3182-3203 and 3343-3352), split `ingest` into dnd, transcript_fallback, liveness and t3, and split `leds` into compute and device_write. Instrumentation only.
4. `[energy · S · none]` Drop the `self.refresh_why_panel()` call at status_bar_legacy.py:3322. (SP-10 quick win)
5. `[slim · S · none]` **Delete the four speculative modules.** (SP-03) acp_transport, coordinator_policy, opencode_bridge and utility_generation, with their tests. Set `KNOWN_UNWIRED = {}`, and mark the STATUS.md entries 'removed at <sha>'.
6. `[slim · S · low]` **Drop the sidepulse shim.** (SP-12) Remove src/sidepulse/, pyproject.toml:72-74 and :80, scripts/verify_clean_install.py:70-92, and `sidepulse` from scripts/install-user.sh:23. Keep the recognition strings in providers.py and install.py.
7. `[slim · M · low]` **Delete the NSMenu tree.** (SP-01)
   - Delete the `build_menu` path, the legacy `update_status_menu` body, the menu facade in status_bar.py and menu_projection's menu builders.
   - Delete the nine menu-only modules: clear_agents_popover, away_summary, sparkle_updater (Python), usage_menu_injection, today_menu, mailbox_menu, device_menu, activity_ledger_menu and daily_tips.
   - Update the application_composition.py:40-45 receipt, `install_provider_usage_status_bar`, scripts/verify_fast.py:24-34 and scripts/verify.sh:72-73.
   - Keep every legacy method that `install_ambient_effect_runtime` captures.
8. `[slim · S · low]` **Delete the shadowed methods.** (SP-04) Delete the 40 methods in scratchpad/slimpy/shadowed_methods.txt, except status_bar_legacy.py:10756 `observe_operator_history_events`, :9098 `_deliver_semantic_notification` and :9148 `_activate_notification_action`. Add a test that the composed headless class still routes operator history events to `_enqueue_operator_history_events`.
9. `[slim · M · medium]` **Send Creator Micro keys to the Swift windows.** (SP-06)
   - The headless executor (core_runtime.py:5066-5069 and 5126) publishes `open_window {window: overview|usage|control-center}` and `reveal_ask`, recording `app_not_connected` when no client is connected.
   - The app decodes both and routes them through AppCommandRouter.
   - Remove creator_micro_setup_controller.py:287, then delete the agent_browser_window, provider_usage_window and deck_control_center_window paths.
   - This is a URL-style open, not synthetic input.
10. `[slim · M · low]` **Remove `open_legacy_window`.** (SP-02)
    - Remove the command, `LEGACY_WINDOWS` (core_runtime.py:130-138 and 3297-3316) and tests/test_core_runtime.py:35.
    - Update the doc rows: CORE-PROTOCOL.md:968 and 1003, ARCHITECTURE.md:127, FEATURE-MATRIX.md:14 and 53, feature-disposition.md:50. Mark ROADMAP #5 done.
    - Delete the modules that became dead: effect_studio_window, setup_window, onboarding_runtime, studio_builder, effect_studio_preview, lighting_settings_pane, usage_heatmap_view, main_menu and settings_destination_refresh.
    - settings_window.py stays for SP-10, which is not tonight.
11. `[slim · M · low]` **Move the regression tests onto the real path, then delete the twins.** (SP-09)
    - Port test_silence_clock_does_not_freeze.py, test_ended_unconfirmed.py:171-266 and test_attention.py onto `project_attention`. If the real path fails the 'finished turn held its sweep forever' case, fix it in attention.py and say so in the commit.
    - Then delete `project_attention_from_operator_state`, `project_global_action_status`, operator_accessibility.py:384-511, `rounded_silhouette` and `measured_notch_silhouette`.
12. `[copy · S · low]` **Name History rows when they are recorded.** (polish-05, record-time half) At status_bar_legacy.py:8006-8016, pass `getattr(self, '_core_extras_for', lambda s: None)(status)` instead of `extras=None`.
13. `[docs · S · none]` Amend ROADMAP.md:58 and PLAN-0.8.md:27. Keep the removed severe-weather alert separate from the kept, opt-in notch Weather row, and list agent timers as kept. (slim-swift-11)

### 4. Panel, asks and the core connection (`agentloop`), Swift, L, medium

**Owns:** app/Sources/JRBarApp/PanelStore.swift, PanelView.swift, PanelController.swift, PanelMotion.swift, PanelHotkey.swift, StatusItemController.swift, KeepAwakeFooter.swift, AskAnswers.swift, AskAnswerViews.swift, AskingPane.swift, EventCoordinator.swift, NotificationBridge.swift, PresenceReporter.swift, AgentStateMonitor.swift, LEDFeed.swift, LaunchNotices.swift, SparkleUpdater.swift, Utilities/Agents/**, new SessionOpener.swift; JRBarCore/CoreClient.swift, KeepAwakeReading.swift, PresenceReporting.swift; tests for these, app/Tests/JRBarAppTests/ReplyDraftTests.swift, new app/Tests/JRBarAppTests/ScratchDefaults.swift.
**Shared:** AppDelegate.swift (banner closure, ear click and router open, socketWatcher gating, refusal HUD, app menu, explicit types); CoreModel.swift (clear on disconnect, log refusals); CoreMessages.swift (`CoreAsk.isHeld(at:)`); UtilitiesState.swift (none; organizer fields keep decoding).

1. `[bug · S · low]` **Don't trust a dead daemon's state.** (core-stale-state-reconnect)
   - CoreModel.swift:94-100: on `.disconnected`, set state, lights and lastStateAt to nil, keeping settings and usageSamples. On `.connected`, set hello to nil.
   - `EventCoordinator.reset()` calls `toys?.notch.releaseTakeover()`.
   - Tests: after a disconnect there are no asks and isLive is false; a reconnect before the first state is still not live.
2. `[bug · M · low]` **Opening a session never dead-ends.** (core-open-session-deadends)
   - New SessionOpener.swift: `@MainActor enum SessionOpener { static func open(_ id: String) async -> String? }`. It sends `open_session`. On `not_found` for a live local row it awaits `UtilitiesStore.raiseSessionWindow` (async after `dock` task 1). It returns nil or the refusal line.
   - Adopt it in `PanelStore.open` (its fallback copy goes), `EventCoordinator` notification clicks (:57), the AppDelegate ear click (298-300 and 407-413) and the `jrbar://` router (1788-1792). The router keeps its synchronous pre-checks, starts a Task, and shows any refusal in the HUD.
   - `CoreModel.post` logs `ok:false` replies to `lastDecodeFailure` and `appendLocalLog`.
   - Surfaces that collapse themselves wait for success first.
3. `[bug · M · medium]` **One ask desk.** (core-answer-paths, slim-swift-01)
   - AskAnswers.swift: add a `.reply(String)` verdict sent through `answerAskNow(session:approve:true, replyText:, request:)`. `AskVerbs.allows(.reply)` means canAnswer, wantsTextReply and non-empty trimmed text. Add `AskAnswerLine.replied`.
   - `PanelStore.answer` and `reply` go through the desk. The draft clears only on `outcome.ok`, and the pending key becomes the session.
   - Banner (AppDelegate:695-703, NotificationBridge:113-147): userInfo carries `request` and session. On click, look up the live ask. If it doesn't match, refuse locally with 'That ask was replaced — click to open the session'. Otherwise call `desk.answer(liveAsk, …)`. Use the Approve/Deny category only when `AskVerbs.approves` holds.
   - Delete `NotificationBridge.onAnswerAsk` and EventCoordinator.swift:58.
   - Every desk entry stays a button action.
4. `[bug · S · low]` **Cut the Agent Overview card's roster.** (slim-swift-09, core-answer-paths a) In AgentUtility.swift and AgentUtilityCard.swift, keep AgentAlertRulesTable, quietWhenPaneFrontmost and an 'Open the Overview' button. Delete the roster, groups, countParts, every session verb, pendingAnswers and notice. This also removes the Approve it offered on held questions.
5. `[ux · S · low]` **Show the 45 s hold.** (core-hold-until-hidden, decide-hold-stale-card app half)
   - Add `CoreAsk.isHeld(at: Date)`, false once `holdUntil <= now`, and use it where `isHeldForDecision` is read.
   - Add `holdUntil` as a boundary in `nextAskAgeTick`.
   - AskCard (PanelView.swift:990-1023) draws a depleting ring on held verbs, stepped under Reduce Motion, with a one-shot re-render at holdUntil.
6. `[bug · S · none]` Pass `now: stalenessReference` to `LightExplainer.explain` in PanelStore, so the notch card's 'why this light' line stops using the panel's frozen clock. (core-frozen-clock-explanation)
7. `[bug · S · low]` **Make Follow Focus work.** (presence-dead-facts, open-03 focus part) `PresenceReporting.report(for:)` includes `focus` (`INFocusStatusCenter.default.focusStatus.isFocused` when authorized, else nil). It renews every 60 s while true and sends edges from PresenceReporter's own 15 s check and on didActivateApplication. Test that a focus-only report renews. This makes your existing Follow Focus 'dim' setting do something.
8. `[energy · S · low]` **File feeds only while offline.** (health-latest-json-churn app side, slim-swift-04, perf-idle-wakeups) Start AgentStateMonitor, LEDFeed's strip watchers and the AppDelegate socketWatcher (1637-1645) only while `!core.isLive`. Stop them on connect, and read immediately on disconnect.
9. `[perf · S · low]` **The panel stops kicking off scans.** (core-hol-single-lane app part) Defer `refreshSparklines` (PanelStore.swift:1171-1182) by about 1.5 s after `panelDidOpen`, and skip it while askRows is non-empty. Update the serial-dispatch comments in CoreModel.swift:325 and CoreClient.swift once `daemon` task 2 lands.
10. `[energy · S · low]` **Skip pointless `session_in_front` round trips.** (core-in-front-every-activation) EventCoordinator skips the call when `session.pid` is known and the frontmost pid is neither that pid nor on `AskingPane.ancestry(of:)`. Clear `lastEscalation` on `ask_resolved` for its session.
11. `[slim · S · none]` Delete dead members: `PanelMotion.unfold` (:22), `PanelStore.plainRows` (:796), and PanelHotkey's unused `hotKeyID` parameter (:55-64) plus its two call sites. (slim-swift-13)
12. `[visual · S · low]` **Stop clipping the footer.** (polish-02) In PanelView.swift:1631-1745:
    - left: Clear finished and Quiet…
    - right, inside ViewThatFits: icon-only awake mark, History, More and Settings, with tooltips
    - 'Quit JR-Bar ⌘Q' moves to the bottom of More
    - add a layout test at `PanelLayout.width` with the awake mark, a quiet label and the Undo countdown all shown.
13. `[copy · S · low]` **Usage rows say one thing each.** (polish-07) In PanelStore.swift:1808-1843:
    - tags are 'Runs out in X', 'Used up' (the primary window at 100% or more) or 'Stale'; nothing when on track
    - delete 'resets first'; 'resets now' becomes 'reset — waiting for a new reading'
    - the second line shows reset countdowns only
    - keep a compact 'no room for +1' only in the negative case
    - fold the 0%, not-found and disabled providers into one trailing row that opens the Usage Center.
14. `[copy · S · low]` **Fix the header.** (polish-16) It reads 'Working · 2 agents · 10 workers'. The workers badge gets a square.stack glyph, and the row's accessibility label says '10 workers'.
15. `[ux · S · low]` **Feedback you can see.** (polish-04)
    - When the panel is closed, router refusals and quiet/deep-work confirmations appear in the existing PaletteHUD (Palette/PaletteController.swift:63) on the screen under the pointer.
    - ToastView wraps to 2 lines when it has an action.
    - The stale-copy text at SparkleUpdater.swift:255 names the actual bundle, for example JR-Bar.app.bak-20260921-105351.
16. `[ux · S · low]` **Menus.** (polish-08, menu part)
    - 'Command Palette… ⇧⌘K' is the first item in More (PanelView:1709), the right-click menu (StatusItemController:174-205) and the app menu (AppDelegate:1081).
    - More and the right-click menu come from one shared catalog, so both have Events… (History), Check for Updates… and What's New….
    - 'Control Center…' becomes 'Creator Micro…' without ⌘K, and is listed once a pad has ever been seen.
    - The panel's ⌘K closes the panel and opens the palette.
17. `[ux · S · low]` **One brightness story.** (polish-17, panel part) The panel slider shows 'Mixed' (or the max, with a per-device tooltip) when device values differ. Dragging sets them all.
18. `[feature · S · low]` **Show the power facts.** (core-power-facts-hidden, open-07 footer part) `KeepAwakeReading` adds:
    - the runway line when runway.short, and the charger shortfall when adapter_short
    - 'lets go at <time>' from hold.grace_until, in locale time
    - the last release with its reason.

    `closed_lid.sleep_error` shows once per distinct (error, last_sleep_at) as a LaunchNotices toast plus a local banner. Everything stays local.
19. `[visual · S · none]` The unseen dot at PanelView.swift:623 uses `UnseenDot` from `past` (fixed systemBlue). (polish-10)
20. `[test · S · none]` Add `withScratchDefaults` (ScratchDefaults.swift). It calls removePersistentDomain and deletes ~/Library/Preferences/<suite>.plist in a defer. Adopt it in ReplyDraftTests.swift:14-19. (polish-18)
21. `[build · S · none]` Add explicit types to AppDelegate's slow expressions: `utilitiesStore.menuBar.host = statusItem as any MenuBarBoundaryHost` (:183), and `(tile) -> CGRect?` on the quickQuitTargets compactMap. Re-run `-warn-long-function-bodies=250`; it measures 3.6 s today. (slim-swift-14, cheap half)

### 5. Windows, What's New and the app shell (`windows`), Swift, M, low

**Owns:** app/Sources/JRBarApp/EffectStudio*.swift, LEDPreviewStrip.swift, ControlCenterWindowController.swift, ControlCenterView.swift, DeckStore.swift, DeckRailController.swift, HistoryWindowController.swift, UsageCenterWindowController.swift, Overview/OverviewWindowController.swift, SettingsWindowController.swift, Setup/**, FirstRunCard.swift, Replay/ReplayView.swift, Replay/ReplayWindowController.swift, Intents/**, new WindowContentLifecycle.swift, new WhatsNew/**; JRBarCore/EffectModel.swift; JRBarLEDS/**; src/jrbar/effect_registry.py (descriptions only); README.md (the Shortcuts note); tests for these.
**Shared:** AppDelegate.swift (Replay and intents removal, FirstRunCard removal, What's New launch gate and routing).

1. `[energy · S · low]` **One window-content lifecycle.** (health-offscreen-windows-keep-animating, R2, perf-closed-windows-keep-rendering, open-01) Extract SettingsWindowController.swift:84-121's attach/detach into WindowContentLifecycle.swift: capture geometry, set `contentViewController = nil` and `contentView = NSView(frame:)`, restore geometry, and reapply title and subtitle. Settings uses it.
2. `[energy · S · low]` **Apply it to every titled window.** Covers Effect Studio (28-58), Control Center (31-57), History (74-104), Usage Center (40-48), Overview (141) and Setup.
   - Attach in show() and detach in windowWillClose.
   - Set `hosting.sizingOptions = []` on the resizable windows that already set minSize.
   - Add a lifecycle test per controller asserting `contentViewController == nil` after close.
   - The stores keep their selection.
   - Target: after every window has been opened and closed, JR-Bar idles back at about 2% CPU (check with top and sample).
3. `[energy · S · low]` **Pause Effect Studio when covered.** Add a didChangeOcclusionState observer (like AquariumWindowController.swift:61-71) that sets a store flag. Fold it into LEDStripPreview's `still`, and pause the store's 1 s and 0.5 s tickers.
4. `[bug · S · low]` ControlCenterView.swift:884 and 901 open sessions through SessionOpener. Do this after `agentloop` task 2. (core-open-session-deadends)
5. `[bug · S · low]` AppCommand parses `jrbar://session?id=<percent-encoded id>` into `.openSession(id)` alongside the path form, for the notch lane's Remind Me links. Add a round-trip test. (open-11 support)
6. `[slim · S · none]` **Delete the Replay window.** (core-replay-window-dead, slim-swift-03) Delete ReplayView.swift and ReplayWindowController.swift. In AppDelegate, drop the extra ReplayStore and replayWindow (536-543 and 613), and point `statusItem.onOpenReplay` and PaletteWiring's `replay:` closure at `historyWindow?.showEvents()`. Keep ⌘R. ReplayStore stays as History's model.
7. `[slim · S · none]` **Delete App Intents.** (core-intents-dead) Delete JRBarIntents.swift, the AppDelegate bridge (1668-1676) and AppCommandTests.swift:313-328. Add a README note: Shortcuts reaches every verb through Open URLs with `jrbar://`. The binary stops linking AppIntents.framework.
8. `[slim · S · low]` **One onboarding.** (slim-swift-12) Move FirstRunCard's Screen Bar facts into Setup's welcome or done step, then delete FirstRunCard.swift and its marker logic (AppDelegate 979-985 and 1015-1021). The first-launch panel opens only after Setup finishes or is dismissed.
9. `[slim · S · none]` Delete dead members: `SetupStore.canGoNext`, `SettingsWindowController.pageObservation`, `EffectModel.needsTarget` (:516), `DeckStore.setSettings(enabled:sessionMode:analogEnabled:)` (:336), and in JRBarLEDS `RGB.fromLinear`, `loopSpanMs` and `maxPresentationHz`. Fix the stale doc at LEDSColor.swift:42. (slim-swift-13)
10. `[feature · M · low–medium]` **What's New**, built to the spec below: WhatsNew/{WhatsNewCatalog, WhatsNewView, WhatsNewWindowController}.swift; `SetupState.whatsNewSeen: String?` with tolerant decode; `AppCommand.AppWindow.whatsNew`; the AppDelegate launch gate. (polish-03)
11. `[copy · S · low]` **Plain words in Effect Studio.** (polish-13) EffectModel.swift:107-111 display names: duration_seconds becomes 'Cycle length', seed 'Variation', wave_count 'Waves', palette 'Colours'. Plain descriptions in effect_registry.py:488-496 and 652-660. The raw id moves into a tooltip. Inspector pickers go one per row, with wrapping empty-state text. Update EffectModelTests:91.
12. `[ux · S · low]` **Creator Micro, by name.** (polish-08, window part) ControlCenterWindowController:35-36 titles the window 'Creator Micro' and drops ⌘K. Keep the key grid while disconnected and make the 'Turn on…' notice prominent. Rename the DeckRailController:172 and :474 strings. Keep `jrbar://window/control-center` and `open_control_center` as aliases.
13. `[ux · S · low]` The Rail pill draws the same hold ring using `CoreAsk.isHeld(at:)`. (core-hold-until-hidden, Rail part)

### 6. Menu bar and the ⌘⇧K palette (`menubar`), Swift, M, low

**Owns:** app/Sources/JRBarApp/Utilities/MenuBar/**, Palette/**, Utilities/ExternalAppProbe.swift, HotkeyCenter.swift; their tests (MenuBarActionsTests, MenuBarGateTests, MenuBarTests, MenuBarStateRuleTests, MenuBarIconMirrorTests, PaletteTests).
**Shared:** AppDelegate.swift (applicationWillTerminate calls `stop(forQuit:)`); UtilitiesState.swift (`arrangeOrder` still decodes but is never written).

1. `[crash · S · very low]` **The palette opens.** (health-palette-collection-behavior-throws, polish-01)
   - PaletteController.swift:41 uses `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`, hoisted into `static let behavior` with a test that it never holds both .canJoinAllSpaces and .moveToActiveSpace.
   - In open(), when presenting, set isOpen only after makeKeyAndOrderFront. The headless path, which the PaletteTests at 373/416/433/471/526 cover, stays as it is.
2. `[bug · S · very low]` **⌘⇧K survives the first verb.** (REG-1) `syncParkedPaletteKey` becomes `guard let wanted else { if parkedPaletteKey.started { parkedPaletteKey.stop() }; return }`. Clear `bindings` when the parked set stops. Add the shared-HotkeyCenter repro to MenuBarActionsTests. The card's Open button (MenuBarUtilityCard.swift:1013) reads the bound chord.
3. `[bug · S · very low]` **The Item Bar stops eating the palette's keys.** (REG-9) At MenuBarBar.swift:958-975, add `guard event.window === self.panel else { return event }` in the keyboard branch. `perform(.commandBar)` closes the Item Bar before toggling the palette.
4. `[bug · S · very low]` **Concealed tile press off main.** (REG-6) At MenuBarUtility.swift:3079-3099: `let pressed = await Task.detached(priority: .userInitiated) { MenuBarAX.press(fresh) }.value; if !pressed { clickFallback(fresh) }`. Treat kAXErrorCannotComplete after a press as delivered.
5. `[bug · S · low]` **LED scene after quit.** (REG-4)
   - `MenuBarUtility.stop(forQuit:)` skips `stateRules.stop()`, and applicationWillTerminate calls it.
   - Add a one-shot reconcile once the core's first live facts arrive: if `sceneBeforeRule != nil` and the rule outcome holds no scene, `setScene(before)` and clear the field. It also runs when no while-rule is enabled.
   - Add a relaunch-with-stale-scene test.
6. `[energy · S · low]` **Stop polling every app's menu bar every 20 s.** (health-menubar-ax-full-walk) MenuBarItemLister.swift:331 `fullScanInterval` goes from 20 to 120. After each didLaunchApplication, do full walks at +2, +10 and +30 s. `listingInterval` stays at 2 s.
7. `[energy · S · low]` **Reveal poller.** (R10, menu bar part) MenuBarReveal's timer gets a tolerance of interval × 0.2. It parks on screensDidSleep and lock and resumes on wake and unlock. The near-edge rates don't change.
8. `[perf · S · low]` **Pre-folded palette ranking.** (perf-palette-ranking) Fold each item's lowercased title, subtitle, kind, keywords and verb phrases once when `items` is set, and fold the query once per refilter. The separator list becomes a static set. Add a parity test over random rows. Target: under 1 ms per keystroke at 1,500 rows, from 8–20 ms.
9. `[slim · S · low]` **Delete Arrange (about 1,080 lines).** (slim-swift-05) This is the app's only synthetic ⌘-drag and cursor warp. It is unreachable under your concealer.
   - Delete MenuBarArrange.swift and MenuBarItemMover.swift.
   - Delete MenuBarUtility 1018-1084 and 4077-4086, MenuBarUtilityCard 1256-1305, MenuBarActions 13-16, 126, 158-162 and 323-333, MenuBarCommandBar 29 and 305-309, and the menuBarArrangeOrder/Boundary delegate requirements.
   - Delete the Arrange sections of MenuBarActionsTests and the Arrange asserts in MenuBarGateTests.
   - Under the spacer engine, the card says '⌘-drag items to order them'.
10. `[slim · M · low]` **Delete the fallback chevron.** (slim-swift-06a) Remove installChevron, chevronClicked, chevronSymbol, chevronScreenFrame and the chevron branches. No host means no boundary. Rewrite chevronLifecycle as a host-spacer lifecycle test with a fake MenuBarBoundaryHost. Remove the stale `VisibleCC …menubar-chevron-v2` default once. Never touch `…status-item`.
11. `[slim · S · none]` ExternalAppProbe's Bartender bundle ids come from `MenuBarRivals.known` (MenuBarHealth.swift:95), so Hand over recognises Bartender 6 and 7. (REG-11e)
12. `[slim · S · none]` Delete dead members: `MenuBarBar.isKeyboardDriven` (:780), `MenuBarCombinedItem.popoverShown` (MenuBarExtras:305), MenuBarCommandBar:428, `MenuBarCommands.hideAllSections`, `PaletteModel.selectAction(at:)` (:202). Fix the doc at MenuBarActions.swift:21. (slim-swift-13)
13. `[test · S · none]` MenuBarIconMirrorTests.swift:366 cleans up its defaults suite, meaning the domain and the plist, in a defer. (polish-18)
14. `[bug · S · low]` PaletteWiring.swift:69's session verbs open through SessionOpener. Do this after `agentloop` task 2.
15. `[feature · S · none]` Add a What's New row to WindowPaletteRows (PaletteSources.swift:987) if the rows aren't already derived from `AppWindow.allCases`.
16. `[slim · M · low]` Split MenuBarUtility.swift (4,237 lines) into Concealer, Extras, Listing, Tile actions, Boundary, Ear and Delegate files. Pure move; `private` becomes internal only where needed; one commit, last. (slim-swift-15)

### 7. Dock, ⌥⇥ and the session raise (`dock`), Swift, M, medium

**Owns:** app/Sources/JRBarApp/Utilities/Dock/**, Utilities/UtilitiesStore.swift; Dock tests (DockEnhanceTests, DockControlTests, DockPreviewAgentTests, DockSwitcher tests).
**Shared:** none.

1. `[perf · S · low]` **Async session raise, step 1.** (REG-7) Add `UtilitiesStore.raiseSessionWindow(_:) async -> Bool` that awaits `SessionWindowLocator.raise(sessionID:marks:) async` on DockAXWorker. Land it first; SessionOpener depends on it.
2. `[bug · S · low]` **Dock asks go through the desk.** (REG-5)
   - DockEnhancePanel.swift:1282 and 1291 call `Task { await desk.answer(ask, approve ? .approve : .deny) }` and show `desk.note`.
   - Delete `DockEnhanceController.answer`/`answerAsk`, `preview.answering`/`askNotes`, the DockAskRow note and answering params, `DockUtility.answer`/`sendAnswer`, and the UtilitiesStore.swift:109-113 wiring.
   - Port DockPreviewAgentTests 68-82 and 228-231 onto AskAnswerDesk.
3. `[ux · S · low]` **The preview stops eating keystrokes.** (REG-2)
   - DockSwitcher.swift:894-907 swallows the preview keys only when no ⌘, ⌃ or ⇧ is held. ⌥ passes, except on the walked-card path.
   - Return and Enter are swallowed only when a card is walked; mirror `selectedWindowID` into the tap.
   - Test: ⇧→ passes through while the preview is open.
4. `[perf · M · medium]` **⌥⇥ opens fast.** (REG-3)
   - DockSwitcher.swift:1321-1404: compute the backoff set on main, run the per-pid `windowsReading` concurrently off main (0.5 s timeout each), and write unresponsive pids back on main.
   - Badges come from DockEnhance's cachedItems within itemsTTL; otherwise they fill in from DockAXWorker after the strip shows.
   - rebuild, liveTick, toggleScope and the workspace rebuilds do their AX work on DockAXWorker and apply results by generation.
   - Keep the releaseBeforeOpen tests.
   - Target: open in under 60 ms, down from about 185 ms.
5. `[feature · S · low]` **Agent marks on app-hosted windows.** (open-06) DockAgentMatch.swift: when an APP_HOSTED bundle (Claude, ChatGPT) has exactly one standard window, that window carries appMark's most urgent live mark plus the oldest waiting ask for the needs-you lane. With two or more windows, no guessing. Tests for both cases.
6. `[energy · S · low]` Cache the Dock's pid from NSWorkspace launch and terminate notifications instead of looking it up every tick. (health-pointer-polls)
7. `[energy · S · low]` The Dock pointer tick parks on screensDidSleep and lock and resumes on wake and unlock. Near and far rates don't change. (R10, Dock part)
8. `[slim · S · none]` `UtilitiesStore.applyDock` just calls `dock.applySettings()`. Fold the two pointerDisplayQuartz copies (DockSwitcher 1258 and 1383, DockEnhance 2056 and 2546) into one static helper. (REG-11 d, f)
9. `[slim · S · low]` Delete AppleDockControl's hide half: setAppleDockHidden, isPinned, reassertPinned, and hiddenDelay if nothing uses it. Keep `restore()`, and rewrite its tests to seed the saved keys directly. (slim-swift-07)
10. `[slim · S · none]` Delete `DockSettings.isHorizontal` (:286). (slim-swift-13)
11. `[bug · S · low]` The Data Hoarder opener (UtilitiesStore.swift:92) goes through SessionOpener. Do this after `agentloop` task 2.
12. `[slim · S · low]` **Async session raise, step 2.** Once every caller uses SessionOpener, delete the sync `SessionWindowLocator.raise` and the DockUtility sync overload, and switch DockPreviewAgentTests.swift:120 to the async one. (REG-7)
13. `[slim · M · low]` Split DockEnhance.swift (3,353 lines) into Preferences, HoverTracker, Math, AppleDockReader, preview models and the controller. Pure move, last. (slim-swift-16)

### 8. Notch, Screen Bar, Shelf, toys and Settings search (`notch`), Swift, L, low–medium

**Owns:** app/Sources/JRBarApp/Toys/** (Fold/** stays unedited), ScreenBar*.swift, Shelf*.swift, NotchHUD.swift, NotchHUDKeys.swift, NotchAnnouncements.swift, SettingsStore.swift, SettingsView.swift, SettingsSearch.swift; JRBarCore/NotchIsland.swift; JRBarUI/ScreenBarGeometry.swift; their tests.
**Shared:** ToysState.swift (the lyrics default and `lyricsConsented`).

1. `[privacy · S · low]` **Lyrics are opt-in.** (R1)
   - ToysState.swift:904-906 and :996: default false in the init and the decoder, plus `lyricsConsented` (a missing key reads false), ANDed into `LyricsStore.enabled`.
   - Show one quiet card chip to turn it back on, and never show it if lyrics is off in Settings. The Settings toggle's subtitle names LRCLIB.
   - Tests: NotchLyricsTests:93 now expects false; decoding without the keys gives off; `enabled()==false` never builds an lrclib.net URL.
2. `[bug · S · low]` **Live audio bars.** (R4)
   - AudioLevelTap gets an `onLiveChange` callback, fired from success, failure, death and stop. It sets `cardModel.utility.audioTapLive` and zeroes the levels when live goes false.
   - Remove the copy after sync() (NotchToy.swift:1996-2002).
   - Confine the CoreAudioTapEngine state to workQueue; stop() runs through `workQueue.sync`.
   - Add a NotchToy-level fake-engine test.
3. `[dup · M · medium]` **Notch asks go through the desk.** (slim-swift-01, notch part)
   - Move `open(session:)` onto NotchToy, using SessionOpener.
   - answerCapsule (pinning `capsule.ask.request` to the live ask) and the card rows call `AskAnswerDesk.shared`.
   - Delete NotchAskAnswerer.swift. NotchIslandView:502's pending check reads the desk only. The notch buttons are drawn from AskVerbs.
   - Move the NotchAskAnswerer tests onto the desk.
4. `[ux · S · low]` Held verbs on the notch card show the 45 s ring, using `CoreAsk.isHeld(at:)`. Marks only, and stepped under Reduce Motion. (core-hold-until-hidden, notch part)
5. `[bug · S · very low]` `copyForAgent` (ShelfTray.swift:521-533) returns the pasteboard changeCount, and both callers store it as `pastedChangeCount`. Test it with a private pasteboard. (open-12)
6. `[bug · S · low]` `remind(about:)` (ShelfReminders.swift:277-293) takes row.id and sets `reminder.url = jrbar://session?id=<encoded>`. The router side is `windows` task 5. (open-11)
7. `[bug · S · low]` NotchToy 220 and 228, NotchBuddyToy:336 and the glass card's `openSessionNow` (NotchCardPresenter ~101) open through SessionOpener. Do this after `agentloop` task 2. (core-open-session-deadends, REG-7 caller)
8. `[energy · M · low–medium]` **Park the Screen Bar when nobody can see it.** (R3a)
   - ScreenBarController stops the move poll and the 1 s island watch on screensDidSleep and restarts them on wake. Both also stop while steppedAsideForVideo.
   - Pass `live = isShown && !displayAsleep && !steppedAsideForVideo` into the wings model, and pause the media-ear TimelineView on it.
   - hide() sets live to false.
   - Tests drive every edge.
9. `[energy · M · low]` **One set of decorative bars.** (R6) Add `DecorativeBars(count: 6, live:)`, shared by the island strip, the media ear and the card. The card's ShelfEqualizer pauses under Reduce Motion. NotchBuddy's treatHearts pauses unless a burst started in the last 0.9 s, and the roster is capped at 1/30 s.
10. `[energy · S · low]` ShelfTimerModel uses a one-shot timer armed for the soonest live deadline and re-armed on add, pause, resume, remove, sweep, wake and clock change. Nothing is armed when there are no timers. (R7)
11. `[energy · S · low]` StatusChip (Toy.swift:198-222) stops breathing. Chips show only when they add something. The Aquarium's closed-state chip goes neutral secondary. Advanced's sidebar glyph becomes slider.horizontal.3 (SettingsStore:45-52). (polish-15, toy part)
12. `[slim · S · low]` Add `NotchMotion.panelCurve` and a `NotchSurfaceMotion.present/dismiss` helper that takes each surface's current timings. Adopt it in NotchCardPanel, NotchHUD, ScreenBarPeek and ScreenBarController. No timing changes. (R9)
13. `[slim · M · low]` Add a nonisolated `CoreAudioDefaults` with pure readers (default output and input, name, transport, volume, mute), used by SystemTogglesStore, ScreenBarNotices, AudioLevelTap and NotchHUDKeys. The tap's device listener stays on its workQueue. (R8)
14. `[slim · S · none]` Delete dead members: `ScreenBarController.currentCodes` (:1271), `SettingsStore.hasQuotaSource` (:729), `ScreenBarGeometry.compactBandHeight`. (slim-swift-13)
15. `[ux · M · low]` **Settings search reaches toy and utility rows.** (R5)
    - Add `Toy.searchRows`, built from the same string constants the controls use, with a source-pinning test.
    - Add `SettingsStore.expandedCards`. reveal() inserts the card id, scrolls with ScrollViewReader and highlights the row.
    - The SettingsSearch.swift:69 entry reads 'Creator Micro'.
16. `[visual · S · low]` The closed-lid hold on the ear uses laptopcomputer and shows only while the lid is actually closed; otherwise it shows the lease cup or nothing. The moon means quiet only. Update theClosedLidHoldIsTheMoonAndOutranksALease. (polish-11)
17. `[ux · S · low]` Notch card close, Open, mirror, Timer and page tabs get hit areas of at least 24×24 via `.padding(8).contentShape(Rectangle()).padding(-8)`. The header height stays the same. (polish-14)
18. `[feature · S · low]` The right ear shows an attention mark (no words) while runway.short or adapter_short. (open-07, ear part)
19. `[visual · S · none]` The ScreenBarPeek.swift:337 unseen dot uses `UnseenDot`. (polish-10)
20. `[slim · M · low]` Split NotchToy.swift (NotchControlsView, shake-to-summon, the feedback overlay, gestures) and AquariumView.swift (5,887 lines, by its MARK sections). Pure moves, last. Fold is not touched. (slim-swift-15, slim-swift-16)

### 9. History, Overview, Usage Center, Data Hoarder and Settings pages (`past`), Swift + small Python, M, low

**Owns:** app/Sources/JRBarApp/HistoryStore.swift, HistoryView.swift, Replay/ReplayStore.swift, Overview/{OverviewStore, OverviewView, OverviewFilter, OverviewLinks, UsageGraphView}.swift, UsageCenterStore.swift, UsageCenterView.swift, SessionUsageStore.swift, Utilities/DataHoarder/**, SettingsPagesA.swift, SettingsPagesB.swift, SettingsAtoms.swift, ProviderStyle.swift, new UnseenDot.swift; JRBarCore/{HistoryModel, OverviewModel, UsageForecast, LightExplanation, DataHoarder*}.swift; JRBarUI/StatusIconRenderer.swift (the hex init only); src/jrbar/radar_import.py, integration_settings.py, integration_cli.py; tests for these.
**Shared:** CoreModel.swift and CoreMessages.swift (radar removal); core_runtime.py (remove the radar commands, add the T3 command); CORE-PROTOCOL.md (the radar rows at 942-944, the T3 row); SettingsDocument.swift (`appIntroduced` and the doc at :138).

1. `[bug · S · low]` The Overview keeps at most one `usage_graph` in flight. Picker changes coalesce into one follow-up request with the latest key (OverviewStore 1525-1548 and 1575-1603). (core-hol-single-lane, app part)
2. `[bug · S · none]` `durationText` (OverviewView.swift:1485) uses integer minutes and seconds. Table test: 95 → '1m 35s', 119 → '1m 59s', 3599 → '59m 59s'. (slim-swift-08)
3. `[bug · S · low]` OverviewStore.swift:824 answers through `AskAnswerDesk.shared` instead of calling `answerAskNow` directly. (slim-swift-01, Overview part)
4. `[bug · S · low]` `OverviewStore.openSession` (647-662) and `HistoryStore.open` (311-322) go through SessionOpener, and their raise fallbacks are deleted. Do this after `agentloop` task 2.
5. `[slim · S · low]` **Delete the Agentic Radar lens.** (slim-swift-10) Remove OverviewView 112-115 and 1250-1320, OverviewStore 1409-1470, CoreModel 362-394, CoreMessages 817-905, OverviewModel 204-240, radar_import.py, core_runtime.py 3100-3140, CORE-PROTOCOL 942-944 and the parity-test entries. Leave any radar files on disk alone.
6. `[slim · S · none]` Make `NSColor(statusHex:)` public as `init?(hex:)` in JRBarUI, and delete ProviderStyle's identical copy. (slim-swift-08)
7. `[slim · S · none]` Delete dead members: OverviewStore :636, filteredTimeline/timelineKindCounts/firstErrorSeq/canOpenSelected (1314-1343) and staticEdges (:1457); `DataHoarderCatalog.legacyFingerprint`; `TranscriptRedactor.sensitiveKeys` and its doc; `SettingsKey.appIntroduced` (SettingsDocument:307) and the stale doc at :138. (slim-swift-13)
8. `[copy · S · low]` History folds consecutive rows of one session into one, and the banner counts sessions, not turn ends. The names come from `daemon` task 11. (polish-05)
9. `[ux · S · low]` **Overview empty state.** (polish-06)
   - An empty Needs me view says 'Nobody's waiting on you' and offers a 'Show N working' button.
   - When the filter hides rows, add a whole-roster phrase.
   - The coverage-note footer becomes 'Older runs live in History (⌘Y)'.
   - The chip strip scrolls.
10. `[visual · S · none]` Add UnseenDot.swift (fixed systemBlue) and use it in HistoryView:398, OverviewView:398 and ReconstructedTimelineView:283. (polish-10)
11. `[copy · S · low]` Locale times in HistoryStore:466, UsageForecast:195 (with a locale parameter; update UsageForecastTests:193), LightExplanation:422 and OverviewStore:942, using `Date.FormatStyle(date: .omitted, time: .shortened)`. Widen History's time column. (polish-12)
12. `[visual · S · low]` **Settings › Agents rows fit the window.** (polish-09) In SettingsPagesA 331-420, each row has a full-width status line that wraps to 2 lines, and Repair appears inline when the doctor asks for it. Reinstall, Remove and 'Clicks open ▸' move into a trailing … menu. The CLI-missing rows are grouped under 'CLI not found (4)'.
13. `[copy · S · low]` The colour-vision notes (SettingsPagesB 340-395) collapse under one 'Colour vision: N pairs close — Review' disclosure. Shipped brand colours don't change. (polish-15, settings part)
14. `[copy · S · low]` `global_brightness_scale` is labelled 'Maximum brightness' with the subtitle 'Caps every light JR-Bar drives' (SettingsPagesA:41-44). SettingsPagesA:1053 reads 'under Utilities › Notch'. (polish-17, R5 copy)
15. `[feature · M · low]` **Offer Data Hoarder from History.** (open-05) History's empty search state offers it in one line. Clicking opens a consent sheet with an estimated size. Capture gains a backfill window: by default only files modified in the last 30 days are read, and everything after is followed live. fullContent stays off.
16. `[feature · S · low]` **T3 Code toggle.** (open-09) A Settings › Agents row appears when ~/.t3/userdata/state.sqlite exists, with an Enable toggle through a new daemon command that wraps integration_settings, and a status line. Add the CORE-PROTOCOL row.

## Slimming

These are the audit's estimates, from the Python reachability walker, the Swift linker map and grep. The Python total depends on how many helpers the menu and window code shared.

| Lane | What goes | Lines (approx.) |
|---|---|---|
| pyslim | SP-02 `open_legacy_window` and nine window modules | 6,000 |
| pyslim | SP-01 NSMenu tree and nine menu-only modules | 5,300 |
| pyslim | SP-06 deck windows | 1,400 |
| pyslim | SP-03 four speculative modules | 1,010 |
| pyslim | SP-04 shadowed controller methods | 760 |
| pyslim | SP-05 retired LaunchAgent and status-bar launch | 520 |
| pyslim | SP-09 test-only twins | 400 |
| pyslim | SP-12 sidepulse shim | 100 |
| daemon | SP-08 remote_observation and local_api_contract | 1,370 |
| past | Radar lens (Python side, radar_import.py and its command) | 300 |
| usage | `build_usage_inventory` twin, whole-file read helpers | 50 |
| **Python** | | **about 17,200** |
| menubar | Arrange (1,080), fallback chevron (120), dead members (60) | 1,260 |
| windows | Replay window (215), App Intents (265), FirstRunCard (290), dead members (40) | 800 |
| agentloop | Agent card roster (480), answer-path copies (200), open fallbacks (60), dead members (40) | 780 |
| notch | NotchAskAnswerer and copies (100), audio readers (120), fade helper (70), bars (60), chip timeline (40) | 390 |
| dock | AppleDockControl hide half (90), Dock answer path (60), sync raise (40), merges (20) | 210 |
| past | Radar Swift side (60), hex duplicate (40), dead members (80) | 180 |
| **Swift** | | **about 3,600**, plus about 700 lines of tests |

Added back: What's New (about 400), SessionOpener (80), the window lifecycle helper (60), the slow lane (80), and the new tests. **Net: about 20,000 lines fewer.** The file splits (MenuBarUtility, AquariumView, DockEnhance, NotchToy) remove nothing; they cut incremental type-check time. Deferred slimming, under Not tonight: SP-10 (about 10,000), SP-11 (about 1,500), SP-07 (about 850).

Efficiency targets for the morning:
- JR-Bar idles at about 2% CPU after every window has been opened and closed (45–97% today).
- Warm Codex usage scan about 1.5 s (60–135 s today).
- Cold scan peak about 400 MB (2.6 GB today).
- An Approve replies in under a second during a usage scan (107–195 s worst today).
- Launch to live data about 2.5 s from spawn (3.3 s today).
- The pytest loop about 70 s (about 290 s today).

## The "What's new" moment

**Goal.** The first thing you see after the overnight install is one calm window: what changed, with a one-click way to try each piece.

**When.**
- Armed at launch when Setup is finished and `SetupState.whatsNewSeen`, a new optional string in setup.json with tolerant decode, differs from the catalog's release id.
- Presented at the first moment the core is live, the session is unlocked and no full-screen app is in front. Never in the same launch as Setup.
- It doesn't activate the app: `orderFrontRegardless()`, and it becomes key when clicked.
- The id is stamped when the window closes by any route, so it appears once.
- The install scripts don't open it.

**Where.**
- WhatsNew/WhatsNewCatalog.swift (static entries with stable ids), WhatsNewView.swift, and WhatsNewWindowController.swift, built on the shared WindowContentLifecycle.
- Reopen through `AppCommand.AppWindow.whatsNew` (`jrbar://window/whats-new`), 'What's New…' in the More and right-click menus, and a palette row.

**Look.**
- A titled window about 480 pt wide, 'What's New in JR-Bar'.
- Header: the version and one line, 'Faster, quieter, and ⌘⇧K works now.'
- Up to eight rows. Each has an SF Symbol, a title of at most five words, one sentence, and on the right either a 'Try it' button or a shortcut chip.
- Footer: 'Done'.
- System materials and accent. Rows fade in 0.18 s one after another, with no motion under Reduce Motion.

**Entries.** Drop any entry whose lane didn't merge, and write the words last, from what shipped.
1. `palette`: '⌘⇧K runs all of JR-Bar'. Try it: `.menuBar(.commandBar)`.
2. `open`: 'Open lands on the session'. Claude desktop sessions open on the exact conversation, and Claude in Ghostty raises its pane. No button.
3. `approve`: 'Approve never waits'. Answers skip ahead of usage scans, and held asks show their 45-second window as a ring. No button.
4. `focus`: 'Follow Focus works'. Try it: `.settings(page: "notifications")`.
5. `usage`: 'Usage in a second'. Try it: `.window(.usage)`.
6. `quiet`: 'Idles near zero'. Closed windows stop drawing, and the daemon stays under about 0.5 GB. No button.
7. `lyrics`: 'Lyrics are opt-in'. Synced lyrics ask LRCLIB, so they wait for your click now. Try it opens the Settings page that holds the Notch card, if the router has that page; otherwise no button.
8. `shelf`: 'The Shelf and ⌥⇥'. Try it: `.shelf`. ⌥⇥ gets a chip only.

**Rules.**
- A Try-it runs only on a click, through AppCommandRouter.
- Nothing answers an agent, and nothing leaves the Mac.
- Rows for things still marked 'check by hand' don't over-promise.

**Tests.** Ids are unique; every Try-it survives a round trip through AppCommand's URL form; shouldPresent is checked against a truth table (Setup unfinished, already seen, core offline, locked, full screen); closing stamps the id.

## Not tonight

| Item | Why it waits |
|---|---|
| Drop `st_dev` from usage cache keys (health-cache-key-st-dev) | The prune fix already ends the permanent stall. The key change touches six or more sites, and its `CACHE_VERSION` bump forces cold Claude and Codex rebuilds (about 70 s plus 140 s) on the morning you test. Next wave, with the full list of sites. |
| Hold Codex asks while an unrelated Ghostty tab is in front (codex-hold-ghostty) | A wrong hold hides a Codex prompt, and the check runs osascript every second. Every live session this week is in Claude.app or ChatGPT.app, so there's no payoff yet. |
| Fold's sensor parks at 1 Hz while paused (R3b) | Fold's motion feel is untouchable, and this adds up to 1 s of arming lag after the lid reopens. |
| Route the banner pipeline into ambient lights, then delete it (SP-07) | Fixing it first switches on an effect-on-completion light that has never run. You should decide whether you want it. |
| Delete settings_window and its panes (SP-10, open-08) and the Screen Bar drawing code (SP-11) | About 11,500 lines of surgery in a 19.8k-line file. It needs a live set_setting/doctor parity check and a Screen Bar hand check. Next wave, once tonight's SP-01/02/06 have settled. |
| Move ⌘⇧K ownership out of the Menu Bar utility (slim-swift-02) | It migrates the persisted chord of the key the morning test depends on. REG-1's guard already fixes the bug. |
| Stop registering the agent and combined status items under the concealer (slim-swift-06b) | It changes what sits in your real menu bar and the Control Center battery/Wi-Fi gate. This area has always needed your eyes. |
| Cut the notch Weather row (slim-swift-11) | The atlas says to decide once. Tonight only fixes the docs. |
| Everyday-view pin for the right ear (open-10) | A new setting on your most carefully tuned surface. It needs your taste. |
| Split AppDelegate into an AppGraph plus per-subsystem files, and split CoreMessages (core-appdelegate-split, slim-swift-14/16) | Every lane edits these files tonight. A 1,800-line move on top of nine merges is the likeliest build break with nobody awake. First thing next wave, on its own. |
| CoreModel state slices (perf-coremodel-slices) | Re-measure after the window teardown lands. It touches readers in every lane. |
| Presence: locked, idle, meeting, next event, reminders, and Settings rows for away/meeting/call quiet (open-03 rest) | These would switch on quiet behaviours you haven't chosen. Tonight only wires Focus, which you already turned on. |
| Battery detail popover and on-demand `session_energy` (open-07 rest) | A new surface. Tonight covers the footer lines, the sleep-error toast and the ear mark. |
| Replace `ps` with libproc in the liveness sweep (perf-refresh-main-thread-stalls) | Instrument first (pyslim task 3), then pick the fix from a night of timing lines. |
| One shared pointer clock (health-pointer-polls, R10) | About 3 wakeups a second; tonight's parking and timer tolerance cover most of it. |
| Merge the dismiss watchers, a shared ScreenCaptureKit cache and one AX helper namespace (REG-11 a–c) | No measured cost, and the shared cache carries freshness risk. |
| Spawn the core earlier in launch (perf-launch-to-live-data e) | Needs the supervisor split into spawn-now and attach-later first. |
| Clean up the 1,596 leaked `jrbar.tests.*.plist` files and the fixture machine 'mac-b' in your real remote_peers settings | They're in your Preferences folder and live settings. `mv ~/Library/Preferences/jrbar.tests.*.plist ~/.Trash/` and removing mac-b under Settings › Remote take a minute. Separately, find the test that wrote mac-b into real settings. |
| WidgetKit widget, Focus filter, App Intents in Shortcuts | This Mac has Command Line Tools only; there's no appintentsmetadataprocessor. |
| A GitHub release so the Sparkle feed stops returning 404 | Publishing is a public action. |
| Daemon TCC checks (about 12 TCCAccessRequest calls a minute) | The caller hasn't been traced yet. |

## Hand checks for the morning

1. ⌘⇧K opens. Run a verb, then press ⌘⇧K again: it still works. Open it over a full-screen app too.
2. Open and close Effect Studio, Overview, History, Usage Center and Creator Micro. `top -pid $(pgrep -x JR-Bar)` should settle near 2%. Each window's first-open size should look right.
3. Open the Usage Center: fresh numbers within seconds, and `ps -o rss= -p $(pgrep jrbar-core)` stays under about 500 MB.
4. Click a Claude session in the panel: Claude.app lands on that exact conversation.
5. Click Approve while the Overview's Usage pane is loading: it answers at once.
6. Hover a Dock tile until the preview shows, then press ⇧→ in a text field: the selection extends.
7. With a 'while' rule holding an LED scene, quit and relaunch: your earlier scene comes back once the rule no longer holds.
8. On the notch card, the lyrics chip turns lyrics back on with one click.
9. Turn on a Focus: JR-Bar dims the way your Follow Focus setting says.
10. Click a concealed menu bar item from the Item Bar: its menu opens without a stray app activation.
11. When the Creator Micro is back, its window keys open the Swift Overview, Usage and Creator Micro windows.
12. Force-quit jrbar-core while an ask is showing: the Approve buttons go away until the new daemon reports.
