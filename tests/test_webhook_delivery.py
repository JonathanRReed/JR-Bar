import io
import json

import pytest

from jrbar.webhook_delivery import (
    WebhookEndpoint,
    WebhookReason,
    WebhookValidationError,
    _read_response,
    _request_bytes,
    deliver_webhook,
    encode_webhook_payload,
    sanitize_webhook_payload,
    validate_webhook_url,
)


def _resolver(*_args, **_kwargs):
    return [
        (2, 1, 6, "", ("93.184.216.34", 443)),
    ]


def test_webhook_requires_https_and_a_public_destination__and_2_more() -> None:
    # --- scenario: webhook_requires_https_and_a_public_destination
    with pytest.raises(WebhookValidationError) as insecure:
        validate_webhook_url("http://example.com/hook", resolver=_resolver)
    assert insecure.value.reason is WebhookReason.INSECURE_SCHEME

    def private_resolver(*_args, **_kwargs):
        return [(2, 1, 6, "", ("127.0.0.1", 443))]

    with pytest.raises(WebhookValidationError) as private:
        validate_webhook_url(
            "https://example.com/hook",
            resolver=private_resolver,
        )
    assert private.value.reason is WebhookReason.FORBIDDEN_DESTINATION

    # --- scenario: webhook_refuses_mixed_public_and_private_dns_answers
    def mixed_resolver(*_args, **_kwargs):
        return [
            (2, 1, 6, "", ("93.184.216.34", 443)),
            (2, 1, 6, "", ("10.0.0.5", 443)),
        ]

    with pytest.raises(WebhookValidationError) as refused:
        validate_webhook_url(
            "https://example.com/hook",
            resolver=mixed_resolver,
        )
    assert refused.value.reason is WebhookReason.FORBIDDEN_DESTINATION

    # --- scenario: webhook_payload_drops_session_provider_and_user_labels
    payload = {
        "event": "jrbar.escalation",
        "stage": 3,
        "ask_count": 2,
        "oldest_ask_seconds": 305,
        "provider": "codex",
        "label": "private project title",
        "sessions": [{"provider": "claude", "label": "secret"}],
        "url": "https://secret.invalid",
    }

    safe = sanitize_webhook_payload(payload)
    encoded = json.loads(encode_webhook_payload(payload))

    assert safe == {
        "event": "jrbar.escalation",
        "stage": 3,
        "ask_count": 2,
        "oldest_ask_seconds": 305,
    }
    assert encoded == safe



def test_response_parser_refuses_redirects_and_oversized_bodies() -> None:
    status, size = _read_response(
        io.BytesIO(
            b"HTTP/1.1 302 Found\r\n"
            b"Location: https://example.net/elsewhere\r\n"
            b"Content-Length: 0\r\n\r\n"
        )
    )
    assert status == 302
    assert size == 0

    with pytest.raises(WebhookValidationError) as oversized:
        _read_response(
            io.BytesIO(
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Length: 5000\r\n\r\n"
            )
        )
    assert oversized.value.reason is WebhookReason.RESPONSE_TOO_LARGE


@pytest.mark.parametrize("reply", [
    b"HTTP/1.1 204 No Content\r\n",
    b"HTTP/1.1 204 No Content\r\nContent-Length: 0",
    b"HTTP/nope 204 No Content\r\n\r\n",
    b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n",
])
def test_incomplete_or_invalid_response_is_not_delivery(reply: bytes) -> None:
    with pytest.raises(WebhookValidationError) as refused:
        _read_response(io.BytesIO(reply))
    assert refused.value.reason is WebhookReason.MALFORMED_RESPONSE


class _Socket:
    def __init__(self, reply=b"HTTP/1.1 204 No Content\r\n\r\n", *, fail_send=False):
        self.reply = reply
        self.fail_send = fail_send
        self.sent = []
        self.closed = False
        self.timeouts = []
        self._reply_stream = io.BytesIO(reply) if isinstance(reply, bytes) else None

    def settimeout(self, timeout):
        self.timeouts.append(timeout)

    def recv(self, size):
        if isinstance(self.reply, Exception):
            raise self.reply
        return self._reply_stream.read(size)

    def sendall(self, request):
        self.sent.append(request)
        if self.fail_send:
            raise OSError("connection lost after a partial send")

    def makefile(self, _mode):
        if isinstance(self.reply, Exception):
            raise self.reply
        return io.BytesIO(self.reply)

    def close(self):
        self.closed = True


class _TLS:
    def wrap_socket(self, raw, *, server_hostname):
        assert server_hostname == "example.com"
        return raw


@pytest.mark.parametrize("failure", ["send", "response"])
def test_post_is_never_retried_after_sending_starts(failure: str) -> None:
    connected = []
    first = _Socket(
        TimeoutError("response timed out") if failure == "response" else b"",
        fail_send=failure == "send",
    )

    def connect(address, *, timeout):
        connected.append(address)
        return first if len(connected) == 1 else _Socket()

    endpoint = WebhookEndpoint(
        "https://example.com/hook", "example.com", 443, "/hook",
        ("93.184.216.34", "93.184.216.35"),
    )
    result = deliver_webhook(endpoint, {"event": "jrbar.test"},
                             socket_factory=connect, ssl_context=_TLS())
    assert result.reason is WebhookReason.CONNECTION_FAILED
    assert connected == [("93.184.216.34", 443)]
    assert len(first.sent) == 1
    assert first.closed


def test_connection_failure_before_post_can_use_another_address() -> None:
    connected = []
    delivered = _Socket()

    def connect(address, *, timeout):
        connected.append(address)
        if len(connected) == 1:
            raise OSError("connection refused")
        return delivered

    endpoint = WebhookEndpoint(
        "https://example.com/hook", "example.com", 443, "/hook",
        ("93.184.216.34", "93.184.216.35"),
    )
    result = deliver_webhook(endpoint, {"event": "jrbar.test"},
                             socket_factory=connect, ssl_context=_TLS())
    assert result.delivered
    assert len(connected) == 2
    assert len(delivered.sent) == 1
    assert delivered.closed


@pytest.mark.parametrize("url", [
    "https://example.com/hook\r\nInjected: value",
    "https://example.com/a b",
    "https://example.com:0/hook",
])
def test_invalid_request_target_is_refused_before_dns(url: str) -> None:
    resolved = []

    def resolver(*args, **kwargs):
        resolved.append(args)
        return _resolver()

    with pytest.raises(WebhookValidationError):
        validate_webhook_url(url, resolver=resolver)
    assert resolved == []


@pytest.mark.parametrize("number", [float("nan"), float("inf"), float("-inf")])
def test_nonfinite_event_numbers_are_omitted(number: float) -> None:
    assert json.loads(encode_webhook_payload({"event": "jrbar.test", "minutes": number})) == {
        "event": "jrbar.test",
    }


def test_unicode_urls_and_existing_escapes_form_a_valid_request() -> None:
    endpoint = validate_webhook_url("https://example.com/caf\u00e9/%2F?name=\u00e9&key=%2F", resolver=_resolver)
    request = _request_bytes(endpoint, b"{}")
    assert request.startswith(b"POST /caf%C3%A9/%2F?name=%C3%A9&key=%2F HTTP/1.1\r\n")


def test_unicode_hostname_uses_ascii_for_dns_and_tls() -> None:
    resolved = []

    def resolver(host, *_args, **_kwargs):
        resolved.append(host)
        return _resolver()

    endpoint = validate_webhook_url("https://caf\u00e9.example/hook", resolver=resolver)
    assert endpoint.host == "xn--caf-dma.example"
    assert resolved == [endpoint.host]
    assert b"Host: xn--caf-dma.example\r\n" in _request_bytes(endpoint, b"{}")


@pytest.mark.parametrize("port, expected", [(443, "[2001:4860:4860::8888]"), (8443, "[2001:4860:4860::8888]:8443")])
def test_public_ipv6_host_header_keeps_brackets(port: int, expected: str) -> None:
    endpoint = WebhookEndpoint("", "2001:4860:4860::8888", port, "/", ("2001:4860:4860::8888",))
    assert f"Host: {expected}\r\n".encode("ascii") in _request_bytes(endpoint, b"{}")


def test_redirect_is_refused_without_connecting_to_its_location() -> None:
    connected = []
    response = _Socket(b"HTTP/1.1 302 Found\r\nLocation: https://private.invalid/token\r\n\r\n")

    def connect(address, *, timeout):
        connected.append(address)
        return response

    endpoint = validate_webhook_url("https://example.com/hook", resolver=_resolver)
    result = deliver_webhook(endpoint, {}, socket_factory=connect, ssl_context=_TLS())
    assert result.reason is WebhookReason.REDIRECT_REFUSED
    assert result.status == 302
    assert connected == [("93.184.216.34", 443)]


@pytest.mark.parametrize("informational", [100, 103])
def test_informational_headers_are_followed_by_the_final_delivery_status(informational):
    response = _Socket(
        f"HTTP/1.1 {informational} Interim\r\nX-Hint: ready\r\n\r\n".encode()
        + b"HTTP/1.1 204 No Content\r\n\r\n"
    )
    endpoint = WebhookEndpoint("https://example.com/hook", "example.com", 443, "/hook", ("93.184.216.34",))
    result = deliver_webhook(endpoint, {}, socket_factory=lambda *_a, **_k: response,
                             ssl_context=_TLS())
    assert result.reason is WebhookReason.DELIVERED
    assert result.status == 204
    assert response.closed


def test_informational_responses_share_the_total_header_byte_limit():
    interim = b"HTTP/1.1 103 Early Hints\r\nX-Hint: " + b"x" * 4000 + b"\r\n\r\n"
    with pytest.raises(WebhookValidationError) as refused:
        _read_response(io.BytesIO(interim * 5 + b"HTTP/1.1 204 No Content\r\n\r\n"))
    assert refused.value.reason is WebhookReason.RESPONSE_TOO_LARGE


def test_protocol_upgrade_is_still_rejected_as_a_final_status():
    response = _Socket(b"HTTP/1.1 101 Switching Protocols\r\n\r\n")
    endpoint = WebhookEndpoint("https://example.com/hook", "example.com", 443, "/hook", ("93.184.216.34",))
    result = deliver_webhook(endpoint, {}, socket_factory=lambda *_a, **_k: response,
                             ssl_context=_TLS())
    assert result.reason is WebhookReason.REMOTE_REJECTED
    assert result.status == 101


def test_connection_attempts_share_one_delivery_budget():
    clock = [0.0]
    timeouts = []

    def connect(_address, *, timeout):
        timeouts.append(timeout)
        clock[0] += 4
        raise OSError("synthetic connection failure")

    endpoint = WebhookEndpoint("https://example.com/hook", "example.com", 443, "/hook",
                               ("93.184.216.34", "93.184.216.35", "93.184.216.36"))
    result = deliver_webhook(endpoint, {}, socket_factory=connect, ssl_context=_TLS(),
                             timeout=8, clock=lambda: clock[0])
    assert result.reason is WebhookReason.CONNECTION_FAILED
    assert timeouts == [8, 4], "no third connection starts after the deadline"


def test_tls_and_response_reads_receive_only_the_remaining_budget():
    clock = [0.0]
    response = _Socket()
    connections = []

    def connect(_address, *, timeout):
        connections.append(timeout)
        if len(connections) == 1:
            clock[0] += 5
            raise OSError("synthetic connection failure")
        return response

    class TLS:
        def wrap_socket(self, raw, *, server_hostname):
            assert server_hostname == "example.com"
            clock[0] += 2
            return raw

    endpoint = WebhookEndpoint("https://example.com/hook", "example.com", 443, "/hook",
                               ("93.184.216.34", "93.184.216.35"))
    result = deliver_webhook(endpoint, {}, socket_factory=connect, ssl_context=TLS(),
                             timeout=8, clock=lambda: clock[0])
    assert result.delivered
    assert connections == [8, 3]
    assert response.timeouts == [3, 1, 1]


def test_trickled_header_bytes_cannot_reset_the_delivery_deadline():
    clock = [0.0]

    class Trickle(_Socket):
        reads = 0

        def recv(self, _size):
            self.reads += 1
            clock[0] += 2
            return b"H"

    response = Trickle()
    endpoint = WebhookEndpoint("https://example.com/hook", "example.com", 443, "/hook",
                               ("93.184.216.34", "93.184.216.35"))
    connected = []

    def connect(address, *, timeout):
        connected.append(address)
        return response

    result = deliver_webhook(endpoint, {}, socket_factory=connect, ssl_context=_TLS(),
                             timeout=8, clock=lambda: clock[0])
    assert result.reason is WebhookReason.CONNECTION_FAILED
    assert response.reads == 4
    assert response.timeouts[-4:] == [8, 6, 4, 2]
    assert len(connected) == 1, "a started POST is never retried"
    assert response.closed
