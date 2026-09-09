"""The serve endpoint: persisted truth, loopback, read-only."""

from __future__ import annotations

import json
import threading
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from sidepulse.local_api_contract import LocalAPIRequest, ReplayGuard
from sidepulse.product_identity import PRODUCT_DISPLAY_NAME
from sidepulse.provider_usage_store import default_provider_usage_state_path
from sidepulse.providers import default_state_dir
from sidepulse.serve import (
    _read_json,
    build_authenticated_local_api_response,
    build_serve_document,
    create_serve_server,
)

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


def _write_private_state(home: Path) -> None:
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
                "schema_version": 1,
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
                "schema_version": 2,
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
    from sidepulse import serve

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


def test_endpoint_serves_json_and_404s_elsewhere() -> None:
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


def test_status_endpoint_requires_bearer_authentication_by_default() -> None:
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


def test_status_endpoint_has_no_anonymous_default_even_without_a_token() -> None:
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


def test_cli_status_requires_token_unless_anonymous_compatibility_is_explicit(
    monkeypatch, capsys
) -> None:
    from sidepulse.cli import SERVE_ACCESS_TOKEN_ENV, build_sidepulse_parser, cmd_serve

    parser = build_sidepulse_parser()
    calls = []
    monkeypatch.setattr("sidepulse.serve.serve", lambda **kwargs: calls.append(kwargs))
    monkeypatch.delenv(SERVE_ACCESS_TOKEN_ENV, raising=False)

    assert cmd_serve(parser.parse_args(["serve"])) == 2
    assert SERVE_ACCESS_TOKEN_ENV in capsys.readouterr().err
    assert calls == []

    assert cmd_serve(parser.parse_args(["serve", "--allow-anonymous-status"])) == 0
    assert calls[-1]["allow_anonymous_status"] is True
    assert calls[-1]["status_access_token"] is None


def test_in_process_integrations_are_authenticated_and_only_reuse_redacted_projection(
    tmp_path: Path,
) -> None:
    _write_private_state(tmp_path)
    secret = b"local-integration-test-key"
    request = LocalAPIRequest(
        client_id="streamdeck",
        capability="agents.read",
        nonce="n-1",
        issued_at=1000.0,
        expires_at=1020.0,
    ).sign(secret)
    guard = ReplayGuard()

    response = build_authenticated_local_api_response(
        request.encode(),
        secret=secret,
        replay_guard=guard,
        home=tmp_path,
        now=1001.0,
    )
    response_document = json.loads(response.encode())

    assert response_document["capability"] == "agents.read"
    assert response_document["data"] == {
        "agents": build_serve_document(tmp_path)["agents"]
    }
    with pytest.raises(ValueError, match="replayed"):
        build_authenticated_local_api_response(
            request,
            secret=secret,
            replay_guard=guard,
            home=tmp_path,
            now=1001.0,
        )

    encoded = response.encode()
    assert all(sentinel.encode() not in encoded for sentinel in PRIVATE_SENTINELS)
