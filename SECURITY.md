# JR-Bar security policy

## What ships, and what is supported

JR-Bar ships as one signed `JR-Bar.app` carrying three programs and the
updater framework:

| Path | What it is |
| --- | --- |
| `Contents/MacOS/JR-Bar` | the Swift menu-bar app; takes no arguments |
| `Contents/Helpers/jrbar-core.app` | the Python daemon, frozen with PyInstaller |
| `Contents/Helpers/jrbar-hook` | the compiled shim your agent's hooks execute, through a small launcher script at `~/.local/share/jrbar/hook/jrbar-hook` that exits 0 when the app is gone |
| `Contents/Frameworks/Sparkle.framework` | the pinned in-app updater |

All of these are sealed by the outer signature, except the launcher script: it
lives in your home directory, is owned by you and rewritten at each hook refresh,
and holds one line naming the bundled shim, so it adds nothing a process running as you could not already do
to your agent's own config. A bundle in which the
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

**As of 2026-10-01 no release meets that bar.** Versions 0.9.15 and 0.9.16
were published by hand at the owner's direction. Their apps, installers and
update archives passed signing, notarization and Gatekeeper checks, but the
controlled performance and system-uninstall receipts were not completed (and
0.9.15's strict older-version upgrade receipt was not either), so neither is
production-supported under this policy. The
[0.9.16 release notes](https://github.com/JonathanRReed/JR-Bar/releases/tag/v0.9.16)
list which receipts ran and which did not, and the fail-closed scripts were
not loosened for either release.

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
   action, and a provider's usage read, the one that reads another app's
   sign-in, runs only after you turned that provider on. Secrets never enter logs, diagnostics, notifications, webhooks,
   history, or exception strings.
2. **No unauthorised remote control.** Remote-peer support is read-only. It must
   not execute remote commands or grant navigation, mutation or capacity
   authority.
3. **Loopback is not trusted.** Local HTTP ingest is disabled by default,
   bearer-authenticated, loopback-only, rate-limited, concurrency-limited and
   schema-bounded. `jrbar serve` binds `127.0.0.1` only, answers no request
   whose `Host` is not a loopback name on its own port (so a rebound DNS name
   gets nothing), sends no CORS headers, and requires the bearer on every
   route. Its two answering routes also need `serve_answer_enabled`, which is
   off by default.
4. **The local sockets are owner-only.** `core.sock`, `events.sock` and
   `hook-ingress.sock` under the user's state directory are `srw-------`, and
   the daemon refuses to run when another JR-Bar already owns them. Everything
   arriving on them is data: hook payloads and provider text never become
   commands, arguments or executable code. The daemon appends a hook line only
   to a log directly in its own state directory, whatever path a connection
   names. A peer is admitted by its uid, but `core.sock` takes a privileged
   command (answering an ask, switching on a consent, installing a hook, a
   token) only from the JR-Bar app itself, which proves a per-launch secret
   (see Known limits).
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
   provider, project and user labels are removed. The phone alert is off until
   a topic is entered and it is turned on, and sends only a fixed line (see
   below).
10. **Build identity is stable and sealed.** Production artifacts use reviewed
    exact dependencies from a hash-bound lock, exact entitlements (two:
    `com.apple.security.automation.apple-events`, and
    `com.apple.security.personal-information.location` so the Wi-Fi name can
    be read; nothing reads coordinates), Developer ID signing with the
    hardened runtime, notarization, stapling, Gatekeeper checks, an SBOM,
    checksums and a release evidence manifest. Every Mach-O in the bundle links
    only Apple system libraries or code inside the bundle, and the Python
    runtime is the one inside `Helpers/jrbar-core.app`.
11. **The update path cannot be redirected.** The feed URL and the Ed25519
    public key are baked into the bundle and covered by its signature. Losing
    or rotating the Sparkle private key is a release-blocking event, not a
    configuration change.
12. **An import is a layout, not a grant.** A settings file never switches on
    a request that leaves the Mac, a program that runs, an answering route or
    a permission prompt. That includes Menu Bar script rules (a rule that runs
    a shell command is left off the page unless this Mac already has it), the
    proxy hub, extra agent homes, usage hooks and the webhook.
13. **Upgrades do not destroy state.** Settings migrations are versioned,
    idempotent, backup-preserving, and read-only when a newer schema is
    encountered.

## What leaves the Mac

Nothing leaves the Mac until you turn the feature on. Each row below is off
on a fresh install, and a test proves it stays off (`tests/test_usage_consent.py`,
`tests/test_outbound_default_off.py`, `OutboundDefaultOffTests`). The only
things that read another app's sign-in are the provider usage reads, and they
read it only for a provider you turned on.

| Feature | Who is asked | When | Where you turn it on |
| --- | --- | --- | --- |
| Claude usage | `api.anthropic.com`, with the sign-in Claude Code keeps in your Keychain | each usage refresh, while it is on | Settings > Agents & Usage > Provider usage; Setup; `jrbar providers usage claude on` |
| Codex usage | `chatgpt.com`, by running `codex app-server` with Codex's own sign-in | each usage refresh, while it is on | the same switch for Codex |
| Cursor usage | `cursor.com`, with the token in Cursor's own database or a browser session you imported | each usage refresh, while it is on | the same switch for Cursor |
| Devin usage | `app.devin.ai`, with a token you gave JR-Bar or a browser session you approved | each usage refresh, while it is on | the same switch for Devin |
| Grok usage | `cli-chat-proxy.grok.com`, with the sign-in in `~/.grok/auth.json` | each usage refresh, while it is on | the same switch for Grok |
| Gemini usage | `cloudcode-pa.googleapis.com` and `oauth2.googleapis.com`, with the sign-in in `~/.gemini/oauth_creds.json` | each usage refresh, while it is on | the same switch for Gemini |
| OpenCode Go usage | `opencode.ai`, with your OpenCode Go key | each usage refresh, while it is on | the same switch for OpenCode |
| OpenAI API spend | `api.openai.com`, with the Admin key you gave JR-Bar | each usage refresh, while it is on | the same switch for OpenAI API |
| Antigravity usage | nothing leaves the Mac; the running Antigravity app answers on `127.0.0.1` | each usage refresh, while it is on | the same switch for Antigravity |
| Claude plan limits (monitor) | `api.anthropic.com`, with Claude's sign-in | while on | Settings > Agents & Usage > Claude |
| Provider status pages | `status.anthropic.com`, `status.openai.com`, `status.cursor.com`, no key or account | every 10 minutes, only for a provider found here | Settings > Agents & Usage > Advanced > Incidents |
| Agent update checks | `registry.npmjs.org`, no key or account | every 6 hours | Settings > Agents & Usage > Advanced > Updates |
| App update checks | the signed Sparkle feed on GitHub | on your schedule | Settings > General |
| Lyrics | `lrclib.net`: title, artist, album and length of the playing track | per new track | the notch card's Lyrics switch, then its agreement |
| Webhook | the HTTPS address you type | per event you chose | Settings > Alerts & Sounds > Advanced > Webhook |
| Remote peers and usage sync | your own other Mac, over `sftp` | while on | Settings > Remote > Peers |
| Cloud ingest | nothing leaves; it listens on `127.0.0.1` only | while on | Settings > Remote > Cloud ingest |
| CLIProxyAPI hub | nothing leaves; it asks `127.0.0.1:8317` | while on | the `cliproxy_hub` setting ([cliproxy-hub.md](docs/user/cliproxy-hub.md)) |

Usage consent is a record per provider in `~/.config/jrbar/provider-usage.json`
(`usage_consent_version`, where it came from, when). Turning a provider off
removes the record, and the card goes back to "Usage off. Turn on to show
quota." with no number. Without consent JR-Bar still counts tokens in files on
this Mac and shows Claude Code's own status line if you installed it; neither
sends anything.

An upgrade from a build that asked every provider by default keeps a provider
on only when it was enabled and had already returned a reading. Each one is
logged ("usage consent: kept ...") and marked `migration`. Everything else
starts off.

## Known limits

These are boundaries JR-Bar does not defend, stated so nobody assumes they do.

- **`core.sock` trusts the app, not the user.** The kernel can tell the daemon
  a peer's uid and nothing more, and a process running as you includes an
  agent's shell tool and anything an agent installs. So the daemon accepts a
  privileged command only on a connection that has proved a secret the app
  made for that launch: 32 random bytes, handed to the daemon over its stdin
  pipe (never its environment or arguments, so `ps` and the hooks and provider
  CLIs it starts never see them), kept in memory on both sides, new at every
  daemon start, and never sent over the socket (the proof is an HMAC-SHA256
  over a nonce the daemon offers in `hello`, compared in constant time; a bad
  proof is delayed, logged without content, and ends the connection). The app
  also sends its proof only to the process it started. A daemon the app did
  not start holds no secret and takes no privileged command (a source checkout
  can opt out with `JRBAR_DEV_ALLOW_UNAUTH=1`; the frozen release ignores it).
  `docs/CORE-PROTOCOL.md`, "Who may send what", lists which commands are which,
  and a command nobody classified is privileged.
- **Protected settings are sealed against a hand edit of `settings.json`.** The
  daemon takes an outside edit of that file, so the settings that grant a
  capability (`serve_enabled`, `serve_answer_enabled`, the webhook address and
  events, cloud ingest, remote peers, usage hooks, the proxy hub, extra agent
  homes, provider status feeds and update checks, the Claude plan limits, the
  closed-lid policy, global shortcuts; the list is `SEALED_KEYS` in
  `src/jrbar/settings_seal.py`) carry an HMAC-SHA256 seal in the file. Its key is
  32 random bytes in a macOS Keychain item the app creates with an access list
  that trusts the app's code signature alone, so another process running as you
  gets a prompt or a refusal, not the key. The app hands the key to the daemon
  it starts over the same stdin pipe as the secret. The daemon writes the seal
  on a save, from the settings it holds in memory (which only an authenticated
  command changes), and checks it on every load: at startup, when it takes an
  outside edit, and once a second by the file's size and time. A protected
  value the seal does not vouch for is ignored: the daemon keeps what it held
  (the last sealed values at a restart, the defaults if there are none), logs
  `settings.json changed a protected setting outside JR-Bar; ignored` once with
  no values, writes the held values back over the file, keeps what it found as
  `settings.json.rejected`, and Settings shows a banner with **Keep the
  change**. Every other setting follows an outside edit as it always did. The
  answering route `/answer` reads its switch from the daemon's memory, so a
  stolen serve token with the switch off still answers nothing.
- **What a process running as you can still do.** Read everything the daemon
  publishes (sessions, asks and their previews, usage, settings), read the serve
  token (Stream Deck setup needs it), and send the unprivileged commands:
  display preferences (brightness, scene, colours, dimming), start or end a quiet
  period, snooze, hold keep-awake, ask for a usage refresh, fire confetti, and
  edit any setting that is not on the sealed list. It **cannot** answer or deny
  an ask, type into an agent, turn on `serve`, answering, webhooks, cloud
  ingest, remote peers or a usage hook, change a consent or a path the daemon
  reads, or install or remove hooks, over the socket or by editing
  `settings.json`. It can still make the daemon's four client slots busy, which
  only delays the app's reconnect, and it can delete or corrupt `settings.json`
  (the daemon then keeps what it holds, or at a restart starts the protected
  settings off, never on).
- **What the seal does not cover.** (1) With no key the daemon behaves as it
  did before sealing: the Keychain was locked or declined, an ad-hoc
  development build the Keychain item does not trust, or a daemon the app did
  not start. Settings says "Protected settings are not sealed (Keychain
  unavailable)". (2) The consent files beside it are sealed the same way, with
  the same key, but only against an edit that grants more: `provider-usage.json`
  (each provider's usage consent), `browser-consent.json` (the browser profiles,
  sites and fields JR-Bar may read) and `integrations.json` (the integrations
  switches and the folder and device they read). The daemon keeps an HMAC of the
  consent in each file in the sealed setting `companion_seals`, checks it at
  every read, and seals what it writes itself. A file whose consent grants more
  than was sealed is not used: it is put back from a sealed copy, kept as
  `<file>.rejected`, and Settings shows the same banner with **Keep the
  change**. A change that only takes consent away is accepted. The first start
  after an upgrade adopts the files as they are, so a file forged before that
  start is adopted too. The `jrbar` command line has no key, so while the daemon
  is sealed a consent it grants in those files is ignored until you keep it in
  Settings. The other small files under `~/.config/jrbar` (display and look
  preferences) are not sealed. (3) A replay: a program that
  kept an old, valid copy of your `settings.json` and `settings.json.sealed` can
  put them back and the seal will accept them; keeping that out needs a counter
  outside the files. (4) A program that can debug the daemon or the app, load
  code into them, or change the app bundle is a different boundary (root, or a
  signed-code change). (5) The serve token is a readable file; it is a bearer
  for status, and answering is separate. (6) The Keychain item uses the
  file-based Keychain, whose access-list calls Apple has deprecated but not
  removed; the newer Keychain needs a provisioning profile that JR-Bar does
  not ship.
- **The closed-lid helper is one root-owned rule, and the install runs no file
  from the app.** The helper is a sudoers drop-in
  (`/etc/sudoers.d/jrbar-disablesleep`) that lets your account run exactly
  `/usr/bin/pmset -a disablesleep 0` and `... 1` without a password. Both
  commands are the system's own root-owned binary, so nothing in the app bundle
  is ever a sudo target. The command Setup copies is a fixed `sudo /bin/sh -c`
  script, not `sudo <path inside JR-Bar.app>`, because a process running as you
  can replace a file in a bundle you own (a copy in `~/Applications`) before you
  paste. The script takes the user from `$SUDO_USER`, checks the rule with
  `visudo -cf` under a dotted name sudo ignores, and moves it into place at mode
  0440. What remains: (1) the Terminal command you paste is only as trustworthy
  as the clipboard and the window you paste it in; read it before you press
  Return. (2) `jrbar status-bar install-sleep-helper`, the CLI form, still runs
  whatever `jrbar` you point `sudo` at; use the copied command, or a copy of
  `jrbar` that is root-owned. (3) Anyone who can already run `sudo` as you can
  hold the display awake with a closed lid, which is the point of the helper;
  the closed-lid fail-safe still releases it when the renewal heartbeat goes
  stale.
- **Development environment overrides are honored in the release app.**
  `JRBAR_CORE_EXEC`, `JRBAR_CORE_SOCKET` and `JRBAR_STATE_DIR` redirect what
  the app and the shim talk to. They need
  control of the launch environment, which is the same-user boundary again.
  `JRBAR_CORE_EXEC` hands its child the app secret like the bundled daemon, so
  a daemon the app launched that way is authenticated too.
- **`jrbar://` links can start a quiet period** (`quiet`, `deepwork`) without
  a confirmation. They cannot answer an ask.

## The phone alert: what leaves the Mac, and when

The phone alert (Settings › Alerts & Sounds › Phone alert, `ntfy_alert.py`) is the one
feature that sends a message about your agents to a service outside this Mac,
so what it sends is fixed and short.

- **It is off until you act.** `ntfy_enabled` is false by default. Nothing is
  sent until you have entered a topic **and** turned it on. A topic alone sends
  nothing, and so does the switch without a topic. A setting that is not
  exactly `true` loads as off. The Test button is the one exception, and only
  because you pressed it: it sends one fixed test line and never turns the
  feature on.
- **What is sent.** One plain-text HTTPS POST: the body is `<Agent> needs you`
  or `<Agent> finished`, where the agent is the provider's name from JR-Bar's
  own table (`Claude`, `Codex`, or `An agent` when it has none). The title is
  `JR-Bar` and the User-Agent is `JR-Bar/<version>`. That is all. No prompt
  text, no file path, no project or session name, no token and no account id
  is ever passed to the sender, so none can leave. The destination is
  `https://ntfy.sh/<your topic>`, or the https address of your own ntfy server.
- **When.** When an agent starts waiting on you, or a run finishes. By default
  only while you are away: the screen is locked, or the Mac has been idle for
  five minutes (read from the session; JR-Bar posts no input to find out). If
  JR-Bar cannot tell, it sends nothing. It also respects the quiet policy that
  governs webhooks. The same line from the same agent goes out at most once
  per 20 seconds, and never more than 30 an hour.
- **How.** HTTPS only, port 443 or 8443, no credentials in the address, no
  query string, no redirects followed, an 8 second timeout, no retries, and no
  local or private address literal. The reply is not read for anything.
- **It never answers anything.** It notifies. Nothing on the phone can approve,
  deny or reply to an ask; an ask is answered only by a person, at JR-Bar.
- **Treat the topic as a password.** Anyone who knows a topic on ntfy.sh can
  read what is posted to it. Pick a long, unguessable name, or run your own
  server. The topic is stored in `settings.json` and in a settings export.
  Neither the daemon's log nor the diagnostics report contains it.
- **Tests.** The transport is injectable. The tests prove the default is off,
  that no request is made without both a topic and the switch, that the away
  condition holds, and that the line carries nothing but the fixed words.

## In scope

- provider hook installation, preservation and removal, and the compiled shim
  they execute;
- the local Unix sockets and loopback ingest;
- credential and token handling;
- settings, logs, history, export and private-state storage;
- navigation and terminal-opening policy;
- Tailscale/SFTP peer transport;
- webhook delivery and the phone alert;
- hardware, keymap and power-up animation writes;
- process supervision between the Swift app and the frozen daemon, and UI
  threading, where they create security or privacy impact;
- installer, LaunchAgent, login item, signing, notarization, Sparkle update and
  uninstall behaviour;
- dependency, workflow and release-chain compromise. GitHub Actions runs source
  checks (and a manual build of the Python wheel and sdist) on hosted runners,
  with `contents: read` and no signing material;
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
