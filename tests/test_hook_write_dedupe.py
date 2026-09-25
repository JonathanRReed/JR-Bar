from __future__ import annotations

from types import SimpleNamespace

import pytest

from jrbar import hook


def test_hook_log_main_appends_and_notifies_once_per_event_token(
    tmp_path,
    monkeypatch,
) -> None:
    log_path = tmp_path / "grok.jsonl"
    record = object()
    hint = SimpleNamespace(event_token=SimpleNamespace(value="same-event"))
    writes: list[object] = []
    hints: list[object] = []

    monkeypatch.setattr(
        hook,
        "routed_hook_payload",
        lambda provider, configured_path, payload, logged_at=None: ("grok", log_path, {}),
    )
    monkeypatch.setattr(hook, "_normalized_hook_record", lambda provider, line: record)
    monkeypatch.setattr(hook, "_refresh_hint_for_record", lambda provider, value: hint)
    monkeypatch.setattr(
        hook,
        "write_normalized_hook_record",
        lambda path, value: writes.append(value),
    )
    monkeypatch.setattr(
        hook,
        "send_refresh_hint",
        lambda value, event_name=None: hints.append(value),
    )
    monkeypatch.setattr(hook.sys, "stdin", SimpleNamespace(read=lambda: "{}"))

    assert hook.hook_log_main("grok", log_path) == 0
    assert hook.hook_log_main("grok", log_path) == 0

    assert writes == [record]
    assert hints == [hint]
    assert hook.hook_dedupe_path(log_path).is_file()


def test_process_hook_payload_owns_no_stdio_and_reports_written(
    tmp_path,
    monkeypatch,
) -> None:
    log_path = tmp_path / "grok.jsonl"
    record = object()
    hint = SimpleNamespace(event_token=SimpleNamespace(value="event"))
    writes: list[object] = []
    hints: list[object] = []
    monkeypatch.setattr(
        hook,
        "routed_hook_payload",
        lambda provider, configured_path, payload, logged_at=None: ("grok", log_path, {}),
    )
    monkeypatch.setattr(hook, "_normalized_hook_record", lambda provider, line: record)
    monkeypatch.setattr(hook, "_refresh_hint_for_record", lambda provider, value: hint)
    monkeypatch.setattr(
        hook,
        "write_normalized_hook_record",
        lambda path, value: writes.append(value),
    )
    monkeypatch.setattr(
        hook,
        "send_refresh_hint",
        lambda value, event_name=None: hints.append(value),
    )
    monkeypatch.setattr(
        hook.sys,
        "stdin",
        SimpleNamespace(read=lambda: (_ for _ in ()).throw(AssertionError("stdin read"))),
    )

    outcome = hook.process_hook_payload("grok", log_path, "{}")

    assert outcome is hook.HookProcessingOutcome.WRITTEN
    assert writes == [record]
    assert hints == [hint]


def test_process_hook_payload_applies_in_process_hint_before_return(
    tmp_path,
    monkeypatch,
) -> None:
    log_path = tmp_path / "grok.jsonl"
    record = object()
    hint = SimpleNamespace(event_token=SimpleNamespace(value="event"))
    lifecycle: list[str] = []
    monkeypatch.setattr(
        hook,
        "routed_hook_payload",
        lambda provider, configured_path, payload, logged_at=None: ("grok", log_path, {}),
    )
    monkeypatch.setattr(hook, "_normalized_hook_record", lambda provider, line: record)
    monkeypatch.setattr(hook, "_refresh_hint_for_record", lambda provider, value: hint)
    monkeypatch.setattr(
        hook,
        "write_normalized_hook_record",
        lambda path, value: lifecycle.append("written"),
    )
    monkeypatch.setattr(
        hook,
        "send_refresh_hint",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            AssertionError("app-owned ingress must not use the hint socket")
        ),
    )

    outcome = hook.process_hook_payload(
        "grok",
        log_path,
        "{}",
        refresh_hint_handler=lambda value: lifecycle.append(
            "applied" if value is hint else "wrong-hint"
        ),
    )
    lifecycle.append("returned")

    assert outcome is hook.HookProcessingOutcome.WRITTEN
    assert lifecycle == ["written", "applied", "returned"]


def test_process_hook_payload_propagates_failure_for_ingress_receipt(
    tmp_path,
    monkeypatch,
) -> None:
    record = object()
    monkeypatch.setattr(
        hook,
        "routed_hook_payload",
        lambda provider, configured_path, payload, logged_at=None: ("claude", configured_path, {}),
    )
    monkeypatch.setattr(hook, "_normalized_hook_record", lambda provider, line: record)
    monkeypatch.setattr(hook, "_refresh_hint_for_record", lambda provider, value: None)
    monkeypatch.setattr(
        hook,
        "write_normalized_hook_record",
        lambda path, value: (_ for _ in ()).throw(OSError("private detail")),
    )

    with pytest.raises(OSError, match="private detail"):
        hook.process_hook_payload("claude", tmp_path / "claude.jsonl", "{}")


def test_a_replay_past_the_horizon_is_logged_with_its_queued_time_but_wakes_nothing(
    tmp_path,
    monkeypatch,
) -> None:
    log_path = tmp_path / "grok.jsonl"
    record = object()
    hint = SimpleNamespace(event_token=SimpleNamespace(value="event"))
    routed: list[str | None] = []
    writes: list[object] = []
    monkeypatch.setattr(
        hook,
        "routed_hook_payload",
        lambda provider, configured_path, payload, logged_at=None: (
            routed.append(logged_at) or ("grok", log_path, {})
        ),
    )
    monkeypatch.setattr(hook, "_normalized_hook_record", lambda provider, line: record)
    monkeypatch.setattr(hook, "_refresh_hint_for_record", lambda provider, value: hint)
    monkeypatch.setattr(
        hook,
        "write_normalized_hook_record",
        lambda path, value: writes.append(value),
    )
    monkeypatch.setattr(
        hook,
        "send_refresh_hint",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("stale replay sent a hint")),
    )

    def handler(_value):
        raise AssertionError("stale replay woke the monitor")

    outcome = hook.process_hook_payload(
        "grok",
        log_path,
        "{}",
        refresh_hint_handler=handler,
        logged_at="2026-09-22T12:00:00.000000Z",
        refresh=False,
    )

    assert outcome is hook.HookProcessingOutcome.WRITTEN
    assert routed == ["2026-09-22T12:00:00.000000Z"]
    assert writes == [record]
    # Still deduplicated: a second replay of the same event writes nothing.
    assert (
        hook.process_hook_payload("grok", log_path, "{}", refresh=False)
        is hook.HookProcessingOutcome.DUPLICATE
    )
    assert writes == [record]


def test_hook_logged_at_formats_a_queued_epoch_like_a_live_stamp() -> None:
    assert hook.hook_logged_at(1790078400.25) == "2026-09-22T12:00:00.250000Z"
    line = hook.format_hook_payload(
        "claude", '{"hook_event_name":"Stop"}', logged_at=hook.hook_logged_at(1790078400.25)
    )
    assert line["logged_at"] == "2026-09-22T12:00:00.250000Z"
    assert len(hook.hook_logged_at()) == len("2026-09-22T12:00:00.250000Z")


# --- the daemon's live ingress: resident dedupe, one fsync, no reread ----------


def _claude_payload(session: str, event: str) -> str:
    import json

    body = {
        "hook_event_name": event,
        "session_id": session,
        "cwd": "/tmp/synthetic",
        "transcript_path": f"/tmp/synthetic/{session}.jsonl",
    }
    if event == "UserPromptSubmit":
        body["prompt"] = "synthetic prompt"
    return json.dumps(body)


def test_the_live_ingress_writes_once_and_the_monitor_takes_its_own_line__and_2_more(
    tmp_path,
    monkeypatch,
) -> None:
    # --- scenario: the_live_ingress_writes_once_and_the_monitor_takes_its_own_line
    """Per hook the daemon rewrote and fsynced the dedupe file, appended
    and fsynced the log, then reopened the log it had just written (which
    the virus scanner holds up). Now the dedupe lives in memory, the append
    is the one fsync, and the monitor takes the line it was handed."""
    import os

    from jrbar import private_io, reconcile_cursors
    from jrbar.collector import LiveAgentMonitor
    from jrbar.hook_dedupe import ResidentDeduplicators

    log_path = tmp_path / "claude.jsonl"
    monitor = LiveAgentMonitor()
    deduplicators = ResidentDeduplicators()
    reads: list[object] = []
    real_slice = reconcile_cursors.read_private_log_slice

    def counting_slice(path, **kwargs):
        reads.append(path)
        return real_slice(path, **kwargs)

    monkeypatch.setattr(reconcile_cursors, "read_private_log_slice", counting_slice)
    fsyncs: list[int] = []
    real_fsync = os.fsync
    monkeypatch.setattr(os, "fsync", lambda fd: fsyncs.append(fd) or real_fsync(fd))

    def send(session: str, event: str):
        return hook.process_hook_payload(
            "claude",
            log_path,
            _claude_payload(session, event),
            appended_handler=lambda hint, appended: monitor.reconcile_appended_line(
                hint, appended, log_path=log_path
            ),
            deduplicator_for=deduplicators,
        )

    def modes() -> dict[str, str]:
        return {status.session_id: status.mode.value for status in monitor.snapshot().statuses}

    assert send("alpha", "SessionStart") is hook.HookProcessingOutcome.WRITTEN
    assert len(reads) == 1, "no cursor yet: the first line is read from the log"
    fsyncs.clear()
    assert send("alpha", "UserPromptSubmit") is hook.HookProcessingOutcome.WRITTEN
    assert len(reads) == 1, "the monitor took its own line without reopening the log"
    assert len(fsyncs) == 1, "the log append is the one fsync"
    assert modes()["alpha"] == "working"
    size = log_path.stat().st_size
    assert monitor._reconcile_log_cursors[next(iter(monitor._reconcile_log_cursors))][2] == size

    # --- scenario: a_line_someone_else_appended_first_is_read_from_the_log
    record = hook._normalized_hook_record("claude", {"hook_event_name": "SessionStart", "session_id": "beta", "cwd": "/tmp/synthetic"})
    private_io.append_private_text(
        log_path,
        __import__("json").dumps(
            hook.normalized_provider_record_to_payload(record), separators=(",", ":"), sort_keys=True
        )
        + "\n",
    )
    send("alpha", "Stop")
    assert len(reads) == 2, "a foreign line before ours: the log is reread"
    works = {work.key.work_id.value for work in monitor.operator_state.works}
    assert {"alpha", "beta"} <= works
    assert modes().get("alpha") == "completed"

    # --- scenario: a_repeat_is_caught_in_memory_and_another_writer_is_seen
    """The file stays the backing store: a token the standalone hook wrote
    is honoured, and the daemon's own tokens land in the file."""
    from jrbar.hook_dedupe import HookEventDeduplicator

    dedupe_path = hook.hook_dedupe_path(log_path)
    resident = deduplicators(dedupe_path)
    ran: list[str] = []
    assert resident.run_once("token-1", lambda: ran.append("1")) is True
    assert resident.run_once("token-1", lambda: ran.append("again")) is False
    standalone = HookEventDeduplicator(dedupe_path)
    assert "token-1" in standalone.tokens()
    assert standalone.run_once("token-2", lambda: ran.append("2")) is True
    assert resident.run_once("token-2", lambda: ran.append("dup")) is False
    assert ran == ["1", "2"]
    dedupe_path.unlink()
    assert resident.run_once("token-3", lambda: ran.append("3")) is True
    assert dedupe_path.is_file() and "token-3" in standalone.tokens()
    deduplicators.close()
