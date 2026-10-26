# Shared UI

Import `JRBarUI`. Components render supplied facts and start no jobs or timers.

- `JRBarTokens.TypeStyle` has five styles: title 26, heading 17, body 13,
  callout 12 and caption 11 pt. Use `.font(style.font)` and add weight when
  needed. `lineHeight` records the approved ramp for custom drawing.
- `JRBarTokens.Ink` supplies adaptive labels, fills, separators and status
  colours. `accent` follows the system. `Radius` and `Space` hold the
  approved radii and 4 pt spacing grid.
- `JRBarTokens.Motion` supplies `quick`, `panelEntrance`, `rowChange` and
  `notchSettle`. Use `.animation`; durations are 100, 140, 160 and 250 ms.
  Curves do not bounce. Respect Reduce Motion at the owning screen.
- `ProviderPalette` owns fixed provider defaults. `ProviderStyle` uses it.
  Studio overrides still come from `colors.agent_colors` in the daemon's
  document. Pass an overridden accent to the components when available.
- `UsageGaugeRow(provider:name:now:connected:accent:onAction:)` draws each supplied
  window independently. Pass the page's clock and connection state. A
  stale reading is grey and names its age. An elapsed window has no bar
  value or current percentage. L3's absent, not-found, missing-recent,
  source-idle and failing states stay distinct. Absent providers draw no
  row; not-found providers draw their status without old numbers.
  Pass `onAction` to show the daemon's action label. Route that click through
  the existing provider action command with `provider.actionKind`.
- `ProviderLogoTile(provider:size:accent:)` draws the existing vector mark
  with contrast-adjusted ink. Providers without a shipped mark get a symbol.
- `StatusBanner(_:kind:action:)` belongs above the page's rows. Supply one
  recovery action. `SettingsRow(_:control:)` holds one title and control.
- `AgentGroupRow(provider:name:workerCount:unlinked:expanded:members:)` takes
  a binding and the caller's proven members. It never infers a group.

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
