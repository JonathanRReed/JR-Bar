"""A refused hook frame says why and for which agent, and nothing else:
a reason code, a known provider id and a length, never header or payload
text. Hooks doctor counts today's."""

from __future__ import annotations

import json
import struct
import time
from pathlib import Path

import pytest

from jrbar.hook_doctor import rejected_hook_frames, render_hook_doctor
from jrbar.hook_ingress_protocol import (
    HOOK_FRAME_REFUSALS,
    HookIngressRequest,
    decode_hook_ingress_request,
    encode_hook_ingress_request,
    explain_hook_ingress_refusal,
)

SECRET = "synthetic-private-prompt"


def frame(header: dict, body: str = "{}") -> bytes:
    encoded_header = json.dumps(header).encode()
    encoded_body = body.encode()
    return b"JRBARHOOK\x01" + struct.pack(">II", len(encoded_header), len(encoded_body)) + encoded_header + encoded_body


def good_header(**changes) -> dict:
    header = {"version": 1, "provider": "codex", "log_path": "/tmp/synthetic/codex.jsonl"}
    header.update(changes)
    return {key: value for key, value in header.items() if value is not None}


def test_the_frame_helper_builds_what_the_encoder_builds():
    request = HookIngressRequest("codex", "/tmp/synthetic/codex.jsonl", "{}")
    assert decode_hook_ingress_request(encode_hook_ingress_request(request)) == request
    assert decode_hook_ingress_request(frame(good_header())) is not None


@pytest.mark.parametrize("payload,reason,provider", [
    (b"GET / HTTP/1.1\r\n", "not_a_frame", None),
    (b"JRBARHOOK\x01\x00", "short_frame", None),
    (frame(good_header())[:-1], "bad_lengths", "codex"),
    (frame(good_header(version=99)), "wrong_version", "codex"),
    (frame(good_header(log_path=None)), "bad_fields", "codex"),
    (frame(good_header(ppid=1, decide_ms=50000)), "orphaned_decide", "codex"),
    (frame(good_header(provider="synthetic-unknown")), "bad_request", None),
])
def test_each_refusal_names_its_reason_and_a_known_provider(payload, reason, provider):
    assert decode_hook_ingress_request(payload) is None
    assert explain_hook_ingress_refusal(payload) == (reason, provider)
    assert reason in HOOK_FRAME_REFUSALS


def test_a_header_that_is_not_json_is_bad_header():
    header = b"{not json " + SECRET.encode()
    payload = b"JRBARHOOK\x01" + struct.pack(">II", len(header), 0) + header
    assert explain_hook_ingress_refusal(payload) == ("bad_header", None)


def test_an_unknown_provider_name_is_never_recorded():
    reason, provider = explain_hook_ingress_refusal(frame(good_header(provider=SECRET, version=99)))
    assert reason == "wrong_version"
    assert provider is None


def test_the_rejection_log_is_content_free(tmp_path: Path):
    from jrbar.hook_ingress import HookIngressService

    path = tmp_path / "rejections.jsonl"
    service = HookIngressService(process=lambda _request: None, rejection_path=path)
    payload = frame(good_header(version=99), body=json.dumps({"prompt": SECRET}))
    reason, provider = explain_hook_ingress_refusal(payload)
    service.refuse_invalid(reason, provider=provider, frame_bytes=len(payload))
    stored = path.read_text()
    row = json.loads(stored)
    assert row["detail"] == "wrong_version"
    assert row["provider"] == "codex"
    assert row["bytes"] == len(payload)
    assert SECRET not in stored and "/tmp/synthetic" not in stored


def write_log(directory: Path, rows: list[dict]) -> None:
    (directory / "hook-ingress-rejections.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))


def stamp(epoch: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def test_doctor_counts_today_and_names_the_newest_reason(tmp_path: Path):
    now = time.mktime((2026, 10, 27, 15, 0, 0, 0, 0, -1))
    write_log(tmp_path, [
        {"recorded_at": stamp(now - 3 * 86400), "reason": "refused_invalid", "provider": None},
        {"recorded_at": stamp(now - 3600), "reason": "refused_invalid", "detail": "bad_lengths", "provider": "claude"},
        {"recorded_at": stamp(now - 60), "reason": "refused_invalid", "detail": "wrong_version", "provider": "codex"},
    ])
    with (tmp_path / "hook-ingress-rejections.jsonl").open("a") as log:
        log.write("not json\n")
    summary = rejected_hook_frames(tmp_path, now=now)
    assert summary["today"] == 2
    assert summary["newest_detail"] == "wrong_version"
    assert summary["newest_provider"] == "codex"
    assert summary["sentence"] == ("2 hook events were refused today. "
                                   "The newest: the hook is from another JR-Bar version; reinstall hooks.")


def test_doctor_says_nothing_when_nothing_was_refused(tmp_path: Path):
    summary = rejected_hook_frames(tmp_path, now=1_800_000_000)
    assert summary == {"today": 0, "newest_at": None, "newest_detail": None, "newest_provider": None, "sentence": None}
    report = {"state_dir": "/tmp/x", "shim": None, "ingress_socket": {"path": "a", "answers": False},
              "core_socket": {"path": "b", "answers": False}, "pending": [], "providers": [], "rejected": summary}
    assert "refused hook events: none today" in render_hook_doctor(report)
