# JR-Bar docs

Start with the [README](../README.md) for what JR-Bar is and how to
install it. This page lists everything else.

## Using JR-Bar

- [Install and remove](user/install.md)
- [The command line](user/cli.md): `jrbar usage`, `jrbar status`,
  `jrbar hooks doctor`, settings by dot path, `jrbar://` links
- [Providers](user/providers.md): hooks, usage cards and what each state
  means
- [Where the usage numbers come from](user/usage-sources.md): OpenCode Go,
  account homes, token history, prices, reset credits, reset confirmation
- [Usage hooks](user/usage-hooks.md): run your own program when a quota
  runs low or resets
- [Claude Code's status line](user/claude-statusline.md) as a quota source
- [CLIProxyAPI as a usage hub](user/cliproxy-hub.md)
- [Scripts, status bars and launchers](user/scripts-and-status.md):
  `jrbar serve`, xbar and SwiftBar, Raycast, and the
  [examples](../examples/README.md)
- [Toys](TOYS.md) and [Utilities](UTILITIES.md)
- [Control Center](CONTROL-CENTER.md) for the Creator Micro 2, and its
  [adapter](creator-micro-2.md)
- [Integrations](INTEGRATIONS.md): T3 Code and Alcove, read-only
- [Compatibility](COMPATIBILITY.md): what it runs on and how sure we are

## How it works

- [Architecture](ARCHITECTURE.md): the three processes, data paths and
  the module map
- [Core protocol](CORE-PROTOCOL.md): every document and command between
  the app and the daemon
- [Native provider usage](NATIVE-PROVIDERS.md) and the
  [provider adapter guide](PROVIDER-ADAPTER-GUIDE.md)
- [Top-of-screen contract](TOP-OF-SCREEN.md): how Notch, Screen Bar, Menu
  Bar and Dock share the top of the display
- [Effect authoring guide](EFFECT-AUTHORING-GUIDE.md)
- [Integration boundary](INTEGRATIONS-NATIVE.md)
- [Screen Bar profiling](SCREEN-BAR-PROFILING.md)
- [Packaging and signing](../packaging/README.md), and
  [running the app from a checkout](../app/README.md)

## Working on JR-Bar

- [CONTRIBUTING](../CONTRIBUTING.md) and [AGENTS](../AGENTS.md) (for coding
  agents)
- [Local verification](LOCAL-VERIFICATION.md) and
  [final testing](FINAL-TESTING.md)
- [Releasing](PRODUCTION-RELEASE.md); `make release-check` runs every
  release check without publishing
- [Repository hygiene](REPOSITORY-HYGIENE.md)
- [Prior art and attribution](PRIOR-ART.md)
- [Upstream research cadence](UPSTREAM-RESEARCH-CADENCE.md);
  `scripts/check_upstreams.py` shows what each upstream has changed since
  the last review
- [Feature matrix](FEATURE-MATRIX.md), [roadmap](ROADMAP.md) and
  [feature disposition](feature-disposition.md)

## History

Plans, audits and research notes, kept for provenance. Nothing in the
build reads them.

- Plans: [0.8 plan](PLAN-0.8.md), [build spec](BUILD-SPEC.md),
  [vision](VISION.md), [production task contract](production-task-contract.md),
  [toy parity](TOY-PARITY.md), [upgrade ledger](upgrade/STATUS.md)
- Audits: [rescue report](RESCUE-REPORT.md)
- Research: [ecosystem](ECOSYSTEM-RESEARCH.md),
  [providers](PROVIDER-RESEARCH.md),
  [upstream refresh 2026-08-30](UPSTREAM-REFRESH-2026-08-30.md),
  [upstream sync](UPSTREAM-SYNC.md), [research/](research/)
- [archive/](archive/): the dated plans and audits once they are done, the
  superseded plans and the pre-0.8 specs:
  - Plans: [product design 2026-09-19](archive/product-design-2026-09-19.md),
    [finishing pass 2026-09-19](archive/finish-2026-09-19.md),
    [Data Hoarder plan 2026-09-19](archive/data-hoarder-implementation-2026-09-19.md),
    [upgrade plan 2026-09-24](archive/UPGRADE-PLAN-2026-09-24.md)
  - Audits: [systems audit 2026-09-16](archive/AUDIT-2026-09-16.md),
    [branch consolidation 2026-09-07](archive/BRANCH-CONSOLIDATION-2026-09-07.md),
    [archive/audits/](archive/audits/) (2026-08-15 to 2026-09-21)
