"""OpenCode's usage card reports only what a provider actually said.

OpenCode itself has no quota. The only real quota source is an OpenCode
Go subscription, read from opencode.ai with the Go API key. Before this
lane the collector invented a bindable "Free Tier" lane at 100 % and
dropped it when an error string showed up; these tests pin the honest
behaviour and the opt-in rules around the one outbound request.
"""

from __future__ import annotations

import json
import logging
import sqlite3
from dataclasses import replace
from datetime import datetime
from pathlib import Path

import pytest

from jrbar.core_projection import usage_document
from jrbar.provider_usage_collectors import (
    OPENCODE_GO_USAGE_URL,
    ProviderHttpError,
    collect_opencode,
)
from jrbar.provider_usage_parsers import parse_opencode_go_usage
from jrbar.provider_usage_platform import ProviderSourceState, most_constrained_lane
from jrbar.provider_usage_runtime import ProviderUsageService, ProviderUsageState
from jrbar.provider_usage_settings import default_provider_usage_settings

FIXTURE = Path(__file__).parent / "fixtures" / "provider_usage" / "opencode-go-usage.json"
OBSERVED = datetime.fromisoformat("2026-09-24T18:00:00+00:00").timestamp()
SYNTHETIC_KEY = "sk-synthetic-opencode-go-0000"


class FakeHttp:
    def __init__(self, response):
        self.response = response
        self.calls: list[tuple[str, str, dict]] = []

    def __call__(self, method, url, *, headers=None, body=None, timeout=20.0):
        self.calls.append((method, url, dict(headers or {})))
        if isinstance(self.response, Exception):
            raise self.response
        return self.response


def _preference(**options):
    pref = default_provider_usage_settings().preference("opencode")
    for key, value in options.items():
        pref = pref.with_option(key, value)
    return pref


def _data_root(home: Path) -> Path:
    root = home / ".local" / "share" / "opencode"
    root.mkdir(parents=True, exist_ok=True)
    return root


def _write_auth(root: Path, document: dict) -> None:
    (root / "auth.json").write_text(json.dumps(document), encoding="utf-8")


def _write_db(root: Path, *, limit_error_at: float | None = None) -> None:
    con = sqlite3.connect(root / "opencode.db")
    con.execute("CREATE TABLE session (tokens_input INT, tokens_output INT, model TEXT)")
    con.execute("INSERT INTO session VALUES (500, 100, 'muse-spark')")
    con.execute("CREATE TABLE message (id TEXT, session_id TEXT, time_created INT, data TEXT)")
    if limit_error_at is not None:
        con.execute(
            "INSERT INTO message VALUES ('m1', 's1', ?, ?)",
            (int(limit_error_at * 1000), json.dumps({"error": {"type": "FreeUsageLimitError"}})),
        )
    con.commit()
    con.close()


def _fixture() -> dict:
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


def test_recorded_fixture_gives_three_lanes_two_bindable() -> None:
    snapshot = parse_opencode_go_usage(_fixture(), observed_at=OBSERVED)

    assert [lane.lane_id for lane in snapshot.lanes] == ["go-rolling", "go-weekly", "go-monthly"]
    rolling, weekly, monthly = snapshot.lanes
    assert rolling.remaining_percent == pytest.approx(57.5)
    assert weekly.remaining_percent == pytest.approx(82.0)
    assert monthly.remaining_percent == pytest.approx(92.75)
    assert (rolling.bindable, weekly.bindable, monthly.bindable) == (True, True, False)
    assert rolling.reset_at == datetime.fromisoformat("2026-09-24T21:40:00+00:00").timestamp()
    assert {lane.source_id for lane in snapshot.lanes} == {"opencode-go-api"}
    # The monthly figure is detail: it can never be the lane that drives
    # the lights, even when it is the lowest.
    tight = replace(
        snapshot,
        lanes=(rolling, weekly, replace(monthly, remaining_percent=1.0)),
    )
    assert most_constrained_lane(tight).lane_id == "go-rolling"


def test_collector_reads_the_go_key_from_auth_json_and_keeps_tokens(tmp_path: Path) -> None:
    root = _data_root(tmp_path)
    _write_auth(root, {"opencode-go": {"type": "api", "key": SYNTHETIC_KEY}, "google": {"type": "api", "key": "x"}})
    _write_db(root)
    http = FakeHttp(_fixture())

    snapshot = collect_opencode(_preference(), observed_at=OBSERVED, home=tmp_path, env={}, http_json=http)

    assert snapshot.state is ProviderSourceState.READY
    assert len(snapshot.lanes) == 3
    assert snapshot.account_plan == "Go"
    assert (snapshot.input_tokens, snapshot.output_tokens) == (500, 100)
    assert http.calls == [("GET", OPENCODE_GO_USAGE_URL, {"Authorization": f"Bearer {SYNTHETIC_KEY}"})]


def test_forbidden_means_a_zen_key_without_go_and_gives_no_lane(tmp_path: Path) -> None:
    root = _data_root(tmp_path)
    _write_auth(root, {"opencode-go": {"type": "api", "key": SYNTHETIC_KEY}})
    _write_db(root)

    snapshot = collect_opencode(
        _preference(),
        observed_at=OBSERVED,
        home=tmp_path,
        env={},
        http_json=FakeHttp(ProviderHttpError(403, "http_error")),
    )

    assert snapshot.state is ProviderSourceState.UNSUPPORTED
    assert snapshot.reason_code == "opencode_go_not_subscribed"
    assert snapshot.lanes == ()
    assert snapshot.input_tokens == 500


def test_no_key_gives_no_lane_and_no_quota_source(tmp_path: Path) -> None:
    root = _data_root(tmp_path)
    # Other providers' sign-ins are not an OpenCode quota source.
    _write_auth(root, {"github-copilot": {"type": "oauth", "access": "x"}, "google": {"type": "api", "key": "y"}})
    _write_db(root)
    http = FakeHttp(AssertionError("no key must mean no request"))

    snapshot = collect_opencode(_preference(), observed_at=OBSERVED, home=tmp_path, env={}, http_json=http)

    assert http.calls == []
    assert snapshot.state is ProviderSourceState.UNSUPPORTED
    assert snapshot.reason_code == "opencode_no_quota_source"
    assert snapshot.lanes == ()
    assert snapshot.account_label is None
    assert (snapshot.input_tokens, snapshot.output_tokens, snapshot.model_count) == (500, 100, 1)
    document = usage_document(ProviderUsageState((snapshot,), OBSERVED, None, False))
    row = document["providers"][0]
    assert row["quota_source"] is False
    assert row["windows"] == []
    assert row["constrained"] is None


def test_xdg_data_home_is_honoured(tmp_path: Path) -> None:
    xdg = tmp_path / "xdg-data"
    root = xdg / "opencode"
    root.mkdir(parents=True)
    _write_auth(root, {"opencode-go": {"type": "api", "key": SYNTHETIC_KEY}})
    # The default location holds nothing: only the XDG root has data.
    http = FakeHttp(_fixture())

    snapshot = collect_opencode(
        _preference(),
        observed_at=OBSERVED,
        home=tmp_path / "home",
        env={"XDG_DATA_HOME": str(xdg)},
        http_json=http,
    )

    assert snapshot.state is ProviderSourceState.READY
    assert len(http.calls) == 1

    # A relative XDG_DATA_HOME is ignored, as the spec says.
    missing = collect_opencode(
        _preference(),
        observed_at=OBSERVED,
        home=tmp_path / "home",
        env={"XDG_DATA_HOME": "relative/xdg"},
        http_json=FakeHttp(AssertionError("unexpected request")),
    )
    assert missing.state is ProviderSourceState.SOURCE_NOT_FOUND


def test_environment_key_is_the_fallback(tmp_path: Path) -> None:
    http = FakeHttp(_fixture())

    snapshot = collect_opencode(
        _preference(),
        observed_at=OBSERVED,
        home=tmp_path,
        env={"OPENCODE_API_KEY": SYNTHETIC_KEY},
        http_json=http,
    )

    assert snapshot.state is ProviderSourceState.READY
    assert http.calls[0][2]["Authorization"] == f"Bearer {SYNTHETIC_KEY}"


def test_go_usage_off_makes_no_request_even_with_a_key(tmp_path: Path) -> None:
    root = _data_root(tmp_path)
    _write_auth(root, {"opencode-go": {"type": "api", "key": SYNTHETIC_KEY}})
    http = FakeHttp(AssertionError("go_usage=off must not reach opencode.ai"))

    snapshot = collect_opencode(
        _preference(go_usage="off"),
        observed_at=OBSERVED,
        home=tmp_path,
        env={"OPENCODE_API_KEY": SYNTHETIC_KEY},
        http_json=http,
    )

    assert http.calls == []
    assert snapshot.state is ProviderSourceState.UNSUPPORTED
    assert snapshot.lanes == ()


def test_a_disabled_provider_makes_no_request_even_with_a_key(tmp_path: Path) -> None:
    root = _data_root(tmp_path)
    _write_auth(root, {"opencode-go": {"type": "api", "key": SYNTHETIC_KEY}})
    http = FakeHttp(AssertionError("a disabled provider must not reach opencode.ai"))
    settings = default_provider_usage_settings().with_enabled("opencode", False)
    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={
            "opencode": lambda preference, home, observed, _credentials: collect_opencode(
                preference, observed_at=observed, home=home, env={}, http_json=http
            )
        },
        credentials=object(),
        home=tmp_path,
        clock=lambda: OBSERVED,
        incident_lookup=lambda *_args: None,
    )

    result = service.refresh_now(providers=("opencode",), force=True)

    assert http.calls == []
    assert result.by_provider("opencode").state is ProviderSourceState.DISABLED


def test_the_key_never_reaches_the_snapshot_or_the_log(tmp_path: Path, caplog) -> None:
    caplog.set_level(logging.DEBUG)
    root = _data_root(tmp_path)
    _write_auth(root, {"opencode-go": {"type": "api", "key": SYNTHETIC_KEY}})
    outcomes = [
        _fixture(),
        ProviderHttpError(403, "http_error"),
        ProviderHttpError(401, "http_error"),
        ProviderHttpError(0, "network_error"),
        {"unexpected": True},
    ]
    for outcome in outcomes:
        snapshot = collect_opencode(
            _preference(),
            observed_at=OBSERVED,
            home=tmp_path,
            env={},
            http_json=FakeHttp(outcome),
        )
        document = usage_document(ProviderUsageState((snapshot,), OBSERVED, None, False))
        assert SYNTHETIC_KEY not in repr(snapshot)
        assert SYNTHETIC_KEY not in json.dumps(document)
    assert SYNTHETIC_KEY not in caplog.text


def test_an_observed_limit_error_is_an_incident_never_a_lane(tmp_path: Path) -> None:
    root = _data_root(tmp_path)
    _write_db(root, limit_error_at=OBSERVED - 600)

    snapshot = collect_opencode(
        _preference(),
        observed_at=OBSERVED,
        home=tmp_path,
        env={},
        http_json=FakeHttp(AssertionError("no key, no request")),
    )

    assert snapshot.lanes == ()
    assert snapshot.state is ProviderSourceState.UNSUPPORTED
    assert snapshot.incident == "OpenCode: a usage limit was hit 10 min ago"


def test_unsupported_replaces_old_lanes_instead_of_going_stale(tmp_path: Path) -> None:
    """A store written by the old collector held a READY "Free Tier" lane.
    After the upgrade that lane must disappear, not linger as stale."""
    settings = default_provider_usage_settings()
    fabricated = parse_opencode_go_usage(_fixture(), observed_at=OBSERVED - 60)
    root = _data_root(tmp_path)
    _write_db(root)
    service = ProviderUsageService(
        settings_loader=lambda: settings,
        collectors={
            "opencode": lambda preference, home, observed, _credentials: collect_opencode(
                preference, observed_at=observed, home=home, env={}, http_json=FakeHttp({})
            )
        },
        credentials=object(),
        home=tmp_path,
        clock=lambda: OBSERVED,
        state_loader=lambda: ProviderUsageState((fabricated,), OBSERVED - 60, None, False),
        incident_lookup=lambda *_args: None,
    )

    result = service.refresh_now(providers=("opencode",), force=True)

    current = result.by_provider("opencode")
    assert current.state is ProviderSourceState.UNSUPPORTED
    assert current.lanes == ()
