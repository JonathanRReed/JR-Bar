# JR-Bar security policy

## What ships, and what is supported

JR-Bar 0.8 is one signed `JR-Bar.app` carrying three programs:

| Path | What it is |
| --- | --- |
| `Contents/MacOS/JR-Bar` | the Swift menu-bar app; takes no arguments |
| `Contents/Helpers/jrbar-core.app` | the Python daemon, frozen with PyInstaller |
| `Contents/Helpers/jrbar-hook` | the compiled shim your agent's hooks execute |
| `Contents/Frameworks/Sparkle.framework` | the pinned in-app updater |

All three are nested code sealed by the outer signature. A bundle in which the
daemon or the shim is missing, unsigned, or signed by a different team is not a
JR-Bar release, whatever the outer signature says.

Only the newest signed and notarized JR-Bar GitHub Release is supported. Source
checkouts, editable installs, unsigned packages, ad-hoc-signed development
bundles and commits on `main` are development artifacts unless the release page
carries all of:

- a Developer ID signed and notarized, stapled `JR-Bar-<version>.pkg`;
- `JR-Bar-<version>.zip`, the Sparkle archive of the same bundle;
- `SHA256SUMS`;
- `jrbar-sbom.cdx.json`;
- `release-environment.txt`;
- `release-verification.json`, showing the exact commit, signing team,
  installed-upgrade result, hardware matrix and performance evidence.

A version is not production-supported until `scripts/verify_macos_release.sh`
has passed *with nothing skipped* on the reviewed release Mac. That gate is
fail-closed by construction: it writes `release-verification.json` only when
every receipt kind is present, passed and bound to the same candidate, and
`scripts/publish_release.sh` will not publish without it.

**As of 2026-09-10 no release meets that bar.** The release Mac has a Developer
ID Application identity and the Sparkle signing key, but no Developer ID
Installer certificate and no notarization profile, so the PKG is unsigned and
nothing is notarized. Treat every current artifact as a development build.

Updates arrive through Sparkle from a feed pinned in the app
(`SUFeedURL`, an asset of the durable `updates` release) with `SUPublicEDKey`,
`SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` set. An unsigned or
tampered feed is rejected before anything is extracted. Automatic checks are off
until you turn them on in Settings › General.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability or privacy leak. Send a
private report to [Contact@JonathanRReed.com](mailto:Contact@JonathanRReed.com)
with:

- the affected JR-Bar version or commit, and whether it came from a GitHub
  Release, a Sparkle update, or a local `make package` build;
- the macOS and hardware versions;
- a concise reproduction;
- expected and observed behaviour;
- whether credentials, prompts, session labels, paths, hooks, device files, the
  local sockets or local history may have been exposed.

Do not include real access tokens, refresh tokens, private prompts, full
transcripts, or unrelated personal data. Redact secrets and use synthetic
fixtures.

Reports are acknowledged as soon as they can be reviewed. A fix is published
only after validation against the relevant security boundary and a complete
release gate run.

## Security properties that must hold

JR-Bar is a local ambient-attention utility. These are release requirements.

1. **No unapproved secret access.** Keychain reads require an explicit user
   action. Secrets never enter logs, diagnostics, notifications, webhooks,
   history, or exception strings.
2. **No unauthorised remote control.** Remote-peer support is read-only. It must
   not execute remote commands or grant navigation, mutation or capacity
   authority.
3. **Loopback is not trusted.** Local HTTP ingest is disabled by default,
   bearer-authenticated, loopback-only, rate-limited, concurrency-limited and
   schema-bounded.
4. **The local sockets are owner-only.** `core.sock`, `events.sock` and
   `hook-ingress.sock` under the user's state directory are `srw-------`, and
   the daemon refuses to run when another JR-Bar already owns them. Everything
   arriving on them is data: hook payloads and provider text never become
   commands, arguments or executable code.
5. **No arbitrary command execution.** Navigation targets are provider-specific,
   canonical, freshness-checked, generation-fenced and allowlisted before
   execution. A macOS Shortcut runs by exact name through `/usr/bin/shortcuts`
   with fixed argv and no shell expansion.
6. **Private state stays private.** Sensitive files use owner-only directories
   and files, no-follow descriptors, identity checks, atomic publication,
   bounded reads and rollback-aware transactions.
7. **Physical writes are exact.** Device paths reject symlinks, hardlinks, mount
   swaps, torn writes and readback mismatches. Final LED bytes must pass the
   packaged firmware parser before publication. Keymap writes back up and verify
   the original first and record recovery progress before each destructive step.
8. **Visible light is safety-compiled.** Every hardware, Screen Bar, preview,
   setup, test and Studio presentation passes the universal cadence and
   saturated-red safety compiler.
9. **Network outputs are minimal.** Webhooks require HTTPS, public destinations,
   bounded payloads, no redirects and product-owned reason codes. Session,
   provider, project and user labels are removed.
10. **Build identity is stable and sealed.** Production artifacts use reviewed
    exact dependencies from a hash-bound lock, exact entitlements (one:
    `com.apple.security.automation.apple-events`), Developer ID signing with the
    hardened runtime, notarization, stapling, Gatekeeper checks, an SBOM,
    checksums and a release evidence manifest. Every Mach-O in the bundle links
    only Apple system libraries or code inside the bundle, and the Python
    runtime is the one inside `Helpers/jrbar-core.app`.
11. **The update path cannot be redirected.** The feed URL and the Ed25519
    public key are baked into the bundle and covered by its signature. Losing
    or rotating the Sparkle private key is a release-blocking event, not a
    configuration change.
12. **Upgrades do not destroy state.** Settings migrations are versioned,
    idempotent, backup-preserving, and read-only when a newer schema is
    encountered.

## In scope

- provider hook installation, preservation and removal, and the compiled shim
  they execute;
- the local Unix sockets and loopback ingest;
- credential and token handling;
- settings, logs, history, export and private-state storage;
- navigation and terminal-opening policy;
- Tailscale/SFTP peer transport;
- webhook delivery;
- hardware, keymap and power-up animation writes;
- process supervision between the Swift app and the frozen daemon, and UI
  threading, where they create security or privacy impact;
- installer, LaunchAgent, login item, signing, notarization, Sparkle update and
  uninstall behaviour;
- dependency, workflow and release-chain compromise. GitHub Actions runs source
  checks only, on hosted runners, with `contents: read` and no signing material;
  the self-hosted release workflow was retired on 2026-09-10 rather than put the
  Developer ID key on a machine that executes workflow code.

## Out of scope

- vulnerabilities in upstream AI providers, macOS, Tailscale, terminal
  applications, or SidePulse and Creator Micro firmware, that JR-Bar neither
  introduces nor can mitigate;
- denial of service requiring the user to deliberately replace reviewed binaries
  or disable macOS protections;
- reports based only on an unsigned or ad-hoc development bundle behaving
  differently from the signed release identity — an ad-hoc bundle is a different
  app to macOS and loses the user's TCC grants by design;
- social-engineering claims without a product vulnerability.

## Disclosure and remediation

Security fixes are developed on a private or restricted branch when public
details would increase risk. Releases include a concise advisory, affected
versions, impact, remediation and verification evidence. Secrets found in
history are revoked and removed from the repository history; deleting the
current file is not sufficient.
