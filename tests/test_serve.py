"""The serve endpoint: persisted truth, loopback, read-only."""

from __future__ import annotations

import json
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import ClassVar

import pytest

from jrbar import serve
from jrbar.product_identity import PRODUCT_DISPLAY_NAME
from jrbar.provider_usage_store import default_provider_usage_state_path
from jrbar.providers import default_state_dir
from jrbar.serve import (
    _read_json,
    build_serve_document,
    create_serve_server,
)


@pytest.fixture(autouse=True)
def _clock_before_the_saved_windows_reset(monkeypatch: pytest.MonkeyPatch) -> None:
    """The saved windows below reset at 1500 and 2000; hold the quota
    summary's clock at 1200 so they are still running."""
    monkeypatch.setattr(serve, "_wall_clock", lambda: 1200.0)


PRIVATE_SENTINELS = (
    "PRIVATE_ACCOUNT_LABEL",
    "PRIVATE_ACTION_LABEL",
    "PRIVATE_COST",
    "PRIVATE_CREDIT",
    "PRIVATE_INCIDENT_TEXT",
    "PRIVATE_LANE_LABEL",
    "PRIVATE_MODEL_NAME",
    "PRIVATE_SOURCE_ID",
    "PRIVATE_SESSION_LABEL",
    "PRIVATE_WORK_ID",
    "PRIVATE_REQUEST_ID",
    "PRIVATE_MESSAGE_TEXT",
)


def _write_private_state(home: Path, *, usage_schema_version: int = 1) -> None:
    latest_path = default_state_dir(home) / "latest.json"
    latest_path.parent.mkdir(parents=True)
    latest_path.write_text(
        json.dumps(
            {
                "version": 2,
                "generation": 17,
                "last_clock": {"message": "PRIVATE_MESSAGE_TEXT"},
                "works": [
                    {
                        "key": {"work_id": "PRIVATE_WORK_ID"},
                        "lifecycle": "active",
                        "source_health": "healthy",
                        "source_freshness": "fresh",
                        "next_actor": "provider",
                        "safe_label": "PRIVATE_SESSION_LABEL",
                        "request_keys": [{"request_id": "PRIVATE_REQUEST_ID"}],
                        "timing_uncertain": False,
                    },
                    {
                        "lifecycle": "waiting",
                        "source_health": "partial",
                        "source_freshness": "stale",
                        "next_actor": "user",
                        "safe_label": "PRIVATE_SESSION_LABEL",
                        "timing_uncertain": True,
                    },
                ],
            }
        ),
        encoding="utf-8",
    )
    usage_path = default_provider_usage_state_path(home)
    usage_path.parent.mkdir(parents=True, exist_ok=True)
    usage_path.write_text(
        json.dumps(
            {
                "schema_version": usage_schema_version,
                "refreshed_at": 1000.0,
                "next_refresh_at": 1060.0,
                "snapshots": [
                    {
                        "provider_id": "claude",
                        "account_label": "PRIVATE_ACCOUNT_LABEL",
                        "observed_at": 999.0,
                        "state": "ready",
                        "reason_code": None,
                        "action_label": "PRIVATE_ACTION_LABEL",
                        "lanes": [
                            {
                                "provider_id": "claude",
                                "lane_id": "weekly",
                                "label": "PRIVATE_LANE_LABEL",
                                "remaining_percent": 25.5,
                                "reset_at": 2000.0,
                                "scope": "all",
                                "model": "PRIVATE_MODEL_NAME",
                                "feature": None,
                                "bindable": True,
                                "source_id": "PRIVATE_SOURCE_ID",
                            },
                            {
                                "provider_id": "claude",
                                "lane_id": "session",
                                "label": "PRIVATE_LANE_LABEL",
                                "remaining_percent": 80.0,
                                "reset_at": 1500.0,
                                "scope": "all",
                                "model": None,
                                "feature": None,
                                "bindable": True,
                                "source_id": "PRIVATE_SOURCE_ID",
                            },
                        ],
                        "input_tokens": 123,
                        "cached_input_tokens": 45,
                        "output_tokens": 67,
                        "model_count": 2,
                        "estimated_cost_usd": "PRIVATE_COST",
                        "cache_savings_usd": "PRIVATE_COST",
                        "credits_remaining": "PRIVATE_CREDIT",
                        "incident": "PRIVATE_INCIDENT_TEXT",
                    }
                ],
            }
        ),
        encoding="utf-8",
    )


def test_document_is_assembled_from_persisted_state() -> None:
    document = build_serve_document()
    assert document["schema_version"] == 2
    assert document["privacy"] == "redacted"
    assert "agents" in document and "usage" in document


def test_document_rebuilds_an_exact_redacted_public_schema(tmp_path: Path) -> None:
    _write_private_state(tmp_path)

    document = build_serve_document(tmp_path)

    assert document == {
        "schema_version": 2,
        "privacy": "redacted",
        "agents": {
            "generation": 17,
            "work_count": 2,
            "lifecycle_counts": {"active": 1, "waiting": 1},
            "next_actor_counts": {"provider": 1, "user": 1},
            "source_health_counts": {"healthy": 1, "partial": 1},
            "source_freshness_counts": {"fresh": 1, "stale": 1},
            "timing_uncertain_count": 1,
            "workers": {"work_count": 0, "lifecycle_counts": {}},
        },
        "usage": {
            "refreshed_at": 1000.0,
            "next_refresh_at": 1060.0,
            "providers": [
                {
                    "provider_id": "claude",
                    "observed_at": 999.0,
                    "state": "ready",
                    "quota": {
                        "window_count": 2,
                        "remaining_percent": 25.5,
                        "next_reset_at": 1500.0,
                    },
                }
            ],
        },
    }
    encoded = json.dumps(document, sort_keys=True)
    assert all(sentinel not in encoded for sentinel in PRIVATE_SENTINELS)


@pytest.mark.parametrize("version", [1, 2, 3])
def test_every_store_version_the_loader_reads_is_served(tmp_path: Path, version: int) -> None:
    """The saved usage file is written at the store's current version (3
    today); the endpoint used to accept only 1, so its usage was always null."""
    _write_private_state(tmp_path, usage_schema_version=version)

    usage = build_serve_document(tmp_path)["usage"]

    assert usage is not None
    assert [item["provider_id"] for item in usage["providers"]] == ["claude"]
    assert usage["providers"][0]["quota"]["remaining_percent"] == 25.5
    assert all(
        sentinel not in json.dumps(usage, sort_keys=True) for sentinel in PRIVATE_SENTINELS
    )


@pytest.mark.parametrize("version", [0, 4, 99, "3", 3.0, True, None])
def test_an_unknown_or_mistyped_store_version_is_not_served(tmp_path: Path, version: object) -> None:
    _write_private_state(tmp_path, usage_schema_version=1)
    path = default_provider_usage_state_path(tmp_path)
    document = json.loads(path.read_text(encoding="utf-8"))
    document["schema_version"] = version
    path.write_text(json.dumps(document), encoding="utf-8")

    assert build_serve_document(tmp_path)["usage"] is None


def test_future_persisted_schemas_fail_closed(tmp_path: Path) -> None:
    latest_path = default_state_dir(tmp_path) / "latest.json"
    latest_path.parent.mkdir(parents=True)
    latest_path.write_text(
        json.dumps(
            {
                "version": 3,
                "generation": 1,
                "works": [{"safe_label": "PRIVATE_SESSION_LABEL"}],
            }
        ),
        encoding="utf-8",
    )
    usage_path = default_provider_usage_state_path(tmp_path)
    usage_path.parent.mkdir(parents=True, exist_ok=True)
    usage_path.write_text(
        json.dumps(
            {
                "schema_version": 99,
                "snapshots": [{"account_label": "PRIVATE_ACCOUNT_LABEL"}],
            }
        ),
        encoding="utf-8",
    )

    document = build_serve_document(tmp_path)

    assert document["agents"] is None
    assert document["usage"] is None
    assert all(
        sentinel not in json.dumps(document, sort_keys=True)
        for sentinel in PRIVATE_SENTINELS
    )


_PARENT_KEY = {
    "version": {"major": 1, "minor": 0},
    "provider_id": "claude",
    "adapter_id": "hooks",
    "source_instance_id": "global",
    "capability_id": "live_agent_events",
    "work_id": "PRIVATE_WORK_ID",
}


def _work(lifecycle: str, next_actor: str, **extra) -> dict:
    return {
        "lifecycle": lifecycle,
        "source_health": "healthy",
        "source_freshness": "fresh",
        "next_actor": next_actor,
        "safe_label": "PRIVATE_SESSION_LABEL",
        "timing_uncertain": False,
        **extra,
    }


def _serve_agents(home: Path, works: list[dict]) -> dict:
    latest_path = default_state_dir(home) / "latest.json"
    latest_path.parent.mkdir(parents=True, exist_ok=True)
    latest_path.write_text(
        json.dumps({"version": 2, "generation": 3, "works": works}),
        encoding="utf-8",
    )
    document = build_serve_document(home)
    assert all(
        sentinel not in json.dumps(document, sort_keys=True)
        for sentinel in PRIVATE_SENTINELS
    )
    return document["agents"]


def test_the_counts_are_main_sessions_and_a_blocked_worker_is_its_own_number(
    tmp_path: Path,
) -> None:
    agents = _serve_agents(
        tmp_path,
        [
            _work("active", "provider", parent_key=None),
            *(
                _work("waiting", "user", parent_key=_PARENT_KEY)
                for _ in range(3)
            ),
        ],
    )

    # The Stream Deck key reads these two: one working, none waiting.
    assert agents["work_count"] == 1
    assert agents["lifecycle_counts"] == {"active": 1}
    assert agents["next_actor_counts"] == {"provider": 1}
    assert agents["source_health_counts"] == {"healthy": 1}
    assert agents["source_freshness_counts"] == {"fresh": 1}
    # The waiting sub-agents stay visible, as numbers and nothing more.
    assert agents["workers"] == {"work_count": 3, "lifecycle_counts": {"waiting": 3}}


def test_a_waiting_main_still_counts_as_waiting(tmp_path: Path) -> None:
    agents = _serve_agents(
        tmp_path,
        [
            _work("waiting", "user", parent_key=None),
            _work("active", "provider", parent_key=_PARENT_KEY),
        ],
    )

    assert agents["lifecycle_counts"] == {"waiting": 1}
    assert agents["next_actor_counts"] == {"user": 1}
    assert agents["workers"] == {"work_count": 1, "lifecycle_counts": {"active": 1}}


def test_a_work_without_a_parent_key_is_a_main_session(tmp_path: Path) -> None:
    # Older persisted files carry no parent_key at all.
    agents = _serve_agents(
        tmp_path,
        [
            _work("active", "provider"),
            _work("waiting", "user", parent_key=None),
        ],
    )

    assert agents["work_count"] == 2
    assert agents["lifecycle_counts"] == {"active": 1, "waiting": 1}
    assert agents["workers"] == {"work_count": 0, "lifecycle_counts": {}}


def test_a_malformed_parent_key_is_rejected_not_guessed(tmp_path: Path) -> None:
    agents = _serve_agents(
        tmp_path,
        [
            _work("active", "provider"),
            _work("waiting", "user", parent_key="PRIVATE_WORK_ID"),
            _work("waiting", "user", parent_key=["PRIVATE_WORK_ID"]),
            _work("waiting", "user", parent_key={}),
            _work("waiting", "user", parent_key=True),
            _work("waiting", "user", parent_key=0),
        ],
    )

    # Neither a main session nor a worker: the entry is left out, like any
    # other value the allowlist does not recognise.
    assert agents["work_count"] == 1
    assert agents["lifecycle_counts"] == {"active": 1}
    assert agents["workers"] == {"work_count": 0, "lifecycle_counts": {}}


def test_unknown_public_values_are_omitted(tmp_path: Path) -> None:
    _write_private_state(tmp_path)
    latest_path = default_state_dir(tmp_path) / "latest.json"
    latest = json.loads(latest_path.read_text(encoding="utf-8"))
    latest["works"] = [
        {
            "lifecycle": "future-private-state",
            "source_health": "future-private-health",
            "source_freshness": "future-private-freshness",
            "next_actor": "future-private-actor",
            "safe_label": "PRIVATE_SESSION_LABEL",
            "timing_uncertain": False,
        }
    ]
    latest_path.write_text(json.dumps(latest), encoding="utf-8")
    usage_path = default_provider_usage_state_path(tmp_path)
    usage = json.loads(usage_path.read_text(encoding="utf-8"))
    usage["snapshots"] = [
        {
            "provider_id": "private-provider",
            "account_label": "PRIVATE_ACCOUNT_LABEL",
            "observed_at": 1000.0,
            "state": "future-private-state",
            "lanes": [],
        }
    ]
    usage_path.write_text(json.dumps(usage), encoding="utf-8")

    document = build_serve_document(tmp_path)

    assert document["agents"]["work_count"] == 0
    assert document["usage"]["providers"] == []
    assert all(
        sentinel not in json.dumps(document, sort_keys=True)
        for sentinel in PRIVATE_SENTINELS
    )


def test_oversized_state_files_fail_closed(tmp_path: Path, monkeypatch) -> None:
    from jrbar import serve

    _write_private_state(tmp_path)
    monkeypatch.setattr(serve, "_MAX_STATE_BYTES", 1)

    document = build_serve_document(tmp_path)

    assert document["agents"] is None
    assert document["usage"] is None


def test_symlinked_state_files_fail_closed(tmp_path: Path) -> None:
    target = tmp_path / "private-target.json"
    target.write_text(
        json.dumps({"safe_label": "PRIVATE_SESSION_LABEL"}), encoding="utf-8"
    )
    latest_path = default_state_dir(tmp_path) / "latest.json"
    latest_path.parent.mkdir(parents=True)
    latest_path.symlink_to(target)
    usage_path = default_provider_usage_state_path(tmp_path)
    usage_path.parent.mkdir(parents=True, exist_ok=True)
    usage_path.symlink_to(target)

    assert _read_json(latest_path) is None
    assert _read_json(usage_path) is None
    document = build_serve_document(tmp_path)
    assert document["agents"] is None
    assert document["usage"] is None


@pytest.mark.parametrize("section", ["agents", "usage"])
def test_deeply_nested_saved_state_preserves_the_other_section_and_recovers(
    tmp_path: Path, section: str
) -> None:
    _write_private_state(tmp_path)
    baseline = build_serve_document(tmp_path)
    path = (default_state_dir(tmp_path) / "latest.json" if section == "agents"
            else default_provider_usage_state_path(tmp_path))
    original = path.read_bytes()
    depth = 10_000
    path.write_text("[" * depth + "0" + "]" * depth, encoding="utf-8")

    document = build_serve_document(tmp_path)

    assert document[section] is None
    other = "usage" if section == "agents" else "agents"
    assert document[other] == baseline[other]
    path.write_bytes(original)
    assert build_serve_document(tmp_path) == baseline


@pytest.mark.parametrize("field", [
    "refreshed_at", "next_refresh_at", "observed_at", "remaining_percent", "reset_at",
])
def test_unrepresentable_saved_numbers_do_not_discard_valid_status(
    tmp_path: Path, field: str
) -> None:
    _write_private_state(tmp_path)
    baseline = build_serve_document(tmp_path)
    path = default_provider_usage_state_path(tmp_path)
    usage = json.loads(path.read_text(encoding="utf-8"))
    target = usage
    if field == "observed_at":
        target = usage["snapshots"][0]
    elif field in {"remaining_percent", "reset_at"}:
        target = usage["snapshots"][0]["lanes"][0]
    target[field] = 10 ** 400
    path.write_text(json.dumps(usage), encoding="utf-8")

    document = build_serve_document(tmp_path)

    assert document["agents"] == baseline["agents"]
    if field in {"refreshed_at", "next_refresh_at"}:
        assert document["usage"][field] is None
        assert document["usage"]["providers"] == baseline["usage"]["providers"]
    elif field == "observed_at":
        assert document["usage"]["providers"] == []
    else:
        assert document["usage"]["providers"][0]["quota"] == {
            "window_count": 1, "remaining_percent": 80.0, "next_reset_at": 1500.0,
        }


@pytest.mark.parametrize("corruption", ["deep_json", "huge_timestamp"])
def test_authenticated_status_survives_unusable_state_and_recovers(
    tmp_path: Path, corruption: str
) -> None:
    _write_private_state(tmp_path)
    baseline = build_serve_document(tmp_path)
    path = default_provider_usage_state_path(tmp_path)
    original = path.read_bytes()
    if corruption == "deep_json":
        depth = 10_000
        path.write_text("[" * depth + "0" + "]" * depth, encoding="utf-8")
    else:
        usage = json.loads(original)
        usage["snapshots"][0]["observed_at"] = 10 ** 400
        path.write_text(json.dumps(usage), encoding="utf-8")
    token = b"synthetic-status-recovery-token"
    server = create_serve_server(port=0, home=tmp_path, status_access_token=token)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    request = urllib.request.Request(
        f"http://127.0.0.1:{server.server_address[1]}/status.json",
        headers={"Authorization": f"Bearer {token.decode('ascii')}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            assert response.status == 200
            document = json.load(response)
        assert document["agents"] == baseline["agents"]
        if corruption == "deep_json":
            assert document["usage"] is None
        else:
            assert document["usage"]["providers"] == []
        assert all(sentinel not in json.dumps(document) for sentinel in PRIVATE_SENTINELS)
        path.write_bytes(original)
        with urllib.request.urlopen(request, timeout=5) as response:
            assert response.status == 200
            assert json.load(response) == baseline
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
    assert not thread.is_alive()


def test_endpoint_serves_json_and_404s_elsewhere__and_2_more() -> None:
    # --- scenario: endpoint_serves_json_and_404s_elsewhere
    server = create_serve_server(port=0, allow_anonymous_status=True)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/status.json", timeout=5
        ) as response:
            assert response.status == 200
            assert response.headers["Server"].startswith(
                f"{PRODUCT_DISPLAY_NAME} "
            )
            payload = json.loads(response.read().decode("utf-8"))
            assert payload["schema_version"] == 2
            assert payload["privacy"] == "redacted"
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/etc/passwd", timeout=5)
            raise AssertionError("unexpected 200")
        except urllib.error.HTTPError as error:
            assert error.code == 404
    finally:
        server.shutdown()
        server.server_close()

    # --- scenario: status_endpoint_requires_bearer_authentication_by_default
    token = b"local-status-access-token"
    server = create_serve_server(port=0, status_access_token=token)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with pytest.raises(urllib.error.HTTPError) as missing:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/status.json", timeout=5)
        assert missing.value.code == 401

        wrong = urllib.request.Request(
            f"http://127.0.0.1:{port}/status.json",
            headers={"Authorization": "Bearer wrong"},
        )
        with pytest.raises(urllib.error.HTTPError) as invalid:
            urllib.request.urlopen(wrong, timeout=5)
        assert invalid.value.code == 401

        authenticated = urllib.request.Request(
            f"http://127.0.0.1:{port}/status.json",
            headers={"Authorization": f"Bearer {token.decode('ascii')}"},
        )
        with urllib.request.urlopen(authenticated, timeout=5) as response:
            assert response.status == 200
    finally:
        server.shutdown()
        server.server_close()

    # --- scenario: status_endpoint_has_no_anonymous_default_even_without_a_token
    server = create_serve_server(port=0)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with pytest.raises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/status.json", timeout=5)
        assert raised.value.code == 401
    finally:
        server.shutdown()
        server.server_close()



@pytest.mark.parametrize(
    ("host_header", "expected"),
    [
        ("evil.example", 403),
        ("evil.example:{port}", 403),
        ("127.0.0.1.evil.example:{port}", 403),
        ("192.168.1.20:{port}", 403),
        ("127.0.0.1:{port}", 200),
        ("localhost:{port}", 200),
        ("[::1]:{port}", 200),
        ("localhost", 200),
    ],
)
def test_a_foreign_host_header_is_refused_before_anything_is_served(
    host_header: str, expected: int
) -> None:
    """DNS rebinding: a page on a hostile name that resolves to 127.0.0.1
    reaches this socket with its own name in Host. Only the loopback names
    are ours, whatever the route and whether or not the status is anonymous."""
    import http.client

    server = create_serve_server(port=0, allow_anonymous_status=True)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        connection.putrequest("GET", "/status.json", skip_host=True)
        connection.putheader("Host", host_header.format(port=port))
        connection.endheaders()
        response = connection.getresponse()
        body = response.read()
        connection.close()
        assert response.status == expected
        if expected == 403:
            assert b"schema_version" not in body
    finally:
        server.shutdown()
        server.server_close()


def test_cli_status_requires_token_unless_anonymous_compatibility_is_explicit(
    monkeypatch, capsys
) -> None:
    from jrbar.cli import SERVE_ACCESS_TOKEN_ENV, build_jrbar_parser, cmd_serve

    parser = build_jrbar_parser()
    calls = []
    monkeypatch.setattr("jrbar.serve.serve", lambda **kwargs: calls.append(kwargs))
    monkeypatch.delenv(SERVE_ACCESS_TOKEN_ENV, raising=False)

    assert cmd_serve(parser.parse_args(["serve"])) == 2
    assert SERVE_ACCESS_TOKEN_ENV in capsys.readouterr().err
    assert calls == []

    assert cmd_serve(parser.parse_args(["serve", "--allow-anonymous-status"])) == 0
    assert calls[-1]["allow_anonymous_status"] is True
    assert calls[-1]["status_access_token"] is None


def test_a_peer_cannot_pin_serve_threads__and_1_more(monkeypatch) -> None:
    import socket

    from jrbar import serve as serve_module

    def closed_by_server(connection: socket.socket, timeout: float = 5.0) -> bool:
        connection.settimeout(timeout)
        try:
            return connection.recv(1024) == b""
        except ConnectionResetError:
            return True

    # --- scenario: a half-sent request gives its thread up at the handler timeout
    assert serve_module._ServeHandler.timeout == serve_module.SERVE_HANDLER_TIMEOUT_SECONDS == 5.0
    monkeypatch.setattr(serve_module._ServeHandler, "timeout", 0.2)
    server = create_serve_server(port=0, allow_anonymous_status=True)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        trickler = socket.create_connection(("127.0.0.1", port), timeout=5)
        trickler.sendall(b"GET /status.js")
        assert closed_by_server(trickler)
        trickler.close()
    finally:
        server.shutdown()
        server.server_close()

    # --- scenario: past the connection cap a new one is closed, and a slot comes back when one ends
    monkeypatch.setattr(serve_module._ServeHandler, "timeout", 5.0)
    monkeypatch.setattr(serve_module, "MAX_SERVE_CONNECTIONS", 2)
    server = create_serve_server(port=0, allow_anonymous_status=True)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        idle = [socket.create_connection(("127.0.0.1", port), timeout=5) for _ in range(2)]
        refused = socket.create_connection(("127.0.0.1", port), timeout=5)
        assert closed_by_server(refused)
        refused.close()
        for connection in idle:
            connection.close()
        deadline = time.monotonic() + 5.0
        while True:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/status.json", timeout=5) as response:
                    assert response.status == 200
                break
            except (urllib.error.URLError, ConnectionError):
                # The idle handlers are still noticing their peers left.
                assert time.monotonic() < deadline
    finally:
        server.shutdown()
        server.server_close()


def test_serve_command_refuses_a_bad_or_taken_port_without_a_traceback(monkeypatch, capsys) -> None:
    import socket

    import pytest

    from jrbar import cli

    parser = cli.build_parser()
    with pytest.raises(SystemExit) as refused:
        parser.parse_args(["serve", "--port", "99999"])
    assert refused.value.code == 2
    assert "0-65535" in capsys.readouterr().err

    monkeypatch.setenv(cli.SERVE_ACCESS_TOKEN_ENV, "synthetic-token-" + "x" * 24)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as taken:
        taken.bind(("127.0.0.1", 0))
        taken.listen(1)
        port = taken.getsockname()[1]
        args = parser.parse_args(["serve", "--port", str(port)])
        assert cli.cmd_serve(args) == 1
    err = capsys.readouterr().err
    assert f"port {port}" in err and "--port" in err


def test_serve_command_says_how_long_the_access_token_must_be(monkeypatch, capsys) -> None:
    from jrbar import cli

    monkeypatch.setenv(cli.SERVE_ACCESS_TOKEN_ENV, "short")
    args = cli.build_parser().parse_args(["serve", "--port", "0"])
    assert cli.cmd_serve(args) == 2
    assert "at least 24 characters" in capsys.readouterr().err


class _ManualTimer:
    """A timer that fires when the test says so."""

    created: ClassVar[list[_ManualTimer]] = []
    armed: ClassVar[threading.Event] = threading.Event()

    def __init__(self, seconds, function, args=()):
        self.seconds, self.function, self.args = seconds, function, args
        self.daemon = False
        self.cancelled = False
        _ManualTimer.created.append(self)

    def start(self) -> None:
        _ManualTimer.armed.set()

    def cancel(self) -> None:
        self.cancelled = True

    def fire(self) -> None:
        if not self.cancelled:
            self.function(*self.args)


def test_a_client_that_never_finishes_its_headers_is_hung_up_on_at_the_deadline() -> None:
    import socket
    import threading

    from jrbar.request_deadline import RequestDeadlines
    from jrbar.serve import ServeConfiguration, _ServeHandler, _ServeServer

    _ManualTimer.created = []
    _ManualTimer.armed.clear()
    server = _ServeServer(
        ("127.0.0.1", 0),
        _ServeHandler,
        ServeConfiguration(status_access_token=b"t" * 32),
        deadlines=RequestDeadlines(timer_factory=_ManualTimer),
    )
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
    thread.start()
    try:
        with socket.create_connection(server.server_address, timeout=10.0) as slow:
            slow.sendall(b"GET /status.json HTTP/1.1\r\nHost: x\r\n")  # headers never end
            assert _ManualTimer.armed.wait(timeout=5.0), "the connection armed a deadline"
            _ManualTimer.created[0].fire()
            slow.settimeout(5.0)
            try:
                response = slow.recv(4096)
            except ConnectionResetError:
                response = b""
            assert response == b"", "the server closed the connection"

        # A normal request disarms its deadline once the headers are read.
        _ManualTimer.created.clear()
        quick = socket.create_connection(server.server_address, timeout=10.0)
        quick.sendall(b"GET /nope HTTP/1.0\r\n\r\n")
        quick.settimeout(5.0)
        assert quick.recv(4096).startswith(b"HTTP/1.")
        quick.close()
        assert _ManualTimer.created and _ManualTimer.created[0].cancelled
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5.0)
