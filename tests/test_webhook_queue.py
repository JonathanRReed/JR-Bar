from __future__ import annotations

import threading

from jrbar.webhook_delivery import (
    WebhookDeliveryService,
    WebhookEndpoint,
    WebhookReason,
    WebhookResult,
)


def _endpoint(url: str) -> WebhookEndpoint:
    return WebhookEndpoint(
        url=url,
        host="example.com",
        port=443,
        request_target="/hook",
        addresses=("93.184.216.34",),
    )


def _assert_worker_failure_rejects_request(monkeypatch, failure: str) -> None:
    real_thread = threading.Thread
    attempts = []
    validated = []
    delivered = []
    receipts = []
    completed = threading.Event()

    class FailedStartThread:
        def start(self):
            raise RuntimeError("synthetic worker start failure")

        def is_alive(self):
            return False

    def make_thread(*args, **kwargs):
        attempts.append(failure)
        if len(attempts) == 1:
            if failure == "constructor":
                raise RuntimeError("synthetic worker constructor failure")
            return FailedStartThread()
        return real_thread(*args, **kwargs)

    def validate(url):
        validated.append(url)
        return _endpoint(url)

    def deliver(_target, payload):
        delivered.append(payload["event"])
        return WebhookResult(WebhookReason.DELIVERED, 204)

    def receipt(value):
        receipts.append(value)
        completed.set()

    monkeypatch.setattr("jrbar.webhook_delivery.threading.Thread", make_thread)
    service = WebhookDeliveryService(
        maximum_queue_depth=1,
        validator=validate,
        deliver=deliver,
    )
    rejected_url = "https://example.com/rejected"
    retry_url = "https://example.com/retry"
    try:
        assert service.submit(
            rejected_url, {"event": "rejected"}, callback=receipt,
        ) is WebhookReason.CONNECTION_FAILED
        assert validated == []
        assert delivered == []
        assert receipts == []
        assert service.submit(
            retry_url, {"event": "retry"}, callback=receipt,
        ) is None
        assert completed.wait(1.0)
        assert validated == [retry_url]
        assert delivered == ["retry"]
        assert len(receipts) == 1
        assert receipts[0].request.url == retry_url
        assert receipts[0].result.reason is WebhookReason.DELIVERED
        assert len(attempts) == 2
    finally:
        service.close()


def test_worker_constructor_failure_rejects_request_and_allows_retry(monkeypatch) -> None:
    _assert_worker_failure_rejects_request(monkeypatch, "constructor")


def test_worker_start_failure_rejects_request_and_allows_retry(monkeypatch) -> None:
    _assert_worker_failure_rejects_request(monkeypatch, "start")


def _assert_worker_replacement_preserves_queue(monkeypatch, failure: str) -> None:
    real_thread = threading.Thread
    attempts = []
    validated = []
    delivered = []
    receipts = []
    completed = threading.Event()

    class QueuedOwner:
        alive = True

        def start(self):
            pass

        def is_alive(self):
            return self.alive

    class FailedStartThread:
        def start(self):
            raise RuntimeError("synthetic replacement start failure")

        def is_alive(self):
            return False

    owner = QueuedOwner()

    def make_thread(*args, **kwargs):
        attempts.append(failure)
        if len(attempts) == 1:
            return owner
        if len(attempts) == 2:
            if failure == "constructor":
                raise RuntimeError("synthetic replacement constructor failure")
            return FailedStartThread()
        return real_thread(*args, **kwargs)

    def validate(url):
        validated.append(url)
        return _endpoint(url)

    def deliver(_target, payload):
        delivered.append(payload["event"])
        return WebhookResult(WebhookReason.DELIVERED, 204)

    def receipt(value):
        receipts.append(value)
        if value.request.url == "https://example.com/retry":
            completed.set()

    monkeypatch.setattr("jrbar.webhook_delivery.threading.Thread", make_thread)
    service = WebhookDeliveryService(
        maximum_queue_depth=3,
        validator=validate,
        deliver=deliver,
    )
    try:
        for event in ("first", "second"):
            assert service.submit(
                f"https://example.com/{event}", {"event": event}, callback=receipt,
            ) is None
        assert len(attempts) == 1
        owner.alive = False
        assert service.submit(
            "https://example.com/rejected", {"event": "rejected"}, callback=receipt,
        ) is WebhookReason.CONNECTION_FAILED
        assert validated == []
        assert delivered == []
        assert receipts == []
        assert service.submit(
            "https://example.com/retry", {"event": "retry"}, callback=receipt,
        ) is None
        assert completed.wait(1.0)
        expected_urls = [f"https://example.com/{event}" for event in ("first", "second", "retry")]
        assert validated == expected_urls
        assert delivered == ["first", "second", "retry"]
        assert [value.request.url for value in receipts] == expected_urls
        assert all(value.result.reason is WebhookReason.DELIVERED for value in receipts)
        assert len(attempts) == 3
    finally:
        service.close()


def test_worker_constructor_replacement_failure_preserves_accepted_queue(monkeypatch) -> None:
    _assert_worker_replacement_preserves_queue(monkeypatch, "constructor")


def test_worker_start_replacement_failure_preserves_accepted_queue(monkeypatch) -> None:
    _assert_worker_replacement_preserves_queue(monkeypatch, "start")


def test_queue_depth_is_bounded_while_one_delivery_is_in_flight__and_1_more() -> None:
    # --- scenario: queue_depth_is_bounded_while_one_delivery_is_in_flight
    started = threading.Event()
    release = threading.Event()
    completed = threading.Event()
    delivered = []

    def deliver(_target, payload):
        started.set()
        release.wait(1.0)
        delivered.append(payload["event"])
        return WebhookResult(WebhookReason.DELIVERED, 204)

    service = WebhookDeliveryService(
        maximum_queue_depth=1,
        validator=_endpoint,
        deliver=deliver,
    )
    assert service.submit("https://example.com/hook", {"event": "first"}) is None
    assert started.wait(1.0)
    assert (
        service.submit(
            "https://example.com/hook",
            {"event": "second"},
            callback=lambda _receipt: completed.set(),
        )
        is None
    )
    assert service.submit(
        "https://example.com/hook",
        {"event": "third"},
    ) is WebhookReason.QUEUE_FULL

    release.set()
    assert completed.wait(1.0)
    assert delivered == ["first", "second"]
    service.close()

    # --- scenario: close_discards_queued_work_but_allows_inflight_cleanup
    started = threading.Event()
    release = threading.Event()
    first_done = threading.Event()
    second_done = threading.Event()

    def deliver(_target, _payload):
        started.set()
        release.wait(1.0)
        return WebhookResult(WebhookReason.DELIVERED, 204)

    service = WebhookDeliveryService(
        maximum_queue_depth=2,
        validator=_endpoint,
        deliver=deliver,
    )
    service.submit(
        "https://example.com/hook",
        {"event": "first"},
        callback=lambda _receipt: first_done.set(),
    )
    assert started.wait(1.0)
    service.submit(
        "https://example.com/hook",
        {"event": "second"},
        callback=lambda _receipt: second_done.set(),
    )

    service.close()
    release.set()

    assert first_done.wait(1.0)
    assert not second_done.wait(0.2)


def test_close_during_validation_stops_the_unsent_request() -> None:
    validating = threading.Event()
    release = threading.Event()
    finished = threading.Event()
    delivered = []
    receipts = []

    def validate(url):
        validating.set()
        assert release.wait(1.0)
        return _endpoint(url)

    def deliver(_endpoint, payload):
        delivered.append(payload)
        return WebhookResult(WebhookReason.DELIVERED, 204)

    def receipt(value):
        receipts.append(value)
        finished.set()

    service = WebhookDeliveryService(validator=validate, deliver=deliver)
    assert service.submit("https://example.com/hook", {"event": "jrbar.test"},
                          callback=receipt) is None
    assert validating.wait(1.0)
    service.close()
    release.set()
    assert finished.wait(1.0)
    assert delivered == []
    assert receipts[0].result.reason is WebhookReason.CLOSED
    assert service.submit("https://example.com/hook", {}) is WebhookReason.CLOSED


def test_receipt_listener_failure_cannot_log_endpoint_secrets(caplog) -> None:
    failed = threading.Event()
    continued = threading.Event()
    secret_url = "https://example.com/hook?token=synthetic-secret"

    def callback(receipt):
        failed.set()
        raise ValueError(receipt.request.url)

    service = WebhookDeliveryService(
        validator=_endpoint,
        deliver=lambda _endpoint, _payload: WebhookResult(WebhookReason.DELIVERED, 204),
    )
    try:
        assert service.submit(secret_url, {}, callback=callback) is None
        assert failed.wait(1.0)
        assert service.submit(secret_url, {}, callback=lambda _receipt: continued.set()) is None
        assert continued.wait(1.0)
        assert "webhook delivery receipt listener failed" in caplog.text
        assert "synthetic-secret" not in caplog.text
    finally:
        service.close()

