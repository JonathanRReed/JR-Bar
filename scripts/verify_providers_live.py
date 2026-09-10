#!/usr/bin/env python3
"""Drive the real agent CLIs against a scripted LLM and check what the daemon saw.

Runs on the Mac that has JR-Bar.app installed and its daemon up. For each
provider it builds a scratch home (the real configs are never touched),
points the CLI at ``scripts/mock_llm_server.py`` (no quota, deterministic
answer: one shell tool call, then "done"), runs one non-interactive turn,
and asserts the hook records the daemon wrote to ``~/.local/state/jrbar/
<provider>.jsonl`` for that session, in order:

    session_start, user_prompt_submit, pre_tool_use, post_tool_use, stop, session_end

Then it asks the daemon over ``core.sock`` for the session's row, which must
read ``lifecycle: "completed"`` -- a finished one-shot run has also exited,
and exiting must not cost it the green check. For Codex it also runs the
Interrupt drill (SIGINT mid-tool: interrupt then session_end) and the Kill
drill (SIGKILL mid-tool, no end event at all: that row must read ``ended``),
and checks ``usage_history codex 7d`` has
records when ``~/.codex/sessions`` has rollouts. ``--asks`` adds the
approval drill: an interactive Codex under ``-a on-request`` in a pty, the
mock asking to leave the sandbox, ``state.asks`` naming it, and
``answer_ask`` answered with ``not_frontmost`` (a pty is never in front),
``unsupported`` or an approval.

Providers whose CLI is not installed are skipped; Gemini is skipped with the
reason when the CLI refuses a local endpoint. Exit 0 when nothing failed.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import pty
import re
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
STATE_DIR = Path(os.environ.get("JRBAR_STATE_DIR") or Path.home() / ".local" / "state" / "jrbar")
CORE_SOCK = STATE_DIR / "core.sock"
INSTALLED_SHIM = Path.home() / "Applications" / "JR-Bar.app" / "Contents" / "Helpers" / "jrbar-hook"
FULL_TURN = ("session_start", "user_prompt_submit", "pre_tool_use", "post_tool_use", "stop", "session_end")
INTERRUPTED_TURN = ("session_start", "user_prompt_submit", "pre_tool_use", "interrupt", "session_end")
#: The two lifecycle words that mean the run is over.
FINISHED_LIFECYCLES = frozenset({"completed", "ended"})
#: The one word that means the provider said so: the green check.
DONE_LIFECYCLES = frozenset({"completed"})
#: Over without a provider's end event: the liveness sweep's synthetic one.
UNCONFIRMED_LIFECYCLES = frozenset({"ended"})
PI_PROVIDER = "mock"
PI_MODEL = "mock-model"
#: The key the scratch agents present to the mock; its value never matters.
MOCK_API_KEY = "sk-ant-mock-key-for-jrbar-drills"


def drain(fd: int) -> bytes:
    """Read whatever the pty has, so the agent never blocks on a full buffer.

    A TUI keeps drawing while it waits for an answer; stop reading and it
    stops being able to write, which looks from the outside like the turn
    ending on its own.
    """
    out = bytearray()
    while True:
        ready, _, _ = select.select([fd], [], [], 0)
        if not ready:
            return bytes(out)
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            return bytes(out)
        if not chunk:
            return bytes(out)
        out += chunk


class Check:
    def __init__(self) -> None:
        self.rows: list[tuple[str, str, str]] = []
        self.failed = 0

    def ok(self, name: str, detail: str = "") -> None:
        self.rows.append(("ok", name, detail))
        print(f"  ok    {name}  {detail}")

    def fail(self, name: str, detail: str = "") -> None:
        self.failed += 1
        self.rows.append(("FAIL", name, detail))
        print(f"  FAIL  {name}  {detail}")

    def skip(self, name: str, detail: str = "") -> None:
        self.rows.append(("skip", name, detail))
        print(f"  skip  {name}  {detail}")


# -- daemon socket ------------------------------------------------------------
def core_command(name: str, args: dict | None = None, *, timeout: float = 120.0) -> tuple[dict, dict | None]:
    """One command over core.sock; returns (reply, state-on-connect)."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(str(CORE_SOCK))
    handle = sock.makefile("rwb")
    handle.write((json.dumps({"t": "command", "v": 1, "id": "verify", "name": name, "args": args or {}}) + "\n").encode())
    handle.flush()
    state = None
    try:
        while True:
            line = handle.readline()
            if not line:
                raise RuntimeError("daemon closed the socket")
            frame = json.loads(line)
            if frame.get("t") == "state":
                state = frame
            if frame.get("t") == "reply" and frame.get("id") == "verify":
                return frame, state
    finally:
        sock.close()


def core_state() -> dict:
    return core_command("ping")[1] or {}


def session_row(
    provider: str,
    session_id: str,
    *,
    wait: float = 20.0,
    lifecycles: frozenset[str] | None = FINISHED_LIFECYCLES,
) -> dict | None:
    """The daemon's row for one session; waits for it to read as over.

    The projection catches up a beat behind the last hook record, so a row
    fetched the instant the CLI exits can still say `active`. Waiting for
    one of ``lifecycles`` (and falling back to whatever the last row was) is
    what makes this drill about the daemon's reading rather than its clock.
    ``lifecycles=None`` takes the first row it sees.
    """
    deadline = time.time() + wait
    last: dict | None = None
    while True:
        for row in core_state().get("sessions", []):
            if row.get("provider") == provider and session_id in str(row.get("id")):
                last = row
                if lifecycles is None or row.get("lifecycle") in lifecycles:
                    return row
        if time.time() > deadline:
            return last
        time.sleep(1.0)


# -- hook log -------------------------------------------------------------------
def log_path(provider: str) -> Path:
    return STATE_DIR / f"{provider}.jsonl"


def log_length(provider: str) -> int:
    try:
        with log_path(provider).open("rb") as handle:
            return sum(1 for _ in handle)
    except FileNotFoundError:
        return 0


def new_records(provider: str, since: int) -> list[dict]:
    """Records appended after ``since``, in the order they happened.

    Every hook is its own short-lived process appending to one file, so two
    that fire a millisecond apart can land in either order; the daemon reads
    `occurred_at_epoch`, and so does this.
    """
    out: list[tuple[float, int, dict]] = []
    try:
        with log_path(provider).open("r", encoding="utf-8") as handle:
            for index, line in enumerate(handle):
                if index < since:
                    continue
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                at = record.get("occurred_at_epoch")
                out.append((float(at) if isinstance(at, (int, float)) else 0.0, index, record))
    except FileNotFoundError:
        pass
    return [record for _, _, record in sorted(out, key=lambda row: (row[0], row[1]))]


def wait_for_events(provider: str, since: int, session: str | None, wanted: tuple[str, ...], *, timeout: float) -> tuple[list[str], str | None]:
    """Poll the log until every wanted event landed for the session (or time is up)."""
    deadline = time.time() + timeout
    while True:
        records = new_records(provider, since)
        if session is None:
            starts = [r for r in records if r.get("event_name") == "session_start"]
            if starts:
                session = str(starts[0].get("provider_work_id"))
        names = [r["event_name"] for r in records if session and r.get("provider_work_id") == session]
        if session and all(name in names for name in wanted):
            return names, session
        if time.time() > deadline:
            return names, session
        time.sleep(0.5)


def in_order(names: list[str], wanted: tuple[str, ...]) -> bool:
    """Whether ``wanted`` appears in ``names`` in order, as a subsequence.

    Not "the first of each is in order": a session can legitimately carry a
    repeated event name -- a SIGINT'd run whose process the liveness sweep
    reaps writes its own synthetic ``session_end`` beside the provider's --
    and matching on first occurrences failed such a turn even though every
    event it wanted did happen, in the order it wanted them.
    """

    remaining = iter(names)
    return all(any(name == seen for seen in remaining) for name in wanted)


# -- mock ------------------------------------------------------------------------
class Mock:
    def __init__(self, scratch: Path, *extra: str) -> None:
        self.log = scratch / f"mock-{int(time.time() * 1000)}.jsonl"
        self.process = subprocess.Popen(
            [sys.executable, str(REPO / "scripts" / "mock_llm_server.py"), "--port", "0", "--log", str(self.log), *extra],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        line = self.process.stdout.readline() if self.process.stdout else ""
        match = re.search(r"MOCK_LLM_PORT=(\d+)", line)
        if not match:
            raise RuntimeError("mock server did not report a port")
        self.port = int(match.group(1))
        self.base = f"http://127.0.0.1:{self.port}"

    def requests(self) -> int:
        try:
            return sum(1 for _ in self.log.open())
        except FileNotFoundError:
            return 0

    def stop(self) -> None:
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()


# -- processes ------------------------------------------------------------------
def clean_env(extra: dict[str, str]) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "ANTHROPIC", "CODEX_", "PI_CODING", "GEMINI", "GOOGLE_GEMINI"))}
    env.update(extra)
    return env


def run(argv: list[str], *, env: dict[str, str], cwd: Path, timeout: float) -> tuple[int | str, str]:
    process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, cwd=str(cwd), start_new_session=True)
    try:
        out, _ = process.communicate(timeout=timeout)
        return process.returncode, out
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        out, _ = process.communicate()
        return "timeout", out


# -- scratch homes ----------------------------------------------------------------
def retarget(home: Path, base_url: str) -> None:
    """Point an existing scratch CODEX_HOME at a different mock port."""
    config = home / "config.toml"
    config.write_text(
        re.sub(r'base_url = "http://127\.0\.0\.1:\d+/v1"', f'base_url = "{base_url}/v1"', config.read_text())
    )


def codex_home(scratch: Path, base_url: str, shim: Path) -> Path:
    from jrbar import install

    home = scratch / "codex-home"
    home.mkdir(parents=True)
    real = Path.home() / ".codex" / "config.toml"
    text = real.read_text() if real.exists() else ""
    text = install.strip_managed_block(text)
    text = re.sub(r"\n\[hooks\.state[^\n]*\]\n(?:[^\[\n][^\n]*\n)*", "\n", text)
    text = re.sub(r"^model_provider = .*\n", "", text, flags=re.M)
    text = re.sub(r"^model = .*$", 'model = "mock-model"', text, count=1, flags=re.M)
    if 'model = "mock-model"' not in text:
        text = 'model = "mock-model"\n' + text
    text = text.replace(
        'model = "mock-model"',
        'model = "mock-model"\nmodel_provider = "mock"\nsuppress_unstable_features_warning = true\n\n'
        f'[model_providers.mock]\nname = "mock"\nbase_url = "{base_url}/v1"\nenv_key = "MOCK_API_KEY"\n'
        'wire_api = "responses"\nrequest_max_retries = 0\nstream_max_retries = 0\n',
        1,
    )
    config = home / "config.toml"
    config.write_text(text)
    os.chmod(config, 0o600)
    os.environ["JRBAR_HOOK_EXEC"] = str(shim)
    install.install_codex_hooks(config_path=config)
    hashes = install.local_codex_hook_hashes(config)
    config.write_text(install.update_codex_trusted_hashes(config.read_text(), hashes))
    auth = Path.home() / ".codex" / "auth.json"
    if auth.exists():
        shutil.copy(auth, home / "auth.json")
    return home


def pi_home(scratch: Path, base_url: str, shim: Path) -> Path:
    from jrbar.install import pi_extension_source

    home = scratch / "pi-home"
    (home / "extensions").mkdir(parents=True)
    (home / "extensions" / "jrbar.ts").write_text(pi_extension_source([str(shim), "--provider", "pi", "--log", str(log_path("pi"))]))
    (home / "models.json").write_text(json.dumps({
        "providers": {PI_PROVIDER: {"baseUrl": f"{base_url}/v1", "api": "openai-completions", "apiKey": "mock-key",
                                     "models": [{"id": PI_MODEL, "name": "Mock", "contextWindow": 128000, "maxTokens": 4096}]}}
    }, indent=1))
    (home / "settings.json").write_text(json.dumps({"defaultProvider": PI_PROVIDER, "defaultModel": PI_MODEL, "quietStartup": True, "lastChangelogVersion": "0.73.1"}))
    return home


def gemini_home(scratch: Path) -> Path | None:
    real = Path.home() / ".gemini" / "settings.json"
    if not real.exists():
        return None
    settings = json.loads(real.read_text())
    if "hooks" not in settings:
        return None
    home = scratch / "gemini-home"
    home.mkdir()
    (home / "settings.json").write_text(json.dumps({"hooks": settings["hooks"], "security": {"auth": {"selectedType": "gemini-api-key"}}, "general": {"disableUpdateNag": True}}, indent=1))
    return home


# -- drills -----------------------------------------------------------------------
def check_turn(check: Check, provider: str, label: str, since: int, session: str | None, *, timeout: float) -> str | None:
    names, session = wait_for_events(provider, since, session, FULL_TURN, timeout=timeout)
    if session and in_order(names, FULL_TURN):
        check.ok(f"{label} events", " > ".join(names))
    else:
        check.fail(f"{label} events", f"session={session} got {names}")
        return session
    row = session_row(provider, session, lifecycles=DONE_LIFECYCLES)
    if row is None:
        check.fail(f"{label} state row", "no session row in state within 20s")
        return session
    detail = f"lifecycle={row.get('lifecycle')} mode={row.get('mode')} event={row.get('event')}"
    # A one-shot CLI run sends a real Stop and SessionEnd and then exits.
    # That is the whole life of the run, and it has to read `completed` --
    # the green check, "Done". `ended` here is the defect: a finished run
    # demoted for having exited (CORE-PROTOCOL, sessions[]).
    if row.get("lifecycle") in DONE_LIFECYCLES and row.get("mode") == "completed":
        check.ok(f"{label} state row", detail)
    else:
        check.fail(f"{label} state row", detail)
    return session


def codex_drills(check: Check, scratch: Path, work: Path, shim: Path, *, asks: bool) -> None:
    if shutil.which("codex") is None:
        check.skip("codex", "codex not on PATH")
        return
    mock = Mock(scratch)
    home = codex_home(scratch, mock.base, shim)
    env = clean_env({"MOCK_API_KEY": "mock", "CODEX_HOME": str(home)})
    base = ["codex", "exec", "--skip-git-repo-check", "-s", "danger-full-access", "-c", 'approval_policy="never"', "--json"]
    try:
        since = log_length("codex")
        code, out = run([*base, "run echo hi"], env=env, cwd=work, timeout=120)
        thread = None
        for line in out.splitlines():
            if '"thread.started"' in line:
                try:
                    thread = json.loads(line)["thread_id"]
                except ValueError:
                    pass
        if code != 0 or thread is None:
            check.fail("codex exec", f"rc={code} {out[-400:]}")
        else:
            check.ok("codex exec", f"thread {thread[:8]} rc=0 mock requests={mock.requests()}")
            check_turn(check, "codex", "codex exec", since, thread, timeout=30)
    finally:
        mock.stop()

    # Interrupt: a long tool, SIGINT to the process group mid-tool. The same
    # scratch CODEX_HOME is reused with the new mock's port so the trust
    # handshake is not paid twice.
    mock = Mock(scratch, "--tool-command", "sleep 45; echo hi")
    try:
        retarget(home, mock.base)
        env = clean_env({"MOCK_API_KEY": "mock", "CODEX_HOME": str(home)})
        since = log_length("codex")
        process = subprocess.Popen([*base, "run the command"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, cwd=str(work), start_new_session=True)
        names, thread = wait_for_events("codex", since, None, ("pre_tool_use",), timeout=40)
        if "pre_tool_use" not in names:
            os.killpg(process.pid, signal.SIGKILL)
            check.fail("codex interrupt", f"no pre_tool_use before SIGINT: {names}")
        else:
            time.sleep(1.0)
            os.killpg(process.pid, signal.SIGINT)
            try:
                process.communicate(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
            names, thread = wait_for_events("codex", since, thread, INTERRUPTED_TURN, timeout=15)
            if thread and in_order(names, INTERRUPTED_TURN):
                check.ok("codex interrupt events", " > ".join(names))
            else:
                check.fail("codex interrupt events", f"got {names}")
            row = session_row("codex", thread or "") if thread else None
            if row is not None and row.get("lifecycle") in FINISHED_LIFECYCLES:
                check.ok("codex interrupt state row", f"lifecycle={row['lifecycle']} mode={row['mode']} pid={row.get('pid')}")
            else:
                check.fail("codex interrupt state row", f"row={None if row is None else (row.get('lifecycle'), row.get('mode'), row.get('event'))}")
    finally:
        mock.stop()

    codex_kill_drill(check, scratch, work, home, base)

    if asks:
        codex_ask_drill(check, scratch, work, home)


def codex_kill_drill(check: Check, scratch: Path, work: Path, home: Path, base: list[str]) -> None:
    """The other half of the rule: a session nobody ended reads `ended`.

    SIGKILL mid-tool, so the CLI never gets to send `Stop` or `SessionEnd`.
    The daemon's liveness sweep notices the dead process within
    `LIVENESS_POLL_SECONDS` and writes a synthetic end; that row must stay
    grey. If this one ever reads `completed`, the green check has stopped
    meaning "the provider said so".
    """

    mock = Mock(scratch, "--tool-command", "sleep 90; echo hi")
    process = None
    try:
        retarget(home, mock.base)
        env = clean_env({"MOCK_API_KEY": "mock", "CODEX_HOME": str(home)})
        since = log_length("codex")
        process = subprocess.Popen(
            [*base, "run the command"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
            cwd=str(work),
            start_new_session=True,
        )
        names, thread = wait_for_events("codex", since, None, ("pre_tool_use",), timeout=40)
        if "pre_tool_use" not in names or not thread:
            check.fail("codex kill", f"no pre_tool_use before SIGKILL: {names}")
            return
        time.sleep(1.0)
        os.killpg(process.pid, signal.SIGKILL)
        try:
            process.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            pass
        check.ok("codex kill", f"SIGKILL to {thread[:8]} mid-tool")
        # The sweep runs every five seconds; give it several turns.
        row = session_row("codex", thread, wait=45.0, lifecycles=UNCONFIRMED_LIFECYCLES)
        detail = (
            "no session row in state within 45s"
            if row is None
            else f"lifecycle={row.get('lifecycle')} mode={row.get('mode')} event={row.get('event')} stale={row.get('stale')}"
        )
        if row is not None and row.get("lifecycle") in UNCONFIRMED_LIFECYCLES:
            check.ok("codex kill state row", detail)
        else:
            check.fail("codex kill state row", detail)
    finally:
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except OSError:
                pass
        mock.stop()


def codex_ask_drill(check: Check, scratch: Path, work: Path, home: Path) -> None:
    """Interactive Codex in a pty under -a on-request; the mock asks to leave the sandbox."""
    mock = Mock(scratch, "--escalate")
    # The scratch config names the previous mock's port; rewrite for this one.
    retarget(home, mock.base)
    env = clean_env({"MOCK_API_KEY": "mock", "CODEX_HOME": str(home), "TERM": "xterm-256color", "COLUMNS": "120", "LINES": "40"})
    since = log_length("codex")
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(str(work))
        os.execvpe("codex", ["codex", "-a", "on-request", "-s", "workspace-write", "run the command"], env)
    try:
        deadline = time.time() + 45
        thread = None
        while time.time() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.5)
            if ready:
                try:
                    os.read(fd, 65536)
                except OSError:
                    break
            records = [r for r in new_records("codex", since) if r.get("event_name") == "permission_request"]
            if records:
                thread = str(records[0]["provider_work_id"])
                break
        if thread is None:
            check.fail("codex ask", "no permission_request within 45s")
            return
        check.ok("codex ask recorded", f"permission_request for {thread[:8]}")
        ask, state = None, {}
        for _ in range(30):
            state = core_state()
            ask = next((a for a in state.get("asks", []) if thread in json.dumps(a)), None)
            if ask is not None:
                break
            drain(fd)
            time.sleep(1.0)
        if ask is None:
            rows = [
                {k: row.get(k) for k in ("id", "lifecycle", "mode", "event", "stale")}
                for row in state.get("sessions", [])
                if thread in str(row.get("id"))
            ]
            check.fail(
                "codex ask in state.asks",
                f"not named within 30s; asks={json.dumps(state.get('asks'))[:160]} row={json.dumps(rows)[:200]}",
            )
            return
        check.ok("codex ask in state.asks", json.dumps(ask)[:160])
        session = f"codex:session:{thread}"
        reply, _ = core_command("answer_ask", {"session": session, "decision": "approve"})
        if reply.get("ok"):
            check.ok("answer_ask", json.dumps(reply.get("result"))[:160])
        else:
            code = (reply.get("error") or {}).get("code")
            if code in {"not_frontmost", "unsupported"}:
                check.ok("answer_ask", f"refused as expected from a pty: {code} ({(reply.get('error') or {}).get('message')})")
            else:
                check.fail("answer_ask", json.dumps(reply)[:200])
        # Past the frontmost guard: this is what the daemon can actually do
        # once the terminal IS in front, which is the part a permission in
        # System Settings would gate.
        forced, _ = core_command(
            "answer_ask", {"session": session, "decision": "approve", "only_if_frontmost": False}
        )
        if forced.get("ok"):
            check.ok("answer_ask only_if_frontmost=false", json.dumps(forced.get("result"))[:160])
        else:
            error = forced.get("error") or {}
            check.ok(
                "answer_ask only_if_frontmost=false",
                f"refused: {error.get('code')} ({error.get('message')})",
            )
    finally:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        mock.stop()


def claude_home(scratch: Path, work: Path) -> Path | None:
    """A scratch ``CLAUDE_CONFIG_DIR`` with the real hooks and no first-run
    questions: onboarding answered, the work directory already trusted.

    Claude Code will not run anything in a directory it has not been told
    to trust, and that dialog is the first thing a fresh config sees.
    """
    real = Path.home() / ".claude" / "settings.json"
    if not real.exists():
        return None
    home = scratch / "claude-home"
    home.mkdir(parents=True, exist_ok=True)
    settings = json.loads(real.read_text())
    if "hooks" not in settings:
        return None
    (home / "settings.json").write_text(json.dumps({"hooks": settings["hooks"]}, indent=1))
    (home / ".claude.json").write_text(
        json.dumps(
            {
                "hasCompletedOnboarding": True,
                "theme": "dark",
                # Claude Code otherwise stops on "Detected a custom API key
                # in your environment"; it remembers the answer by the
                # key's last twenty characters.
                "customApiKeyResponses": {"approved": [MOCK_API_KEY[-20:]], "rejected": []},
                "projects": {
                    str(work): {
                        "hasTrustDialogAccepted": True,
                        "hasCompletedProjectOnboarding": True,
                        "allowedTools": [],
                        "history": [],
                    }
                },
            },
            indent=1,
        )
    )
    return home


def claude_ask_drill(check: Check, scratch: Path, work: Path) -> None:
    """Interactive Claude Code in a pty with permissions on: the mock asks
    for a shell command, Claude asks the owner, JR-Bar should see it."""
    if shutil.which("claude") is None:
        check.skip("claude ask", "claude not on PATH")
        return
    # `echo`, and anything the Bash sandbox can contain, runs without a
    # prompt; reaching the network is what Claude Code asks about.
    home = claude_home(scratch, work)
    if home is None:
        check.skip("claude ask", "no ~/.claude/settings.json hooks to copy")
        return
    mock = Mock(scratch, "--tool-command", "touch ~/jrbar-ask-probe && rm -f ~/jrbar-ask-probe")
    env = clean_env(
        {
            "CLAUDE_CONFIG_DIR": str(home),
            "ANTHROPIC_BASE_URL": mock.base,
            "ANTHROPIC_API_KEY": MOCK_API_KEY,
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "TERM": "xterm-256color",
            "COLUMNS": "120",
            "LINES": "40",
        }
    )
    since = log_length("claude")
    transcript = bytearray()
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(str(work))
        os.execvpe("claude", ["claude", "--permission-mode", "default", "run the command"], env)
    # A pty starts 0x0; a full-screen TUI will not draw or take input until
    # it has a size, so say one before reading a line of it.
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    try:
        deadline = time.time() + 90
        session = None
        answered: set[bytes] = set()
        while time.time() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.5)
            if ready:
                try:
                    transcript += os.read(fd, 65536)
                except OSError:
                    break
            # Claude Code asks two first-run questions before it will run
            # anything: whether this directory is trusted, and whether to
            # use the API key it found in the environment. Each is a list
            # with the wanted answer one step from the cursor.
            for marker, arrow in ((b"trust this folder", b"\x1b[B"), (b"use this API key", b"\x1b[A")):
                if marker not in answered and marker in transcript:
                    answered.add(marker)
                    time.sleep(1.0)
                    os.write(fd, arrow)
                    time.sleep(0.3)
                    os.write(fd, b"\r")
                    transcript.clear()
            records = [r for r in new_records("claude", since) if r.get("event_name") == "permission_request"]
            if records:
                session = str(records[0]["provider_work_id"])
                break
        if session is None:
            names = sorted({str(r.get("event_name")) for r in new_records("claude", since)})
            tail = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]|[\r\x00-\x08\x0b-\x1f]", " ", transcript.decode("utf-8", "replace"))
            tail = " ".join(tail.split())[-200:]
            check.fail("claude ask recorded", f"no permission_request within 90s; saw {names}; screen: {tail!r}")
            return
        check.ok("claude ask recorded", f"permission_request for {session[:8]}")
        ask, state = None, {}
        for _ in range(30):
            state = core_state()
            ask = next((a for a in state.get("asks", []) if session in json.dumps(a)), None)
            if ask is not None:
                break
            drain(fd)
            time.sleep(1.0)
        if ask is None:
            rows = [
                {k: row.get(k) for k in ("id", "lifecycle", "mode", "event", "stale")}
                for row in state.get("sessions", [])
                if session in str(row.get("id"))
            ]
            check.fail(
                "claude ask in state.asks",
                f"not named within 30s; asks={json.dumps(state.get('asks'))[:160]} row={json.dumps(rows)[:200]}",
            )
            return
        check.ok("claude ask in state.asks", json.dumps(ask)[:160])
        for label, args in (
            ("answer_ask", {}),
            ("answer_ask only_if_frontmost=false", {"only_if_frontmost": False}),
        ):
            drain(fd)
            reply, _ = core_command(
                "answer_ask", {"session": f"claude:session:{session}", "decision": "approve", **args}
            )
            if reply.get("ok"):
                check.ok(f"claude {label}", json.dumps(reply.get("result"))[:160])
            else:
                error = reply.get("error") or {}
                check.ok(f"claude {label}", f"refused: {error.get('code')} ({error.get('message')})")
    finally:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        mock.stop()


def pi_drill(check: Check, scratch: Path, work: Path, shim: Path) -> None:
    if shutil.which("pi") is None:
        check.skip("pi", "pi not on PATH")
        return
    mock = Mock(scratch)
    home = pi_home(scratch, mock.base, shim)
    env = clean_env({"PI_CODING_AGENT_DIR": str(home)})
    try:
        since = log_length("pi")
        code, out = run(["pi", "-p", "--provider", PI_PROVIDER, "--model", PI_MODEL, "--no-skills", "--no-context-files", "run echo hi"], env=env, cwd=work, timeout=90)
        if code != 0:
            check.fail("pi -p", f"rc={code} {out[-400:]}")
            return
        check.ok("pi -p", f"rc=0 answer={out.strip()[-40:]!r} mock requests={mock.requests()}")
        check_turn(check, "pi", "pi -p", since, None, timeout=30)
    finally:
        mock.stop()


def claude_drill(check: Check, scratch: Path, work: Path, *, asks: bool = False) -> None:
    if shutil.which("claude") is None:
        check.skip("claude", "claude not on PATH")
        return
    mock = Mock(scratch)
    env = clean_env({"ANTHROPIC_BASE_URL": mock.base, "ANTHROPIC_API_KEY": MOCK_API_KEY, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"})
    try:
        since = log_length("claude")
        code, out = run(["claude", "-p", "run echo hi", "--dangerously-skip-permissions"], env=env, cwd=work, timeout=120)
        if code != 0 or mock.requests() == 0:
            check.fail("claude -p", f"rc={code} mock requests={mock.requests()} {out[-300:]}")
            return
        check.ok("claude -p", f"rc=0 answer={out.strip()[-40:]!r} mock requests={mock.requests()}")
        check_turn(check, "claude", "claude -p", since, None, timeout=30)
    finally:
        mock.stop()
    if asks:
        claude_ask_drill(check, scratch, work)


def gemini_drill(check: Check, scratch: Path, work: Path) -> None:
    if shutil.which("gemini") is None:
        check.skip("gemini", "gemini not on PATH")
        return
    home = gemini_home(scratch)
    if home is None:
        check.skip("gemini", "no ~/.gemini/settings.json hooks to copy")
        return
    mock = Mock(scratch)
    env = clean_env({"GEMINI_CLI_HOME": str(home), "GOOGLE_GEMINI_BASE_URL": mock.base, "GEMINI_API_KEY": "mock-key"})
    try:
        since = log_length("gemini")
        code, out = run(["gemini", "-p", "run echo hi", "--yolo", "--skip-trust", "-m", "mock-model"], env=env, cwd=work, timeout=90)
        if "Invalid auth method" in out or mock.requests() == 0:
            check.skip("gemini", f"the CLI will not talk to a local endpoint (rc={code}): {out.strip().splitlines()[-1][:120] if out.strip() else ''}")
            return
        check.ok("gemini -p", f"rc={code} mock requests={mock.requests()}")
        check_turn(check, "gemini", "gemini -p", since, None, timeout=30)
    finally:
        mock.stop()


def usage_check(check: Check) -> None:
    sessions = Path.home() / ".codex" / "sessions"
    recent = [p for p in sessions.rglob("*.jsonl") if time.time() - p.stat().st_mtime < 7 * 86400] if sessions.exists() else []
    if not recent:
        check.skip("usage_history codex 7d", "no Codex rollouts from the last 7 days on this Mac")
        return
    # The first ask may be answered `pending` while the scan runs (the app
    # sees the same thing and waits for `usage_history_ready`); ask again
    # until a scanned document lands, and time both.
    started = time.time()
    waited = 0.0
    result: dict = {}
    reply: dict = {}
    while time.time() - started < 300:
        first = time.time()
        reply, _ = core_command("usage_history", {"provider": "codex", "range": "7d"}, timeout=300)
        waited = time.time() - first
        result = reply.get("result") or {}
        if not reply.get("ok") or not result.get("pending"):
            break
        time.sleep(2.0)
    tokens = sum(int(day.get("tokens_in", 0)) + int(day.get("tokens_out", 0)) for day in result.get("days", []))
    if reply.get("ok") and result.get("records", 0) > 0 and tokens > 0:
        check.ok(
            "usage_history codex 7d",
            f"records={result['records']} tokens={tokens} "
            f"pricing={((result.get('pricing') or {}).get('model'))} ({(result.get('pricing') or {}).get('source')}) "
            f"reply={waited:.2f}s scan={time.time() - started:.1f}s",
        )
    else:
        check.fail("usage_history codex 7d", json.dumps(reply)[:300])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--asks", action="store_true", help="also run the interactive Codex approval drill")
    parser.add_argument("--only", nargs="*", default=None, choices=["codex", "pi", "claude", "gemini", "usage"], help="restrict to these drills")
    parser.add_argument("--keep", action="store_true", help="keep the scratch directory")
    parser.add_argument("--shim", default=str(INSTALLED_SHIM), help="hook shim the scratch configs invoke")
    args = parser.parse_args(argv)
    shim = Path(args.shim).expanduser()
    check = Check()
    if not CORE_SOCK.exists():
        print(f"no daemon socket at {CORE_SOCK}; start JR-Bar.app first", file=sys.stderr)
        return 2
    if not shim.is_file():
        print(f"no hook shim at {shim}", file=sys.stderr)
        return 2
    if subprocess.run(["pgrep", "-f", "mock_llm_server.py"], capture_output=True).returncode == 0:
        print("a mock_llm_server.py is already running; stop it first", file=sys.stderr)
        return 2
    sys.path.insert(0, str(REPO / "src"))
    # Resolved: macOS hands out /var/folders/... which is a link to
    # /private/var/..., and Codex keys its hook trust by the resolved path.
    scratch = Path(tempfile.mkdtemp(prefix="jrbar-verify-")).resolve()
    work = scratch / "work"
    work.mkdir()
    subprocess.run(["git", "init", "-q", str(work)], check=False)
    wanted = set(args.only or ["codex", "pi", "claude", "gemini", "usage"])
    print(f"scratch: {scratch}")
    try:
        if "codex" in wanted:
            print("== codex")
            codex_drills(check, scratch, work, shim, asks=args.asks)
        if "pi" in wanted:
            print("== pi")
            pi_drill(check, scratch, work, shim)
        if "claude" in wanted:
            print("== claude")
            claude_drill(check, scratch, work, asks=args.asks)
        if "gemini" in wanted:
            print("== gemini")
            gemini_drill(check, scratch, work)
        if "usage" in wanted:
            print("== usage")
            usage_check(check)
    finally:
        if not args.keep:
            shutil.rmtree(scratch, ignore_errors=True)
    print("== summary")
    for status, name, detail in check.rows:
        print(f"  {status:5} {name}: {detail}")
    print(f"{check.failed} failed, {sum(1 for r in check.rows if r[0] == 'ok')} ok, {sum(1 for r in check.rows if r[0] == 'skip')} skipped")
    return 1 if check.failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
