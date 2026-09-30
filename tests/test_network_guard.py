"""The suite reaches no network: loopback and unix sockets only.

conftest.py refuses a connect to any address that is not loopback, and swaps
the provider status-page poller for one that starts no thread and fetches
nothing. A test that wants a feed answer injects a fake; it never depends on
what a vendor's status page says today.
"""

from __future__ import annotations

import shutil
import socket
import tempfile
import threading
from pathlib import Path

import pytest

import jrbar.status_feeds
from jrbar.provider_usage_platform import (
    ProviderSourceState,
    ProviderUsageSnapshot,
    UsageLane,
)
from jrbar.provider_usage_runtime import ProviderUsageService
from jrbar.provider_usage_settings import default_provider_usage_settings
from jrbar.status_feeds import STATUS_FEED_THREAD_NAME

# Reserved for documentation (RFC 5737, RFC 3849) and the reserved .invalid
# TLD: nothing answers there, and the sockets below never block, so a guard
# that stopped working could not hang the run.
_PUBLIC_V4 = ("192.0.2.1", 443)
_PUBLIC_V6 = ("2001:db8::1", 443, 0, 0)
_PUBLIC_NAME = ("status-feed-canary.invalid", 443)


def _refused_targets():
    yield socket.AF_INET, _PUBLIC_V4
    yield socket.AF_INET, _PUBLIC_NAME
    if socket.has_ipv6:
        yield socket.AF_INET6, _PUBLIC_V6


def test_a_connect_to_a_public_address_is_refused() -> None:
    for family, address in _refused_targets():
        for method in ("connect", "connect_ex"):
            with socket.socket(family, socket.SOCK_STREAM) as client:
                client.setblocking(False)
                with pytest.raises(AssertionError, match="reach the network"):
                    getattr(client, method)(address)


def test_create_connection_to_a_public_address_is_refused() -> None:
    with pytest.raises(AssertionError, match="reach the network"):
        socket.create_connection(_PUBLIC_V4, timeout=0.5)


def test_a_loopback_connect_still_works() -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(5.0)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as client:
            client.settimeout(5.0)
            client.connect(listener.getsockname())
            connection, _ = listener.accept()
            with connection:
                client.sendall(b"ping")
                connection.settimeout(5.0)
                assert connection.recv(4) == b"ping"


def test_a_unix_socket_connect_still_works() -> None:
    # AF_UNIX paths are capped at 104 bytes; pytest's tmp_path can be longer.
    folder = Path(tempfile.mkdtemp(prefix="jrbar-", dir=tempfile.gettempdir()))
    try:
        path = str(folder / "guard.sock")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(path)
            listener.listen(1)
            listener.settimeout(5.0)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(5.0)
                client.connect(path)
                connection, _ = listener.accept()
                connection.close()
    finally:
        shutil.rmtree(folder, ignore_errors=True)


def test_the_shared_status_feed_poller_is_inert_under_test(inert_status_feed_poller) -> None:
    poller = jrbar.status_feeds.shared_status_feed_poller()
    assert poller is inert_status_feed_poller

    poller.start(provider_ids=("codex",))
    poller.poll_once()

    assert poller.started == [("codex",)]
    assert poller.current() == {}
    assert poller.incident_for("codex", now=1000.0) is None
    assert not _status_feed_threads()


def test_a_default_provider_usage_service_starts_no_status_feed_thread(
    tmp_path, inert_status_feed_poller
) -> None:
    # Provider status pages are opt-in, so a service with no settings wired
    # does not even ask the shared poller to start a feed for the provider it
    # refreshed; and the shared poller is the inert one under test anyway.
    service = ProviderUsageService(
        settings_loader=default_provider_usage_settings,
        credentials=object(),
        home=tmp_path,
        clock=lambda: 1000.0,
        collectors={"codex": lambda _preference, _home, _now, _credentials: _snapshot()},
    )

    result = service.refresh_now(providers=("codex",)).by_provider("codex")

    assert result.incident is None
    assert inert_status_feed_poller.started == []
    assert not _status_feed_threads()


def _status_feed_threads() -> list[threading.Thread]:
    return [
        thread
        for thread in threading.enumerate()
        if thread.name.startswith(STATUS_FEED_THREAD_NAME)
    ]


def _snapshot() -> ProviderUsageSnapshot:
    lane = UsageLane(
        provider_id="codex",
        lane_id="weekly",
        label="Weekly",
        remaining_percent=50.0,
        reset_at=None,
        scope="all",
        model=None,
        feature=None,
        bindable=True,
        source_id="fixture",
    )
    return ProviderUsageSnapshot(
        provider_id="codex",
        account_label=None,
        observed_at=1000.0,
        state=ProviderSourceState.READY,
        reason_code=None,
        action_label=None,
        lanes=(lane,),
        input_tokens=0,
        cached_input_tokens=0,
        output_tokens=0,
        model_count=0,
        estimated_cost_usd=None,
        cache_savings_usd=None,
        credits_remaining=None,
        incident=None,
    )
