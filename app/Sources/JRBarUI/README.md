# Shared UI

Import `JRBarUI`. Components render supplied facts and start no jobs or timers.

- `JRBarTokens.TypeStyle` supplies title 26/32, title1 22/28, heading
  17/22, title3 15/20, headline 13/18, body 13/18, callout 12/16,
  caption 11/14 and section 11/14. Use `.jrbarType(.body)` to apply
  font and leading to wrapped text. Section text is secondary and semibold.
- `JRBarTokens.Ink` supplies adaptive labels, fills, separators and status
  colours, including hover, group, groupEdge, quaternary and accentSoft.
  `onAccent` is the native selected-control text colour.
  Neutral ink strengthens in Increase Contrast. `accent` follows the system;
  `working` stays blue. Stale text uses `stale`; stale bars use `tertiary`.
- `Radius` and `Space` hold the approved radii and 4 pt spacing grid.
  `Radius.pill` returns a Capsule. `Radius.providerTile(size:)` scales tiles.
- `Motion` supplies quick 100 ms, panelEntrance 140 ms, rowChange 160 ms,
  notchSettle 250 ms, notchClose 180 ms and reduced 80 ms.
  Native windows use `progress(at:)` on the same curves, with exact end times. Quick and
  notchClose ease in. Use `animation(reduceMotion:)` for fades and
  `transition(reduceMotion:)` for entrance transitions. When Reduce Motion
  is on, change layout without animation and fade inserted content only.
- `jrbarAccessibility(reduceMotion:reduceTransparency:increaseContrast:)`
  pins accessibility states for previews or app preferences. Omitted motion
  and transparency values follow macOS. Increase Contrast also follows
  macOS; passing true forces it for a proof. Settings groups use an opaque
  content plate with Reduce Transparency.
  Existing previews can read `EnvironmentValues.jrbarReduceMotion`; nil
  means follow macOS.
- `ProviderPalette` owns provider defaults, display names and logo IDs.
  Studio overrides still come from `colors.agent_colors` in the daemon's
  document. Pass an overridden accent when available.
- `.jrbarSidebarSelection(_:)` gives sidebar rows an accent fill and selected text colour.
  Apply selection ink before `.jrbarType` so it overrides the type token's
  default label ink.

`UsageGaugeRow(provider:name:now:connected:accent:style:windowNames:
snapshotReceivedAt:locale:timeZone:pace:fix:onAction:onRetry:)` renders
supplied facts without polling. The default `.detail` layout has 6 pt
lanes and optional pace ticks. Use `.compact` in the panel and drawer.
It has a 20 pt tile and a 100 pt identity column. Window columns share
all remaining width, with a 64 pt minimum. Each percentage sits beside
its 4 pt gauge, with the reset time below. Normal panel rows are 44 pt
tall with 4/12 pt padding. Status and action rows keep extra height.
Columns wrap below the name when they cannot fit beside it.

Place `UsageGaugeHeader(windowNames:)` once above compact rows. Pass the
same names to each row so mixed window sets align. A missing slot is a
dash. `orderedWindowNames(_:)` deduplicates names and places 5h before 7d.
Rows identify columns by window name. Detail rows label their own lanes.
Percentages clamp to 0...100. Missing values have no track. Elapsed
windows say Reset; an unmeasured window says No reading.

Pass the page's clock, locale, time zone and connection state. Pass
`snapshotReceivedAt` from the store when the snapshot arrives, especially
when `readingAt` is missing. The age then advances from
`lastGoodAgeSeconds`. A row captures arrival locally if this is omitted.
Stale age appears once under the name. Each lane keeps only its reset
time: `in 42m`, a same-day clock time, or a later weekday and hour.
No timers run inside the row.

Status text stays below the name with tail truncation and its full text
in the help and accessibility tree. Failure causes use label ink and a
red triangle. Actions occupy a separate line beneath the name. Supply
optional `fix` text and `onRetry` there. Route `onAction` through the
existing provider action command with `provider.actionKind`. Absent
providers draw no row. Not-found, consent-off and sessions-only providers
draw no old numbers.

- `JRBarGauge(value:tint:stale:height:pace:)` is the shared continuous
  gauge. Value and pace use percent units, 0...100. Nil draws nothing.
  Detail lanes use height 6 and a 1.5 pt pace tick extending 2 pt each side.
- `StateDot(_:)` takes working, asking, done, failed, stale or live. Its
  8 pt dot breathes on working and asking with periods of 1.6 and 1 s.
  Reduce Motion stops breathing. It starts no data jobs.
- `ProviderLogoTile(provider:size:accent:dim:surface:)` defaults to 20 pt.
  Sizes 16/20/28/40 use radii 5/6/8/11. Grok defaults to monochrome ink.
  Dim tiles use a neutral plate, secondary mark and separator edge.
  Accessibility uses the display name. Pass `.black`, `.lightGlass` or
  `.darkGlass` for those backgrounds; ordinary content plates are automatic.
- `StatusBanner(_:kind:detail:action:)` has a semibold title, optional
  11 pt detail, radius 12 and a small prominent action. Use information for
  non-failure messages. Omit the action builder for messages without one.
- `SettingsRow(_:subtitle:control:)` applies 8/12 pt padding and small
  control size. Supply a native switch with `.toggleStyle(.switch)`.
  `SettingsNavigationRow(_:subtitle:action:)` adds a chevron and hover fill.
  Place rows in `SettingsGroup { ... }` for radius 12, group fill, edge
  and separators inset 12 pt at both ends. The group supplies each row's
  insets, including bare pickers and custom rows. Use `.settingsRowInsets()`
  on custom rows so they keep the same padding outside a group without
  doubling it inside one. Controls retain their own accessible labels.
- `AgentGroupRow(provider:name:project:subtitle:elapsed:state:memberMarks:
  workerCount:unlinked:expanded:members:)` takes proven members and an
  expansion binding. Project is secondary; subtitle is the task; elapsed
  and StateDot sit on the right. Mixed groups take provider IDs in
  `memberMarks`. The left chevron rotates over 140 ms. Unlinked workers
  have an info icon, dim tile and one 0.55 opacity on normal label colours.
  They cannot expand or acquire a strip share.
- Use `AgentMemberRow(provider:name:role:elapsed:state:isLast:)` inside the
  group builder. It draws a 28 pt row indented 34 pt, with a tree line.
  Set `isLast` on the final member to end the line at that row.

`ProviderListStore` lives in JRBarApp. AppDelegate creates one and passes
it to `PanelStore` and `SettingsStore` as `providerList`. Reuse that instance.

Call `refresh()` on page open. `providers` gives ordered default accounts
and excludes T3 Code, which belongs under Integrations. `rows` retains all
configured accounts. `setTracked`, `setUsageConsent`, `setPanelVisible`,
`setMenuBarVisible` and `setOrder` await the daemon's saved replies. Show
`failure` once at page level. Disable edits while their identity is in
`busy`, or while `writingPresentation` is true.

Track uses `set_provider_enabled`. It does not grant usage consent or
remove hooks. Before `setUsageConsent`, show the provider's consent summary
and obtain the person's explicit choice. Panel visibility writes the
per-instance `panel_hidden` option and leaves Track unchanged. Menu bar
visibility and shared order use `set_setting` on `provider_display`.
`arranged(_:provider:surface:)` applies that order to the menu bar, panel or
whole list. Unknown providers keep their input order after ranked providers.

The daemon defaults `provider_display` to null. On first connection the
store imports the old app preferences once. A missing field means an older
daemon, so the store does not send an unsupported migration. The app clears
its legacy copy only after the saved presentation becomes available.

Run `scripts/check_design_tokens.py` through the development Python. Its
baseline records existing literals by file and expression. New literals
fail. After converting a screen, run it with `--prune` to remove retired
allowances. This command cannot add allowances. A necessary exception needs
`// jrbar-token-exception: reason` on the offending line. Token definitions
use that marker too. `make fast` runs the check and its tests.

Render the foundation matrix with `JRBAR_RENDER_PROOF=1` and
`JRBAR_RENDER_PROOF_DIR=<scratch directory>`, then run
`swift test --package-path app --filter JRBarAppTests.FoundationRenderProofTests`.
Leave `JRBAR_INTERACTIVE_TESTS` unset. The host uses
`WindowPresenter.renderProofKey` to make only an offscreen proof window key,
so switches and buttons capture their active accent. Open every PNG.
