"""The CLIProxyAPI hub against a local fake of its management API.

The fake records every path and every api-call URL it is asked for, so
the tests can hold the hub to its promise: it lists accounts and reads
usage, and it never touches a reset or consume endpoint.
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from jrbar.cliproxy_hub import (
    HubClient,
    HubError,
    HubSource,
    LocalIdentities,
    collect_hub,
    instance_for,
    validated_hub_url,
)
from jrbar.provider_usage_platform import ProviderSourceState

NOW = 1_790_000_000.0
KEY = "mgmt-key-synthetic-0000"

AUTH_FILES = {
    "files": [
        {"id": "claude-work.json", "auth_index": "a1", "provider": "claude", "email": "work@example.com"},
        {"id": "claude-home.json", "auth_index": "a2", "provider": "claude", "email": "me@example.com"},
        {
            "id": "codex-pro.json",
            "auth_index": "a3",
            "provider": "codex",
            "email": "codex@example.com",
            "id_token": {"chatgpt_account_id": "acct-remote", "chatgpt_plan_type": "pro"},
        },
        {"id": "old.json", "auth_index": "a4", "provider": "claude", "email": "old@example.com", "disabled": True},
        {"id": "qwen.json", "auth_index": "a5", "provider": "qwen"},
    ]
}
CLAUDE_USAGE = {
    "five_hour": {"utilization": 12.0, "resets_at": "2026-09-21T16:00:00+00:00"},
    "seven_day": {"utilization": 35.0, "resets_at": "2026-09-27T16:00:00+00:00"},
    "seven_day_opus": None,
    "limits": [
        {"kind": "weekly_scoped", "group": "weekly", "percent": 80, "resets_at": "2026-09-27T16:00:00+00:00",
         "scope": {"model": {"id": None, "display_name": "Fable"}}}
    ],
}
CODEX_USAGE = {
    "plan_type": "pro",
    "rate_limit": {
        "primary_window": {"used_percent": 30, "reset_at": NOW + 5 * 86400, "limit_window_seconds": 604800},
        "secondary_window": None,
    },
}
CREDITS = {
    "credits": [
        {"id": "c1", "status": "available", "reset_type": "codex_rate_limits", "expires_at": "2026-12-31T00:00:00Z"},
        {"id": "c2", "status": "redeemed", "reset_type": "codex_rate_limits", "expires_at": "2026-12-31T00:00:00Z"},
    ]
}


class FakeHub:
    def __init__(self, *, auth_status: int = 200, account_status: int = 200) -> None:
        self.paths: list[str] = []
        self.calls: list[dict] = []
        self.keys: list[str | None] = []
        hub = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args) -> None:
                return

            def _send(self, status: int, document: object) -> None:
                body = json.dumps(document).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None:
                hub.paths.append(self.path)
                hub.keys.append(self.headers.get("Authorization"))
                if self.path.endswith("/auth-files"):
                    self._send(auth_status, AUTH_FILES if auth_status == 200 else {"error": "no"})
                else:
                    self._send(404, {"error": "not found"})

            def do_POST(self) -> None:
                hub.paths.append(self.path)
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length) or b"{}")
                if self.path.endswith("/api-call"):
                    hub.calls.append(body)
                    url = body.get("url", "")
                    if "rate-limit-reset-credits" in url:
                        self._send(200, {"status_code": 200, "body": json.dumps(CREDITS)})
                    elif "anthropic" in url:
                        payload = CLAUDE_USAGE
                        self._send(200, {"status_code": account_status, "body": json.dumps(payload)})
                    else:
                        self._send(200, {"status_code": account_status, "body": json.dumps(CODEX_USAGE)})
                else:
                    self._send(404, {"error": "not found"})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5.0)

    def assert_read_only(self) -> None:
        touched = " ".join(self.paths + [call.get("url", "") for call in self.calls]).lower()
        assert "consume" not in touched
        assert "reset-quota" not in touched
        assert "quota/reset" not in touched


@pytest.fixture
def hub():
    fake = FakeHub()
    try:
        yield fake
    finally:
        fake.close()


def settings(url: str, **changes) -> dict:
    return {"enabled": True, "url": url, "min_interval_seconds": 300, **changes}


def test_accounts_are_listed_and_read_without_ever_touching_a_reset(hub: FakeHub) -> None:
    snapshots = collect_hub(settings(hub.url), now=NOW, key_reader=lambda: KEY, identities=LocalIdentities())

    by_instance = {snapshot.source_instance_id: snapshot for snapshot in snapshots}
    assert set(by_instance) == {instance_for("a1"), instance_for("a2"), instance_for("a3")}
    work = by_instance[instance_for("a1")]
    assert work.provider_id == "claude" and work.account_label == "work@example.com"
    assert {lane.lane_id: lane.remaining_percent for lane in work.lanes if lane.bindable} == {
        "five-hour": 88.0,
        "weekly": 65.0,
    }
    assert {lane.source_id for lane in work.lanes} == {"cliproxy"}
    codex = by_instance[instance_for("a3")]
    assert codex.provider_id == "codex" and codex.account_plan == "pro"
    assert [(lane.lane_id, lane.bindable) for lane in codex.lanes] == [("weekly", True)]
    assert codex.reset_credits == 1
    # The proxy fills in its own token; the key is only ever the management one.
    assert set(hub.keys) == {f"Bearer {KEY}"}
    assert all(call["header"]["Authorization"] == "Bearer $TOKEN$" for call in hub.calls)
    # Disabled and unknown-provider accounts are never asked about.
    assert all(call["auth_index"] in {"a1", "a2", "a3"} for call in hub.calls)
    hub.assert_read_only()


def test_lanes_bind_only_for_the_known_windows(hub: FakeHub) -> None:
    snapshots = collect_hub(settings(hub.url), now=NOW, key_reader=lambda: KEY, identities=LocalIdentities())
    for snapshot in snapshots:
        for lane in snapshot.lanes:
            assert lane.bindable == (lane.lane_id in {"five-hour", "weekly"}), lane


def test_the_local_account_is_not_counted_twice(hub: FakeHub) -> None:
    mine = LocalIdentities(codex_account_id="acct-remote", claude_email="ME@example.com")

    snapshots = collect_hub(settings(hub.url), now=NOW, key_reader=lambda: KEY, identities=mine)

    assert {snapshot.source_instance_id for snapshot in snapshots} == {instance_for("a1")}
    assert all(call["auth_index"] == "a1" for call in hub.calls)


def test_a_non_loopback_url_is_refused_before_any_connection() -> None:
    for url in ("http://192.168.1.10:8317", "https://proxy.example.com", "http://127.0.0.1:8317/v0", "ftp://localhost"):
        assert validated_hub_url(url) is None
        [status] = collect_hub(
            settings(url),
            now=NOW,
            key_reader=lambda: pytest.fail("no key is read for a refused URL"),
            transport=lambda *_a, **_k: pytest.fail("no request for a refused URL"),
        )
        assert status.state is ProviderSourceState.ERROR
        assert status.reason_code == "cliproxy_url_not_loopback"
    assert validated_hub_url("http://localhost:8317/") == "http://localhost:8317"


def test_a_missing_key_is_needs_consent_and_asks_nothing(hub: FakeHub) -> None:
    [status] = collect_hub(settings(hub.url), now=NOW, key_reader=lambda: None)

    assert status.state is ProviderSourceState.NEEDS_CONSENT
    assert "credential set cliproxy" in status.action_label
    assert hub.paths == []


def test_a_rejected_key_is_needs_sign_in() -> None:
    fake = FakeHub(auth_status=401)
    try:
        [status] = collect_hub(settings(fake.url), now=NOW, key_reader=lambda: "wrong")
    finally:
        fake.close()
    assert status.state is ProviderSourceState.NEEDS_SIGN_IN
    assert status.reason_code == "cliproxy_key_rejected"


def test_a_signed_out_account_is_its_own_card() -> None:
    fake = FakeHub(account_status=401)
    try:
        snapshots = collect_hub(settings(fake.url), now=NOW, key_reader=lambda: KEY, identities=LocalIdentities())
    finally:
        fake.close()
    assert {snapshot.state for snapshot in snapshots} == {ProviderSourceState.NEEDS_SIGN_IN}
    fake.assert_read_only()


def test_the_client_refuses_reset_and_consume_outright() -> None:
    client = HubClient("http://127.0.0.1:1", KEY, transport=lambda *_a, **_k: pytest.fail("sent"))
    for path in ("reset-quota", "quota/reset", "plugins/x/quota/reset"):
        with pytest.raises(HubError):
            client._management("POST", path, {})
    from jrbar.cliproxy_hub import HubAccount

    account = HubAccount("a3", "codex", None, None, None)
    with pytest.raises(HubError):
        client.api_call(account, "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")


def test_off_means_no_request_and_the_interval_holds(hub: FakeHub) -> None:
    assert collect_hub({"enabled": False, "url": hub.url}, now=NOW, key_reader=lambda: KEY) == ()
    assert hub.paths == []

    current = {"cliproxy_hub": settings(hub.url)}
    source = HubSource(
        settings_loader=lambda: type("S", (), current)(),
        key_reader=lambda: KEY,
        identities=LocalIdentities,
    )
    first = source(NOW)
    asked = len(hub.paths)
    again = source(NOW + 120)
    assert again == first and len(hub.paths) == asked, "inside five minutes the last answer is served"
    source(NOW + 301)
    assert len(hub.paths) > asked


def test_the_management_key_can_be_stored_under_cliproxy(tmp_path: Path) -> None:
    from io import StringIO

    from jrbar.provider_management import CREDENTIAL_ACCOUNTS
    from jrbar.provider_usage_cli import main as providers_main

    assert CREDENTIAL_ACCOUNTS["cliproxy"] == ("management",)

    class Store:
        def __init__(self) -> None:
            self.saved: dict = {}

        def set(self, provider, account, secret):
            self.saved[(provider, account)] = secret

    store = Store()
    out = StringIO()
    code = providers_main(
        ["credential", "set", "cliproxy", "management", "--stdin"],
        stdin=StringIO(KEY + "\n"),
        stdout=out,
        credentials=store,
        home=tmp_path,
        settings_path=tmp_path / "provider-usage.json",
        consent_path=tmp_path / "consents.json",
        state_path=tmp_path / "state.json",
    )
    assert code == 0
    assert store.saved == {("cliproxy", "management"): KEY}
    assert "CLIProxyAPI credential stored" in out.getvalue()


def test_the_usage_runtime_adds_hub_accounts_after_the_configured_ones(hub: FakeHub, tmp_path: Path) -> None:
    from jrbar.provider_usage_runtime import ProviderUsageService
    from jrbar.provider_usage_settings import default_provider_usage_settings

    calls: list[float] = []

    def extra(now: float, *, force: bool = False):
        calls.append(now)
        return collect_hub(settings(hub.url), now=now, key_reader=lambda: KEY, identities=LocalIdentities())

    settings_document = default_provider_usage_settings()
    service = ProviderUsageService(
        settings_loader=lambda: settings_document,
        collectors={},
        credentials=object(),
        home=tmp_path,
        clock=lambda: NOW,
        incident_lookup=lambda *_args: None,
        extra_source=extra,
    )

    state = service.refresh_now(force=True)
    hub_rows = [snapshot for snapshot in state.snapshots if snapshot.source_instance_id.startswith("cliproxy:")]
    assert len(hub_rows) == 3
    assert state.snapshots[: len(state.snapshots) - 3] == tuple(
        snapshot for snapshot in state.snapshots if not snapshot.source_instance_id.startswith("cliproxy:")
    )

    # A refresh scoped to another provider keeps the hub rows it already had.
    scoped = service.refresh_now(providers=("grok",), force=True)
    assert len(calls) == 1
    assert [s for s in scoped.snapshots if s.source_instance_id.startswith("cliproxy:")] == hub_rows


class _SlowTransport:
    """A management API where every call takes ten seconds on a fake clock."""

    def __init__(self) -> None:
        self.clock = 0.0
        self.timeouts: list[float] = []

    def monotonic(self) -> float:
        return self.clock

    def __call__(self, method, url, *, headers, body, timeout):
        self.timeouts.append(timeout)
        self.clock += 10.0
        if url.endswith("/auth-files"):
            return AUTH_FILES
        target = body["url"]
        if "rate-limit-reset-credits" in target:
            return {"status_code": 200, "body": json.dumps(CREDITS)}
        payload = CLAUDE_USAGE if "anthropic" in target else CODEX_USAGE
        return {"status_code": 200, "body": json.dumps(payload)}


def test_a_slow_proxy_cannot_hold_the_refresh_past_the_deadline() -> None:
    """The hub runs inside the usage refresh. Sixteen accounts at fifteen
    seconds a call would hold every provider's numbers for minutes."""
    slow = _SlowTransport()
    snapshots = collect_hub(
        settings("http://127.0.0.1:8317"), now=NOW, key_reader=lambda: KEY, identities=LocalIdentities(),
        transport=slow, deadline_seconds=30.0, monotonic=slow.monotonic,
    )

    assert slow.clock <= 30.0, "no call starts after the deadline"
    assert all(timeout <= 15.0 for timeout in slow.timeouts)
    assert slow.timeouts[-1] <= 10.0, "the last call only gets the time that is left"
    by_instance = {snapshot.source_instance_id: snapshot for snapshot in snapshots}
    assert by_instance[instance_for("a1")].state is ProviderSourceState.READY
    late = by_instance[instance_for("a3")]
    assert late.state is ProviderSourceState.UNAVAILABLE and late.reason_code == "cliproxy_slow"


def test_an_account_the_deadline_missed_keeps_its_last_reading() -> None:
    first = collect_hub(settings("http://127.0.0.1:8317"), now=NOW, key_reader=lambda: KEY,
                        identities=LocalIdentities(), transport=_SlowTransport(), deadline_seconds=600.0)
    previous = {snapshot.identity: snapshot for snapshot in first}

    slow = _SlowTransport()
    again = collect_hub(
        settings("http://127.0.0.1:8317"), now=NOW + 600, key_reader=lambda: KEY, identities=LocalIdentities(),
        transport=slow, deadline_seconds=30.0, monotonic=slow.monotonic, previous=previous,
    )

    codex = {snapshot.source_instance_id: snapshot for snapshot in again}[instance_for("a3")]
    assert codex == previous[("codex", instance_for("a3"))], "the old reading, with its old time"


def test_a_forced_refresh_still_waits_a_minute_after_the_last_hub_read(hub: FakeHub) -> None:
    current = {"cliproxy_hub": settings(hub.url)}
    source = HubSource(settings_loader=lambda: type("S", (), current)(), key_reader=lambda: KEY, identities=LocalIdentities)
    source(NOW)
    asked = len(hub.paths)

    source(NOW + 30, force=True)
    assert len(hub.paths) == asked, "a menu open right after a read asks the proxy nothing"
    source(NOW + 61, force=True)
    assert len(hub.paths) > asked, "past the floor a forced refresh reads"
