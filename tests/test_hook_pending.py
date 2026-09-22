"""The shim's ``<provider>.pending.jsonl`` fallback and the daemon's drain."""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

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
    # that line is still a delivery, not a rejection.
    assert request_from_pending_line(_line(ppid_start=-1.0)).ppid_start is None
    # queued_at_ms (milliseconds) arrives as the request's epoch; lines from
    # an older shim, or with a nonsense stamp, simply have none.
    assert request_from_pending_line(_line(queued_at_ms=1790078400250)).queued_at_epoch == 1790078400.25
    assert request_from_pending_line(_line()).queued_at_epoch is None
    assert request_from_pending_line(_line(queued_at_ms=True)).queued_at_epoch is None
    assert request_from_pending_line(_line(queued_at_ms="soon")).queued_at_epoch is None
    assert request_from_pending_line(_line(queued_at_ms=-5)).queued_at_epoch is None


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


def test_a_spooled_payload_replays_with_its_queued_time_and_wakes_the_monitor_only_while_fresh(
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
    # A live delivery is stamped on arrival and always refreshes.
    assert set(live) == {"refresh_hint_handler"}
    assert fresh["logged_at"] == hook.hook_logged_at(now - 60.0) and fresh["refresh"] is True
    assert stale["logged_at"] == hook.hook_logged_at(now - PENDING_REPLAY_HORIZON_SECONDS - 60.0)
    assert stale["refresh"] is False
    for bad in (True, float("nan"), float("inf"), 0.0, -1.0, "1790078400"):
        with pytest.raises(ValueError):
            request(bad)  # type: ignore[arg-type]
