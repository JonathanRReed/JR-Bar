from __future__ import annotations

import io
import json
import socket
import stat
from pathlib import Path

import pytest

from jrbar import hook_client
from jrbar.hook_ingress_protocol import (
    HOOK_INGRESS_SOCKET_NAME,
    MAX_HOOK_INGRESS_PAYLOAD_BYTES,
    HookIngressDisposition,
    HookIngressRequest,
    candidate_hook_ingress_socket_paths,
    decode_hook_ingress_request,
    decode_hook_ingress_response,
    encode_hook_ingress_request,
    encode_hook_ingress_response,
    submit_hook_ingress,
)


class _FakeSocket:
    def __init__(self, response: bytes | BaseException) -> None:
        self.response = response
        self.timeout: float | None = None
        self.connected: str | None = None
        self.sent = b""
        self.shutdown_how: int | None = None
        self.closed = False

    def settimeout(self, timeout: float) -> None:
        self.timeout = timeout

    def connect(self, path: str) -> None:
        self.connected = path
        if isinstance(self.response, BaseException):
            raise self.response

    def sendall(self, payload: bytes) -> None:
        self.sent += payload

    def shutdown(self, how: int) -> None:
        self.shutdown_how = how

    def recv(self, _maximum: int) -> bytes:
        assert isinstance(self.response, bytes)
        return self.response

    def close(self) -> None:
        self.closed = True


class _ReceiveFailureSocket(_FakeSocket):
    def __init__(self) -> None:
        super().__init__(b"")

    def recv(self, _maximum: int) -> bytes:
        raise TimeoutError("acknowledgement delayed")


def _request(payload: str = "{}") -> HookIngressRequest:
    return HookIngressRequest("claude", "/tmp/state/claude.jsonl", payload)


def test_request_repr_never_contains_payload__and_2_more() -> None:
    # --- scenario: request_repr_never_contains_payload
    request = _request('{"prompt":"private body"}')

    assert "private body" not in repr(request)

    # --- scenario: request_rejects_invalid_outer_values
    for provider, log_path, payload in [
        ("unknown", "/tmp/state/unknown.jsonl", "{}"),
        ("claude", "relative.jsonl", "{}"),
        ("claude", "/tmp/state/claude\x00.jsonl", "{}"),
        ("claude", "/tmp/state/claude.jsonl", "x" * (MAX_HOOK_INGRESS_PAYLOAD_BYTES + 1)),
    ]:
        with pytest.raises(ValueError, match="invalid hook ingress request"):
            HookIngressRequest(provider, log_path, payload)

    # --- scenario: protocol_round_trip_preserves_escaped_json_without_outer_copy
    payload = '{"tool_input":{"command":"printf \\\"a\\\\nb\\\""}}\n'
    request = _request(payload)

    encoded = encode_hook_ingress_request(request)
    decoded = decode_hook_ingress_request(encoded)

    assert decoded == request
    assert decoded is not request



def test_protocol_rejects_truncated_duplicate_and_unknown_headers__and_1_more() -> None:
    # --- scenario: protocol_rejects_truncated_duplicate_and_unknown_headers
    encoded = encode_hook_ingress_request(_request())
    magic_size = encoded.index(b"{")
    header_end = encoded.index(b"}", magic_size) + 1
    header = json.loads(encoded[magic_size:header_end])

    assert decode_hook_ingress_request(encoded[:-1]) is None
    duplicate = encoded[:magic_size] + b'{"log_path":"/tmp/a","log_path":"/tmp/b","provider":"claude","version":1}' + encoded[header_end:]
    assert decode_hook_ingress_request(duplicate) is None
    header["extra"] = True
    changed = json.dumps(header, separators=(",", ":")).encode()
    unknown = encoded[:magic_size] + changed + encoded[header_end:]
    assert decode_hook_ingress_request(unknown) is None

    # --- scenario: response_tokens_are_exact_and_round_trip
    for disposition in [
        HookIngressDisposition.ACCEPTED,
        HookIngressDisposition.REFUSED_FULL,
        HookIngressDisposition.REFUSED_CLOSED,
        HookIngressDisposition.REFUSED_INVALID,
    ]:
        encoded = encode_hook_ingress_response(disposition)
        assert encoded.endswith(b"\n")
        assert decode_hook_ingress_response(encoded) is disposition
        assert decode_hook_ingress_response(encoded + b"extra") is HookIngressDisposition.UNAVAILABLE



def test_candidate_socket_paths_try_xdg_then_standard_without_duplicates(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    home = tmp_path / "home"
    xdg = tmp_path / "xdg"
    home.mkdir()
    xdg.mkdir()
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("XDG_STATE_HOME", str(xdg))

    assert candidate_hook_ingress_socket_paths() == (
        xdg / "jrbar" / HOOK_INGRESS_SOCKET_NAME,
        home / ".local" / "state" / "jrbar" / HOOK_INGRESS_SOCKET_NAME,
    )

    monkeypatch.setenv("XDG_STATE_HOME", str(home / ".local" / "state"))
    assert candidate_hook_ingress_socket_paths() == (
        home / ".local" / "state" / "jrbar" / HOOK_INGRESS_SOCKET_NAME,
    )


def test_submit_uses_one_tight_timeout_and_stops_after_explicit_response(
    tmp_path: Path,
) -> None:
    target = tmp_path / HOOK_INGRESS_SOCKET_NAME
    target.touch(mode=0o600)
    target.chmod(stat.S_IRUSR | stat.S_IWUSR)
    fake = _FakeSocket(encode_hook_ingress_response(HookIngressDisposition.ACCEPTED))

    result = submit_hook_ingress(
        _request(),
        socket_path=target,
        timeout_seconds=0.03,
        socket_factory=lambda *_args: fake,
        require_socket_leaf=False,
    )

    assert result is HookIngressDisposition.ACCEPTED
    assert fake.timeout == 0.03
    assert fake.connected == str(target)
    assert fake.shutdown_how == socket.SHUT_WR
    assert decode_hook_ingress_request(fake.sent) == _request()
    assert fake.closed


def test_submit_returns_unavailable_without_leaking_exception_text(tmp_path: Path) -> None:
    target = tmp_path / HOOK_INGRESS_SOCKET_NAME
    fake = _FakeSocket(OSError("private path detail"))

    result = submit_hook_ingress(
        _request(),
        socket_path=target,
        socket_factory=lambda *_args: fake,
        require_socket_leaf=False,
    )

    assert result is HookIngressDisposition.UNAVAILABLE
    assert fake.closed


def test_submit_falls_back_after_connected_submission_loses_ack(
    tmp_path: Path,
) -> None:
    """A lost ack after connect is AMBIGUOUS: the ingress may have queued
    the request, but the hook cannot tell -- so the client re-processes
    through the dedupe-checked synchronous path. Worst case is a
    suppressed duplicate; the alternative is a silently dropped event."""
    target = tmp_path / HOOK_INGRESS_SOCKET_NAME
    fake = _ReceiveFailureSocket()

    disposition = submit_hook_ingress(
        _request(),
        socket_path=target,
        socket_factory=lambda *_args: fake,
        require_socket_leaf=False,
    )
    fallback: list[object] = []
    result = hook_client.run_hook_client(
        "claude",
        Path("/tmp/state/claude.jsonl"),
        "{}",
        submit=lambda _request_value: disposition,
        fallback=lambda *_args: fallback.append(object()),
        spool=lambda *_args: pytest.fail("an unproven admission was spooled"),
    )

    assert disposition is HookIngressDisposition.SUBMISSION_AMBIGUOUS
    assert result == 0
    assert len(fallback) == 1
    assert fake.sent
    assert fake.closed


def test_client_falls_back_when_admission_is_unproven__and_2_more() -> None:
    # --- scenario: client_falls_back_when_admission_is_unproven
    for disposition in [
        HookIngressDisposition.UNAVAILABLE,
        HookIngressDisposition.SUBMISSION_AMBIGUOUS,
    ]:
        fallback: list[tuple[str, Path, str]] = []

        assert (
            hook_client.run_hook_client(
                "claude",
                Path("/tmp/state/claude.jsonl"),
                '{"hook_event_name":"Stop"}',
                submit=lambda _request_value: disposition,
                fallback=lambda provider, path, payload: fallback.append((provider, path, payload)),
                spool=lambda *_args: pytest.fail("an unproven admission was spooled"),
            )
            == 0
        )

        assert fallback == [
            ("claude", Path("/tmp/state/claude.jsonl"), '{"hook_event_name":"Stop"}')
        ]

    # --- scenario: client_rejects_oversized_payload_without_fallback
    fallback: list[object] = []

    result = hook_client.run_hook_client(
        "claude",
        Path("/tmp/state/claude.jsonl"),
        "x" * (MAX_HOOK_INGRESS_PAYLOAD_BYTES + 1),
        submit=lambda _request_value: pytest.fail("invalid request reached ingress"),
        fallback=lambda *_args: fallback.append(object()),
        spool=lambda *_args: fallback.append(object()),
    )

    assert result == 0
    assert fallback == []

    # --- scenario: client_spools_a_refusal_and_never_processes_it_out_of_order
    """The daemon's FIFO is the order events count in. A refused payload
    processed here would land ahead of everything the full queue still
    holds; spooled, the drain replays it behind them. The default spool
    writes the shim's line and never loads the processing path."""
    for disposition in [
        HookIngressDisposition.ACCEPTED,
        HookIngressDisposition.REFUSED_FULL,
        HookIngressDisposition.REFUSED_CLOSED,
        HookIngressDisposition.REFUSED_INVALID,
    ]:
        fallback: list[object] = []
        spooled: list[tuple[str, Path, str]] = []

        result = hook_client.run_hook_client(
            "claude",
            Path("/tmp/state/claude.jsonl"),
            "{}",
            submit=lambda _request_value: disposition,
            fallback=lambda *_args: fallback.append(object()),
            spool=lambda provider, path, payload: spooled.append((provider, path, payload)),
        )

        assert result == 0
        assert fallback == []
        refused = disposition in (HookIngressDisposition.REFUSED_FULL, HookIngressDisposition.REFUSED_CLOSED)
        assert spooled == ([("claude", Path("/tmp/state/claude.jsonl"), "{}")] if refused else [])

    from jrbar import hook as hook_module
    from jrbar.hook_pending import pending_hook_files
    from jrbar.state_paths import default_state_dir

    pending = default_state_dir() / "claude.pending.jsonl"
    pending.unlink(missing_ok=True)
    processed: list[object] = []
    original = hook_module.process_hook_payload
    hook_module.process_hook_payload = lambda *args, **kwargs: processed.append(args)
    try:
        assert (
            hook_client.run_hook_client(
                "claude",
                Path("/tmp/state/claude.jsonl"),
                '{"hook_event_name":"Stop","session_id":"refused"}',
                submit=lambda _request_value: HookIngressDisposition.REFUSED_FULL,
            )
            == 0
        )
        assert processed == []
        assert pending in pending_hook_files()
        rows = [json.loads(line) for line in pending.read_text().splitlines()]
        assert [(row["provider"], row["payload"]) for row in rows] == [
            ("claude", '{"hook_event_name":"Stop","session_id":"refused"}')
        ]
        assert "ppid" not in rows[0]
    finally:
        hook_module.process_hook_payload = original
        pending.unlink(missing_ok=True)



def test_main_reads_stdin_once_and_cursor_always_returns_json__and_2_more(monkeypatch: pytest.MonkeyPatch,) -> None:
    # --- scenario: main_reads_stdin_once_and_cursor_always_returns_json
    class _Buffer(io.BytesIO):
        reads = 0

        def read(self, *args, **kwargs):
            self.reads += 1
            return super().read(*args, **kwargs)

    class _Input:
        def __init__(self, value: bytes) -> None:
            self.buffer = _Buffer(value)

    source = _Input(b'{"hook_event_name":"stop"}')
    output = io.StringIO()
    seen: list[str] = []
    monkeypatch.setattr(hook_client.sys, "stdin", source)
    monkeypatch.setattr(hook_client.sys, "stdout", output)
    monkeypatch.setattr(
        hook_client,
        "run_hook_client",
        lambda provider, path, payload: seen.append(f"{provider}:{path}:{payload}") or 0,
    )

    assert hook_client.main(["--provider", "cursor", "--log", "/tmp/cursor.jsonl"]) == 0

    assert source.buffer.reads == 1
    assert seen == ['cursor:/tmp/cursor.jsonl:{"hook_event_name":"stop"}']
    assert output.getvalue() == "{}\n"

    # --- scenario: main_bounds_stdin_before_client_admission
    monkeypatch.undo()
    class _Buffer(io.BytesIO):
        def __init__(self, value: bytes) -> None:
            super().__init__(value)
            self.read_sizes: list[int] = []

        def read(self, size: int = -1, *args, **kwargs):
            self.read_sizes.append(size)
            return super().read(size, *args, **kwargs)

    class _Input:
        def __init__(self, value: bytes) -> None:
            self.buffer = _Buffer(value)

    source = _Input(b"x" * (MAX_HOOK_INGRESS_PAYLOAD_BYTES + 2))
    monkeypatch.setattr(hook_client.sys, "stdin", source)
    monkeypatch.setattr(
        hook_client,
        "run_hook_client",
        lambda *_args: pytest.fail("oversized stdin reached client admission"),
    )

    assert hook_client.hook_client_main("claude", Path("/tmp/claude.jsonl")) == 0

    assert source.buffer.read_sizes == [MAX_HOOK_INGRESS_PAYLOAD_BYTES + 1]

    # --- scenario: main_caps_multibyte_stdin_by_encoded_bytes_before_admission
    monkeypatch.undo()
    class _Buffer(io.BytesIO):
        def __init__(self, value: bytes) -> None:
            super().__init__(value)
            self.read_sizes: list[int] = []

        def read(self, size: int = -1, *args, **kwargs):
            self.read_sizes.append(size)
            return super().read(size, *args, **kwargs)

    class _Input:
        def __init__(self, value: bytes) -> None:
            self.buffer = _Buffer(value)

    source = _Input("é".encode() * MAX_HOOK_INGRESS_PAYLOAD_BYTES)
    monkeypatch.setattr(hook_client.sys, "stdin", source)
    monkeypatch.setattr(
        hook_client,
        "run_hook_client",
        lambda *_args: pytest.fail("multibyte oversized stdin reached client admission"),
    )

    assert hook_client.hook_client_main("claude", Path("/tmp/claude.jsonl")) == 0

    assert source.buffer.read_sizes == [MAX_HOOK_INGRESS_PAYLOAD_BYTES + 1]



def test_main_rejects_invalid_utf8_before_admission(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class _Input:
        buffer = io.BytesIO(b"\xff")

    monkeypatch.setattr(hook_client.sys, "stdin", _Input())
    monkeypatch.setattr(
        hook_client,
        "run_hook_client",
        lambda *_args: pytest.fail("invalid UTF-8 reached client admission"),
    )

    assert hook_client.hook_client_main("claude", Path("/tmp/claude.jsonl")) == 0
