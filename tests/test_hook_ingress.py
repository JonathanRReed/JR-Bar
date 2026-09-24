from __future__ import annotations

import json
import os
import socket
import stat
import tempfile
import threading
import time
from pathlib import Path

import pytest

from jrbar import hook_client
from jrbar.hook_ingress import (
    HookIngressOutcome,
    HookIngressReceipt,
    HookIngressService,
)
from jrbar.hook_ingress_protocol import (
    HookIngressDisposition,
    HookIngressRequest,
    submit_hook_ingress,
)


def _request(name: str) -> HookIngressRequest:
    return HookIngressRequest(
        "claude",
        "/tmp/state/claude.jsonl",
        json.dumps({"hook_event_name": "PreToolUse", "session_id": name}),
    )


def test_fifo_preserves_acceptance_order_with_one_worker__and_2_more() -> None:
    # --- scenario: fifo_preserves_acceptance_order_with_one_worker
    first_started = threading.Event()
    release_first = threading.Event()
    completed: list[str] = []
    worker_ids: set[int] = set()

    def process(request: HookIngressRequest) -> str:
        name = json.loads(request.payload_text)["session_id"]
        worker_ids.add(threading.get_ident())
        if name == "first":
            first_started.set()
            assert release_first.wait(1.0)
        completed.append(name)
        return name

    service = HookIngressService(process=process, maximum_accepted=4)
    assert service.submit(_request("first")) is HookIngressDisposition.ACCEPTED
    assert first_started.wait(1.0)
    assert service.submit(_request("second")) is HookIngressDisposition.ACCEPTED
    assert service.submit(_request("third")) is HookIngressDisposition.ACCEPTED

    release_first.set()
    assert service.wait_idle(timeout_seconds=1.0)

    assert completed == ["first", "second", "third"]
    assert len(worker_ids) == 1
    assert service.close(timeout_seconds=1.0)

    # --- scenario: bound_counts_running_plus_pending_and_records_full_refusal
    started = threading.Event()
    release = threading.Event()
    receipts: list[HookIngressReceipt] = []

    def process(_request_value: HookIngressRequest) -> None:
        started.set()
        assert release.wait(1.0)

    service = HookIngressService(
        process=process,
        maximum_accepted=2,
        receipt_handler=receipts.append,
        rejection_recorder=receipts.append,
    )
    assert service.submit(_request("first")) is HookIngressDisposition.ACCEPTED
    assert started.wait(1.0)
    assert service.submit(_request("second")) is HookIngressDisposition.ACCEPTED
    assert service.submit(_request("third")) is HookIngressDisposition.REFUSED_FULL

    snapshot = service.snapshot()
    assert snapshot.running
    assert snapshot.pending_count == 1
    assert snapshot.accepted_outstanding == 2
    assert snapshot.refused_full == 1
    refusal = next(receipt for receipt in receipts if receipt.outcome is HookIngressOutcome.REFUSED_FULL)
    assert "third" not in repr(refusal)

    release.set()
    assert service.close(timeout_seconds=1.0)

    # --- scenario: processing_failure_has_content_free_receipt_and_does_not_stop_fifo
    completed: list[str] = []
    receipts: list[HookIngressReceipt] = []

    def process(request: HookIngressRequest) -> None:
        name = json.loads(request.payload_text)["session_id"]
        if name == "fail-private-session":
            raise RuntimeError("private failure detail")
        completed.append(name)

    service = HookIngressService(
        process=process,
        receipt_handler=receipts.append,
        rejection_recorder=receipts.append,
    )
    service.submit(_request("fail-private-session"))
    service.submit(_request("after"))

    assert service.wait_idle(timeout_seconds=1.0)

    assert completed == ["after"]
    failed = next(receipt for receipt in receipts if receipt.outcome is HookIngressOutcome.FAILED)
    assert failed.error_code == "processing_failed"
    assert "private" not in repr(failed)
    assert service.snapshot().failed == 1
    assert service.close(timeout_seconds=1.0)



def test_close_drains_every_accepted_request_and_then_refuses_new_work__and_2_more() -> None:
    # --- scenario: close_drains_every_accepted_request_and_then_refuses_new_work
    completed: list[str] = []
    service = HookIngressService(
        process=lambda request: completed.append(json.loads(request.payload_text)["session_id"]),
    )
    for name in ("one", "two", "three"):
        assert service.submit(_request(name)) is HookIngressDisposition.ACCEPTED

    assert service.close(timeout_seconds=1.0)

    assert completed == ["one", "two", "three"]
    assert service.submit(_request("late")) is HookIngressDisposition.REFUSED_CLOSED
    snapshot = service.snapshot()
    assert not snapshot.accepting
    assert not snapshot.running
    assert snapshot.pending_count == 0
    assert not snapshot.thread_alive

    # --- scenario: close_timeout_records_running_and_pending_as_not_drained
    started = threading.Event()
    release = threading.Event()
    receipts: list[HookIngressReceipt] = []

    def process(_request_value: HookIngressRequest) -> None:
        started.set()
        release.wait(2.0)

    service = HookIngressService(
        process=process,
        maximum_accepted=3,
        receipt_handler=receipts.append,
        rejection_recorder=receipts.append,
    )
    service.submit(_request("running-private"))
    assert started.wait(1.0)
    service.submit(_request("pending-private"))

    assert not service.close(timeout_seconds=0.01)

    timed_out = [
        receipt
        for receipt in receipts
        if receipt.outcome is HookIngressOutcome.REJECTED_SHUTDOWN_TIMEOUT
    ]
    assert [receipt.sequence for receipt in timed_out] == [1, 2]
    assert "private" not in repr(timed_out)
    assert service.snapshot().shutdown_timeout == 2

    release.set()
    assert service.wait_stopped(timeout_seconds=1.0)

    # --- scenario: rejection_recorder_failure_never_breaks_admission_contract
    started = threading.Event()
    release = threading.Event()
    service = HookIngressService(
        process=lambda _request_value: (started.set(), release.wait(1.0)),
        maximum_accepted=1,
        rejection_recorder=lambda _receipt: (_ for _ in ()).throw(OSError("private")),
    )
    assert service.submit(_request("first")) is HookIngressDisposition.ACCEPTED
    assert started.wait(1.0)

    assert service.submit(_request("second")) is HookIngressDisposition.REFUSED_FULL

    release.set()
    assert service.close(timeout_seconds=1.0)



def test_socket_admits_on_private_same_uid_path_and_processes_request__and_2_more() -> None:
    # --- scenario: socket_admits_on_private_same_uid_path_and_processes_request
    with tempfile.TemporaryDirectory(prefix="jrbar-hi-", dir="/tmp") as directory:
        socket_path = Path(directory) / "hook-ingress.sock"
        completed = threading.Event()
        seen: list[HookIngressRequest] = []
        service = HookIngressService(
            process=lambda request: (seen.append(request), completed.set()),
            socket_path=socket_path,
        )
        assert service.start() == socket_path
        try:
            mode = stat.S_IMODE(socket_path.lstat().st_mode)
            assert mode == 0o600
            assert socket_path.lstat().st_uid == os.geteuid()

            assert (
                submit_hook_ingress(
                    _request("socket"),
                    socket_path=socket_path,
                    timeout_seconds=0.5,
                )
                is HookIngressDisposition.ACCEPTED
            )
            assert completed.wait(1.0)
            assert seen == [_request("socket")]
        finally:
            assert service.close(timeout_seconds=1.0)
        assert not socket_path.exists()

    # --- scenario: lost_ack_after_acceptance_falls_back_through_dedupe
    ack_started = threading.Event()
    release_ack = threading.Event()

    class SlowAckIngress(HookIngressService):
        @staticmethod
        def _send_response(connection, disposition) -> None:
            ack_started.set()
            assert release_ack.wait(1.0)
            HookIngressService._send_response(connection, disposition)

    with tempfile.TemporaryDirectory(prefix="jrbar-hi-", dir="/tmp") as directory:
        socket_path = Path(directory) / "hook-ingress.sock"
        completed = threading.Event()
        processed: list[HookIngressRequest] = []
        fallback: list[object] = []
        disposition: list[HookIngressDisposition] = []

        def submit_slow_ack(
            request: HookIngressRequest,
        ) -> HookIngressDisposition:
            result = submit_hook_ingress(
                request,
                socket_path=socket_path,
                timeout_seconds=0.02,
            )
            disposition.append(result)
            return result

        service = SlowAckIngress(
            process=lambda request: (processed.append(request), completed.set()),
            socket_path=socket_path,
        )
        service.start()
        try:
            assert (
                hook_client.run_hook_client(
                    "claude",
                    Path("/tmp/state/claude.jsonl"),
                    _request("slow-ack").payload_text,
                    submit=submit_slow_ack,
                    fallback=lambda *_args: fallback.append(object()),
                )
                == 0
            )
            assert disposition == [HookIngressDisposition.SUBMISSION_AMBIGUOUS]
            assert ack_started.wait(1.0)
            # The ingress DID accept it and will still process it; the
            # client cannot observe that, so it also runs the synchronous
            # fallback -- the dedupe-checked write path makes the double
            # delivery a suppressed duplicate rather than a double record.
            assert len(fallback) == 1
            release_ack.set()
            assert completed.wait(1.0)
            assert len(processed) == 1
            assert service.snapshot().accepted == 1
        finally:
            assert service.close(timeout_seconds=1.0)

    # --- scenario: a_trickling_connection_never_serializes_later_hooks
    """One read-to-EOF client used to hold the sole ingress slot for as
    long as it kept the stream alive; each connection now gets its own
    bounded worker, so a peer that never finishes cannot starve hooks."""
    with tempfile.TemporaryDirectory(prefix="jrbar-hi-", dir="/tmp") as directory:
        socket_path = Path(directory) / "hook-ingress.sock"
        completed = threading.Event()
        service = HookIngressService(
            process=lambda _request_value: completed.set(),
            socket_path=socket_path,
        )
        service.start()
        try:
            trickler = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            trickler.connect(str(socket_path))
            # A stream that starts but never finishes: the old code read
            # it to EOF on the accept thread and nothing else was served.
            trickler.sendall(b"J")
            try:
                assert (
                    submit_hook_ingress(
                        _request("concurrent"),
                        socket_path=socket_path,
                        timeout_seconds=0.5,
                    )
                    is HookIngressDisposition.ACCEPTED
                )
                assert completed.wait(1.0)
            finally:
                trickler.close()
        finally:
            assert service.close(timeout_seconds=1.0)



def test_trickling_connection_dies_at_the_whole_connection_deadline(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Keeping each recv under the per-read timeout must NOT keep a
    connection alive forever: the deadline covers the whole connection."""
    monkeypatch.setattr(
        "jrbar.hook_ingress.HOOK_INGRESS_CONNECTION_DEADLINE_SECONDS", 0.4
    )
    with tempfile.TemporaryDirectory(prefix="jrbar-hi-", dir="/tmp") as directory:
        socket_path = Path(directory) / "hook-ingress.sock"
        service = HookIngressService(
            process=lambda _request_value: None,
            socket_path=socket_path,
        )
        service.start()
        try:
            trickler = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            trickler.settimeout(0.2)
            trickler.connect(str(socket_path))
            closed = False
            start = time.monotonic()
            # Drip one byte faster than the per-recv timeout so the ONLY
            # thing that can cut this connection is the whole-connection
            # deadline. The recv timeout doubles as the pacing: every
            # iteration waits ~0.1s while the server still holds us.
            while time.monotonic() - start < 3.0:
                try:
                    trickler.sendall(b"x")
                except OSError:
                    closed = True
                    break
                try:
                    if trickler.recv(1) == b"":
                        closed = True
                        break
                except TimeoutError:
                    pass
            assert closed, "a trickling connection outlived its deadline"
            trickler.close()
        finally:
            assert service.close(timeout_seconds=1.0)


def test_socket_rejects_cross_uid_peer_as_ambiguous_without_processing() -> None:
    with tempfile.TemporaryDirectory(prefix="jrbar-hi-", dir="/tmp") as directory:
        socket_path = Path(directory) / "hook-ingress.sock"
        seen: list[HookIngressRequest] = []
        service = HookIngressService(
            process=seen.append,
            socket_path=socket_path,
            peer_uid_reader=lambda _connection: os.geteuid() + 1,
        )
        service.start()
        try:
            assert (
                submit_hook_ingress(
                    _request("foreign"),
                    socket_path=socket_path,
                    timeout_seconds=0.2,
                )
                is HookIngressDisposition.SUBMISSION_AMBIGUOUS
            )
            assert service.close(timeout_seconds=1.0)
            assert seen == []
        finally:
            service.close(timeout_seconds=1.0)


def test_default_rejection_record_contains_no_payload_or_path(
    tmp_path: Path,
) -> None:
    rejection_path = tmp_path / "rejections.jsonl"
    started = threading.Event()
    release = threading.Event()
    service = HookIngressService(
        process=lambda _request_value: (started.set(), release.wait(1.0)),
        maximum_accepted=1,
        rejection_path=rejection_path,
    )
    service.submit(_request("running"))
    assert started.wait(1.0)
    assert service.submit(_request("private-payload")) is HookIngressDisposition.REFUSED_FULL

    stored = rejection_path.read_text()
    document = json.loads(stored)
    assert document["reason"] == HookIngressOutcome.REFUSED_FULL.value
    assert document["provider"] == "claude"
    assert frozenset(document) == {
        "recorded_at",
        "provider",
        "reason",
        "sequence",
        "version",
    }
    assert "private-payload" not in stored
    assert "/tmp/state" not in stored

    release.set()
    assert service.close(timeout_seconds=1.0)


def test_direct_and_queued_paths_write_the_same_minimized_record(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from jrbar.hook import process_hook_payload

    # This contract compares the durable minimized records. Refresh delivery
    # is covered by the app-owned handler tests below and must not make this
    # byte-equivalence check depend on whichever installed app owns the live
    # event socket while the source suite runs.
    monkeypatch.setattr("jrbar.hook.send_refresh_hint", lambda *_args, **_kwargs: False)

    payload = json.dumps(
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "same-session",
            "request_id": "same-request",
            "logged_at": "2026-08-29T12:00:00Z",
            "prompt": "private prompt",
            "tool_input": {"command": "private command"},
        }
    )
    direct = tmp_path / "direct.jsonl"
    queued = tmp_path / "queued.jsonl"
    assert process_hook_payload("claude", direct, payload) is not None
    service = HookIngressService()
    assert (
        service.submit(HookIngressRequest("claude", str(queued), payload))
        is HookIngressDisposition.ACCEPTED
    )
    assert service.close(timeout_seconds=1.0)

    assert direct.read_bytes() == queued.read_bytes()
    stored = direct.read_text()
    assert "private prompt" not in stored
    assert "private command" not in stored


def test_close_waits_until_app_owned_refresh_handler_finishes(
    tmp_path: Path,
) -> None:
    from jrbar.hook import process_hook_payload

    payload = json.dumps(
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "shutdown-tail",
            "request_id": "permission:shutdown-tail",
            "logged_at": "2026-08-29T12:00:00Z",
        }
    )
    log_path = tmp_path / "claude.jsonl"
    refresh_started = threading.Event()
    release_refresh = threading.Event()
    close_started = threading.Event()
    timeline: list[str] = []

    def apply_refresh(_hint: object) -> None:
        timeline.append("refresh_started")
        refresh_started.set()
        assert release_refresh.wait(1.0)
        timeline.append("refresh_finished")

    def process(request: HookIngressRequest) -> object:
        return process_hook_payload(
            request.provider,
            Path(request.log_path),
            request.payload_text,
            refresh_hint_handler=apply_refresh,
        )

    service = HookIngressService(process=process)
    assert (
        service.submit(HookIngressRequest("claude", str(log_path), payload))
        is HookIngressDisposition.ACCEPTED
    )
    assert refresh_started.wait(1.0)

    close_result: list[bool] = []

    def close_service() -> None:
        timeline.append("close_started")
        close_started.set()
        close_result.append(service.close(timeout_seconds=1.0))
        timeline.append("close_finished")

    close_thread = threading.Thread(target=close_service)
    close_thread.start()
    assert close_started.wait(1.0)

    release_refresh.set()
    close_thread.join(timeout=1.0)
    assert not close_thread.is_alive()
    assert close_result == [True]
    assert timeline == [
        "refresh_started",
        "close_started",
        "refresh_finished",
        "close_finished",
    ]
    assert log_path.is_file()


def test_waits_reject_invalid_timeouts() -> None:
    for timeout in [-1, float("nan"), True, None]:
        service = HookIngressService(process=lambda _request_value: None)
        with pytest.raises(ValueError, match="invalid hook ingress timeout"):
            service.wait_idle(timeout_seconds=timeout)  # type: ignore[arg-type]
        with pytest.raises(ValueError, match="invalid hook ingress timeout"):
            service.close(timeout_seconds=timeout)  # type: ignore[arg-type]


def test_the_queue_holds_128_hooks_and_16_mb_of_payloads__and_1_more() -> None:
    # --- scenario: the default bound is 128 outstanding and 16 MB of payload
    """32 filled in ten seconds of parallel agents (2026-09-22) and every
    refusal past it was lost. The count bound is 128 now, and the payload
    bytes it holds are bounded too, so 128 large payloads cannot pile up."""
    from jrbar.hook_ingress import (
        MAX_HOOK_INGRESS_ACCEPTED,
        MAX_HOOK_INGRESS_OUTSTANDING_BYTES,
    )

    assert MAX_HOOK_INGRESS_ACCEPTED == 128
    assert MAX_HOOK_INGRESS_OUTSTANDING_BYTES == 16 * 1024 * 1024
    release = threading.Event()
    started = threading.Event()

    def process(_request_value: HookIngressRequest) -> None:
        started.set()
        assert release.wait(5.0)

    service = HookIngressService(process=process, rejection_recorder=lambda _receipt: None)
    try:
        dispositions = [service.submit(_request(f"s{index}")) for index in range(129)]
        assert dispositions[:128] == [HookIngressDisposition.ACCEPTED] * 128
        assert dispositions[128] is HookIngressDisposition.REFUSED_FULL
    finally:
        release.set()
        assert service.close(timeout_seconds=5.0)

    release.clear()
    big = "x" * 400
    service = HookIngressService(
        process=process,
        maximum_outstanding_bytes=1000,
        rejection_recorder=lambda _receipt: None,
    )

    def large(name: str) -> HookIngressRequest:
        return HookIngressRequest(
            "claude",
            "/tmp/state/claude.jsonl",
            json.dumps({"hook_event_name": "PreToolUse", "session_id": name, "body": big}),
        )

    try:
        assert service.submit(large("one")) is HookIngressDisposition.ACCEPTED
        assert started.wait(1.0)
        assert service.submit(large("two")) is HookIngressDisposition.ACCEPTED
        assert service.submit(large("three")) is HookIngressDisposition.REFUSED_FULL
        # A small one still fits under the byte bound.
        assert service.submit(_request("small")) is HookIngressDisposition.ACCEPTED
    finally:
        release.set()
        assert service.close(timeout_seconds=5.0)


    # --- scenario: the spool is drained as soon as a queue that refused is empty
    release.clear()
    cleared: list[int] = []
    told = threading.Event()
    sentinel = threading.Event()

    def process_until_sentinel(request: HookIngressRequest) -> None:
        if json.loads(request.payload_text)["session_id"] == "sentinel":
            sentinel.set()
        else:
            assert release.wait(5.0)

    def backlog_cleared() -> None:
        cleared.append(service.snapshot().pending_count)
        told.set()

    service = HookIngressService(
        process=process_until_sentinel,
        maximum_accepted=2,
        rejection_recorder=lambda _receipt: None,
        backlog_cleared=backlog_cleared,
    )
    try:
        assert service.submit(_request("first")) is HookIngressDisposition.ACCEPTED
        assert service.submit(_request("second")) is HookIngressDisposition.ACCEPTED
        assert service.submit(_request("third")) is HookIngressDisposition.REFUSED_FULL
        assert cleared == []
        release.set()
        assert told.wait(5.0)
        # Once, with nothing left queued ahead of the spooled payload.
        assert cleared == [0]
        # A queue that refused nothing since it was last empty says nothing:
        # the sentinel runs only after "fourth" has been checked.
        assert service.submit(_request("fourth")) is HookIngressDisposition.ACCEPTED
        assert service.submit(_request("sentinel")) is HookIngressDisposition.ACCEPTED
        assert sentinel.wait(5.0)
        assert cleared == [0]
    finally:
        assert service.close(timeout_seconds=5.0)
