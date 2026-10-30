"""Factory and WorkOS loopback servers use invented accounts and credentials."""

import base64
import json
import sqlite3
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

import pytest

from jrbar import factory_session
from jrbar.provider_usage_collectors import _default_http_json
from jrbar.provider_usage_factory import collect_factory
from tests.test_factory_browser_session import auth, billing, browser_database, preference, session
from tests.test_factory_browser_session import context as factory_context

context = factory_context


def token(expiry, subject="synthetic-user", org="synthetic-org"):
    claims = json.dumps({"exp": expiry, "sub": subject, "org_id": org}).encode()
    return "synthetic." + base64.urlsafe_b64encode(claims).decode().rstrip("=") + ".signature"


@pytest.fixture
def remote():
    state = {"refreshes": [], "requests": [], "refresh_status": 200, "refresh_error": "invalid_grant", "reject_client": None, "auth_status": 200,
             "billing_status": 200, "user": "synthetic-user", "org": "synthetic-org",
             "access": token(2000), "refresh": "synthetic-rotated-1",
             "reject_access": None, "now": 1000, "valid_refresh": "synthetic-refresh-token", "retired": {}}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            assert self.path == "/user_management/authenticate"
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            state["refreshes"].append(body)
            assert body["grant_type"] == "refresh_token"
            assert body["client_id"] in factory_session.WORKOS_CLIENT_IDS
            assert self.headers.get("Authorization") is None
            assert self.headers.get("Cookie") is None
            status = state["refresh_status"]
            code = state["refresh_error"]
            if body["client_id"] == state["reject_client"]:
                status, code = 400, "invalid_client"
            elif body.get("organization_id") and body["organization_id"] == state.get("reject_org"):
                status, code = 400, "organization_not_found"
            payload = {"access_token": state["access"], "refresh_token": state["refresh"]}
            if status == 200:
                submitted = body["refresh_token"]
                if submitted == state["valid_refresh"]:
                    state["retired"][submitted] = (state["now"] + 30, payload)
                    state["valid_refresh"] = payload["refresh_token"]
                else:
                    replay = state["retired"].get(submitted)
                    if replay and state["now"] <= replay[0]:
                        payload = replay[1]
                    else:
                        status = 400
            field = state.get("error_field", "error")
            self.reply(status, payload if status == 200 else {field: code, "message": "synthetic-secret", "refresh_token": "synthetic-private-value"})

        def do_GET(self):
            state["requests"].append((self.path, self.headers.get("Authorization")))
            assert self.headers["Origin"] == "https://app.factory.ai"
            assert self.headers["x-factory-client"] == "web-app"
            if self.headers.get("Authorization") == state["reject_access"]:
                self.reply(401, {})
            elif self.path.endswith("/auth/me"):
                self.reply(state["auth_status"], auth(state["user"], state["org"]))
            else:
                self.reply(state["billing_status"], billing())

        def reply(self, status, payload):
            raw = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

    # Separate servers prove that Factory headers never accompany the WorkOS token exchange.
    workos = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    factory = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in (workos, factory)]
    for thread in threads:
        thread.start()

    def http(method, url, **kwargs):
        parsed = urlsplit(url)
        assert parsed.scheme == "https"
        assert parsed.netloc in {"api.workos.com", "api.factory.ai"}
        server = workos if parsed.netloc == "api.workos.com" else factory
        target = f"http://127.0.0.1:{server.server_port}{parsed.path}"
        if parsed.query:
            target += "?" + parsed.query
        return _default_http_json(method, target, **kwargs)

    try:
        yield state, http
    finally:
        for server in (workos, factory):
            server.shutdown()
            server.server_close()
        for thread in threads:
            thread.join(timeout=3)
            assert not thread.is_alive()


def connect_refresh_only(home, store):
    profile = browser_database(home)
    database = profile / "storage/default/https+++app.factory.ai/ls/data.sqlite"
    with sqlite3.connect(database) as db:
        db.execute("DELETE FROM data WHERE key='workos:access-token'")
        db.execute("INSERT INTO data VALUES ('factory:active-organization-id', 'synthetic-org', 0)")
    before = database.read_bytes()
    result = factory_session.import_session({"browser": "zen", "profile": profile.name,
        "confirm": True, "allow_refresh": True}, store)
    assert result["provider"] == "factory"
    return database, before


def test_refresh_only_browser_rotates_only_after_usage_is_enabled_and_consented(context, remote):
    home, store = context
    state, http = remote
    database, original = connect_refresh_only(home, store)
    assert not state["refreshes"] and not state["requests"]
    for prefs in (preference(enabled=False), preference(usage_consented=False)):
        assert not collect_factory(prefs, observed_at=1000, credentials=store, http_json=http).lanes
    assert not state["refreshes"] and not state["requests"]
    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.lanes and result.account_discriminator
    saved = json.loads(store.get("factory", "web-session").secret)
    assert saved["refresh_token"] == "synthetic-rotated-1"
    assert saved["consent_version"] == 2
    # Factory's own organization ID checks the account; WorkOS never sees it.
    assert "organization_id" not in state["refreshes"][0]
    assert database.read_bytes() == original
    # The next poll uses JR-Bar's token, without importing the old browser copy.
    assert collect_factory(preference(), observed_at=1001, credentials=store, http_json=http).lanes
    assert len(state["refreshes"]) == 1
    # Expiry rotates the stored token, then uses the replacement on the next expiry.
    state.update(access=token(3000), refresh="synthetic-rotated-2")
    assert collect_factory(preference(), observed_at=2000, credentials=store, http_json=http).lanes
    assert state["refreshes"][-1]["refresh_token"] == "synthetic-rotated-1"
    assert json.loads(store.get("factory", "web-session").secret)["refresh_token"] == "synthetic-rotated-2"
    assert database.read_bytes() == original


def test_no_connection_makes_no_remote_request(context, remote):
    _, store = context
    state, http = remote
    assert not collect_factory(preference(), observed_at=1000, credentials=store, http_json=http).lanes
    assert not state["requests"] and not state["refreshes"]


@pytest.mark.parametrize("status", [400, 401, 429, 503])
def test_refresh_failures_are_sanitized_and_preserve_tokens(context, remote, status):
    home, store = context
    state, http = remote
    connect_refresh_only(home, store)
    state["refresh_status"] = status
    before = json.loads(store.get("factory", "web-session").secret)
    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert not result.lanes
    assert "synthetic-secret" not in repr(result)
    saved = json.loads(store.get("factory", "web-session").secret)
    assert saved["refresh_token"] == before["refresh_token"]
    assert not state["requests"]
    count = len(state["refreshes"])
    collect_factory(preference(), observed_at=1001, credentials=store, http_json=http)
    if status in {400, 401}:
        assert result.reason_code == "factory_refresh_invalid_grant"
        assert saved["refresh_rejected"]
        assert len(state["refreshes"]) == count
    else:
        assert not saved.get("refresh_rejected")
        assert len(state["refreshes"]) == count + 1


@pytest.mark.parametrize("endpoint", ["auth", "billing"])
def test_401_renews_once_and_probes_identity_again(context, remote, endpoint):
    _, store = context
    state, http = remote
    old = token(2000)
    store.set("factory", "web-session", json.dumps(session(consent_version=2, access_token=old)))
    state.update(access=token(3000), reject_access="Bearer " + old)
    if endpoint == "billing":
        state["reject_access"] = None
        original_http = http
        rejected = False
        def http(method, url, **kwargs):
            nonlocal rejected
            if url.endswith("/billing/limits") and not rejected:
                from jrbar.provider_usage_collectors import ProviderHttpError
                rejected = True
                raise ProviderHttpError(401, "http_error")
            return original_http(method, url, **kwargs)
    assert collect_factory(preference(), observed_at=1000, credentials=store, http_json=http).lanes
    assert len(state["refreshes"]) == 1
    state["auth_status"] = 401
    failed = collect_factory(preference(), observed_at=1001, credentials=store, http_json=http)
    assert not failed.lanes and failed.reason_code == "browser_session_expired"
    assert len(state["refreshes"]) == 2


@pytest.mark.parametrize("change", ["user", "org"])
def test_account_change_after_rotation_stops_before_billing(context, remote, change):
    home, store = context
    state, http = remote
    connect_refresh_only(home, store)
    assert collect_factory(preference(), observed_at=1000, credentials=store, http_json=http).lanes
    state[change] = "synthetic-other"
    state["requests"].clear()
    result = collect_factory(preference(), observed_at=2000, credentials=store, http_json=http)
    assert not result.lanes and result.account_discriminator is None
    assert result.reason_code == "web_session_account_changed"
    assert all(path.endswith("/auth/me") for path, _ in state["requests"])
    # Keep the rotated credential even when account validation fails.
    assert store.get("factory", "web-session").available


def test_disconnect_during_exchange_cannot_restore_session(context, remote):
    home, store = context
    state, transport = remote
    connect_refresh_only(home, store)
    def http(method, url, **kwargs):
        result = transport(method, url, **kwargs)
        if method == "POST":
            factory_session.disconnect({}, store)
        return result
    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert not result.lanes and result.reason_code == "web_session_changed"
    assert not store.get("factory", "web-session").available
    assert not state["requests"]


def test_rotation_is_saved_before_a_failed_identity_probe(context, remote):
    home, store = context
    state, http = remote
    connect_refresh_only(home, store)
    state["auth_status"] = 503
    assert not collect_factory(preference(), observed_at=1000, credentials=store, http_json=http).lanes
    assert json.loads(store.get("factory", "web-session").secret)["refresh_token"] == state["refresh"]
    state["auth_status"] = 200
    assert collect_factory(preference(), observed_at=1001, credentials=store, http_json=http).lanes
    assert len(state["refreshes"]) == 1


def test_rotated_token_save_failure_stops_before_usage(context, remote, monkeypatch):
    home, store = context
    state, http = remote
    connect_refresh_only(home, store)
    def fail(*_args):
        raise OSError("synthetic-secret")
    monkeypatch.setattr(store._backend, "set_password", fail)
    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert not result.lanes and result.reason_code == "web_session_unavailable"
    assert not state["requests"]
    assert "synthetic-secret" not in repr(result)


def test_named_rotation_changes_only_its_instance(context, remote):
    from jrbar.provider_instances import ProviderInstanceKey
    from jrbar.provider_usage_runtime import _InstanceCredentialView

    _, store = context
    _, http = remote
    default = json.dumps(session())
    store.set("factory", "web-session", default)
    work = ProviderInstanceKey("factory", "work")
    store.set_for_instance(work, "web-session", json.dumps(session(consent_version=2, access_token=token(900))))
    view = _InstanceCredentialView(store, work)
    result = collect_factory(preference(source_instance_id="work"), observed_at=1000, credentials=view, http_json=http)
    assert result.lanes and result.source_instance_id == "work"
    assert json.loads(store.get_for_instance(work, "web-session").secret)["refresh_token"] == "synthetic-rotated-1"
    assert store.get("factory", "web-session").secret == default


@pytest.mark.parametrize("value", [None, "true", 1, {}, []])
def test_refresh_permission_must_be_an_explicit_boolean(context, monkeypatch, value):
    _, store = context
    monkeypatch.setattr(factory_session, "read_browser_session", lambda *_a, **_k: pytest.fail("read without valid consent"))
    from jrbar.core_server import CommandError
    with pytest.raises(CommandError) as error:
        factory_session.import_session({"browser": "zen", "profile": "synthetic.default",
            "confirm": True, "allow_refresh": value}, store)
    assert error.value.code == "invalid_args"


def test_synthetic_workos_rotation_leaves_browser_copy_invalid_after_grace(context, remote):
    from jrbar.factory_refresh import WORKOS_URL
    from jrbar.provider_usage_collectors import ProviderHttpError

    home, store = context
    state, http = remote
    database, original = connect_refresh_only(home, store)
    assert collect_factory(preference(), observed_at=1000, credentials=store, http_json=http).lanes
    body = {"client_id": factory_session.WORKOS_CLIENT_IDS[0], "grant_type": "refresh_token",
            "refresh_token": "synthetic-refresh-token"}
    replay = http("POST", WORKOS_URL, body=body)
    assert replay["refresh_token"] == "synthetic-rotated-1"
    state["now"] = 1031
    with pytest.raises(ProviderHttpError) as rejected:
        http("POST", WORKOS_URL, body=body)
    assert rejected.value.status == 400
    assert database.read_bytes() == original


def test_api_key_fallback_does_not_spend_connected_browser_token(context, remote):
    home, store = context
    state, http = remote
    connect_refresh_only(home, store)
    store.set("factory", "api-key", "synthetic-api-key")
    assert collect_factory(preference(), observed_at=1000, credentials=store, http_json=http).lanes
    assert not state["refreshes"]
    assert all(authorization == "Bearer synthetic-api-key" for _, authorization in state["requests"])


def test_overlapping_polls_use_one_rotated_credential(context, remote):
    from concurrent.futures import ThreadPoolExecutor

    home, store = context
    state, transport = remote
    connect_refresh_only(home, store)
    started = threading.Event()
    release = threading.Event()
    second_started = threading.Event()
    def http(method, url, **kwargs):
        if method == "POST":
            started.set()
            assert release.wait(timeout=5)
        return transport(method, url, **kwargs)
    def poll(second=False):
        if second:
            second_started.set()
        return collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(poll)
        try:
            assert started.wait(timeout=5)
            second = executor.submit(poll, True)
            assert second_started.wait(timeout=5)
        finally:
            release.set()
        assert first.result(timeout=5).lanes
        assert second.result(timeout=5).lanes
    assert len(state["refreshes"]) == 1


def test_disconnect_after_client_rejection_stops_the_fallback_exchange(context, remote):
    from jrbar.provider_usage_collectors import ProviderHttpError

    home, store = context
    state, transport = remote
    connect_refresh_only(home, store)
    state["refresh_status"] = 400
    def http(method, url, **kwargs):
        try:
            return transport(method, url, **kwargs)
        except ProviderHttpError:
            factory_session.disconnect({}, store)
            raise
    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert not result.lanes and result.reason_code == "web_session_changed"
    assert len(state["refreshes"]) == 1
    assert not store.get("factory", "web-session").available


def replace_browser_refresh(database, value):
    with sqlite3.connect(database) as db:
        db.execute("UPDATE data SET value=? WHERE key='workos:refresh-token'", (value,))


def test_superseded_refresh_recovers_current_browser_once_without_writes(context, remote, monkeypatch, caplog):
    home, store = context
    state, http = remote
    database, _ = connect_refresh_only(home, store)
    state["valid_refresh"] = "synthetic-new-browser-token"
    replace_browser_refresh(database, state["valid_refresh"])
    original = database.read_bytes()
    reader = factory_session.read_browser_session
    reads = []
    def read(browser, profile, **kwargs):
        reads.append((browser, profile))
        return reader(browser, profile, **kwargs)
    monkeypatch.setattr(factory_session, "read_browser_session", read)
    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.lanes
    assert reads == [("zen", "synthetic.default")]
    assert [row["refresh_token"] for row in state["refreshes"]] == [
        "synthetic-refresh-token", "synthetic-refresh-token", "synthetic-new-browser-token"]
    saved = json.loads(store.get("factory", "web-session").secret)
    assert saved["refresh_token"] == state["refresh"] and saved["access_token"] == state["access"]
    assert not saved.get("refresh_rejected")
    assert database.read_bytes() == original
    assert "status=400 error=invalid_grant" in caplog.text
    assert "synthetic-" not in caplog.text


def test_same_token_needs_reconnect_and_backoff_bounds_browser_reads(context, remote, monkeypatch):
    home, store = context
    state, http = remote
    connect_refresh_only(home, store)
    state["refresh_status"] = 400
    reader = factory_session.read_browser_session
    reads = []
    def read(*args, **kwargs):
        reads.append(True)
        return reader(*args, **kwargs)
    monkeypatch.setattr(factory_session, "read_browser_session", read)
    for now, expected_reads, expected_next in [(1000, 1, 1060), (1001, 1, 1060), (1060, 2, 1180), (1179, 2, 1180)]:
        result = collect_factory(preference(), observed_at=now, credentials=store, http_json=http)
        assert not result.lanes and result.reason_code == "factory_refresh_invalid_grant"
        saved = json.loads(store.get("factory", "web-session").secret)
        assert saved["refresh_status"] == 400 and saved["refresh_retry_at"] == expected_next
        assert len(reads) == expected_reads
    # Same failed token is never exchanged again, even when the browser-read backoff expires.
    assert len(state["refreshes"]) == 2


def test_rejected_session_can_recover_after_backoff(context, remote):
    home, store = context
    state, http = remote
    database, _ = connect_refresh_only(home, store)
    state["valid_refresh"] = "synthetic-future-browser-token"
    assert collect_factory(preference(), observed_at=1000, credentials=store, http_json=http).reason_code == "factory_refresh_invalid_grant"
    replace_browser_refresh(database, state["valid_refresh"])
    assert not collect_factory(preference(), observed_at=1059, credentials=store, http_json=http).lanes
    assert collect_factory(preference(), observed_at=1060, credentials=store, http_json=http).lanes
    assert len(state["refreshes"]) == 3


def test_browser_retry_rejection_keeps_class_and_never_reads_again_in_cycle(context, remote, monkeypatch):
    home, store = context
    state, http = remote
    database, _ = connect_refresh_only(home, store)
    replace_browser_refresh(database, "synthetic-also-expired")
    state.update(refresh_status=401, refresh_error="invalid_request")
    reader = factory_session.read_browser_session
    reads = []
    def read(*args, **kwargs):
        reads.append(True)
        return reader(*args, **kwargs)
    monkeypatch.setattr(factory_session, "read_browser_session", read)
    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.reason_code == "factory_refresh_invalid_request"
    assert len(reads) == 1 and len(state["refreshes"]) == 4
    assert json.loads(store.get("factory", "web-session").secret)["refresh_status"] == 401


def test_invalid_client_tries_next_client_even_when_one_was_saved(context, remote):
    home, store = context
    state, http = remote
    connect_refresh_only(home, store)
    saved = json.loads(store.get("factory", "web-session").secret)
    store.set("factory", "web-session", json.dumps({**saved, "client_id": factory_session.WORKOS_CLIENT_IDS[0]}))
    state["reject_client"] = factory_session.WORKOS_CLIENT_IDS[0]
    assert collect_factory(preference(), observed_at=1000, credentials=store, http_json=http).lanes
    assert [row["client_id"] for row in state["refreshes"]] == list(factory_session.WORKOS_CLIENT_IDS)


@pytest.mark.parametrize("organization", ["synthetic-org", '"synthetic-org"'])
def test_organization_storage_decodes_raw_and_json_quoted(context, remote, organization):
    home, store = context
    _, http = remote
    database, _ = connect_refresh_only(home, store)
    with sqlite3.connect(database) as db:
        db.execute("UPDATE data SET value=? WHERE key='factory:active-organization-id'", (organization,))
    factory_session.import_session({"browser": "zen", "profile": "synthetic.default", "confirm": True, "allow_refresh": True}, store)
    assert json.loads(store.get("factory", "web-session").secret)["organization_id"] == "synthetic-org"
    assert collect_factory(preference(), observed_at=1000, credentials=store, http_json=http).lanes


def test_jwt_organization_takes_priority_over_active_storage_hint(context):
    home, store = context
    database, _ = connect_refresh_only(home, store)
    with sqlite3.connect(database) as db:
        db.execute("INSERT INTO data VALUES ('workos:access-token', ?, 0)", (token(2000, org="synthetic-jwt-org"),))
    imported = factory_session.read_browser_session("zen", "synthetic.default")
    assert imported["organization_id"] == "synthetic-jwt-org"


@pytest.mark.parametrize("code", ["invalid_grant", "invalid_client", "invalid_request", "session_ended",
                                  "synthetic-private-value", "Synthetic Private Value", "x" * 60,
                                  {"secret": "synthetic-private-value"}])
def test_workos_errors_keep_only_safe_codes(context, remote, caplog, code):
    from jrbar.provider_availability import availability_document

    home, store = context
    state, http = remote
    connect_refresh_only(home, store)
    state.update(refresh_status=400, refresh_error=code)
    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    safe = {"invalid_grant", "invalid_client", "invalid_request", "session_ended"}
    expected = code if isinstance(code, str) and code in safe else "unknown_error"
    assert result.reason_code == "factory_refresh_" + expected
    document = availability_document(result, now=1000, installed=True)
    assert expected in document["status_text"] and "Connect Factory" in document["status_text"]
    assert "synthetic-" not in caplog.text + repr(result) + repr(document)


def test_recovery_requires_current_v2_profile_and_instance_consent(context, remote, monkeypatch):
    from jrbar.provider_browser_consent import load_browser_consents, save_browser_consents

    home, store = context
    state, http = remote
    connect_refresh_only(home, store)
    loaded = load_browser_consents()
    updated = loaded.store.revoke("factory", "zen", "synthetic.default")
    save_browser_consents(updated, loaded=loaded)
    monkeypatch.setattr(factory_session, "read_browser_session", lambda *_a, **_k: pytest.fail("read without consent"))
    state["refresh_status"] = 400
    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.reason_code == "factory_refresh_invalid_grant"


def test_workos_code_field_is_read_when_error_is_absent():
    from jrbar.provider_usage_collectors import _safe_error_code
    assert _safe_error_code("organization_selection_required")
    assert not _safe_error_code("eyJhbGciOi.synthetic")
    assert not _safe_error_code("")


def test_workos_reasons_sent_as_code_are_shown(context, remote):
    home, store = context
    state, http = remote
    connect_refresh_only(home, store)
    state.update(refresh_status=400, refresh_error="session_ended", error_field="code")
    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.reason_code == "factory_refresh_session_ended"


def test_a_workos_organization_is_sent_and_dropped_when_workos_does_not_know_it(context, remote):
    home, store = context
    state, http = remote
    connect_refresh_only(home, store)
    session = json.loads(store.get("factory", "web-session").secret)
    session["organization_id"] = "org_synthetic"
    store.set_for_instance(factory_session._instance({}), "web-session", json.dumps(session, separators=(",", ":"), sort_keys=True))
    state.update(reject_org="org_synthetic")
    result = collect_factory(preference(), observed_at=1000, credentials=store, http_json=http)
    assert result.lanes, (result.state, result.reason_code, state["refreshes"])
    sent = [body.get("organization_id") for body in state["refreshes"]]
    assert sent[:2] == ["org_synthetic", None]
