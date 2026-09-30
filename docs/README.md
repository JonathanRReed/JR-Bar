# JR-Bar docs

Start with the [README](../README.md) for what JR-Bar is and how to
install it. This page lists everything else.

## Using JR-Bar

- [Quick start](user/quick-start.md): install hooks, find a session, answer an
  ask, and check quota
- [Recovery](user/recovery.md): monitor offline, stale quota, missing hooks,
  and macOS permissions
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
- [Toys](TOYS.md) and [Utilities](UTILITIES.md); [toy parity](TOY-PARITY.md)
  measures each native surface against the app it stands in for, and
  [archive lifetime](ARCHIVE-LIFECYCLE.md) says how Data Hoarder opens,
  closes and reads its archive
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
- [Screen Bar profiling](SCREEN-BAR-PROFILING.md)
- [Packaging and signing](../packaging/README.md), and
  [running the app from a checkout](../app/README.md)

## Working on JR-Bar

- [CONTRIBUTING](../CONTRIBUTING.md) and [AGENTS](../AGENTS.md) (for coding
  agents)
- [Local verification](LOCAL-VERIFICATION.md) and
  [final testing](FINAL-TESTING.md)
- [Releasing](PRODUCTION-RELEASE.md); `make release-check` runs the release
  preconditions without publishing
- [Repository hygiene](REPOSITORY-HYGIENE.md)
- [Prior art and attribution](PRIOR-ART.md)
- [Upstream research cadence](UPSTREAM-RESEARCH-CADENCE.md);
  `scripts/check_upstreams.py` shows what each upstream has changed since
  the last review. [Upstream sync](UPSTREAM-SYNC.md) and the
  [2026-08-30 refresh](UPSTREAM-REFRESH-2026-08-30.md) record how past
  reviews went.
- [Feature matrix](FEATURE-MATRIX.md) and [roadmap](ROADMAP.md)

## History

Plans, audits, research notes and the pre-0.8 specs, kept for provenance.
Nothing in the build reads them. They all live in [archive/](archive/): the
dated plans and audits once they are done, the repair handoff, the 0.8 plan,
the vision, the build spec, the feature disposition ledger, the upgrade
ledger and the research notes.
