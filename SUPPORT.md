# JR-Bar support

JR-Bar is a native macOS menu-bar app with a bundled daemon that reads
local agent state and drives the SidePulse Pro, the SidePulse Dot, the
Creator Micro 2 and the on-screen Screen Bar. It is a personal project
made public: support is best effort, through the issue tracker, with no
response-time or compatibility guarantee.

## What is supported

The current release is `JR-Bar-<version>.pkg` from
[GitHub releases](https://github.com/JonathanRReed/JR-Bar/releases), or
the same package built from `main` with `make package`. It needs an Apple
silicon Mac on macOS 26 or newer. Until a notarized release is published,
a package built on one Mac will be refused by Gatekeeper on another; build
it locally.

Providers are listed in the [README](README.md#providers). A provider
being listed means JR-Bar knows its hook shape and, where it exists, its
usage source; it does not mean the service, plan, credentials or endpoint
are available on your machine, and the panel says `~` or "Sign in via the
CLI" rather than inventing a number. T3 Code is a read-only integration
with a reviewed version window in [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

Out of scope: provider outages and policy changes, macOS defects,
third-party apps, Tailscale or SSH setup, modified bundles, disabled macOS
protections, and unsupported hardware.

## Before filing

```sh
alias jrbar='~/Applications/JR-Bar.app/Contents/Helpers/jrbar-core.app/Contents/MacOS/jrbar-core'
jrbar doctor          # the daemon's commit, memory, sockets, hooks, devices, checks
jrbar hooks doctor    # what each provider's config runs today; every line should say runs=shim
```

Settings › Advanced has the same Doctor as a checklist plus the daemon's
log tail. If a session looks wrong, the panel's "Why this light" row and
its popover say which session and which rules produced the light.

## Filing an issue

Use the [issue tracker](https://github.com/JonathanRReed/JR-Bar/issues)
with the template that fits. Include the JR-Bar version (Settings ›
General), how it was installed, the macOS version, the provider or
hardware involved, what you did and what you saw. Attach only sanitised
output: no passwords, tokens, cookies, prompts, transcripts, account
identifiers or personal paths.

For a suspected vulnerability or privacy leak, do not open a public issue;
follow [SECURITY.md](SECURITY.md) (`Contact@JonathanRReed.com`).
