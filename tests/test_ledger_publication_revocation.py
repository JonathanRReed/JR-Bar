"""Queued remote publication obeys current privacy settings."""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path

import pytest

from jrbar import ledger_runtime, remote_peers
from jrbar._status_bar_production import JRStatusBarController
from tests.test_core_runtime import headless  # noqa: F401
from tests.test_remote_peers import NOW, status


@pytest.fixture
def deferred_threads(monkeypatch):
    queued = []

    class Thread:
        def __init__(self, *, target, args, **kwargs):
            self.target = target
            self.args = args

        def start(self):
            queued.append(self)

        def run(self):
            self.target(*self.args)

    monkeypatch.setattr(ledger_runtime.threading, "Thread", Thread)
    return queued


def _request(publisher, settings, callback, label="request"):
    return publisher.request(
        statuses=(status(message="synthetic question"),),
        generated_at=NOW,
        settings=settings,
        signature=label,
        callback=callback,
    )


def test_a_request_is_refused_after_publication_is_revoked(deferred_threads) -> None:
    requested = remote_peers.RemotePeerSettings(publish_enabled=True)
    current = replace(requested, publish_enabled=False)
    calls = []
    publisher = ledger_runtime.RemoteLedgerPublisher(
        lambda *args, **kwargs: calls.append(args), settings_supplier=lambda: current
    )
    assert _request(publisher, requested, lambda result: None) is None
    assert deferred_threads == []
    assert calls == []


@pytest.mark.parametrize("publish_enabled", [False, True])
def test_a_queued_worker_rechecks_privacy_before_publishing(deferred_threads, publish_enabled) -> None:
    current = remote_peers.RemotePeerSettings(publish_enabled=True, include_messages=True)
    calls = []
    results = []

    def publish(*args, **kwargs):
        calls.append(kwargs["settings"])
        return Path("/synthetic/ledger.json")

    publisher = ledger_runtime.RemoteLedgerPublisher(publish, settings_supplier=lambda: current)
    _request(publisher, current, results.append)
    current = replace(current, publish_enabled=publish_enabled, include_messages=False)
    deferred_threads.pop(0).run()
    if publish_enabled:
        assert len(calls) == 1
        assert calls[0].include_messages is False
    else:
        assert calls == []
        assert results[0].reason == ledger_runtime.LEDGER_PUBLISH_REASON_REVOKED


def test_closing_during_a_fake_write_cancels_queued_work_and_callbacks(deferred_threads) -> None:
    settings = remote_peers.RemotePeerSettings(publish_enabled=True, include_messages=True)
    calls = []
    results = []

    def publish(*args, **kwargs):
        calls.append(args)
        _request(publisher, settings, results.append, "queued")
        publisher.close()
        return Path("/synthetic/ledger.json")

    publisher = ledger_runtime.RemoteLedgerPublisher(publish)
    _request(publisher, settings, results.append, "active")
    deferred_threads.pop(0).run()
    assert len(calls) == 1
    assert deferred_threads == []
    assert results == []


def test_later_opt_in_does_not_add_messages_to_an_older_request(deferred_threads) -> None:
    requested = remote_peers.RemotePeerSettings(publish_enabled=True, include_messages=False)
    current = replace(requested, include_messages=True)
    published = []
    publisher = ledger_runtime.RemoteLedgerPublisher(
        lambda *args, **kwargs: published.append(kwargs["settings"]),
        settings_supplier=lambda: current,
    )
    _request(publisher, requested, lambda result: None)
    deferred_threads.pop(0).run()
    assert len(published) == 1
    assert published[0].include_messages is False


@pytest.mark.parametrize("publish_enabled", [False, True])
def test_privacy_is_checked_again_before_the_private_write(monkeypatch, publish_enabled) -> None:
    current = remote_peers.RemotePeerSettings(publish_enabled=True, include_messages=True)
    writes = []
    original_build = remote_peers.build_remote_ledger_document

    def build(**kwargs):
        nonlocal current
        payload = original_build(**kwargs)
        current = replace(current, publish_enabled=publish_enabled, include_messages=False)
        return payload

    monkeypatch.setattr(remote_peers, "build_remote_ledger_document", build)
    monkeypatch.setattr(remote_peers, "atomic_private_write", lambda path, payload: writes.append(payload))
    result = remote_peers.publish_local_ledger(
        (status(message="synthetic question"),),
        machine="synthetic-mac",
        generated_at=NOW,
        path=Path("/synthetic/ledger.json"),
        settings=current,
        settings_supplier=lambda: current,
    )
    if publish_enabled:
        assert result == Path("/synthetic/ledger.json")
        assert len(writes) == 1
        assert "synthetic question" not in writes[0]
    else:
        assert result is None
        assert writes == []


def test_controller_closes_the_pending_publisher_when_publication_turns_off(headless) -> None:  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    closed = []

    class Publisher:
        def close(self):
            closed.append(True)

    controller._production_ledger_publisher = Publisher()
    controller._published_ledger_signature = "old"
    controller._ledger_publish_pending_signature = "old"
    JRStatusBarController.publish_local_ledger_now(controller, (status(),))
    assert closed == [True]
    assert controller._production_ledger_publisher is None
    assert controller._ledger_publish_pending_signature is None


def test_controller_republishes_without_messages_after_sharing_is_revoked(headless, monkeypatch) -> None:  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    old = remote_peers.RemotePeerSettings(publish_enabled=True, include_messages=True)
    controller.settings = controller.settings.with_remote_peers(replace(old, include_messages=False))
    controller._ledger_publish_policy = (True, True)
    controller._published_ledger_signature = "old"
    controller._ledger_publish_pending_signature = "old"
    closed = []
    requested = []

    class Publisher:
        def close(self):
            closed.append(True)

        def request(self, **kwargs):
            requested.append(kwargs)

    controller._production_ledger_publisher = Publisher()
    monkeypatch.setattr(controller, "_ledger_publisher", lambda: Publisher(), raising=False)
    monkeypatch.setattr(controller, "_ledger_publish_ready", lambda result: None, raising=False)
    JRStatusBarController.publish_local_ledger_now(controller, (status(message="synthetic question"),))
    assert closed == [True]
    assert len(requested) == 1
    assert requested[0]["settings"].include_messages is False


def test_a_callback_queued_before_an_off_on_cycle_cannot_complete_the_new_request(headless, monkeypatch) -> None:  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    settings = remote_peers.RemotePeerSettings(publish_enabled=True, include_messages=True)
    controller.settings = controller.settings.with_remote_peers(settings)
    requests = []

    class Publisher:
        def close(self):
            pass

        def request(self, **kwargs):
            requests.append(ledger_runtime.LedgerPublishRequest(
                len(requests) + 1,
                kwargs["statuses"],
                kwargs["generated_at"],
                kwargs["settings"],
                kwargs["signature"],
            ))

    monkeypatch.setattr(controller, "_ledger_publisher", lambda: Publisher(), raising=False)
    monkeypatch.setattr(controller, "_ledger_publish_ready", lambda result: None, raising=False)
    rows = (status(message="synthetic question"),)
    JRStatusBarController.publish_local_ledger_now(controller, rows)
    old = requests[-1]
    controller.settings = controller.settings.with_remote_peers(replace(settings, publish_enabled=False))
    JRStatusBarController.publish_local_ledger_now(controller, rows)
    controller.settings = controller.settings.with_remote_peers(settings)
    JRStatusBarController.publish_local_ledger_now(controller, rows)
    latest = requests[-1]
    assert latest.signature != old.signature
    result = ledger_runtime.LedgerPublishResult(old, Path("/synthetic/old-ledger.json"))

    JRStatusBarController.applyLedgerPublishResult_(controller, result)

    assert controller._ledger_publish_pending_signature == latest.signature
    assert controller._published_ledger_signature is None
