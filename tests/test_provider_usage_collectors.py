from __future__ import annotations

import json
import sqlite3
from dataclasses import replace
from pathlib import Path

from jrbar.provider_usage_collectors import (
    ProviderHttpError,
    collect_antigravity,
    collect_cursor,
    collect_devin,
    collect_grok,
    collect_openai_api,
    collect_opencode,
)
from jrbar.provider_usage_settings import default_provider_usage_settings


class FixtureCredentials:
    """Inert test-only credential source. Values are not real credentials."""

    def __init__(self, values=None):
        self.values = values or {}

    def get(self, provider, account):
        value = self.values.get((provider, account))
        return type(
            "Read",
            (),
            {
                "available": value is not None,
                "secret": value,
                "reason": None if value is not None else "credential_not_found",
            },
        )()


class FixtureHttp:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def __call__(self, method, url, *, headers=None, body=None, timeout=20.0):
        self.calls.append((method, url, headers or {}, body, timeout))
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


def preference(provider, **changes):
    pref = default_provider_usage_settings().preference(provider)
    if "browser_sources" in changes:
        pref = replace(pref, browser_sources=changes["browser_sources"])
    for key, value in changes.get("options", {}).items():
        pref = pref.with_option(key, value)
    return pref


def test_cursor_reads_local_app_session_and_fetches_usage(tmp_path: Path):
    db = tmp_path / "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    db.parent.mkdir(parents=True)
    with sqlite3.connect(db) as connection:
        connection.execute("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)")
        connection.execute(
            "INSERT INTO ItemTable(key, value) VALUES (?, ?)",
            ("cursorAuth/accessToken", "fixture-cursor-session"),
        )
    http = FixtureHttp(
        [
            {"email": "person@example.invalid"},
            {"planUsage": {"usedPercent": 30}, "billingCycleEnd": 3000},
        ]
    )

    result = collect_cursor(
        preference("cursor"), home=tmp_path, observed_at=1000, http_json=http
    )

    assert result.state.value == "ready"
    assert result.lanes[0].remaining_percent == 70
    assert result.account_label == "person@example.invalid"
    assert http.calls[0][2]["Authorization"] == "Bearer fixture-cursor-session"
    assert http.calls[1][1].endswith("/api/usage-summary")


def test_cursor_without_local_auth_explains_browser_consent(tmp_path: Path):
    result = collect_cursor(
        preference("cursor"),
        home=tmp_path,
        observed_at=1000,
        http_json=FixtureHttp([]),
    )
    assert result.state.value == "needs_consent"
    assert result.action_label == "Enable Cursor browser access"


def test_devin_uses_sidepulse_credential_and_org_endpoint():
    http = FixtureHttp(
        [
            {
                "daily": {"used_percent": 10, "resets_at": 2000},
                "weekly": {"used_percent": 20, "resets_at": 3000},
            }
        ]
    )
    result = collect_devin(
        preference("devin", options={"organization": "org_fixture"}),
        observed_at=1000,
        credentials=FixtureCredentials({("devin", "token"): "fixture-devin-session"}),
        http_json=http,
    )
    assert result.state.value == "ready"
    assert "/api/org_fixture/billing/quota/usage" in http.calls[0][1]
    assert http.calls[0][2]["Authorization"] == "Bearer fixture-devin-session"


def test_grok_reads_local_auth_and_cli_proxy(tmp_path: Path):
    grok = tmp_path / ".grok"
    grok.mkdir()
    (grok / "auth.json").write_text(
        json.dumps(
            {
                "https://auth.x.ai::fixture": {
                    "key": "fixture-grok-session",
                    "expires_at": 9999999999,
                    "email": "person@example.invalid",
                    "auth_mode": "supergrok",
                }
            }
        )
    )
    http = FixtureHttp(
        [{"config": {"creditUsagePercent": 44, "billingPeriodEnd": 3000}}]
    )
    result = collect_grok(
        preference("grok"),
        home=tmp_path,
        observed_at=1000,
        credentials=FixtureCredentials(),
        http_json=http,
    )
    assert result.state.value == "ready"
    assert result.lanes[0].remaining_percent == 56
    assert result.account_label == "person@example.invalid"
    assert http.calls[0][2]["x-xai-token-auth"] == "xai-grok-cli"


def test_grok_missing_login_is_actionable(tmp_path: Path):
    result = collect_grok(
        preference("grok"),
        home=tmp_path,
        observed_at=1000,
        credentials=FixtureCredentials(),
        http_json=FixtureHttp([]),
    )
    assert result.state.value == "needs_sign_in"
    assert result.action_label == "Run grok login"


def test_antigravity_uses_configured_loopback_endpoint__and_2_more(tmp_path: Path) -> None:
    # --- scenario: antigravity_uses_configured_loopback_endpoint
    http = FixtureHttp(
        [
            {
                "response": {
                    "groups": [
                        {
                            "displayName": "Gemini Models",
                            "buckets": [
                                {
                                    "bucketId": "weekly",
                                    "remaining": {"remainingFraction": 0.75},
                                }
                            ],
                        }
                    ]
                }
            }
        ]
    )
    result = collect_antigravity(
        preference("antigravity", options={"endpoint": "https://127.0.0.1:4321"}),
        observed_at=1000,
        http_json=http,
        command_runner=lambda _args, _timeout: "",
        home=tmp_path,
    )
    assert result.state.value == "ready"
    assert result.lanes[0].label == "Gemini Weekly"
    assert "RetrieveUserQuotaSummary" in http.calls[0][1]

    # --- scenario: antigravity_allows_http_loopback_and_discovers_dynamically
    payload = {
        "response": {
            "groups": [
                {
                    "displayName": "Gemini Models",
                    "buckets": [
                        {
                            "bucketId": "weekly",
                            "remaining": {"remainingFraction": 0.9},
                        }
                    ],
                }
            ]
        }
    }
    http = FixtureHttp([payload])
    # http:// scheme allowed
    result = collect_antigravity(
        preference("antigravity", options={"endpoint": "http://127.0.0.1:54321"}),
        observed_at=1000,
        http_json=http,
        home=tmp_path,
    )
    assert result.state.value == "ready"
    assert "http://127.0.0.1:54321" in http.calls[0][1]

    # Dynamic discovery via command_runner
    def runner(args, _timeout):
        if args[0] == "ps":
            return "12345 /opt/antigravity/bin/language_server --csrf_token testcsrf123\n"
        if args[0] == "lsof":
            return "language 12345 user 12u IPv4 0x1234 0t0 TCP 127.0.0.1:44556 (LISTEN)\n"
        return ""

    http2 = FixtureHttp([payload])
    res2 = collect_antigravity(
        preference("antigravity"),
        observed_at=1000,
        http_json=http2,
        command_runner=runner,
        process_identity_resolver=lambda pid: (
            pid,
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server",
            501,
            123456,
            789,
        ),
        home=tmp_path,
    )
    assert res2.state.value == "ready"
    assert "http://127.0.0.1:44556" in http2.calls[0][1]
    assert http2.calls[0][2]["X-Codeium-Csrf-Token"] == "testcsrf123"

    # --- scenario: antigravity_multi_port_discovery_tries_candidate_ports
    payload = {
        "response": {
            "groups": [
                {
                    "displayName": "Gemini Models",
                    "buckets": [
                        {
                            "bucketId": "weekly",
                            "remaining": {"remainingFraction": 0.93},
                        },
                        {
                            "bucketId": "5h",
                            "remaining": {"remainingFraction": 0.58},
                        },
                    ],
                },
                {
                    "displayName": "Claude and GPT models",
                    "buckets": [
                        {
                            "bucketId": "weekly",
                            "remaining": {"remainingFraction": 0.83},
                        },
                        {
                            "bucketId": "5h",
                            "remaining": {"remainingFraction": 1.0},
                        },
                    ],
                },
            ]
        }
    }

    # Simulate port 1 failing (e.g. 400 HTTPS error) and port 2 succeeding
    def http_fail_then_succeed(method, url, **kwargs):
        if "59237" in url:
            raise ProviderHttpError(400, "Bad Request: Client sent an HTTP request to an HTTPS server")
        return payload

    def runner(args, _timeout):
        if args[0] == "ps":
            return "31583 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token csrfABC\n"
        if args[0] == "lsof":
            return "ls 31583 user 12u IPv4 0x1 0t0 TCP 127.0.0.1:59237 (LISTEN)\nls 31583 user 13u IPv4 0x2 0t0 TCP 127.0.0.1:59238 (LISTEN)\n"
        return ""

    result = collect_antigravity(
        preference("antigravity"),
        observed_at=1000,
        http_json=http_fail_then_succeed,
        command_runner=runner,
        process_identity_resolver=lambda pid: (
            pid,
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server",
            501,
            123456,
            789,
        ),
        home=tmp_path,
    )
    assert result.state.value == "ready"
    assert len(result.lanes) == 4
    labels = [lane.label for lane in result.lanes]
    assert "Gemini Weekly" in labels
    assert "Gemini 5-Hour" in labels
    assert "Claude + GPT Weekly" in labels
    assert "Claude + GPT 5-Hour" in labels



def test_antigravity_endpoint_cache_reuses_only_the_same_verified_process__and_2_more(
    tmp_path: Path,
) -> None:
    # --- scenario: antigravity_endpoint_cache_reuses_only_the_same_verified_process
    import jrbar.provider_usage_collectors as puc

    puc._cached_antigravity_connection.clear()
    puc._cached_antigravity_connection["endpoint"] = "http://127.0.0.1:9999"
    puc._cached_antigravity_connection["csrf"] = "token-123"
    identity = (
        12345,
        "/Applications/Antigravity.app/Contents/Resources/bin/language_server",
        501,
        123456,
        789,
    )
    puc._cached_antigravity_connection["pid"] = identity[0]
    puc._cached_antigravity_connection["process_identity"] = identity

    called_urls = []
    def mock_http(method, url, **kwargs):
        called_urls.append(url)
        return {
            "groups": [
                {
                    "displayName": "Gemini Models",
                    "buckets": [
                        {
                            "displayName": "Weekly",
                            "bucketId": "weekly",
                            "remaining": {"remainingFraction": 0.9},
                        }
                    ],
                }
            ]
        }

    res = puc.collect_antigravity(
        preference("antigravity"),
        observed_at=1000,
        http_json=mock_http,
        process_identity_resolver=lambda pid: identity if pid == identity[0] else None,
        home=tmp_path,
    )
    assert res.state.value == "ready"
    assert len(called_urls) == 1
    assert "http://127.0.0.1:9999" in called_urls[0]
    puc._cached_antigravity_connection.clear()

    # --- scenario: antigravity_discovery_rejects_process_name_spoof_before_http
    def runner(args, _timeout):
        if args[0] == "ps":
            return "12345 /tmp/language_server --csrf_token attacker\n"
        if args[0] == "lsof":
            return "fake 12345 user 12u IPv4 0x1 0t0 TCP 127.0.0.1:44556 (LISTEN)\n"
        return ""

    http_calls = []
    result = collect_antigravity(
        preference("antigravity"),
        observed_at=1000,
        http_json=lambda *args, **kwargs: http_calls.append((args, kwargs)),
        command_runner=runner,
        process_identity_resolver=lambda _pid: None,
        home=Path("/nonexistent-antigravity-test-home"),
    )

    assert result.state.value == "source_not_found"
    assert http_calls == []

    # --- scenario: antigravity_cache_is_dropped_when_pid_identity_changes
    import jrbar.provider_usage_collectors as puc

    old_identity = (
        12345,
        "/Applications/Antigravity.app/Contents/Resources/bin/language_server",
        501,
        123456,
        789,
    )
    replacement_identity = (*old_identity[:3], 123457, 100)
    puc._cached_antigravity_connection.clear()
    puc._cached_antigravity_connection.update(
        endpoint="http://127.0.0.1:9999",
        csrf="token-123",
        pid=old_identity[0],
        process_identity=old_identity,
    )
    http_calls = []

    result = collect_antigravity(
        preference("antigravity"),
        observed_at=1000,
        http_json=lambda *args, **kwargs: http_calls.append((args, kwargs)),
        command_runner=lambda _args, _timeout: "",
        process_identity_resolver=lambda _pid: replacement_identity,
        home=Path("/nonexistent-antigravity-test-home"),
    )

    assert result.state.value == "source_not_found"
    assert http_calls == []
    assert puc._cached_antigravity_connection == {}



def test_openai_admin_usage_uses_official_organization_endpoints__and_2_more() -> None:
    # --- scenario: openai_admin_usage_uses_official_organization_endpoints
    http = FixtureHttp(
        [
            {
                "data": [
                    {
                        "results": [
                            {"input_tokens": 10, "output_tokens": 5, "model": "gpt-fixture"}
                        ]
                    }
                ]
            },
            {"data": [{"results": [{"amount": {"value": 1.25}}]}]},
        ]
    )
    result = collect_openai_api(
        preference("openai-api"),
        observed_at=2_000_000,
        credentials=FixtureCredentials(
            {("openai-api", "admin-key"): "fixture-openai-admin-session"}
        ),
        http_json=http,
    )
    assert result.state.value == "ready"
    assert result.estimated_cost_usd == 1.25
    assert "/v1/organization/usage/completions" in http.calls[0][1]
    assert "/v1/organization/costs" in http.calls[1][1]

    # --- scenario: http_unauthorized_maps_to_sign_in_required
    result = collect_devin(
        preference("devin", options={"organization": "org_fixture"}),
        observed_at=1000,
        credentials=FixtureCredentials({("devin", "token"): "fixture-invalid"}),
        http_json=FixtureHttp([ProviderHttpError(401, "unauthorized")]),
    )
    assert result.state.value == "needs_sign_in"
    assert result.reason_code == "authentication_required"

    # --- scenario: devin_sends_the_org_header_the_endpoint_actually_requires
    """A valid session token alone returns 401. Confirmed live against a
    real account: the request only authenticates when it also carries
    x-cog-org-id, which is why "Import" could appear to succeed and the
    card still said reconnect."""
    http = FixtureHttp([{"daily_percentage": 80, "weekly_percentage": 40}])
    result = collect_devin(
        preference(
            "devin",
            options={"organization": "org/acme", "organization_id": "org-abc12345"},
        ),
        observed_at=1000,
        credentials=FixtureCredentials({("devin", "token"): "auth1_fixture"}),
        http_json=http,
    )
    assert result.state.value == "ready"
    _method, url, headers = http.calls[0][:3]
    assert headers["x-cog-org-id"] == "org-abc12345"
    # The internal id is the path segment the endpoint answers on, and
    # the slash in an "org/<slug>" value must survive: quote(safe="")
    # used to escape it to %2F, so no stored org shape could ever work.
    assert "/api/org-abc12345/billing/quota/usage" in url
    assert "%2F" not in url



def test_devin_browser_setting_requires_an_explicit_import_before_collection__and_2_more() -> None:
    # --- scenario: devin_browser_setting_requires_an_explicit_import_before_collection
    http = FixtureHttp([])
    result = collect_devin(
        preference("devin", browser_sources=True),
        observed_at=1000,
        credentials=FixtureCredentials({}),
        http_json=http,
    )
    assert result.state.value == "source_not_found"
    assert result.action_label == "Import Devin browser session"
    assert http.calls == []

    # --- scenario: devin_without_browser_access_still_asks_for_consent_first
    result = collect_devin(
        preference("devin", browser_sources=False),
        observed_at=1000,
        credentials=FixtureCredentials({}),
        http_json=FixtureHttp([]),
    )
    assert result.state.value == "needs_consent"
    assert result.action_label == "Enable Devin browser access"

    # --- scenario: devin_uses_only_the_explicitly_imported_stored_session
    http = FixtureHttp([{"daily_percentage": 10}])
    result = collect_devin(
        preference(
            "devin",
            browser_sources=True,
            options={"organization_id": "org-abc12345"},
        ),
        observed_at=1000,
        credentials=FixtureCredentials({("devin", "token"): "auth1_exact_import"}),
        http_json=http,
    )
    assert result.state.value == "ready"
    assert http.calls[0][2]["Authorization"] == "Bearer auth1_exact_import"



def test_devin_uses_a_manual_stored_token_when_browser_sources_are_enabled__and_2_more() -> None:
    # --- scenario: devin_uses_a_manual_stored_token_when_browser_sources_are_enabled
    http = FixtureHttp([{"daily_percentage": 10}])
    result = collect_devin(
        preference(
            "devin",
            browser_sources=True,
            options={"organization_id": "org-abc12345"},
        ),
        observed_at=1000,
        credentials=FixtureCredentials({("devin", "token"): "pasted-key"}),
        http_json=http,
    )
    assert result.state.value == "ready"
    assert http.calls[0][2]["Authorization"] == "Bearer pasted-key"

    # --- scenario: codex_reading_that_stopped_moving_is_reported_stale
    """Reported live as "why does it say 48 percent, it should be around
    96": the 48 was computed from a rollout written three days earlier.
    Codex quota is only as fresh as the newest rollout, and usage burned
    elsewhere is invisible here, so a frozen reading must say so."""
    from jrbar.provider_usage_codex_claude import (
        CODEX_READING_STALE_SECONDS,
        collect_codex,
    )

    now = 1_000_000.0

    def scan(_home, _observed_at):
        return {
            "windows": [
                {"label": "primary", "window_minutes": 10080, "used_percent": 52.0}
            ],
            "windows_observed_at": now - CODEX_READING_STALE_SECONDS - 60.0,
        }

    result = collect_codex(
        preference("codex"), home=Path("/tmp"), observed_at=now, local_scanner=scan
    )
    assert result.state.value == "stale"
    assert result.reason_code == "local_reading_stale"
    # The number is still shown -- it is the newest thing known, just old.
    assert result.lanes[0].remaining_percent == 48.0
    assert "ago" in result.action_label
    # The card's "read ... ago" names when the rollout was written, not when
    # this poll ran: observed_at is the attempt, read_at is the reading.
    assert result.observed_at == now
    assert result.read_at == now - CODEX_READING_STALE_SECONDS - 60.0

    # --- scenario: a_fresh_codex_reading_is_not_flagged
    from jrbar.provider_usage_codex_claude import collect_codex

    now = 1_000_000.0

    def scan(_home, _observed_at):
        return {
            "windows": [
                {"label": "primary", "window_minutes": 10080, "used_percent": 52.0}
            ],
            "windows_observed_at": now - 60.0,
        }

    result = collect_codex(
        preference("codex"), home=Path("/tmp"), observed_at=now, local_scanner=scan
    )
    assert result.state.value == "ready"
    assert result.action_label is None
    assert result.read_at is None

    # --- scenario: a_codex_evidence_time_that_is_not_a_time_is_not_flagged
    from jrbar.provider_usage_codex_claude import collect_codex

    now = 1_000_000.0

    def scan(_home, _observed_at):
        return {
            "windows": [
                {"label": "primary", "window_minutes": 10080, "used_percent": 52.0}
            ],
            "windows_observed_at": float("nan"),
        }

    result = collect_codex(
        preference("codex"), home=Path("/tmp"), observed_at=now, local_scanner=scan
    )
    assert result.state.value == "ready"
    assert result.read_at is None



def _write_gemini_home(tmp_path: Path, *, steps: int | None = None) -> None:
    """A synthetic Gemini CLI home: a sign-in file and, when asked, a summaries db."""
    gemini_dir = tmp_path / ".gemini"
    gemini_dir.mkdir(parents=True, exist_ok=True)
    (gemini_dir / "oauth_creds.json").write_text(
        json.dumps({"email": "testuser@example.com"}), encoding="utf-8"
    )
    if steps is not None:
        db_dir = gemini_dir / "antigravity-cli"
        db_dir.mkdir(parents=True, exist_ok=True)
        con = sqlite3.connect(db_dir / "conversation_summaries.db")
        con.execute(
            "CREATE TABLE conversation_summaries "
            "(conversation_id TEXT, step_count INT, last_modified_time TEXT)"
        )
        con.execute("INSERT INTO conversation_summaries VALUES ('c1', ?, 't')", (steps,))
        con.commit()
        con.close()


_ANTIGRAVITY_STABLE_IDENTITY = (
    12345,
    "/Applications/Antigravity.app/Contents/Resources/bin/language_server",
    501,
    123456,
    789,
)


def _duplicate_lane_payload() -> dict:
    """Two Gemini groups that each carry a weekly bucket: the same lane id twice."""
    bucket = {"bucketId": "weekly", "remaining": {"remainingFraction": 0.5}}
    return {
        "response": {
            "groups": [
                {"displayName": "Gemini Pro", "buckets": [dict(bucket)]},
                {"displayName": "Gemini Flash", "buckets": [dict(bucket)]},
            ]
        }
    }


def test_antigravity_without_a_running_server_invents_no_lane__and_1_more(tmp_path: Path) -> None:
    # --- scenario: antigravity_without_a_running_server_invents_no_lane
    _write_gemini_home(tmp_path, steps=10)

    result = collect_antigravity(
        preference("antigravity"),
        observed_at=1000,
        command_runner=lambda _args, _timeout: "",
        home=tmp_path,
    )
    # A Gemini CLI sign-in is not an Antigravity quota: nothing was measured,
    # so there is no lane, no token figure, and the row says what to do.
    assert result.state.value == "source_not_found"
    assert result.state.value != "ready"
    assert result.reason_code == "antigravity_not_detected"
    assert result.action_label
    assert result.action_label.startswith("Open Antigravity")
    assert result.lanes == ()
    assert result.input_tokens == 0

    # --- scenario: opencode_collector_reports_tokens_and_no_invented_quota
    root = tmp_path / ".local" / "share" / "opencode"
    root.mkdir(parents=True)
    auth_file = root / "auth.json"
    auth_file.write_text(json.dumps({"github-copilot": {"token": "test"}}), encoding="utf-8")
    db_file = root / "opencode.db"
    con = sqlite3.connect(db_file)
    con.execute("CREATE TABLE session (tokens_input INT, tokens_output INT, model TEXT)")
    con.execute("INSERT INTO session VALUES (500, 100, 'muse-spark')")
    con.execute("CREATE TABLE message (id TEXT, session_id TEXT, time_created INT, data TEXT)")
    err_json = json.dumps({"error": {"type": "FreeUsageLimitError"}})
    observed = 1_700_000_000.0
    err_time_ms = int((observed - 600.0) * 1000.0)
    con.execute("INSERT INTO message VALUES ('m1', 's1', ?, ?)", (err_time_ms, err_json))
    con.commit()
    con.close()

    result = collect_opencode(
        preference("opencode"),
        observed_at=observed,
        home=tmp_path,
        env={},
    )
    # A Copilot sign-in is not an OpenCode quota, and a logged limit error
    # is an incident: no lane is invented from either (see
    # tests/test_opencode_go_usage.py for the OpenCode Go source).
    assert result.state.value == "unsupported"
    assert result.reason_code == "opencode_no_quota_source"
    assert result.account_label is None
    assert result.input_tokens == 500
    assert result.output_tokens == 100
    assert result.lanes == ()
    assert result.incident is not None


def test_antigravity_real_quota_carries_no_steps_estimate(tmp_path: Path) -> None:
    # A step count proves activity, not tokens: even with a summaries db on
    # disk and a server that answers, the token figure is not made up.
    _write_gemini_home(tmp_path, steps=10)
    payload = {
        "response": {
            "groups": [
                {
                    "displayName": "Gemini Models",
                    "buckets": [
                        {"bucketId": "weekly", "remaining": {"remainingFraction": 0.3}}
                    ],
                }
            ]
        }
    }
    http = FixtureHttp([payload])
    result = collect_antigravity(
        preference("antigravity", options={"endpoint": "http://127.0.0.1:54321"}),
        observed_at=1000,
        http_json=http,
        command_runner=lambda _args, _timeout: "",
        home=tmp_path,
    )
    assert result.state.value == "ready"
    assert [lane.lane_id for lane in result.lanes] == ["gemini-weekly"]
    assert result.lanes[0].source_id == "antigravity-app"
    assert result.input_tokens == 0


def test_antigravity_answer_the_parser_rejects_is_an_error_not_a_fake_lane(
    tmp_path: Path,
) -> None:
    _write_gemini_home(tmp_path, steps=10)
    for payload in (_duplicate_lane_payload(), {"unexpected": 1}):
        http = FixtureHttp([payload])
        result = collect_antigravity(
            preference("antigravity", options={"endpoint": "http://127.0.0.1:54321"}),
            observed_at=1000,
            http_json=http,
            command_runner=lambda _args, _timeout: "",
            home=tmp_path,
        )
        assert result.state.value == "error"
        assert result.state.value != "ready"
        assert result.reason_code == "invalid_provider_response"
        assert result.lanes == ()
        assert result.input_tokens == 0


def test_antigravity_odd_answer_outranks_a_sibling_port_http_error(tmp_path: Path) -> None:
    # Discovery tries several ports. A server that answered with a payload
    # we cannot read is better evidence than a neighbour port's 400.
    _write_gemini_home(tmp_path)

    def runner(args, _timeout):
        if args[0] == "ps":
            return "12345 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token abc\n"
        if args[0] == "lsof":
            return (
                "ls 12345 user 12u IPv4 0x1 0t0 TCP 127.0.0.1:59237 (LISTEN)\n"
                "ls 12345 user 13u IPv4 0x2 0t0 TCP 127.0.0.1:59238 (LISTEN)\n"
            )
        return ""

    def http(method, url, **kwargs):
        if "59237" in url:
            return _duplicate_lane_payload()
        raise ProviderHttpError(400, "Bad Request")

    result = collect_antigravity(
        preference("antigravity"),
        observed_at=1000,
        http_json=http,
        command_runner=runner,
        process_identity_resolver=lambda _pid: _ANTIGRAVITY_STABLE_IDENTITY,
        home=tmp_path,
    )
    assert result.state.value == "error"
    assert result.reason_code == "invalid_provider_response"
    assert result.reason_code != "network_unavailable"
    assert result.lanes == ()


def test_antigravity_server_that_answers_401_needs_sign_in(tmp_path: Path) -> None:
    _write_gemini_home(tmp_path)
    http = FixtureHttp([ProviderHttpError(401, "unauthorized")])
    result = collect_antigravity(
        preference("antigravity", options={"endpoint": "http://127.0.0.1:54321"}),
        observed_at=1000,
        http_json=http,
        command_runner=lambda _args, _timeout: "",
        home=tmp_path,
    )
    assert result.state.value == "needs_sign_in"
    assert result.reason_code == "authentication_required"
    assert result.lanes == ()
