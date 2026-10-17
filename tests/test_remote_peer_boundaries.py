"""Remote opt-in and transport limits use synthetic data only."""

from __future__ import annotations

import json
import subprocess
from dataclasses import replace
from pathlib import Path

import pytest

from jrbar import remote_peers, status_bar
from tests.test_core_runtime import headless  # noqa: F401
from tests.test_remote_peers import Clock, _status_json, document, peer, reader_returning


@pytest.mark.parametrize("value", ["false", "true", 1, 0, [], {}, None])
def test_remote_opt_in_requires_boolean_settings(value, tmp_path) -> None:
    raw = dict.fromkeys(
        ("enabled", "publish_enabled", "include_messages", "remote_interrupts_muted"), value
    )
    settings = remote_peers.RemotePeerSettings.from_dict(raw)
    direct = remote_peers.RemotePeerSettings(**raw).normalized()
    for active in (settings, direct):
        assert active.enabled is False
        assert active.publish_enabled is False
        assert active.include_messages is False
        assert active.remote_interrupts_muted is True
        calls = []
        result = remote_peers.collect_remote_ledgers(
            runner=lambda *args: calls.append(args), settings=active
        )
        assert result == remote_peers.PeerRefreshResult()
        assert calls == []
        target = tmp_path / "ledger.json"
        assert remote_peers.publish_local_ledger((), path=target, settings=active) is None
        assert not target.exists()


def test_direct_refresh_cannot_raise_the_peer_ceiling() -> None:
    peers = tuple(peer(f"mac-{index}", f"mac-{index}") for index in range(20))
    result = remote_peers.refresh_peers(
        peers,
        reader=reader_returning(document()),
        now_monotonic=Clock(),
        max_peers=10_000,
    )
    assert result.attempted == remote_peers.MAX_PEERS
    assert len(result.health) == remote_peers.MAX_PEERS


def test_direct_discovery_cannot_raise_the_peer_ceiling() -> None:
    entries = {
        f"nodekey:{index}": {
            "HostName": f"peer-{index}",
            "DNSName": f"peer-{index}.example.test.",
            "OS": "macOS",
            "Online": True,
        }
        for index in range(20)
    }
    peers = remote_peers.parse_tailscale_status(_status_json(Peer=entries), limit=10_000)
    assert len(peers) == remote_peers.MAX_PEERS


@pytest.mark.parametrize("value", [float("inf"), float("nan"), None, "invalid"])
def test_invalid_peer_limit_falls_back_to_the_hard_ceiling(value) -> None:
    assert remote_peers.RemotePeerSettings(max_peers=value).normalized().max_peers == remote_peers.MAX_PEERS
    assert remote_peers.RemotePeerSettings.from_dict({"max_peers": value}).max_peers == remote_peers.MAX_PEERS


@pytest.mark.parametrize("version", [True, 1.0, "1"])
def test_wire_version_must_be_an_integer(version) -> None:
    payload = json.loads(document())
    payload["version"] = version
    with pytest.raises(remote_peers.RemotePeerError) as caught:
        remote_peers.parse_remote_ledger_document(json.dumps(payload))
    assert caught.value.failure == remote_peers.FAILURE_UNSUPPORTED_VERSION


def test_caller_cannot_raise_the_payload_ceiling() -> None:
    payload = document() + " " * remote_peers.MAX_PAYLOAD_BYTES
    with pytest.raises(remote_peers.RemotePeerError) as caught:
        remote_peers.parse_remote_ledger_document(payload, max_bytes=10_000_000)
    assert caught.value.failure == remote_peers.FAILURE_TOO_LARGE
    result = remote_peers.refresh_peers(
        (peer(),),
        reader=reader_returning(payload),
        now_monotonic=Clock(),
        max_bytes=10_000_000,
    )
    assert result.ledgers == ()
    assert result.health[0].failure == remote_peers.FAILURE_TOO_LARGE


@pytest.mark.parametrize("field", ["generated_at", "updated_at"])
def test_timestamp_overflow_is_a_malformed_document(field) -> None:
    payload = json.loads(document())
    target = payload if field == "generated_at" else payload["rows"][0]
    target[field] = "9999-12-31T23:59:59-01:00"
    with pytest.raises(remote_peers.RemotePeerError) as caught:
        remote_peers.parse_remote_ledger_document(json.dumps(payload))
    assert caught.value.failure == remote_peers.FAILURE_MALFORMED


def test_transport_discards_unused_output(tmp_path, monkeypatch) -> None:
    seen = []
    monkeypatch.setattr(remote_peers, "tailscale_cli_path", lambda: Path("/fake/tailscale"))
    monkeypatch.setattr(remote_peers, "_validated_sftp_path", lambda path: path)

    def fake_run(argv, **kwargs):
        seen.append(kwargs)
        if argv[0] == "/fake/tailscale":
            assert kwargs["stdout"] is subprocess.PIPE
            return subprocess.CompletedProcess(argv, 0, "{}")
        assert kwargs["stdout"] is subprocess.DEVNULL
        Path(argv[-1]).write_text(document(), encoding="utf-8")
        return subprocess.CompletedProcess(argv, 0)

    monkeypatch.setattr(remote_peers.subprocess, "run", fake_run)
    assert remote_peers.discover_peers() == ()
    reader = remote_peers.SecureShellPeerReader(scratch_dir=tmp_path / "scratch")
    assert reader("mac-b", "/ledger.json", timeout=1.0, max_bytes=65536) == document()
    assert len(seen) == 2
    assert all(kwargs["stderr"] is subprocess.DEVNULL for kwargs in seen)


def _reachable_result(settings):
    return remote_peers.PeerRefreshResult(
        health=(remote_peers.PeerHealth(machine="mac-b", host="mac-b", reachable=True),),
        request_settings=settings,
    )


def test_disabling_remote_peers_rejects_an_in_flight_result(headless) -> None:  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    enabled = replace(controller.settings.remote_peers, enabled=True)
    result = _reachable_result(enabled)
    controller._remote_refresh = result
    controller._remote_refresh_ever_applied = True
    controller._remote_peers_refresh_running = True
    controller.refresh_.reset_mock()
    before = list(controller._core.published)

    controller.applyRemotePeerRefresh_(result)

    assert controller._remote_peers_refresh_running is False
    assert controller._remote_refresh == remote_peers.PeerRefreshResult()
    assert controller._core.published == before
    controller.refresh_.assert_called_once_with(None)


def test_changed_remote_config_rejects_a_superseded_result(headless) -> None:  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    old = replace(controller.settings.remote_peers, enabled=True)
    active = replace(old, remote_ledger_path="/new/ledger.json")
    controller.settings = controller.settings.with_remote_peers(active)
    controller._remote_refresh_ever_applied = True
    controller._remote_peers_refresh_running = True
    controller.refresh_.reset_mock()
    before = list(controller._core.published)

    controller.applyRemotePeerRefresh_(_reachable_result(old))

    assert controller._remote_peers_refresh_running is False
    assert controller._remote_refresh == remote_peers.PeerRefreshResult()
    assert controller._core.published == before
    controller.refresh_.assert_not_called()

    controller.applyRemotePeerRefresh_(_reachable_result(active))
    assert controller._remote_refresh.health[0].reachable is True


def test_collection_stamps_the_settings_used_for_an_empty_discovery() -> None:
    active = remote_peers.RemotePeerSettings(enabled=True, max_peers=2)
    result = remote_peers.collect_remote_ledgers(settings=active, runner=lambda *args: "{}")
    assert result.request_settings == active.normalized()


@pytest.mark.parametrize("failure_stage", ["construct", "start"])
def test_remote_refresh_start_failure_preserves_state_and_allows_retry(
    headless, monkeypatch, failure_stage  # noqa: F811
) -> None:
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    active = replace(controller.settings.remote_peers, enabled=True)
    controller.settings = controller.settings.with_remote_peers(active)
    previous = _reachable_result(active)
    controller._remote_refresh = previous
    controller._remote_refresh_ever_applied = True
    controller._remote_peers_quiet_rounds = 8
    controller._remote_peers_ticks_to_skip = 2
    before_events = list(controller._core.published)
    controller.refresh_.reset_mock()
    result = replace(previous, attempted=1)
    collected, deliveries, pending, attempts = [], [], [], []

    def collect():
        collected.append(True)
        return result

    def dispatch(selector, value, wait):
        deliveries.append((selector, value, wait))

    class Thread:
        def __init__(self, *, target, daemon, name):
            attempts.append((daemon, name))
            self.target = target
            if len(attempts) == 1 and failure_stage == "construct":
                raise RuntimeError("synthetic thread construction failure")

        def start(self):
            if len(attempts) == 1 and failure_stage == "start":
                raise RuntimeError("synthetic thread start failure")
            pending.append(self.target)

    monkeypatch.setattr(controller, "collect_remote_peer_ledgers", collect)
    monkeypatch.setattr(controller, "performSelectorOnMainThread_withObject_waitUntilDone_", dispatch)
    monkeypatch.setattr(status_bar, "log_status_bar", lambda _message: None)
    monkeypatch.setattr(status_bar.threading, "Thread", Thread)
    refresh = type(controller).start_remote_peer_refresh
    escaped = False
    try:
        refresh(controller)
    except RuntimeError:
        escaped = True
    assert (escaped, controller._remote_peers_refresh_running) == (False, False)
    assert controller._remote_refresh is previous
    assert controller._remote_refresh_ever_applied is True
    assert controller._remote_peers_quiet_rounds == 8
    assert controller._remote_peers_ticks_to_skip == 2
    assert controller._core.published == before_events
    controller.refresh_.assert_not_called()
    assert not collected and not deliveries and not pending

    refresh(controller)
    assert controller._remote_peers_refresh_running is True
    assert len(pending) == 1
    refresh(controller)
    assert attempts == [(True, "jrbar-remote-peers")] * 2
    assert len(pending) == 1
    pending.pop()()
    assert collected == [True]
    assert deliveries == [("applyRemotePeerRefresh:", result, False)]
    assert controller._remote_peers_refresh_running is True
    refresh(controller)
    assert len(attempts) == 2
    controller.applyRemotePeerRefresh_(deliveries.pop()[1])
    assert controller._remote_peers_refresh_running is False
    assert controller._remote_refresh is result
