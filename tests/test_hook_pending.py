"""The shim's ``<provider>.pending.jsonl`` fallback and the daemon's drain."""

from __future__ import annotations

import fcntl
import json
import os
import threading
import time
from pathlib import Path

import pytest

from jrbar.hook import hook_logged_at
from jrbar.hook_ingress_protocol import HookIngressRequest
from jrbar.hook_pending import (
    PENDING_SUFFIX,
    drain_pending_hooks,
    pending_hook_files,
    request_from_pending_line,
)


def _line(provider: str = "claude", **extra) -> str:
    row = {"provider": provider, "ppid": 4242, "ppid_start": 1788982000.5, "payload": '{"hook_event_name":"Stop"}'}
    row.update(extra)
    return json.dumps(row)


def test_request_from_pending_line_carries_the_shim_fields() -> None:
    request = request_from_pending_line(_line(), log_path_for=lambda provider: f"/logs/{provider}.jsonl")
    assert isinstance(request, HookIngressRequest)
    assert request.provider == "claude"
    assert request.log_path == "/logs/claude.jsonl"
    assert request.payload_text == '{"hook_event_name":"Stop"}'
    assert request.ppid == 4242 and request.ppid_start == 1788982000.5
    # Bad rows are dropped, never raised.
    assert request_from_pending_line("not json") is None
    assert request_from_pending_line(json.dumps({"provider": "claude"})) is None
    assert request_from_pending_line(_line(provider="nope")) is None
    assert request_from_pending_line(_line(ppid=1)).ppid is None
    assert request_from_pending_line(_line(ppid_start="x")).ppid_start is None
    # The shim writes -1 when it could not read its parent's start time;
    # that line is still a delivery, not a rejection -- but without the
    # start nothing can tell a replay the pid was not reused, so it
    # registers no process.
    unstarted = request_from_pending_line(_line(ppid_start=-1.0))
    assert unstarted is not None
    assert unstarted.ppid_start is None and unstarted.ppid is None
    # queued_at_ms (milliseconds) arrives as the request's epoch; lines from
    # an older shim, or with a nonsense stamp, simply have none.
    assert request_from_pending_line(_line(queued_at_ms=1_700_000_000_250)).queued_at_epoch == 1_700_000_000.25
    assert request_from_pending_line(_line()).queued_at_epoch is None
    assert request_from_pending_line(_line(queued_at_ms=True)).queued_at_epoch is None
    assert request_from_pending_line(_line(queued_at_ms="soon")).queued_at_epoch is None
    assert request_from_pending_line(_line(queued_at_ms=-5)).queued_at_epoch is None
    # A stamp from the future is capped at the drain time, however far out:
    # past year 9999 it cannot be formatted, and a submit that raised would
    # requeue the line every pass forever.
    before = time.time()
    for future in (int((before + 3600) * 1000), 10**17, 10**400):
        epoch = request_from_pending_line(_line(queued_at_ms=future)).queued_at_epoch
        assert before <= epoch <= time.time()
        hook_logged_at(epoch)


def test_drain_submits_in_file_order_and_removes_the_files__and_1_more(tmp_path: Path) -> None:
    # --- scenario: drain_submits_in_file_order_and_removes_the_files
    (tmp_path / f"claude{PENDING_SUFFIX}").write_text(_line() + "\n" + _line(payload="{}") + "\n\n")
    (tmp_path / f"codex{PENDING_SUFFIX}").write_text(_line(provider="codex") + "\nbroken\n")
    (tmp_path / "unrelated.jsonl").write_text("{}\n")
    assert [path.name for path in pending_hook_files(tmp_path)] == [f"claude{PENDING_SUFFIX}", f"codex{PENDING_SUFFIX}"]
    submitted: list[HookIngressRequest] = []
    count = drain_pending_hooks(submitted.append, state_dir=tmp_path, log_path_for=lambda provider: f"/logs/{provider}.jsonl")
    assert count == 3
    assert [request.provider for request in submitted] == ["claude", "claude", "codex"]
    assert submitted[1].payload_text == "{}"
    assert pending_hook_files(tmp_path) == []
    assert (tmp_path / "unrelated.jsonl").exists()
    # The malformed line was accounted for, not silently deleted.
    assert (tmp_path / "codex.rejected.jsonl").read_text().strip() == "broken"

    # --- scenario: drain_survives_a_submit_that_raises
    (tmp_path / f"claude{PENDING_SUFFIX}").write_text(_line() + "\n" + _line() + "\n")
    calls = []

    def submit(request):
        calls.append(request)
        if len(calls) == 1:
            raise RuntimeError("ingress closed")

    assert drain_pending_hooks(submit, state_dir=tmp_path, log_path_for=lambda p: f"/logs/{p}.jsonl") == 1
    assert len(calls) == 2
    # The failed line goes back to pending for the next drain instead of
    # being unlinked with the file.
    leftovers = pending_hook_files(tmp_path)
    assert len(leftovers) == 1
    assert leftovers[0].read_text().count("\n") == 1
    # And the next drain, with a healthy submit, delivers it.
    assert drain_pending_hooks(submitted.append, state_dir=tmp_path, log_path_for=lambda p: f"/logs/{p}.jsonl") == 1
    assert pending_hook_files(tmp_path) == []



def test_orphaned_drain_files_are_adopted_by_the_next_drain(tmp_path) -> None:
    """A crash between the rename and the unlink stranded every record in the
    renamed file. A HID crash loop left 36 such files holding 226 records."""
    from jrbar.hook_pending import (
        DRAINING_INFIX,
        drain_pending_hooks,
        orphaned_drain_files,
    )

    payload = json.dumps({"hook_event_name": "Stop", "session_id": "s1"})
    row = json.dumps({"provider": "claude", "payload": payload}) + "\n"
    dead = tmp_path / f"claude{PENDING_SUFFIX}{DRAINING_INFIX}999999-1789071960818"
    dead.write_text(row + row, encoding="utf-8")
    live = tmp_path / f"codex{PENDING_SUFFIX}{DRAINING_INFIX}{os.getpid()}-1789071960900"
    live.write_text(row, encoding="utf-8")
    fresh = tmp_path / f"claude{PENDING_SUFFIX}"
    fresh.write_text(row, encoding="utf-8")

    assert orphaned_drain_files(tmp_path) == [dead]

    seen: list[str] = []
    submitted = drain_pending_hooks(
        lambda request: seen.append(request.provider),
        state_dir=tmp_path,
        log_path_for=lambda provider: str(tmp_path / f"{provider}.jsonl"),
    )

    assert submitted == 3
    assert seen == ["claude", "claude", "claude"]
    assert not dead.exists()
    assert not fresh.exists()
    assert live.exists(), "a drain owned by a living process must not be stolen"


def test_a_drain_that_crashes_leaves_a_file_the_next_drain_finds(tmp_path) -> None:
    from jrbar.hook_pending import drain_pending_hooks, orphaned_drain_files

    payload = json.dumps({"hook_event_name": "Stop", "session_id": "s1"})
    (tmp_path / f"claude{PENDING_SUFFIX}").write_text(
        json.dumps({"provider": "claude", "payload": payload}) + "\n", encoding="utf-8"
    )

    class Boom(Exception):
        pass

    def explode(_request):
        raise SystemExit("daemon died mid-drain")

    with pytest.raises(SystemExit):
        drain_pending_hooks(
            explode,
            state_dir=tmp_path,
            log_path_for=lambda provider: str(tmp_path / f"{provider}.jsonl"),
        )

    stranded = list(tmp_path.glob(f"*{PENDING_SUFFIX}.draining-*"))
    assert len(stranded) == 1
    # The dead owner is this pid, which is alive, so simulate the restart by
    # renaming to a pid that is gone.
    stranded[0].rename(tmp_path / stranded[0].name.replace(f"-{os.getpid()}-", "-999999-"))
    assert len(orphaned_drain_files(tmp_path)) == 1

    seen: list[str] = []
    assert (
        drain_pending_hooks(
            lambda request: seen.append(request.provider),
            state_dir=tmp_path,
            log_path_for=lambda provider: str(tmp_path / f"{provider}.jsonl"),
        )
        == 1
    )
    assert seen == ["claude"] and not list(tmp_path.glob("*.draining-*"))


def test_lines_past_the_drain_cap_stay_pending(tmp_path) -> None:
    """A file with more lines than one drain's cap must keep the remainder
    queued -- before, the tail was unlinked with the file, unrecorded."""
    from jrbar import hook_pending

    pending = tmp_path / f"claude{PENDING_SUFFIX}"
    total = hook_pending.MAX_PENDING_LINES_PER_DRAIN + 7
    pending.write_text("".join(_line() + "\n" for _ in range(total)), encoding="utf-8")

    seen: list[str] = []
    count = drain_pending_hooks(
        lambda request: seen.append(request.provider),
        state_dir=tmp_path,
        log_path_for=lambda provider: str(tmp_path / f"{provider}.jsonl"),
    )
    assert count == hook_pending.MAX_PENDING_LINES_PER_DRAIN
    rest = pending_hook_files(tmp_path)
    assert len(rest) == 1
    assert len(rest[0].read_text().splitlines()) == 7
    # A second drain delivers the tail.
    assert (
        drain_pending_hooks(
            lambda request: seen.append(request.provider),
            state_dir=tmp_path,
            log_path_for=lambda provider: str(tmp_path / f"{provider}.jsonl"),
        )
        == 7
    )
    assert pending_hook_files(tmp_path) == []


def test_an_oversized_pending_file_drains_its_newest_lines_and_keeps_the_head(tmp_path, monkeypatch) -> None:
    """Quarantining the whole file replayed none of it -- including the
    newest events, the ones live state needs."""
    from jrbar import hook_pending

    lines = [_line(payload=json.dumps({"hook_event_name": "Stop", "n": n})) + "\n" for n in range(40)]
    blob = "".join(lines).encode("utf-8")
    limit = len(lines[-1].encode("utf-8")) * 10 + 5  # ten whole lines and a partial one
    monkeypatch.setattr(hook_pending, "MAX_PENDING_FILE_BYTES", limit)
    pending = tmp_path / f"claude{PENDING_SUFFIX}"
    pending.write_bytes(blob)
    (tmp_path / "claude.overflow.jsonl").write_text("an older generation\n")

    seen: list[int] = []
    count = drain_pending_hooks(
        lambda request: seen.append(json.loads(request.payload_text)["n"]),
        state_dir=tmp_path,
        log_path_for=lambda provider: f"/logs/{provider}.jsonl",
    )

    assert count == 10 and seen == list(range(30, 40))
    assert pending_hook_files(tmp_path) == [] and not list(tmp_path.glob("*.draining-*"))
    # The older head is kept, whole lines only, as the overflow generation.
    assert (tmp_path / "claude.overflow.jsonl").read_bytes() == "".join(lines[:30]).encode("utf-8")


def test_an_oversized_tail_that_starts_on_a_line_boundary_keeps_its_first_line(tmp_path, monkeypatch) -> None:
    from jrbar import hook_pending

    lines = [_line(payload=json.dumps({"n": n})) + "\n" for n in range(6)]
    monkeypatch.setattr(hook_pending, "MAX_PENDING_FILE_BYTES", sum(len(line) for line in lines[2:]))
    (tmp_path / f"claude{PENDING_SUFFIX}").write_text("".join(lines))
    seen: list[int] = []
    drain_pending_hooks(
        lambda request: seen.append(json.loads(request.payload_text)["n"]),
        state_dir=tmp_path,
        log_path_for=lambda provider: f"/logs/{provider}.jsonl",
    )
    assert seen == [2, 3, 4, 5]
    assert (tmp_path / "claude.overflow.jsonl").read_text() == "".join(lines[:2])


def test_an_oversized_file_without_a_whole_line_in_reach_is_kept_as_overflow(tmp_path, monkeypatch) -> None:
    from jrbar import hook_pending

    monkeypatch.setattr(hook_pending, "MAX_PENDING_FILE_BYTES", 4096)
    pending = tmp_path / f"claude{PENDING_SUFFIX}"
    pending.write_bytes(b"x" * 10_000)
    assert drain_pending_hooks(lambda _r: None, state_dir=tmp_path) == 0
    assert not pending.exists()
    overflow = tmp_path / "claude.overflow.jsonl"
    assert overflow.read_bytes() == b"x" * 10_000


def test_the_drain_waits_out_an_append_already_under_way(tmp_path, monkeypatch) -> None:
    """A shim that found the pending file just before the drain renamed it
    still writes into the renamed file. The shim holds the spool's lock
    through that write, and the drain takes it before it reads: the late
    line is drained, not unlinked with the file."""
    from jrbar import hook_pending

    pending = tmp_path / f"claude{PENDING_SUFFIX}"
    pending.write_text(_line(payload='{"n":1}') + "\n")
    shim = os.open(pending, os.O_WRONLY | os.O_APPEND)
    fcntl.flock(shim, fcntl.LOCK_EX)
    locking = threading.Event()
    real_lock = hook_pending._lock

    def lock(descriptor: int, operation: int) -> bool:
        locking.set()
        return real_lock(descriptor, operation)

    monkeypatch.setattr(hook_pending, "_lock", lock)
    seen: list[str] = []
    drain = threading.Thread(
        target=drain_pending_hooks,
        args=(lambda request: seen.append(request.payload_text),),
        kwargs={"state_dir": tmp_path, "log_path_for": lambda provider: f"/logs/{provider}.jsonl"},
    )
    try:
        drain.start()
        assert locking.wait(5.0)
        assert not pending.exists()  # renamed; the drain waits for the lock
        os.write(shim, (_line(payload='{"n":2}') + "\n").encode())
    finally:
        os.close(shim)
    drain.join(5.0)
    assert seen == ['{"n":1}', '{"n":2}']
    assert list(tmp_path.iterdir()) == []


def test_a_fresh_replay_is_stamped_on_arrival_and_only_history_keeps_its_queued_time(
    monkeypatch,
) -> None:
    import time

    from jrbar import hook
    from jrbar.hook_ingress import AppOwnedHookIngressProcessor
    from jrbar.hook_pending import PENDING_REPLAY_HORIZON_SECONDS

    calls: list[dict] = []
    monkeypatch.setattr(
        hook,
        "process_hook_payload",
        lambda provider, log_path, payload, **kwargs: calls.append(kwargs),
    )
    processor = AppOwnedHookIngressProcessor(lambda _hint: None)
    now = time.time()

    def request(queued_at: float | None) -> HookIngressRequest:
        return HookIngressRequest("claude", "/logs/claude.jsonl", "{}", queued_at_epoch=queued_at)

    processor(request(None))
    processor(request(now - 60.0))
    processor(request(now - PENDING_REPLAY_HORIZON_SECONDS - 60.0))

    live, fresh, stale = calls
    # A live delivery, and a replay inside the horizon, are stamped on
    # arrival and refresh: the monitor's watermark is per provider source,
    # so a queued stamp older than another session's live hook is skipped.
    assert set(live) == {"refresh_hint_handler"}
    assert set(fresh) == {"refresh_hint_handler"}
    # Past the horizon the record is history: its queued time, no refresh.
    assert stale["logged_at"] == hook.hook_logged_at(now - PENDING_REPLAY_HORIZON_SECONDS - 60.0)
    assert stale["refresh"] is False
    for bad in (True, float("nan"), float("inf"), 0.0, -1.0, "1790078400"):
        with pytest.raises(ValueError):
            request(bad)  # type: ignore[arg-type]


def test_a_fresh_replay_reaches_live_state_after_another_sessions_live_hook(tmp_path) -> None:
    """The live monitor keeps one watermark per provider source, shared by
    every session, and skips a batch older than it. Replays stamped with
    their queued time broke that: on a restart session B's first live hook
    moved the watermark to now, every line of session A's spooled backlog
    was older, and A never appeared. Inside the horizon a replay is stamped
    on arrival, so A lands; past it the record is history and stays out."""
    from jrbar._collector_legacy import LiveAgentMonitor
    from jrbar.hook_ingress import AppOwnedHookIngressProcessor
    from jrbar.hook_pending import PENDING_REPLAY_HORIZON_SECONDS

    log = tmp_path / "claude.jsonl"
    monitor = LiveAgentMonitor()
    processor = AppOwnedHookIngressProcessor(lambda hint: monitor.reconcile_refresh_hint(hint, log_path=log))
    now = time.time()

    def submit(session: str, event: dict, queued_at: float | None = None) -> None:
        payload = {"session_id": session, "cwd": f"/tmp/{session}", **event}
        processor(HookIngressRequest("claude", str(log), json.dumps(payload), queued_at_epoch=queued_at))

    submit("B", {"hook_event_name": "UserPromptSubmit", "prompt": "hi"})
    # A's prompt and permission ask, spooled five minutes ago, drain after.
    submit("A", {"hook_event_name": "UserPromptSubmit", "prompt": "go"}, now - 300.0)
    submit(
        "A",
        {"hook_event_name": "Notification", "message": "Claude needs your permission to use Bash"},
        now - 299.0,
    )
    # C's prompt from before the horizon is history for the log only.
    submit("C", {"hook_event_name": "UserPromptSubmit", "prompt": "old"}, now - PENDING_REPLAY_HORIZON_SECONDS - 60.0)
    # B's next live hook rereads the log past C's line; C stays out.
    submit("B", {"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "ls"}})

    sessions = {status.session_id for status in monitor.snapshot().statuses}
    assert sessions == {"A", "B"}
    assert '"C"' in log.read_text()


def test_the_python_client_spools_the_shims_line_and_rotates_at_its_cap(tmp_path, monkeypatch) -> None:
    """spool_pending_hook writes the line the compiled shim writes, so the
    drain replays it the same way, and rotates a full spool the same way:
    the full file becomes the overflow generation and the newest line
    starts a fresh one."""
    from jrbar import hook_pending

    assert hook_pending.spool_pending_hook("claude", '{"hook_event_name":"Stop","t":"π"}', state_dir=tmp_path, now=lambda: 1_700_000_000.25)
    pending = tmp_path / f"claude{PENDING_SUFFIX}"
    assert oct(pending.stat().st_mode & 0o777) == "0o600"
    request = request_from_pending_line(pending.read_text().splitlines()[0], log_path_for=lambda p: f"/logs/{p}.jsonl")
    assert request.payload_text == '{"hook_event_name":"Stop","t":"π"}'
    assert request.queued_at_epoch == 1_700_000_000.25
    assert request.ppid is None

    monkeypatch.setattr(hook_pending, "MAX_SPOOL_BYTES", pending.stat().st_size + 10)
    assert hook_pending.spool_pending_hook("claude", '{"hook_event_name":"Stop","n":2}', state_dir=tmp_path)
    overflow = tmp_path / "claude.overflow.jsonl"
    assert overflow.read_text().count("\n") == 1
    rows = [json.loads(line) for line in pending.read_text().splitlines()]
    assert [row["payload"] for row in rows] == ['{"hook_event_name":"Stop","n":2}']


def test_a_nudge_drains_the_spool_now_instead_of_at_the_interval(tmp_path) -> None:
    """The ingress nudges every running drainer once the queue that refused
    a payload is empty again; the drain comes a settle beat later, not 30 s
    later, and a stopped drainer is no longer nudged."""
    from jrbar import hook_pending
    from jrbar.hook_pending import (
        PENDING_NUDGE_SETTLE_SECONDS,
        PendingHookDrainer,
        nudge_pending_drains,
    )

    passes: list[int] = []
    passed = threading.Event()

    class CountingDrainer(PendingHookDrainer):
        def drain_now(self) -> int:
            count = super().drain_now()
            passes.append(count)
            passed.set()
            return count

    submitted: list[HookIngressRequest] = []
    drainer = CountingDrainer(submitted.append, state_dir=tmp_path, interval_seconds=3600.0)
    drainer.start()
    try:
        assert passed.wait(5.0)  # the first pass, which finds nothing
        passed.clear()
        (tmp_path / f"claude{PENDING_SUFFIX}").write_text(_line() + "\n")
        started = time.monotonic()
        nudge_pending_drains()
        assert passed.wait(5.0)
        assert time.monotonic() - started >= PENDING_NUDGE_SETTLE_SECONDS * 0.9
        assert passes == [0, 1]
        assert len(submitted) == 1
    finally:
        drainer.stop()
    assert drainer not in hook_pending._running_drainers


def test_a_drain_applies_one_refresh_hint_per_source_after_the_pass(tmp_path, monkeypatch) -> None:
    """A spooled backlog reaches the monitor as one reread per provider log:
    the pass holds every hint, the end of the pass applies the newest of
    each source, and it does so even when the pass itself failed."""
    from jrbar.hook_ingress import DeferredRefreshHints
    from jrbar.hook_pending import PendingHookDrainer
    from jrbar.ipc import EventToken, ProviderRefreshHint, SourceKey

    def hint(provider: str, token: str) -> ProviderRefreshHint:
        return ProviderRefreshHint(SourceKey(provider, "hooks", "local", "session"), EventToken(token))

    applied: list[ProviderRefreshHint] = []
    hints = DeferredRefreshHints(applied.append)
    held = [hint("claude", "a" * 32), hint("codex", "b" * 32), hint("claude", "c" * 32)]

    submitted: list[HookIngressRequest] = []

    def submit(request: HookIngressRequest) -> None:
        hints.note(held[len(submitted)])
        submitted.append(request)

    (tmp_path / f"claude{PENDING_SUFFIX}").write_text("\n".join(_line() for _ in held) + "\n")
    drainer = PendingHookDrainer(submit, state_dir=tmp_path, after_drain=hints.flush)
    assert drainer.drain_now() == 3
    # Nothing reached the monitor while the pass ran; after it, one hint
    # per source, the newest one, in the order the sources first appeared.
    assert [(item.source_key.provider_id, item.event_token) for item in applied] == [
        ("claude", held[2].event_token),
        ("codex", held[1].event_token),
    ]
    # A flush with nothing held applies nothing.
    assert hints.flush() == 0 and len(applied) == 2

    # A pass that raises still flushes what it held.
    hints.note(hint("claude", "d" * 32))

    def broken(*_args, **_kwargs) -> int:
        raise RuntimeError("disk gone")

    from jrbar import hook_pending

    monkeypatch.setattr(hook_pending, "drain_pending_hooks", broken)
    with pytest.raises(RuntimeError):
        drainer.drain_now()
    assert applied[-1].event_token == EventToken("d" * 32)

    # A handler that raises costs only its own hint.
    def refuse(item: ProviderRefreshHint) -> None:
        if item.source_key.provider_id == "claude":
            raise RuntimeError("monitor busy")
        applied.append(item)

    picky = DeferredRefreshHints(refuse)
    picky.note(hint("claude", "e" * 32))
    picky.note(hint("codex", "f" * 32))
    assert picky.flush() == 2
    assert applied[-1].event_token == EventToken("f" * 32)
    with pytest.raises(ValueError):
        DeferredRefreshHints(None)  # type: ignore[arg-type]
