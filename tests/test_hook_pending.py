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


def test_drain_submits_in_file_order_and_removes_the_files(tmp_path: Path) -> None:
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


def test_drain_survives_a_submit_that_raises(tmp_path: Path) -> None:
    (tmp_path / f"claude{PENDING_SUFFIX}").write_text(_line() + "\n" + _line() + "\n")
    calls = []

    def submit(request):
        calls.append(request)
        if len(calls) == 1:
            raise RuntimeError("ingress closed")

    assert drain_pending_hooks(submit, state_dir=tmp_path, log_path_for=lambda p: f"/logs/{p}.jsonl") == 1
    assert len(calls) == 2
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
