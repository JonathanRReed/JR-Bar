# Working in JR-Bar

Notes for a coding agent (Claude Code, Codex, anything else) working in
this repository. The human version is [CONTRIBUTING.md](CONTRIBUTING.md);
this file adds the rules that are easy to break from inside a session.

## What it is

Three processes, one direction of truth
([docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)):

- `app/`: `JR-Bar.app`, Swift and SwiftUI. It owns every pixel.
- `src/jrbar/`: `jrbar-core`, the Python daemon, headless. It owns every
  fact.
- `hook/`: `jrbar-hook`, the C shim every provider config runs.

App and daemon talk newline-delimited JSON over
`~/.local/state/jrbar/core.sock`. The contract is
[docs/CORE-PROTOCOL.md](docs/CORE-PROTOCOL.md): a new fact or command
goes there first, and the app never reads the daemon's files behind its
back.

## Build and test

```sh
./scripts/bootstrap-dev.sh                    # .venv with the pinned tools
make fast                                     # lint, imports, contracts, doc links, focused tests
.venv/bin/python -m pytest tests -q           # the full Python suite
.venv/bin/python -m pytest tests/test_x.py -q # one file while working
cd app && swift build --build-tests           # the Swift package and its tests
cd app && swift test --filter SomeSuite       # one suite while working
cd app && swift test                          # everything, once, before you finish
```

In a git worktree without its own `.venv`, use the main checkout's
interpreter and point it at the worktree's sources:
`PYTHONPATH=$PWD/src /path/to/JR-Bar/.venv/bin/python -m pytest …`.

Render proofs for visible work: run the suite with `JRBAR_RENDER_PROOF=1`
and `JRBAR_RENDER_PROOF_DIR=<a scratch folder>`. Then open every PNG you
added and look at it before you call the work done.

## Never

- **Never run a mock daemon on the real `core.sock`.**
  `app/scripts/mock-core.py` listens on `$TMPDIR/jrbar-mock.sock` by
  default. Keep it there, because the installed app is probably running.
- Never write to the LED devices (`/Volumes/SidePulse`, `/Volumes/PulseDot`)
  from a test or a script. Reading `STATUS.TXT` is fine.
- Never post synthetic input or move the pointer.
- Never write the `com.apple.dock` or `com.apple.MenuBar` preferences.
- Never run an install against the real `~/.claude`, `~/.codex` or another
  agent's config from a test. Tests take a temporary home.
- Never push, tag, publish a release or edit the GitHub repository unless
  Jonathan asks. `scripts/release.sh --dry-run` (`make release-check`) is
  safe; the real run publishes.

## Standing decisions

- One status item. The menu bar item is the icon, and nothing adds a
  second one.
- Nothing answers an agent on its own. An ask is answered only by a
  person: a click, a key, a Stream Deck press. No link, hook or rule
  answers one.
- Nothing leaves the Mac without opt-in. A new outbound request is off
  until the person turns it on, and a test proves it stays off.
- Numbers and words, never meters made of block characters or segments.
- Honest states. A provider with no quota source says so, and a lane is
  never invented. The last good reading is kept and marked stale.
- Tests use synthetic data: no real prompts, tokens, account ids, private
  project names or personal paths.

## Tests and timing

`tests/test_deterministic_timing_contract.py` forbids wall-clock sleeps
and unbounded `join()` in tests. Wait on an event or a condition with a
timeout, and pass clocks in as arguments.

Swift Testing suites must not depend on the main run loop's `Timer`s.
Crank time by hand.

## CI's Swift is older

CI builds with Swift 6.3.3, which is older than the local toolchain. It
rejects some code the newer compiler accepts, so avoid:

- long inline SwiftUI or arithmetic expressions (the type checker gives
  up; split them into `let`s);
- a closure that captures a property which a later `let` in the same scope
  shadows (write `self.x`);
- a bare `Task { … }` as a generic closure's only expression (write
  `_ = Task { … }`);
- a test local named like a helper inside `#require` or `#expect`.

## Docs

- User pages live in [docs/user/](docs/user/), indexed from
  [docs/README.md](docs/README.md). Reference docs sit in `docs/`, and
  dated plans and audits move to `docs/archive/` once they are done.
- Write plain sentences about what the thing does for the person. Doc
  comments in the code use the same voice.
- Every relative link must resolve. `scripts/check_doc_links.py` runs in
  `make fast`.
- Credit what you studied in [docs/PRIOR-ART.md](docs/PRIOR-ART.md), with
  the commit and the licence. Reimplement; do not copy code.
- When several branches are built in parallel, only the person merging
  them edits `CHANGELOG.md` and the What's New catalog. Each branch reports
  its bullets instead.

## Commits

`area: what changed in plain words`. For example: `usage: a broken source
names its fix`. Keep commits small and focused, and leave the working tree
clean.
