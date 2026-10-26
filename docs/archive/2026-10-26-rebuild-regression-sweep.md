# 0.10 rebuild regression sweep

Compared v0.9.17.2, `740c1b92`, with the implementation baseline,
`5896145f`. Locations below refer to the old revision unless stated otherwise.
The [0.10 plan](../plans/2026-10-25-0.10.0.md) and its
[approved mockups](../plans/2026-10-25-0.10.0-mockups/index.html) define the
intended layout. The owner's implementation brief also confirms removal of
the notch usage tab, toy pictures, and panel footer LED mirrors.

The sweep used three independent searches:

- Compared view and helper declarations in the old panel, Usage Center,
  Settings pages and shell, Effect Studio, and status item with current
  production references. A test-only reference did not count as a caller.
- Followed surviving views and helpers with no production callers into
  their replacements. This found the forecast, window inspection, reset
  budget, session burn ranking, and Studio current output.
- Compared removed control labels, display strings, help text, and setting
  paths against all current app sources. Then traced their current view
  entry points. Keeping a key in the settings catalog did not count as
  keeping its control.

## Decisions

| Feature | 0.9.17.2 location | Status now | Decision |
| --- | --- | --- | --- |
| Panel run-out and used-up warning | `PanelView.swift:1736`, `UsageRow`, and `:1857`, `UsageTagText` | Each window's caption uses the shared session-aware forecast. Run-out is orange; used-up is red. The reset stays in help and accessibility text. | Restored. The compact bars and columns stay as approved. |
| Provider detail verdict and forecast sentence | `UsageCenterView.swift:543`, `forecastLine` | Each quota window has its verdict chip and explanation in `UsageForecastSummary`. | Restored. |
| Projection at reset | `UsageCenterView.swift:1360`, `QuotaRing.projected`, and `:1429`, help | The detail shows the projected percent as text. Unknown, guarded, idle-held, stale, and disconnected readings never promise a projected burn. | Restored. The ring is replaced by the approved gauge. |
| Recent pace versus rate needed until reset | `UsageCenterView.swift:565`, `UsageResetBudgetView` | The existing reset budget is visible with JRBarUI type, spacing, radius, and colour tokens. | Restored. |
| Idle, no-pace, guarded, stale, and disconnected forecast states | `UsageCenterView.swift:529`, `forecastSummary`, and `:637`, `forecastSource` | `UsageWindowInspection` supplies honest words and suppresses budgets and projections for unavailable readings. The panel leaves ordinary reset captions alone. | Restored. |
| Forecast source, sample count, and local estimate | `UsageCenterView.swift:637`, `forecastSource` | The summary and inspection show forecast evidence. | Restored. |
| Room for another agent | `PanelView.swift:1834`, `resetLine`, and `UsageCenterView.swift:660` | Kept in the compact row's help and accessibility text, and in the detail summary. | Restored. No extra panel caption. |
| Inspect a quota window | `UsageCenterView.swift:506`, `UsageWindowInspectButton`; `UsageWindowInspection.swift` | A detail gauge opens the existing inspection with amount, reset, forecast, source, reading age, and scope. | Restored. |
| Reference-only and unbound window scope | `UsageCenterView.swift:212`, `UsageDetailWindowsLine` | Reference-only windows are text beneath the gauges. Real model sublimits remain independent gauges; inspection names their scope. | Restored. Reference numbers do not become account limits. |
| Per-window forecasts and hub-account idle policy | `UsageCenterStore.swift`, `forecast(for:window:core:now:)` | Both restored views call the existing forecaster. A weekly lane does not borrow a 5h pace; hub accounts keep their own policy. | Retained. |
| Panel row opens the selected provider | `PanelView.swift:1813`, `UsageRow` | Clicking or activating the row opens Usage Center for that provider identity. | Restored. |
| Provider incident | `PanelView.swift:1823`, usage tag; `UsageCenterView.swift:354`, header | The shared gauge identity shows Incident with the provider's message in help. | Restored. |
| Plan, account, fidelity, and source | `UsageCenterView.swift:417`, `accountText` | `UsageProviderFacts` shows the account and source, including CLI fallback and hub sources. | Restored. |
| Last-reading counters, credit balance, and reset credits | `UsageCenterView.swift:448`, `readingsLine` | Detail shows reported counters and credit balances, labelled as last readings. Estimated cost respects the cost switch. | Restored. |
| Reading age on a healthy provider | `UsageCenterView.swift:448`, `readingsLine` | Detail shows the reading age. Stale rows retain the shared gauge's age and recovery actions. | Restored. |
| Why a different quota lane constrains the account | `UsageCenterView.swift:384`, header | Detail names the constrained window and the daemon's explanation. | Restored. |
| Headroom on another provider | `UsageCenterView.swift:399`, `headroomLine` | Detail again shows the comparable window's measured headroom and age. | Restored. |
| Sessions burning the current window | `UsageCenterView.swift:592`, `burnersList` | Detail again shows each local session's token count and share. | Restored. Uses the store's existing bounded refresh. |
| Combined provider usage and drill-down | `UsageCenterView.swift:860`, `CombinedUsageCard` | Overview contains all provider rows, independent quota columns, token/cost totals, and provider selection. | Folded elsewhere, into `UsageOverviewTable`. |
| Fleet tightest window and reported aggregate counters | `UsageCenterView.swift:884`, `CombinedUsageCard`, and `:919`, totals | Overview again names the tightest applicable open window and aggregates reported counters. Old readings are labelled. | Restored. |
| Local-history account ownership | `UsageCenterView.swift:238`, card, and `:668`, history section | History is shown once per provider, with its local and cross-home scope stated. Hub instances do not acquire local-account history. | Restored. |
| Tokens and cost chart, range, refresh, keyboard shortcuts | `UsageCenterView.swift:77`, toolbar; `:1449`, `UsageChart` | New chart, independent curves, range picker, refresh, and shortcut reader remain wired. | Folded elsewhere, into `UsageTokenChart` and the new toolbar. |
| Model totals | `UsageCenterView.swift:1667`, `UsageModelBreakdown` | The By model disclosure lists every model's tokens and estimated cost, including unknown prices. | Restored. |
| Daily input, output, cache, total, and cost | `UsageCenterView.swift:1801`, `UsageDailyTable` | The By day disclosure restores exact daily totals. Cost columns follow the cost switch. | Restored. |
| Cache share, savings, and pricing provenance | `UsageCenterView.swift:757`, `costRow`, and `:782`, `pricingDisclosure` | Detail shows cache share and savings, price model/date, approximate rates, unpriced records, and subscription disclosure. | Restored. |
| Weekday/hour dot heatmap | `UsageCenterView.swift:1730`, `UsagePunchCardView` | The new token chart supplies hourly/daily history. | Intentionally removed. Plan, Mockup review, Usage Center: the 30-day chart replaces the block heatmap. |
| Panel token sparkline | `PanelView.swift:1802`, `UsageRow`, and `:1874`, `UsageSparklineView` | Token charts live in Usage Center. The invisible panel sparkline view, delayed task, cache, and event refresh are deleted. | Folded elsewhere. Plan, Mockup review, Panel, and approved `01-panel.html`: compact percent-used bars and reset captions. |
| Rounded quota rings and older panel bars | `UsageCenterView.swift:1334`, `QuotaRing`; `PanelView.swift:1927`, `QuotaBar` | JRBarUI gauges supply the approved quota layout. Uncalled `QuotaBar` and `UsageTagText` are deleted. | Folded elsewhere. Plan, Design and approved panel/Usage Center mockups. |
| Provider consent, metering, sign-in fixes, credentials, extra accounts, and revocation | `UsageCenterView.swift:265`, `connectionSection`; `:814`, `SignedOutRow`; `:1120`, `UsageOffRow` | Existing controls are under Connection and Settings Providers. No automatic answer or outbound consent is added. | Folded elsewhere, into `UsageProviderConnection` and provider detail settings. |
| Scanning, empty history, failed refresh, stale totals, and retry | `UsageCenterView.swift:671`, history section; `:1850`, `ScanningNote`; `:1873`, `NoLocalRecordsHint`; `:1909`, `UsageSkeleton` | `UsageHistoryPresentation` and the chart retain these states. | Folded elsewhere, into the new status banners. |
| Quota reset notice and reset-feedback failure/retry | `UsageCenterView.swift:254`, reset overlay, and status line | Provider detail again shows Window reset. The reset-save notice and retry remain in the root view. | Restored reset notice; retained failure/retry. |
| Panel provider identity, zero/unknown/elapsed/stale readings, recovery actions | `PanelView.swift:1602`, `UsageSection`; `:1666`, `UsageQuietRow`; `:1736`, `UsageRow` | The shared gauge rows retain these states. Zero readings and failures have their own rows. | Folded elsewhere, into `PanelProviderSection` and `UsageGaugeRow`. |
| Agent list, selection, context menu, worker counts, groups, finished and hidden sessions | `PanelView.swift:487`, `SessionsSection`; `:556`, `HiddenSessionsRow`; `:766`, `SessionRowView` | New agent rows, expandable groups, Earlier, and History carry these actions. | Folded elsewhere, into `PanelAgentsSection` and `PanelAgentView`. Plan, Lights 6 and Panel defaults. |
| Ask details, choices, approve/deny, demo ask, quiet/snoozed states | `PanelView.swift:1167`, `AskRow`; `:1508`, `AskRowChoices` | The ask row and context actions remain reachable. Demo ask moved with provider usage options. | Retained; Settings entry folded into Providers. |
| Monitor status, crash detail, and restart | `PanelView.swift:335`, `PanelHeader`; `:392`, `PanelStateMark` | New title bar and status banners retain status, cause, and restart. | Folded elsewhere, into `PanelTitleBar` and the panel root. |
| Why this light | `PanelView.swift:595`, `WhyLightRow` | Studio's What plays reports the daemon's reasons, cue reasons, and fallback warnings; its inspector shows device output. | Folded elsewhere. Plan, Lights 7: Studio is the home of light. |
| Devices, brightness, Studio, Usage Center, Settings, History, quiet modes, clear and undo | `PanelView.swift:2016`, `DevicesSection`; `:2190`, footer | New footer and Devices popover retain the controls. History and other windows remain in More and their shortcuts. | Folded elsewhere, into `PanelActionsFooter`, `PanelDevicesRow`, and More. |
| Panel LED-mirror dots | `PanelView.swift:2016`, `DevicesSection` | No permanent footer mirror. | Intentionally removed. Owner brief and plan, approved panel cleanup mockup. |
| Panel section labels and partial-row fade | `PanelView.swift:46`, `SectionLabel`; `:315`, `ScrollEdgeFade` | New section headers and complete-row scroll sizing replace them. Uncalled definitions deleted. | Folded elsewhere. Plan, approved panel cleanup mockup. |
| Startup, menu icon styles, app updates, setup rerun, release channel, diagnostics, import/export, reset | `SettingsPagesA.swift:8`, `GeneralPage`; `:56`, `GeneralAdvanced`; `SettingsPagesShell.swift:109` | Existing pages and callbacks remain reachable through the new Settings shell. The old gallery rows and tiles are deleted; the native picker remains. | Folded elsewhere. Plan, Design and Settings mockup. |
| Provider hook installation/removal, CLI detection, session click target, updates, demo asks | `SettingsPagesA.swift:347`, `AgentsPage`; `:465`, `AgentRow` | Providers and their detail pages retain the controls. T3 is under Integrations. | Folded elsewhere. Plan, Usage and providers 4 and Mockup review 1. |
| Track, menu bar, panel, and provider order | `SettingsPagesA.swift:607`, `UsagePage`; `:1514`, `MenuBarProviderPicker` | One provider list owns visibility and order. The test-only legacy picker is deleted. | Folded elsewhere. Plan, Usage and providers 4. |
| Usage range/metric, Claude quota consent, quota thresholds, optional sources | `SettingsPagesA.swift:607`, `UsagePage`; `:667`, `UsageAdvanced` | Providers, provider detail, and Usage options retain these controls. | Folded elsewhere. Plan, Usage and providers, and Settings mockup. |
| Transcript monitoring, sample retention, provider status feeds, update checks | `SettingsPagesA.swift:432`, `AgentsAdvanced`; `:667`, `UsageAdvanced` | Privacy and provider source pages retain the controls. | Folded elsewhere. Plan, Mockup review, Settings. |
| Device hardware, brightness, linking, direction, calibration, Creator Micro, Stream Deck, Screen Bar placement | `SettingsPagesA.swift:743`, `DevicesPage`; `:820`, `DeviceCard`; `:1110`, `CreatorMicroCard`; `:1302`, `ScreenBarCard` | Devices retains hardware controls; light overrides are in Studio Devices. | Folded elsewhere. Plan, Lights 7. |
| Per-device display, provider pin, ask policy, mix | `SettingsPagesA.swift:888`, `DeviceLightSettings` | Studio Devices supplies each control. The uncalled duplicate implementation is deleted. | Folded elsewhere. Plan, Lights 7. |
| Provider/state colours, pulse range, dimming, scenes, automatic speed, cues, milestones | `SettingsPagesB.swift:9`, `LightingPage`; `:161`, `LightingAdvanced` | Studio Providers, State Colours, Scenes, Mix, and Cues retain these controls. The uncalled advanced duplicate is deleted. | Folded elsewhere. Plan, Lights 7. |
| Alerts, Focus, calendar, power, phone/webhook, machine list, Stream Deck | `SettingsPagesB.swift:944`, `NotificationsPage`; `:1330`, `RemotePage` | Existing pages remain in the new navigation; colour and light controls route to Studio. | Retained. |
| Sounds, sound preview, shortcuts and recorders | `SettingsPagesShell.swift:12`, `SoundsPage`; `:250`, `ShortcutsPage` | Existing controls remain, with the new Studio shortcut added by the rebuild. | Retained. |
| Toy functionality and utility detail controls | `Toys/ToysPage.swift`, `ToyCard`; Settings page shell | Feature rows open their existing settings controls. | Folded elsewhere. Plan, approved Settings mockup. |
| Toy pictures | `Toys/ToysPage.swift`, old card layout | No decorative pictures in the Settings list. | Intentionally removed. Owner brief and plan, approved Settings mockup. Shared utility cards still have callers and are kept. |
| Notch usage tab | Old notch card usage page | Absent. No notch files changed in this task. | Intentionally removed. Owner brief and approved notch scope. |
| Studio effect library, filters, import/export, parameters, palettes, assignments, editor, scenes, Moments | `EffectStudioView.swift:9`, root; `:160`, library; `:367`, inspector; `:775`, assignments; `EffectStudioProgram.swift`; `EffectStudioMoments.swift` | All rooms remain in Studio navigation. Assignments moved out of the Effects split view to their own destination. | Folded elsewhere. Plan, Lights 7 and approved Studio mockup. |
| Studio current device output | `EffectStudioView.swift:846`, `EffectLiveOutput` | The surviving view is reachable again in the device inspector. | Restored. |
| Menu bar icon styles, quota meters, pace tint, labels, hover, right-click actions and provider visibility | `StatusItemController.swift`, `StatusItemPlan`, `paceVerdict`, menu; `AppDelegate.swift`, usage rendering | Production callers remain. The provider list now filters and orders the same icon meters. | Retained. Plan, Usage and providers 4 requires the owner's meter icon to stay. |

## Verification

`UsageForecastSurfaceTests` exercises the actual panel row builder and provider
detail model for run-out, used-up, comfortable, no-pace, idle-held, stale, and
guarded readings. It also captures preferences emitted by the rendered gauge
and forecast components. Removing either component fails those tests even if
the forecast engine and strings survive.

Additional checks cover an imminent run-out, reset boundaries, secondary-window
isolation, unavailable sources, no quota source, account facts, credits,
counters, and reference-only windows. Render proofs use synthetic providers
and offscreen snapshots in light and dark.

The final gates passed:

- Full Python suite, `PYTHONPATH=$PWD/src .venv/bin/python -m pytest tests -q -n 4 --dist loadfile`: 19,543 passed and 15 subtests passed. Four existing multiprocessing deprecation warnings remain.
- Full Swift suite, `env -u JRBAR_INTERACTIVE_TESTS -u JRBAR_RENDER_PROOF swift test --no-parallel`, from `app/`: 6,127 registered tests across the four targets. The run passed, with 315 tests skipped by their conditions.
- `make fast`: 187 contract tests, 77 fixture tests, and 347 focused tests passed. Lint, imports, design tokens, bytecode, dependency policy, version checks, and diff hygiene passed.
- Forecast guards and proofs, `JRBAR_RENDER_PROOF=1`: seven tests passed, including seven verdict cases. Both compact widths keep 44-point rows. The later-day clock keeps its minute, and missing-source flags pause the restored inspection.

The ten final PNGs are in `/tmp/jrbar-rebuild-forecast-20261026-bbb06f2e/`:

- `forecast-panel-372-{light,dark}.png`
- `forecast-panel-320-{light,dark}.png`
- `forecast-panel-imminent-372-{light,dark}.png`
- `forecast-panel-imminent-320-{light,dark}.png`
- `forecast-detail-{light,dark}.png`

Each PNG was opened and inspected. The panel proofs include one provider
running out and another used up. The imminent proofs show the 40-minute
caption. The detail proofs show the verdict, headline, projected percent,
and reset budget. These are offscreen component proofs, not installed-app
or hardware receipts. No helper app was created.
