"""W05: the Gemini Code Assist quota source.

Every classification below was verified live on 2026-09-13 against
cloudcode-pa.googleapis.com on the owner's account: the free tier is
retired for this client (ineligibleTiers -> UNSUPPORTED_CLIENT), a
non-onboarded account gets no cloudaicompanionProject, and
retrieveUserQuota answers 403 "no valid license" -- an onboarding state,
not an authentication one.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from test_provider_usage_collectors import FixtureCredentials, FixtureHttp, preference

from jrbar.provider_usage_collectors import (
    ProviderHttpError,
    collect_gemini,
)
from jrbar.provider_usage_parsers import parse_gemini_usage
from jrbar.provider_usage_platform import ProviderSourceState

NOW = 1_789_346_400.0


def _oauth_dir(tmp_path: Path, **fields) -> Path:
    gemini_dir = tmp_path / ".gemini"
    gemini_dir.mkdir(parents=True, exist_ok=True)
    creds = {
        "access_token": "ya29.live-token",
        "expiry_date": int((NOW + 3600) * 1000),
        "refresh_token": "1//refresh",
        "token_type": "Bearer",
        "id_token": "h." + __import__("base64").urlsafe_b64encode(
            json.dumps({"email": "owner@example.com"}).encode()
        ).decode().rstrip("=") + ".s",
    }
    creds.update(fields)
    for key in [key for key, value in creds.items() if value is None]:
        del creds[key]
    (gemini_dir / "oauth_creds.json").write_text(json.dumps(creds))
    return tmp_path


@pytest.fixture(autouse=True)
def _no_project_env(monkeypatch):
    monkeypatch.delenv("GOOGLE_CLOUD_PROJECT", raising=False)
    monkeypatch.delenv("GCLOUD_PROJECT", raising=False)


def test_gemini_quota_buckets_become_model_lanes(tmp_path):
    http = FixtureHttp(
        [
            {
                "buckets": [
                    {
                        "modelId": "gemini-3-pro",
                        "remainingFraction": 0.42,
                        "remainingAmount": 21,
                        "resetTime": "2026-09-14T00:00:00Z",
                    },
                    {"modelId": "gemini-3-flash", "remainingFraction": 1.0},
                ]
            }
        ]
    )
    snapshot = collect_gemini(
        preference("gemini", options={"project_id": "my-gcp-project"}),
        home=_oauth_dir(tmp_path),
        observed_at=NOW,
        credentials=FixtureCredentials(),
        http_json=http,
    )
    assert snapshot.state is ProviderSourceState.READY
    assert snapshot.account_label == "owner@example.com"
    assert len(snapshot.lanes) == 2
    pro = snapshot.lanes[0]
    assert pro.model == "gemini-3-pro"
    assert pro.remaining_percent == pytest.approx(42.0)
    assert pro.reset_at is not None
    # The endpoint reports only model-scoped buckets: no lane may pose as
    # the account's own ceiling (T22).
    assert all(not lane.bindable for lane in snapshot.lanes)
    method, url, headers, body, _ = http.calls[0]
    assert method == "POST"
    assert url.endswith(":retrieveUserQuota")
    assert body == {"project": "my-gcp-project"}
    assert headers["Authorization"] == "Bearer ya29.live-token"


def test_gemini_project_discovered_via_load_code_assist(tmp_path):
    http = FixtureHttp(
        [
            {"cloudaicompanionProject": "discovered-proj"},
            {"buckets": [{"modelId": "gemini-3-pro", "remainingFraction": 0.9}]},
        ]
    )
    snapshot = collect_gemini(
        preference("gemini"),
        home=_oauth_dir(tmp_path),
        observed_at=NOW,
        credentials=FixtureCredentials(),
        http_json=http,
    )
    assert snapshot.state is ProviderSourceState.READY
    assert http.calls[0][1].endswith(":loadCodeAssist")
    assert http.calls[1][4 - 1] == {"project": "discovered-proj"}


def test_gemini_expired_token_refreshes_in_memory(tmp_path):
    home = _oauth_dir(tmp_path, expiry_date=int((NOW - 60) * 1000))
    creds_path = home / ".gemini" / "oauth_creds.json"
    before = creds_path.read_text()
    http = FixtureHttp(
        [
            {"access_token": "ya29.fresh-token", "expires_in": 3600},
            {"cloudaicompanionProject": "discovered-proj"},
            {"buckets": [{"modelId": "gemini-3-pro", "remainingFraction": 0.5}]},
        ]
    )
    snapshot = collect_gemini(
        preference("gemini"),
        home=home,
        observed_at=NOW,
        credentials=FixtureCredentials(),
        http_json=http,
    )
    assert snapshot.state is ProviderSourceState.READY
    refresh_call = http.calls[0]
    assert refresh_call[1] == "https://oauth2.googleapis.com/token"
    assert refresh_call[3]["grant_type"] == "refresh_token"
    # The creds file belongs to the Gemini CLI; a refresh never rewrites it.
    assert creds_path.read_text() == before


def test_gemini_no_credentials_needs_sign_in(tmp_path):
    snapshot = collect_gemini(
        preference("gemini"),
        home=tmp_path,
        observed_at=NOW,
        credentials=FixtureCredentials(),
        http_json=FixtureHttp([]),
    )
    assert snapshot.state is ProviderSourceState.NEEDS_SIGN_IN
    assert snapshot.reason_code == "authentication_required"
    assert "gemini" in (snapshot.action_label or "").lower()


def test_gemini_expired_without_refresh_needs_sign_in(tmp_path):
    snapshot = collect_gemini(
        preference("gemini"),
        home=_oauth_dir(tmp_path, expiry_date=int((NOW - 60) * 1000), refresh_token=None),
        observed_at=NOW,
        credentials=FixtureCredentials(),
        http_json=FixtureHttp([]),
    )
    assert snapshot.state is ProviderSourceState.NEEDS_SIGN_IN


def test_gemini_ineligible_tier_is_not_a_sign_in(tmp_path):
    """Live-verified: free-tier retirement surfaces as ineligibleTiers."""
    http = FixtureHttp(
        [
            {
                "allowedTiers": [],
                "ineligibleTiers": [
                    {
                        "reasonCode": "UNSUPPORTED_CLIENT",
                        "reasonMessage": "migrate to the Antigravity suite",
                        "tierId": "free-tier",
                    }
                ],
            }
        ]
    )
    snapshot = collect_gemini(
        preference("gemini"),
        home=_oauth_dir(tmp_path),
        observed_at=NOW,
        credentials=FixtureCredentials(),
        http_json=http,
    )
    assert snapshot.state is ProviderSourceState.UNAVAILABLE
    assert snapshot.reason_code == "code_assist_tier_ineligible"


def test_gemini_allowed_tier_without_project_is_actionable(tmp_path):
    http = FixtureHttp(
        [{"allowedTiers": [{"id": "standard-tier", "userDefinedCloudaicompanionProject": True}]}]
    )
    snapshot = collect_gemini(
        preference("gemini"),
        home=_oauth_dir(tmp_path),
        observed_at=NOW,
        credentials=FixtureCredentials(),
        http_json=http,
    )
    assert snapshot.state is ProviderSourceState.SOURCE_NOT_FOUND
    assert snapshot.reason_code == "code_assist_project_required"


def test_gemini_quota_403_is_a_license_state_not_auth(tmp_path):
    """Live-verified: PERMISSION_DENIED 'no valid license' is onboarding,
    so the row must not send the user to re-sign-in."""
    http = FixtureHttp([ProviderHttpError(403, "PERMISSION_DENIED")])
    snapshot = collect_gemini(
        preference("gemini", options={"project_id": "my-gcp-project"}),
        home=_oauth_dir(tmp_path),
        observed_at=NOW,
        credentials=FixtureCredentials(),
        http_json=http,
    )
    assert snapshot.state is ProviderSourceState.SOURCE_NOT_FOUND
    assert snapshot.reason_code == "quota_license_required"


def test_gemini_rate_limit_is_transient(tmp_path):
    http = FixtureHttp([ProviderHttpError(429, "RESOURCE_EXHAUSTED")])
    snapshot = collect_gemini(
        preference("gemini", options={"project_id": "my-gcp-project"}),
        home=_oauth_dir(tmp_path),
        observed_at=NOW,
        credentials=FixtureCredentials(),
        http_json=http,
    )
    assert snapshot.state is ProviderSourceState.RATE_LIMITED


def test_parse_gemini_usage_rejects_shapeless_payloads():
    with pytest.raises(ValueError):
        parse_gemini_usage({}, observed_at=NOW)
    with pytest.raises(ValueError):
        parse_gemini_usage("nope", observed_at=NOW)
    snapshot = parse_gemini_usage(
        {"buckets": [{"remainingFraction": 0.5}, "junk", {"modelId": "m"}]},
        observed_at=NOW,
    )
    assert [lane.model for lane in snapshot.lanes] == ["m"]
    assert snapshot.lanes[0].remaining_percent is None
